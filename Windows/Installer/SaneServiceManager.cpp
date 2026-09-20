#include <winsock2.h>
#include <ws2ipdef.h>
#include <windows.h>
#include <winsvc.h>
#include <iphlpapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <strsafe.h>

#include <cwchar>
#include <string.h>
#include <string>
#include <vector>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "shell32.lib")

namespace
{
    const wchar_t kServiceName[] = L"GeniusColorPage-HR7-SANE";
    const wchar_t kServiceDisplayName[] = L"Genius ColorPage HR7 SANE bridge";
    const wchar_t kRegistryPath[] = L"SOFTWARE\\Genius\\ColorPage-HR7\\SANE";
    const wchar_t kVersionValue[] = L"InstalledVersion";
    const wchar_t kManagedValue[] = L"ManagedByBundle";
    const wchar_t kVersion[] = L"1.0.0.1";
    const DWORD kServicePort = 6566;
    const wchar_t kLegacyServiceDisplayName[] = L"Genius ColorPage HR7 SANE";
    const wchar_t kLegacyServiceDescription[] = L"Local SANE bridge endpoint; listens on IPv4 loopback only.";

    std::wstring QuoteArgument(const std::wstring &argument)
    {
        std::wstring quoted(1, L'"');
        size_t slashes = 0;
        for (wchar_t character : argument)
        {
            if (character == L'\\')
            {
                ++slashes;
                continue;
            }
            if (character == L'"')
            {
                quoted.append(slashes * 2 + 1, L'\\');
                quoted.push_back(L'"');
                slashes = 0;
                continue;
            }
            quoted.append(slashes, L'\\');
            slashes = 0;
            quoted.push_back(character);
        }
        quoted.append(slashes * 2, L'\\');
        quoted.push_back(L'"');
        return quoted;
    }

    std::wstring FullPath(const std::wstring &path)
    {
        DWORD required = GetFullPathNameW(path.c_str(), 0, NULL, NULL);
        if (required == 0 || required > 32767) return std::wstring();
        std::vector<wchar_t> buffer(required + 1, L'\0');
        DWORD written = GetFullPathNameW(path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), NULL);
        return written != 0 && written < buffer.size() ? std::wstring(buffer.data()) : std::wstring();
    }

    std::wstring ExecutableFromCommandLine(const std::wstring &commandLine)
    {
        if (commandLine.empty()) return std::wstring();
        if (commandLine[0] == L'"')
        {
            size_t end = commandLine.find(L'"', 1);
            return end == std::wstring::npos ? std::wstring() : commandLine.substr(1, end - 1);
        }
        size_t end = commandLine.find_first_of(L" \t");
        return commandLine.substr(0, end);
    }

    bool QueryService(SC_HANDLE service, SERVICE_STATUS_PROCESS *status)
    {
        DWORD required = 0;
        return QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
            reinterpret_cast<BYTE *>(status), sizeof(*status), &required) != FALSE;
    }

    bool WaitForServiceState(SC_HANDLE service, DWORD desiredState, DWORD timeoutMs)
    {
        const ULONGLONG deadline = GetTickCount64() + timeoutMs;
        do
        {
            SERVICE_STATUS_PROCESS status = {};
            if (!QueryService(service, &status)) return false;
            if (status.dwCurrentState == desiredState) return true;
            if (status.dwWin32ExitCode != NO_ERROR && status.dwCurrentState == SERVICE_STOPPED)
            {
                SetLastError(status.dwWin32ExitCode);
                return false;
            }
            Sleep(250);
        } while (GetTickCount64() < deadline);
        SetLastError(ERROR_TIMEOUT);
        return false;
    }

    bool StopService(SC_HANDLE service)
    {
        SERVICE_STATUS_PROCESS status = {};
        if (!QueryService(service, &status)) return false;
        if (status.dwCurrentState == SERVICE_STOPPED) return true;
        SERVICE_STATUS ignored = {};
        if (!ControlService(service, SERVICE_CONTROL_STOP, &ignored) && GetLastError() != ERROR_SERVICE_NOT_ACTIVE)
            return false;
        return WaitForServiceState(service, SERVICE_STOPPED, 30000);
    }

    bool IsExpectedListenerProcess(DWORD processId, const std::wstring &expectedExecutable)
    {
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
        if (!process) return false;
        std::vector<wchar_t> image(32768, L'\0');
        DWORD length = static_cast<DWORD>(image.size());
        const bool queried = QueryFullProcessImageNameW(process, 0, image.data(), &length) != FALSE;
        CloseHandle(process);
        if (!queried || length == 0) return false;
        const std::wstring actual = FullPath(std::wstring(image.data(), length));
        const std::wstring expected = FullPath(expectedExecutable);
        return !actual.empty() && !expected.empty() && _wcsicmp(actual.c_str(), expected.c_str()) == 0;
    }

    bool WaitForPortTable(int family, DWORD *matchingRows, bool *onlyLoopback,
                          const std::wstring *expectedExecutable)
    {
        DWORD bytes = 0;
        DWORD result = GetExtendedTcpTable(NULL, &bytes, FALSE, family, TCP_TABLE_OWNER_PID_LISTENER, 0);
        if (result != ERROR_INSUFFICIENT_BUFFER && result != NO_ERROR)
        {
            SetLastError(result);
            return false;
        }
        std::vector<BYTE> buffer(bytes ? bytes : 1);
        result = GetExtendedTcpTable(buffer.data(), &bytes, FALSE, family, TCP_TABLE_OWNER_PID_LISTENER, 0);
        if (result != NO_ERROR)
        {
            SetLastError(result);
            return false;
        }

        if (family == AF_INET)
        {
            const MIB_TCPTABLE_OWNER_PID *table = reinterpret_cast<const MIB_TCPTABLE_OWNER_PID *>(buffer.data());
            for (DWORD index = 0; index < table->dwNumEntries; ++index)
            {
                const MIB_TCPROW_OWNER_PID &row = table->table[index];
                if (ntohs(static_cast<u_short>(row.dwLocalPort)) != kServicePort) continue;
                ++*matchingRows;
                if (row.dwLocalAddr != htonl(INADDR_LOOPBACK)) *onlyLoopback = false;
                if (expectedExecutable && !IsExpectedListenerProcess(row.dwOwningPid, *expectedExecutable))
                    *onlyLoopback = false;
            }
        }
        else if (family == AF_INET6)
        {
            const MIB_TCP6TABLE_OWNER_PID *table = reinterpret_cast<const MIB_TCP6TABLE_OWNER_PID *>(buffer.data());
            for (DWORD index = 0; index < table->dwNumEntries; ++index)
            {
                const MIB_TCP6ROW_OWNER_PID &row = table->table[index];
                if (ntohs(static_cast<u_short>(row.dwLocalPort)) != kServicePort) continue;
                ++*matchingRows;
                *onlyLoopback = false; // The product contract is a single IPv4 127.0.0.1 listener.
            }
        }
        return true;
    }

    bool HasOnlyProductLoopbackListener(const std::wstring &sanedExecutable)
    {
        DWORD matchingRows = 0;
        bool onlyLoopback = true;
        if (!WaitForPortTable(AF_INET, &matchingRows, &onlyLoopback, &sanedExecutable) ||
            !WaitForPortTable(AF_INET6, &matchingRows, &onlyLoopback, &sanedExecutable)) return false;
        return matchingRows == 1 && onlyLoopback;
    }

    bool NoListenerOnProductPort()
    {
        DWORD matchingRows = 0;
        bool onlyLoopback = true;
        return WaitForPortTable(AF_INET, &matchingRows, &onlyLoopback, NULL) &&
            WaitForPortTable(AF_INET6, &matchingRows, &onlyLoopback, NULL) && matchingRows == 0;
    }

    bool EnsureDirectory(const std::wstring &path)
    {
        if (!CreateDirectoryW(path.c_str(), NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
        const DWORD attributes = GetFileAttributesW(path.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        {
            SetLastError(ERROR_DIRECTORY);
            return false;
        }
        return true;
    }

    bool IsLoopbackOnlySanedConfig(const std::wstring &path)
    {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (file == INVALID_HANDLE_VALUE) return false;
        BY_HANDLE_FILE_INFORMATION info = {};
        LARGE_INTEGER size = {};
        const bool safeFile = GetFileInformationByHandle(file, &info) &&
            !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
            GetFileSizeEx(file, &size) && size.QuadPart >= 0 && size.QuadPart <= 65536;
        if (!safeFile)
        {
            CloseHandle(file);
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        std::vector<char> contents(static_cast<size_t>(size.QuadPart) + 1, '\0');
        DWORD bytesRead = 0;
        const BOOL read = ReadFile(file, contents.data(), static_cast<DWORD>(size.QuadPart), &bytesRead, NULL);
        CloseHandle(file);
        if (!read || bytesRead != static_cast<DWORD>(size.QuadPart)) return false;

        size_t allowedEntries = 0;
        size_t offset = 0;
        while (offset < bytesRead)
        {
            size_t end = offset;
            while (end < bytesRead && contents[end] != '\r' && contents[end] != '\n') ++end;
            size_t lineEnd = end;
            for (size_t index = offset; index < end; ++index)
            {
                if (contents[index] == '#') { lineEnd = index; break; }
            }
            while (offset < lineEnd && (contents[offset] == ' ' || contents[offset] == '\t')) ++offset;
            while (lineEnd > offset && (contents[lineEnd - 1] == ' ' || contents[lineEnd - 1] == '\t')) --lineEnd;
            if (lineEnd > offset)
            {
                if (lineEnd - offset != strlen("127.0.0.1") ||
                    memcmp(contents.data() + offset, "127.0.0.1", strlen("127.0.0.1")) != 0)
                {
                    SetLastError(ERROR_ACCESS_DENIED);
                    return false;
                }
                ++allowedEntries;
            }
            offset = end;
            while (offset < bytesRead && (contents[offset] == '\r' || contents[offset] == '\n')) ++offset;
        }
        if (allowedEntries != 1)
        {
            SetLastError(ERROR_ACCESS_DENIED);
            return false;
        }
        return true;
    }

    bool IsExactActiveConfigLines(const std::wstring &path,
                                  const std::vector<std::string> &expectedLines)
    {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (file == INVALID_HANDLE_VALUE) return false;
        BY_HANDLE_FILE_INFORMATION info = {};
        LARGE_INTEGER size = {};
        const bool safeFile = GetFileInformationByHandle(file, &info) &&
            !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
            GetFileSizeEx(file, &size) && size.QuadPart >= 0 && size.QuadPart <= 65536;
        if (!safeFile)
        {
            CloseHandle(file);
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        std::vector<char> contents(static_cast<size_t>(size.QuadPart) + 1, '\0');
        DWORD bytesRead = 0;
        const BOOL read = ReadFile(file, contents.data(), static_cast<DWORD>(size.QuadPart), &bytesRead, NULL);
        CloseHandle(file);
        if (!read || bytesRead != static_cast<DWORD>(size.QuadPart)) return false;

        std::vector<std::string> activeLines;
        size_t offset = 0;
        while (offset < bytesRead)
        {
            size_t end = offset;
            while (end < bytesRead && contents[end] != '\r' && contents[end] != '\n') ++end;
            size_t lineEnd = end;
            for (size_t index = offset; index < end; ++index)
            {
                if (contents[index] == '#') { lineEnd = index; break; }
            }
            size_t lineStart = offset;
            while (lineStart < lineEnd && (contents[lineStart] == ' ' || contents[lineStart] == '\t')) ++lineStart;
            while (lineEnd > lineStart && (contents[lineEnd - 1] == ' ' || contents[lineEnd - 1] == '\t')) --lineEnd;
            if (lineEnd > lineStart)
                activeLines.emplace_back(contents.data() + lineStart, lineEnd - lineStart);
            offset = end;
            while (offset < bytesRead && (contents[offset] == '\r' || contents[offset] == '\n')) ++offset;
        }
        if (activeLines != expectedLines)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        return true;
    }

    bool RunCygrunsrv(const std::wstring &runner, const std::vector<std::wstring> &arguments)
    {
        std::wstring commandLine = QuoteArgument(runner);
        for (const std::wstring &argument : arguments)
        {
            commandLine.push_back(L' ');
            commandLine += QuoteArgument(argument);
        }
        std::vector<wchar_t> writable(commandLine.begin(), commandLine.end());
        writable.push_back(L'\0');
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(runner.c_str(), writable.data(), NULL, NULL, FALSE,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, NULL, NULL, &startup, &process))
        {
            return false;
        }
        CloseHandle(process.hThread);
        DWORD wait = WaitForSingleObject(process.hProcess, 120000);
        DWORD exitCode = ERROR_TIMEOUT;
        if (wait == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &exitCode);
        else if (wait == WAIT_FAILED) exitCode = GetLastError();
        if (wait != WAIT_OBJECT_0) TerminateProcess(process.hProcess, ERROR_TIMEOUT);
        CloseHandle(process.hProcess);
        if (wait != WAIT_OBJECT_0 || exitCode != 0)
        {
            SetLastError(wait == WAIT_OBJECT_0 ? ERROR_INSTALL_FAILURE : exitCode);
            return false;
        }
        return true;
    }

    bool QueryServiceRunner(SC_HANDLE service, std::wstring *runnerPath)
    {
        DWORD bytes = 0;
        QueryServiceConfigW(service, NULL, 0, &bytes);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes < sizeof(QUERY_SERVICE_CONFIGW)) return false;
        std::vector<BYTE> buffer(bytes);
        QUERY_SERVICE_CONFIGW *config = reinterpret_cast<QUERY_SERVICE_CONFIGW *>(buffer.data());
        if (!QueryServiceConfigW(service, config, bytes, &bytes)) return false;
        *runnerPath = ExecutableFromCommandLine(config->lpBinaryPathName);
        return !runnerPath->empty();
    }

    bool QueryServiceSettings(SC_HANDLE service, std::wstring *runnerPath,
                              std::wstring *displayName, std::wstring *accountName,
                              DWORD *serviceType, DWORD *startType)
    {
        DWORD bytes = 0;
        QueryServiceConfigW(service, NULL, 0, &bytes);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes < sizeof(QUERY_SERVICE_CONFIGW)) return false;
        std::vector<BYTE> buffer(bytes);
        QUERY_SERVICE_CONFIGW *config = reinterpret_cast<QUERY_SERVICE_CONFIGW *>(buffer.data());
        if (!QueryServiceConfigW(service, config, bytes, &bytes)) return false;
        *runnerPath = ExecutableFromCommandLine(config->lpBinaryPathName ? config->lpBinaryPathName : L"");
        *displayName = config->lpDisplayName ? config->lpDisplayName : L"";
        *accountName = config->lpServiceStartName ? config->lpServiceStartName : L"";
        *serviceType = config->dwServiceType;
        *startType = config->dwStartType;
        return !runnerPath->empty();
    }

    bool HasServiceDescription(SC_HANDLE service, const wchar_t *expectedDescription)
    {
        DWORD bytes = 0;
        QueryServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, NULL, 0, &bytes);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes < sizeof(SERVICE_DESCRIPTIONW)) return false;
        std::vector<BYTE> buffer(bytes);
        if (!QueryServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, buffer.data(), bytes, &bytes)) return false;
        const SERVICE_DESCRIPTIONW *description = reinterpret_cast<const SERVICE_DESCRIPTIONW *>(buffer.data());
        return description->lpDescription && _wcsicmp(description->lpDescription, expectedDescription) == 0;
    }

    bool ReadRegistryStringValue(const std::wstring &keyPath, const wchar_t *valueName,
                                 std::wstring *value)
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath.c_str(), 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        DWORD type = 0;
        DWORD bytes = 0;
        status = RegQueryValueExW(key, valueName, NULL, &type, NULL, &bytes);
        if (status != ERROR_SUCCESS || type != REG_SZ || bytes < sizeof(wchar_t) ||
            bytes > 65536 || (bytes % sizeof(wchar_t)) != 0)
        {
            RegCloseKey(key);
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }
        std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
        status = RegQueryValueExW(key, valueName, NULL, &type,
            reinterpret_cast<BYTE *>(buffer.data()), &bytes);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS || type != REG_SZ)
        {
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }
        *value = buffer.data();
        return true;
    }

    bool RegistryKeyHasShape(const std::wstring &keyPath, DWORD expectedSubKeys, DWORD expectedValues)
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath.c_str(), 0,
            KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS | KEY_WOW64_64KEY, &key);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        DWORD subKeys = 0;
        DWORD values = 0;
        status = RegQueryInfoKeyW(key, NULL, NULL, NULL, &subKeys, NULL, NULL,
            &values, NULL, NULL, NULL, NULL);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        if (subKeys != expectedSubKeys || values != expectedValues)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        return true;
    }

    bool ReadRegistryDwordValue(const std::wstring &keyPath, const wchar_t *valueName, DWORD expectedValue)
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath.c_str(), 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        DWORD type = 0;
        DWORD bytes = sizeof(DWORD);
        DWORD value = 0;
        status = RegQueryValueExW(key, valueName, NULL, &type, reinterpret_cast<BYTE *>(&value), &bytes);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS || type != REG_DWORD || bytes != sizeof(DWORD))
        {
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }
        if (value != expectedValue)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        return true;
    }

    bool IsRegularFile(const std::wstring &path)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES &&
            !(attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
    }

    bool IsCompatibleLegacyService(SC_HANDLE service, std::wstring *sanedExecutable)
    {
        wchar_t commonAppData[MAX_PATH] = {};
        if (FAILED(SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL, SHGFP_TYPE_CURRENT, commonAppData)))
            return false;
        const std::wstring legacyRoot = std::wstring(commonAppData) +
            L"\\GeniusColorPage-HR7-SANE\\cygwin";
        const std::wstring legacyRunner = legacyRoot + L"\\bin\\cygrunsrv.exe";
        const std::wstring legacySaned = legacyRoot + L"\\opt\\genius-hr7\\sbin\\saned.exe";
        const std::wstring configRoot = legacyRoot + L"\\opt\\genius-hr7\\etc\\sane.d";
        const std::wstring parametersPath = std::wstring(L"SYSTEM\\CurrentControlSet\\Services\\") +
            kServiceName + L"\\Parameters";
        const std::wstring environmentPath = parametersPath + L"\\Environment";

        std::wstring actualRunner;
        std::wstring displayName;
        std::wstring accountName;
        DWORD serviceType = 0;
        DWORD startType = 0;
        if (!QueryServiceSettings(service, &actualRunner, &displayName, &accountName,
                &serviceType, &startType) ||
            _wcsicmp(FullPath(actualRunner).c_str(), FullPath(legacyRunner).c_str()) != 0 ||
            _wcsicmp(displayName.c_str(), kLegacyServiceDisplayName) != 0 ||
            _wcsicmp(accountName.c_str(), L"LocalSystem") != 0 ||
            serviceType != SERVICE_WIN32_OWN_PROCESS || startType != SERVICE_AUTO_START ||
            !HasServiceDescription(service, kLegacyServiceDescription) ||
            !IsRegularFile(legacyRunner) || !IsRegularFile(legacySaned) ||
            !IsLoopbackOnlySanedConfig(configRoot + L"\\saned.conf") ||
            !IsExactActiveConfigLines(configRoot + L"\\dll.conf", { "plustek" }) ||
            !IsExactActiveConfigLines(configRoot + L"\\plustek.conf",
                { "[usb] 0x0458 0x2013", "device auto" }) ||
            !RegistryKeyHasShape(parametersPath, 1, 7) ||
            !RegistryKeyHasShape(environmentPath, 0, 3))
        {
            return false;
        }

        std::wstring configuredPath;
        if (!ReadRegistryStringValue(parametersPath, L"AppPath", &configuredPath) ||
            _wcsicmp(FullPath(configuredPath).c_str(), FullPath(legacySaned).c_str()) != 0)
            return false;
        std::wstring value;
        if (!ReadRegistryStringValue(parametersPath, L"AppArgs", &value) ||
            value != L"-l -b 127.0.0.1 -p 6566 -e") return false;
        if (!ReadRegistryStringValue(parametersPath, L"StdOut", &value) || value != L"/var/log/hr7-saned.log") return false;
        if (!ReadRegistryStringValue(parametersPath, L"StdErr", &value) || value != L"/var/log/hr7-saned.log") return false;
        if (!ReadRegistryDwordValue(parametersPath, L"Shutdown", 1) ||
            !ReadRegistryDwordValue(parametersPath, L"Timeout", 30) ||
            !ReadRegistryDwordValue(parametersPath, L"StopTimeout", 30)) return false;

        if (!ReadRegistryStringValue(environmentPath, L"PATH", &value) ||
            value != L"/opt/genius-hr7/bin:/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane:/usr/bin:/bin") return false;
        if (!ReadRegistryStringValue(environmentPath, L"LD_LIBRARY_PATH", &value) ||
            value != L"/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane") return false;
        if (!ReadRegistryStringValue(environmentPath, L"SANE_CONFIG_DIR", &value) ||
            value != L"/opt/genius-hr7/etc/sane.d") return false;

        SERVICE_STATUS_PROCESS status = {};
        if (!QueryService(service, &status) || status.dwCurrentState != SERVICE_RUNNING ||
            !HasOnlyProductLoopbackListener(legacySaned)) return false;
        *sanedExecutable = legacySaned;
        return true;
    }

    bool IsOwnedService(SC_HANDLE service, const std::wstring &expectedRunner)
    {
        std::wstring actual;
        if (!QueryServiceRunner(service, &actual)) return false;
        const std::wstring normalizedExpected = FullPath(expectedRunner);
        const std::wstring normalizedActual = FullPath(actual);
        return !normalizedExpected.empty() && !normalizedActual.empty() &&
            _wcsicmp(normalizedExpected.c_str(), normalizedActual.c_str()) == 0;
    }

    bool SetInstalledMarker(bool managedByBundle)
    {
        HKEY key = NULL;
        LONG status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0, NULL, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &key, NULL);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        DWORD managed = managedByBundle ? 1U : 0U;
        status = RegSetValueExW(key, kManagedValue, 0, REG_DWORD,
            reinterpret_cast<const BYTE *>(&managed), sizeof(managed));
        if (status == ERROR_SUCCESS)
        {
            status = RegSetValueExW(key, kVersionValue, 0, REG_SZ,
                reinterpret_cast<const BYTE *>(kVersion),
                static_cast<DWORD>((wcslen(kVersion) + 1) * sizeof(wchar_t)));
        }
        RegCloseKey(key);
        if (status != ERROR_SUCCESS) SetLastError(static_cast<DWORD>(status));
        return status == ERROR_SUCCESS;
    }

    bool ClearInstalledMarker()
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        LONG versionStatus = RegDeleteValueW(key, kVersionValue);
        LONG managedStatus = RegDeleteValueW(key, kManagedValue);
        RegCloseKey(key);
        if (versionStatus != ERROR_SUCCESS && versionStatus != ERROR_FILE_NOT_FOUND)
            status = versionStatus;
        else if (managedStatus != ERROR_SUCCESS && managedStatus != ERROR_FILE_NOT_FOUND)
            status = managedStatus;
        else
            status = ERROR_SUCCESS;
        if (status != ERROR_SUCCESS) SetLastError(static_cast<DWORD>(status));
        return status == ERROR_SUCCESS;
    }

    bool HasInstalledMarker(bool *installed, bool *managedByBundle)
    {
        *installed = false;
        *managedByBundle = true; // Older packages did not record this bit; retain ownership checking.
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }

        wchar_t version[64] = {};
        DWORD type = 0;
        DWORD bytes = sizeof(version);
        status = RegQueryValueExW(key, kVersionValue, NULL, &type,
            reinterpret_cast<BYTE *>(version), &bytes);
        if (status == ERROR_FILE_NOT_FOUND)
        {
            RegCloseKey(key);
            return true;
        }
        if (status != ERROR_SUCCESS)
        {
            RegCloseKey(key);
            SetLastError(static_cast<DWORD>(status));
            return false;
        }
        if (type != REG_SZ || bytes < sizeof(wchar_t) || bytes > sizeof(version))
        {
            RegCloseKey(key);
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        *installed = version[0] != L'\0';
        if (*installed)
        {
            DWORD managed = 0;
            DWORD managedType = 0;
            DWORD managedBytes = sizeof(managed);
            status = RegQueryValueExW(key, kManagedValue, NULL, &managedType,
                reinterpret_cast<BYTE *>(&managed), &managedBytes);
            if (status == ERROR_SUCCESS)
            {
                if (managedType != REG_DWORD || managedBytes != sizeof(managed) || managed > 1)
                {
                    RegCloseKey(key);
                    SetLastError(ERROR_INVALID_DATA);
                    return false;
                }
                *managedByBundle = managed != 0;
            }
            else if (status != ERROR_FILE_NOT_FOUND)
            {
                RegCloseKey(key);
                SetLastError(static_cast<DWORD>(status));
                return false;
            }
        }
        RegCloseKey(key);
        return true;
    }

    bool InstallSaneService(const std::wstring &installFolder)
    {
        const std::wstring runtime = installFolder + L"\\runtime";
        const std::wstring runner = runtime + L"\\bin\\cygrunsrv.exe";
        const std::wstring saned = runtime + L"\\opt\\genius-hr7\\sbin\\saned.exe";
        const std::wstring config = runtime + L"\\opt\\genius-hr7\\etc\\sane.d\\saned.conf";
        const std::wstring log = runtime + L"\\var\\log\\hr7-saned.log";
        if (GetFileAttributesW(runner.c_str()) == INVALID_FILE_ATTRIBUTES ||
            GetFileAttributesW(saned.c_str()) == INVALID_FILE_ATTRIBUTES ||
            GetFileAttributesW(config.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            SetLastError(ERROR_FILE_NOT_FOUND);
            return false;
        }
        if (!IsLoopbackOnlySanedConfig(config)) return false;

        const std::wstring logDirectory = runtime + L"\\var\\log";

        SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
        if (!manager) return false;
        SC_HANDLE service = OpenServiceW(manager, kServiceName,
            SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG | SERVICE_START | SERVICE_STOP | DELETE);
        bool created = false;
        bool wasRunning = false;
        if (service)
        {
            if (!IsOwnedService(service, runner))
            {
                std::wstring legacySaned;
                const bool compatibleLegacy = IsCompatibleLegacyService(service, &legacySaned);
                CloseServiceHandle(service);
                CloseServiceHandle(manager);
                if (compatibleLegacy)
                {
                    if (!SetInstalledMarker(false)) return false;
                    const wchar_t message[] =
                        L"A verified Genius HR7 SANE service is already running on this PC. It is restricted to "
                        L"127.0.0.1 and will be left unchanged; setup will use it for local WIA/TWAIN access. "
                        L"Removing this installer later will keep that pre-existing service.\n\n"
                        L"Um servico SANE compativel do Genius HR7 ja esta ativo neste computador. Ele esta "
                        L"restrito a 127.0.0.1 e nao sera alterado; a instalacao o utilizara para acesso WIA/TWAIN. "
                        L"A desinstalacao deste pacote mantera esse servico pre-existente.";
                    MessageBoxW(NULL, message, L"Genius ColorPage-HR7 — existing SANE service",
                        MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
                    return true;
                }
                SetLastError(ERROR_SERVICE_EXISTS);
                return false;
            }
            if (!EnsureDirectory(runtime + L"\\var") || !EnsureDirectory(logDirectory))
            {
                CloseServiceHandle(service);
                CloseServiceHandle(manager);
                return false;
            }
            SERVICE_STATUS_PROCESS previousStatus = {};
            if (!QueryService(service, &previousStatus))
            {
                CloseServiceHandle(service);
                CloseServiceHandle(manager);
                return false;
            }
            wasRunning = previousStatus.dwCurrentState == SERVICE_RUNNING;
            if (!StopService(service))
            {
                CloseServiceHandle(service);
                CloseServiceHandle(manager);
                return false;
            }
        }
        else if (GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST)
        {
            if (!NoListenerOnProductPort())
            {
                CloseServiceHandle(manager);
                SetLastError(ERROR_ADDRESS_ALREADY_ASSOCIATED);
                return false;
            }
            if (!EnsureDirectory(runtime + L"\\var") || !EnsureDirectory(logDirectory))
            {
                CloseServiceHandle(manager);
                return false;
            }
            std::vector<std::wstring> arguments = {
                L"--install", kServiceName,
                L"--disp", kServiceDisplayName,
                L"--desc", L"Local SANE bridge; listens only on IPv4 loopback 127.0.0.1:6566.",
                L"--path", saned,
                L"--args", L"-l -b 127.0.0.1 -p 6566 -e",
                L"--env", L"PATH=/opt/genius-hr7/bin:/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane:/usr/bin:/bin",
                L"--env", L"LD_LIBRARY_PATH=/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane",
                L"--env", L"SANE_CONFIG_DIR=/opt/genius-hr7/etc/sane.d",
                L"--stdout", L"/var/log/hr7-saned.log",
                L"--stderr", L"/var/log/hr7-saned.log",
                L"--type", L"auto",
                L"--timeout", L"30",
                L"--stop-timeout", L"30",
                L"--shutdown"
            };
            if (!RunCygrunsrv(runner, arguments))
            {
                CloseServiceHandle(manager);
                return false;
            }
            created = true;
            service = OpenServiceW(manager, kServiceName,
                SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG | SERVICE_START | SERVICE_STOP | DELETE);
            if (!service)
            {
                DWORD error = GetLastError();
                RunCygrunsrv(runner, { L"--remove", kServiceName });
                CloseServiceHandle(manager);
                SetLastError(error);
                return false;
            }
        }
        else
        {
            DWORD error = GetLastError();
            CloseServiceHandle(manager);
            SetLastError(error);
            return false;
        }

        SERVICE_STATUS_PROCESS status = {};
        if (!QueryService(service, &status))
        {
            DWORD error = GetLastError();
            if (created) RunCygrunsrv(runner, { L"--remove", kServiceName });
            else if (wasRunning) StartServiceW(service, 0, NULL);
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            SetLastError(error);
            return false;
        }
        if (status.dwCurrentState != SERVICE_RUNNING && !StartServiceW(service, 0, NULL) &&
            GetLastError() != ERROR_SERVICE_ALREADY_RUNNING)
        {
            DWORD error = GetLastError();
            if (created) { StopService(service); RunCygrunsrv(runner, { L"--remove", kServiceName }); }
            else if (wasRunning) StartServiceW(service, 0, NULL);
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            SetLastError(error);
            return false;
        }
        if (!WaitForServiceState(service, SERVICE_RUNNING, 30000))
        {
            DWORD error = GetLastError();
            if (created) { StopService(service); RunCygrunsrv(runner, { L"--remove", kServiceName }); }
            else if (wasRunning) StartServiceW(service, 0, NULL);
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            SetLastError(error);
            return false;
        }

        const ULONGLONG deadline = GetTickCount64() + 20000;
        bool listenerReady = false;
        do
        {
            if (HasOnlyProductLoopbackListener(saned)) { listenerReady = true; break; }
            Sleep(250);
        } while (GetTickCount64() < deadline);
        if (!listenerReady)
        {
            DWORD error = ERROR_ADDRESS_NOT_ASSOCIATED;
            if (created)
            {
                StopService(service);
                RunCygrunsrv(runner, { L"--remove", kServiceName });
            }
            else if (wasRunning)
            {
                StartServiceW(service, 0, NULL);
            }
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            SetLastError(error);
            return false;
        }

        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        if (SetInstalledMarker(true)) return true;
        DWORD error = GetLastError();
        if (created)
        {
            SC_HANDLE cleanupManager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
            if (cleanupManager)
            {
                SC_HANDLE cleanupService = OpenServiceW(cleanupManager, kServiceName,
                    SERVICE_QUERY_STATUS | SERVICE_STOP | DELETE);
                if (cleanupService)
                {
                    StopService(cleanupService);
                    CloseServiceHandle(cleanupService);
                    RunCygrunsrv(runner, { L"--remove", kServiceName });
                }
                CloseServiceHandle(cleanupManager);
            }
        }
        else if (wasRunning)
        {
            SC_HANDLE cleanupManager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
            if (cleanupManager)
            {
                SC_HANDLE cleanupService = OpenServiceW(cleanupManager, kServiceName, SERVICE_START);
                if (cleanupService) { StartServiceW(cleanupService, 0, NULL); CloseServiceHandle(cleanupService); }
                CloseServiceHandle(cleanupManager);
            }
        }
        SetLastError(error);
        return false;
    }

    bool RemoveSaneService(const std::wstring &installFolder)
    {
        const std::wstring runner = installFolder + L"\\runtime\\bin\\cygrunsrv.exe";
        bool installed = false;
        bool managedByBundle = true;
        if (!HasInstalledMarker(&installed, &managedByBundle)) return false;
        if (!installed) return true;
        if (!managedByBundle) return ClearInstalledMarker();

        SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        if (!manager) return false;
        SC_HANDLE service = OpenServiceW(manager, kServiceName,
            SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG | SERVICE_STOP | DELETE);
        if (!service)
        {
            DWORD error = GetLastError();
            CloseServiceHandle(manager);
            if (error == ERROR_SERVICE_DOES_NOT_EXIST) return ClearInstalledMarker();
            SetLastError(error);
            return false;
        }
        if (!IsOwnedService(service, runner))
        {
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            SetLastError(ERROR_SERVICE_EXISTS);
            return false;
        }
        if (!StopService(service))
        {
            CloseServiceHandle(service);
            CloseServiceHandle(manager);
            return false;
        }
        CloseServiceHandle(service);
        if (!RunCygrunsrv(runner, { L"--remove", kServiceName }))
        {
            CloseServiceHandle(manager);
            return false;
        }
        CloseServiceHandle(manager);
        return ClearInstalledMarker();
    }

    bool IsAdministrator()
    {
        HANDLE token = NULL;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
        TOKEN_ELEVATION elevation = {};
        DWORD size = 0;
        bool elevated = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size) &&
            elevation.TokenIsElevated != 0;
        CloseHandle(token);
        return elevated;
    }

    void ShowFailure(const wchar_t *operation)
    {
        DWORD error = GetLastError();
        wchar_t message[512] = {};
        StringCchPrintfW(message, ARRAYSIZE(message),
            L"%ls failed with Windows error %lu (0x%08lx).\n\n"
            L"The installer requires exactly one listener on 127.0.0.1:6566 and creates no firewall rule.",
            operation, error, error);
        MessageBoxW(NULL, message, L"Genius ColorPage-HR7 SANE service", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    }
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    if (!IsAdministrator()) return ERROR_ELEVATION_REQUIRED;
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 3 || (_wcsicmp(argv[1], L"install") != 0 && _wcsicmp(argv[1], L"remove") != 0))
    {
        if (argv) LocalFree(argv);
        MessageBoxW(NULL, L"This action is invoked by the Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 SANE service", MB_OK | MB_ICONERROR);
        return ERROR_INVALID_PARAMETER;
    }
    std::wstring installFolder = FullPath(argv[2]);
    const bool installing = _wcsicmp(argv[1], L"install") == 0;
    LocalFree(argv);
    if (installFolder.empty()) { SetLastError(ERROR_INVALID_NAME); ShowFailure(L"Resolve installation directory"); return ERROR_INVALID_NAME; }
    const bool ok = installing ? InstallSaneService(installFolder) : RemoveSaneService(installFolder);
    if (!ok)
    {
        DWORD error = GetLastError();
        ShowFailure(installing ? L"Install SANE service" : L"Remove SANE service");
        return error == ERROR_SUCCESS ? ERROR_INSTALL_FAILURE : error;
    }
    return ERROR_SUCCESS;
}
