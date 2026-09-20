#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>
#include <strsafe.h>

#include <algorithm>
#include <initializer_list>
#include <cwchar>
#include <ctype.h>
#include <string.h>
#include <string>
#include <vector>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")

namespace
{
    const wchar_t kRegistryPath[] = L"SOFTWARE\\Genius\\ColorPage-HR7\\TWAIN";
    const wchar_t kVersionValue[] = L"InstalledVersion";
    const wchar_t kTargetsValue[] = L"ManagedConfigPaths";
    const wchar_t kVersion[] = L"1.0.0.1";
    const wchar_t kOwnershipFile[] = L"Ownership.txt";
    const wchar_t kOriginalFile[] = L"Original.ini";
    const wchar_t kInstalledFile[] = L"Installed.ini";
    const wchar_t kPresentState[] = L"HR7-TWAIN-CONFIG/1\r\nOriginal=present\r\n";
    const wchar_t kAbsentState[] = L"HR7-TWAIN-CONFIG/1\r\nOriginal=absent\r\n";

    std::wstring Join(const std::wstring &left, const wchar_t *right)
    {
        return left + L"\\" + right;
    }

    bool IsDirectory(const std::wstring &path)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES &&
            (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
    }

    bool EnsureDirectory(const std::wstring &path)
    {
        if (!CreateDirectoryW(path.c_str(), NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
        if (!IsDirectory(path)) { SetLastError(ERROR_DIRECTORY); return false; }
        return true;
    }

    bool IsRegularFileOrMissing(const std::wstring &path, bool *exists)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES)
        {
            const DWORD error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
            {
                *exists = false;
                return true;
            }
            return false;
        }
        if ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        *exists = true;
        return true;
    }

    bool ReadBytes(const std::wstring &path, std::vector<BYTE> *bytes)
    {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (file == INVALID_HANDLE_VALUE) return false;
        BY_HANDLE_FILE_INFORMATION info = {};
        LARGE_INTEGER size = {};
        if (!GetFileInformationByHandle(file, &info) ||
            (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
            !GetFileSizeEx(file, &size) || size.QuadPart < 0 || size.QuadPart > 1024 * 1024)
        {
            CloseHandle(file);
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        bytes->assign(static_cast<size_t>(size.QuadPart), 0);
        DWORD total = 0;
        while (total < bytes->size())
        {
            DWORD read = 0;
            const DWORD request = static_cast<DWORD>(std::min<size_t>(bytes->size() - total, 65536));
            if (!ReadFile(file, bytes->data() + total, request, &read, NULL) || read == 0)
            {
                CloseHandle(file);
                if (GetLastError() == ERROR_SUCCESS) SetLastError(ERROR_HANDLE_EOF);
                return false;
            }
            total += read;
        }
        CloseHandle(file);
        return true;
    }

    bool WriteBytesAtomic(const std::wstring &path, const BYTE *bytes, size_t count)
    {
        bool targetExists = false;
        if (!IsRegularFileOrMissing(path, &targetExists)) return false;
        std::wstring temporary = path + L".hr7-" + std::to_wstring(GetCurrentProcessId()) + L".tmp";
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, NULL, CREATE_NEW,
            FILE_ATTRIBUTE_TEMPORARY, NULL);
        if (file == INVALID_HANDLE_VALUE) return false;
        size_t offset = 0;
        bool ok = true;
        while (offset < count)
        {
            DWORD written = 0;
            const DWORD request = static_cast<DWORD>(std::min<size_t>(count - offset, 65536));
            if (!WriteFile(file, bytes + offset, request, &written, NULL) || written == 0)
            {
                ok = false;
                break;
            }
            offset += written;
        }
        if (ok) ok = FlushFileBuffers(file) != FALSE;
        const DWORD writeError = ok ? ERROR_SUCCESS : GetLastError();
        CloseHandle(file);
        if (!ok)
        {
            DeleteFileW(temporary.c_str());
            SetLastError(writeError == ERROR_SUCCESS ? ERROR_WRITE_FAULT : writeError);
            return false;
        }
        if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        {
            const DWORD moveError = GetLastError();
            DeleteFileW(temporary.c_str());
            SetLastError(moveError);
            return false;
        }
        (void)targetExists;
        return true;
    }

    bool WriteBytesAtomic(const std::wstring &path, const std::vector<BYTE> &bytes)
    {
        return WriteBytesAtomic(path, bytes.data(), bytes.size());
    }

    std::vector<BYTE> WideTextBytes(const wchar_t *text)
    {
        const size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
        const BYTE *first = reinterpret_cast<const BYTE *>(text);
        return std::vector<BYTE>(first, first + bytes);
    }

    bool WriteTextFile(const std::wstring &path, const wchar_t *text)
    {
        const std::vector<BYTE> bytes = WideTextBytes(text);
        return WriteBytesAtomic(path, bytes);
    }

    bool ReadTextFile(const std::wstring &path, std::wstring *text)
    {
        std::vector<BYTE> bytes;
        if (!ReadBytes(path, &bytes) || bytes.size() < sizeof(wchar_t) || bytes.size() % sizeof(wchar_t) != 0)
            return false;
        if (bytes.size() > 65536) { SetLastError(ERROR_INVALID_DATA); return false; }
        const wchar_t *wide = reinterpret_cast<const wchar_t *>(bytes.data());
        const size_t count = bytes.size() / sizeof(wchar_t);
        if (wide[count - 1] != L'\0') { SetLastError(ERROR_INVALID_DATA); return false; }
        *text = wide;
        return true;
    }

    bool IsHr7Template(const std::vector<BYTE> &bytes)
    {
        if (bytes.empty() || bytes.size() > 65536) return false;
        std::string text(bytes.begin(), bytes.end());
        std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
            return static_cast<char>(tolower(c));
        });
        return text.find("[sane]") != std::string::npos &&
            text.find("[host.0]") != std::string::npos &&
            text.find("nameoraddress=127.0.0.1") != std::string::npos &&
            text.find("port=6566") != std::string::npos &&
            text.find("autolocatedevice=plustek") != std::string::npos;
    }

    std::wstring SidecarDirectory(const std::wstring &target)
    {
        const size_t separator = target.find_last_of(L"\\/");
        if (separator == std::wstring::npos) return std::wstring();
        return target.substr(0, separator + 1) + L".GeniusColorPageHR7-TWAIN";
    }

    bool FilesEqual(const std::wstring &left, const std::wstring &right)
    {
        std::vector<BYTE> a;
        std::vector<BYTE> b;
        if (!ReadBytes(left, &a) || !ReadBytes(right, &b)) return false;
        return a == b;
    }

    bool BytesEqual(const std::wstring &path, const std::vector<BYTE> &expected)
    {
        std::vector<BYTE> actual;
        return ReadBytes(path, &actual) && actual == expected;
    }

    bool TargetState(const std::wstring &target, std::wstring *state, bool *managed)
    {
        *managed = false;
        const std::wstring sidecar = SidecarDirectory(target);
        if (sidecar.empty()) { SetLastError(ERROR_INVALID_NAME); return false; }
        const DWORD attributes = GetFileAttributesW(sidecar.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES)
        {
            const DWORD error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return true;
            return false;
        }
        if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        std::wstring marker;
        if (!ReadTextFile(Join(sidecar, kOwnershipFile), &marker)) return false;
        if (marker != kPresentState && marker != kAbsentState)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        *state = marker;
        *managed = true;
        return true;
    }

    bool PrepareTarget(const std::wstring &target, const std::vector<BYTE> &templateBytes,
                       bool *preservedUserChanges)
    {
        *preservedUserChanges = false;
        const size_t separator = target.find_last_of(L"\\/");
        if (separator == std::wstring::npos) { SetLastError(ERROR_INVALID_NAME); return false; }
        const std::wstring directory = target.substr(0, separator);
        if (!EnsureDirectory(directory)) return false;
        bool targetExists = false;
        if (!IsRegularFileOrMissing(target, &targetExists)) return false;

        const std::wstring sidecar = SidecarDirectory(target);
        std::wstring state;
        bool managed = false;
        if (!TargetState(target, &state, &managed)) return false;
        if (!managed)
        {
            const DWORD sidecarAttributes = GetFileAttributesW(sidecar.c_str());
            if (sidecarAttributes != INVALID_FILE_ATTRIBUTES)
            {
                SetLastError(ERROR_ALREADY_EXISTS);
                return false;
            }
            if (!EnsureDirectory(sidecar)) return false;
            state = targetExists ? kPresentState : kAbsentState;
            if (targetExists && !CopyFileW(target.c_str(), Join(sidecar, kOriginalFile).c_str(), TRUE))
            {
                DeleteFileW(Join(sidecar, kOriginalFile).c_str());
                RemoveDirectoryW(sidecar.c_str());
                return false;
            }
            if (!WriteTextFile(Join(sidecar, kOwnershipFile), state.c_str()))
            {
                DeleteFileW(Join(sidecar, kOriginalFile).c_str());
                RemoveDirectoryW(sidecar.c_str());
                return false;
            }
            SetFileAttributesW(sidecar.c_str(), FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_HIDDEN);
        }
        else
        {
            bool previousTemplateExists = false;
            if (!IsRegularFileOrMissing(Join(sidecar, kInstalledFile), &previousTemplateExists)) return false;
            if (targetExists && previousTemplateExists &&
                !FilesEqual(target, Join(sidecar, kInstalledFile)))
            {
                // Preserve edits made after installation rather than overwrite user data.
                *preservedUserChanges = true;
                return true;
            }
            if (targetExists && !previousTemplateExists && !BytesEqual(target, templateBytes))
            {
                *preservedUserChanges = true;
                return true;
            }
        }

        if (!WriteBytesAtomic(target, templateBytes)) return false;
        if (!WriteBytesAtomic(Join(sidecar, kInstalledFile), templateBytes)) return false;
        return true;
    }

    bool RestoreTarget(const std::wstring &target, size_t *preservedCount)
    {
        std::wstring state;
        bool managed = false;
        if (!TargetState(target, &state, &managed)) return false;
        if (!managed) return true;

        const std::wstring sidecar = SidecarDirectory(target);
        bool installedExists = false;
        bool targetExists = false;
        if (!IsRegularFileOrMissing(Join(sidecar, kInstalledFile), &installedExists) ||
            !IsRegularFileOrMissing(target, &targetExists)) return false;
        if (targetExists && installedExists && !FilesEqual(target, Join(sidecar, kInstalledFile)))
        {
            // Keep both the user's later settings and the original backup for manual recovery.
            ++*preservedCount;
            return true;
        }

        const std::wstring originalPath = Join(sidecar, kOriginalFile);
        if (state == kPresentState)
        {
            bool originalExists = false;
            if (!IsRegularFileOrMissing(originalPath, &originalExists) || !originalExists)
            {
                SetLastError(ERROR_INVALID_DATA);
                return false;
            }
            std::vector<BYTE> original;
            if (!ReadBytes(originalPath, &original) || !WriteBytesAtomic(target, original)) return false;
        }
        else
        {
            if (targetExists && !DeleteFileW(target.c_str())) return false;
        }

        if (!DeleteFileW(originalPath.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) return false;
        if (!DeleteFileW(Join(sidecar, kInstalledFile).c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) return false;
        if (!DeleteFileW(Join(sidecar, kOwnershipFile).c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) return false;
        SetFileAttributesW(sidecar.c_str(), FILE_ATTRIBUTE_DIRECTORY);
        if (!RemoveDirectoryW(sidecar.c_str()) && GetLastError() != ERROR_DIR_NOT_EMPTY) return false;
        return true;
    }

    bool ReadRegistryString(HKEY key, const wchar_t *name, std::wstring *value)
    {
        DWORD type = 0;
        DWORD bytes = 0;
        LONG status = RegQueryValueExW(key, name, NULL, &type, NULL, &bytes);
        if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) || bytes < sizeof(wchar_t))
            return false;
        std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
        status = RegQueryValueExW(key, name, NULL, &type, reinterpret_cast<BYTE *>(buffer.data()), &bytes);
        if (status != ERROR_SUCCESS) return false;
        std::wstring text(buffer.data());
        if (type == REG_EXPAND_SZ)
        {
            DWORD required = ExpandEnvironmentStringsW(text.c_str(), NULL, 0);
            if (required == 0 || required > 32767) return false;
            std::vector<wchar_t> expanded(required, L'\0');
            if (!ExpandEnvironmentStringsW(text.c_str(), expanded.data(), required)) return false;
            text.assign(expanded.data());
        }
        *value = text;
        return true;
    }

    bool AddUnique(std::vector<std::wstring> *values, const std::wstring &value)
    {
        if (value.empty()) return true;
        for (const std::wstring &existing : *values)
        {
            if (_wcsicmp(existing.c_str(), value.c_str()) == 0) return true;
        }
        values->push_back(value);
        return true;
    }

    bool EnumerateProfileDirectories(std::vector<std::wstring> *profiles,
                                     std::wstring *defaultProfile)
    {
        HKEY profileList = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE,
            L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList", 0,
            KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE | KEY_WOW64_64KEY, &profileList);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }

        defaultProfile->clear();
        ReadRegistryString(profileList, L"Default", defaultProfile);
        if (!defaultProfile->empty()) AddUnique(profiles, *defaultProfile);

        for (DWORD index = 0; ; ++index)
        {
            wchar_t subkeyName[256] = {};
            DWORD chars = ARRAYSIZE(subkeyName);
            status = RegEnumKeyExW(profileList, index, subkeyName, &chars, NULL, NULL, NULL, NULL);
            if (status == ERROR_NO_MORE_ITEMS) break;
            if (status != ERROR_SUCCESS) { RegCloseKey(profileList); SetLastError(static_cast<DWORD>(status)); return false; }
            if (_wcsicmp(subkeyName, L"S-1-5-18") == 0 || _wcsicmp(subkeyName, L"S-1-5-19") == 0 ||
                _wcsicmp(subkeyName, L"S-1-5-20") == 0) continue;
            HKEY profile = NULL;
            status = RegOpenKeyExW(profileList, subkeyName, 0, KEY_QUERY_VALUE, &profile);
            if (status != ERROR_SUCCESS) continue;
            std::wstring path;
            ReadRegistryString(profile, L"ProfileImagePath", &path);
            RegCloseKey(profile);
            if (!path.empty()) AddUnique(profiles, path);
        }
        RegCloseKey(profileList);

        for (std::vector<std::wstring>::iterator it = profiles->begin(); it != profiles->end(); )
        {
            if (!IsDirectory(*it)) it = profiles->erase(it);
            else ++it;
        }
        return true;
    }

    bool GetCurrentKnownFolder(int folder, std::wstring *path)
    {
        wchar_t buffer[MAX_PATH] = {};
        if (FAILED(SHGetFolderPathW(NULL, folder, NULL, SHGFP_TYPE_CURRENT, buffer))) return false;
        *path = buffer;
        return true;
    }

    bool CollectTargets(std::vector<std::wstring> *targets)
    {
        wchar_t programData[MAX_PATH] = {};
        if (FAILED(SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL, SHGFP_TYPE_CURRENT, programData)))
            return false;
        AddUnique(targets, Join(Join(std::wstring(programData), L"SANEWinDS"), L"SANEWinDS.ini"));

        std::vector<std::wstring> profiles;
        std::wstring defaultProfile;
        if (!EnumerateProfileDirectories(&profiles, &defaultProfile)) return false;
        std::wstring currentRoaming;
        if (GetCurrentKnownFolder(CSIDL_APPDATA, &currentRoaming) && IsDirectory(currentRoaming))
            AddUnique(targets, Join(Join(currentRoaming, L"SANEWinDS"), L"SANEWinDS.ini"));

        for (const std::wstring &profile : profiles)
        {
            const std::wstring roaming = Join(profile, L"AppData\\Roaming");
            const bool isDefaultProfile = !defaultProfile.empty() &&
                _wcsicmp(profile.c_str(), defaultProfile.c_str()) == 0;
            // SANEWinDS reads per-user settings from %AppData%, not LocalAppData.
            // Seed the Default profile even when its Roaming folder has not yet
            // been materialized so users created after setup inherit the source.
            if (isDefaultProfile && !IsDirectory(roaming))
            {
                const std::wstring appData = Join(profile, L"AppData");
                if (!IsDirectory(appData) && !EnsureDirectory(appData)) return false;
                if (!IsDirectory(roaming) && !EnsureDirectory(roaming)) return false;
            }
            if (IsDirectory(roaming))
            {
                AddUnique(targets, Join(Join(roaming, L"SANEWinDS"), L"SANEWinDS.ini"));
            }
        }
        return !targets->empty();
    }

    bool WriteInstalledState(const std::vector<std::wstring> &targets)
    {
        HKEY key = NULL;
        LONG status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0, NULL, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &key, NULL);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        size_t chars = 1;
        for (const std::wstring &target : targets) chars += target.size() + 1;
        std::vector<wchar_t> multi(chars, L'\0');
        size_t offset = 0;
        for (const std::wstring &target : targets)
        {
            memcpy(multi.data() + offset, target.c_str(), (target.size() + 1) * sizeof(wchar_t));
            offset += target.size() + 1;
        }
        status = RegSetValueExW(key, kTargetsValue, 0, REG_MULTI_SZ,
            reinterpret_cast<const BYTE *>(multi.data()), static_cast<DWORD>(multi.size() * sizeof(wchar_t)));
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

    bool ReadInstalledTargets(std::vector<std::wstring> *targets, bool *found)
    {
        *found = false;
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }

        DWORD versionType = 0;
        DWORD versionBytes = 0;
        status = RegQueryValueExW(key, kVersionValue, NULL, &versionType, NULL, &versionBytes);
        if (status == ERROR_FILE_NOT_FOUND)
        {
            DWORD orphanedTargetsBytes = 0;
            LONG targetsStatus = RegQueryValueExW(key, kTargetsValue, NULL, NULL, NULL, &orphanedTargetsBytes);
            RegCloseKey(key);
            if (targetsStatus == ERROR_FILE_NOT_FOUND) return true;
            SetLastError(targetsStatus == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(targetsStatus));
            return false;
        }
        if (status != ERROR_SUCCESS || (versionType != REG_SZ && versionType != REG_EXPAND_SZ) ||
            versionBytes < sizeof(wchar_t) || versionBytes % sizeof(wchar_t) != 0)
        {
            RegCloseKey(key);
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }
        std::vector<wchar_t> versionBuffer(versionBytes / sizeof(wchar_t) + 1, L'\0');
        status = RegQueryValueExW(key, kVersionValue, NULL, &versionType,
            reinterpret_cast<BYTE *>(versionBuffer.data()), &versionBytes);
        if (status != ERROR_SUCCESS || versionBuffer[versionBytes / sizeof(wchar_t) - 1] != L'\0' ||
            versionBuffer[0] == L'\0')
        {
            RegCloseKey(key);
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }
        *found = true;
        DWORD type = 0;
        DWORD bytes = 0;
        status = RegQueryValueExW(key, kTargetsValue, NULL, &type, NULL, &bytes);
        if (status != ERROR_SUCCESS || type != REG_MULTI_SZ || bytes < 2 * sizeof(wchar_t) ||
            bytes > 1024 * 1024 || bytes % sizeof(wchar_t) != 0)
        {
            RegCloseKey(key);
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }
        std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
        status = RegQueryValueExW(key, kTargetsValue, NULL, &type,
            reinterpret_cast<BYTE *>(buffer.data()), &bytes);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        const size_t chars = bytes / sizeof(wchar_t);
        if (chars < 2 || buffer[chars - 1] != L'\0' || buffer[chars - 2] != L'\0')
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        for (size_t offset = 0; offset < chars && buffer[offset] != L'\0'; )
        {
            size_t end = offset;
            while (end < chars && buffer[end] != L'\0') ++end;
            if (end == chars)
            {
                SetLastError(ERROR_INVALID_DATA);
                return false;
            }
            targets->push_back(std::wstring(buffer.data() + offset, end - offset));
            offset = end + 1;
        }
        if (targets->empty())
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        return true;
    }

    bool ClearInstalledState()
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        LONG versionStatus = RegDeleteValueW(key, kVersionValue);
        LONG targetsStatus = RegDeleteValueW(key, kTargetsValue);
        RegCloseKey(key);
        if (versionStatus != ERROR_SUCCESS && versionStatus != ERROR_FILE_NOT_FOUND)
            status = versionStatus;
        else if (targetsStatus != ERROR_SUCCESS && targetsStatus != ERROR_FILE_NOT_FOUND)
            status = targetsStatus;
        if (status != ERROR_SUCCESS) SetLastError(static_cast<DWORD>(status));
        return status == ERROR_SUCCESS;
    }

    bool IsAdministrator()
    {
        HANDLE token = NULL;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
        TOKEN_ELEVATION elevation = {};
        DWORD size = 0;
        const bool elevated = GetTokenInformation(token, TokenElevation, &elevation,
            sizeof(elevation), &size) && elevation.TokenIsElevated != 0;
        CloseHandle(token);
        return elevated;
    }

    void ShowFailure(const wchar_t *operation)
    {
        DWORD error = GetLastError();
        wchar_t message[512] = {};
        StringCchPrintfW(message, ARRAYSIZE(message),
            L"%ls failed with Windows error %lu (0x%08lx).\n\n"
            L"The installer preserves existing user configuration in per-profile backup folders.",
            operation, error, error);
        MessageBoxW(NULL, message, L"Genius ColorPage-HR7 TWAIN setup",
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    }

    bool AskForConfigChange()
    {
        const wchar_t message[] =
            L"To make the HR7 available in TWAIN applications, setup will create or update the SANEWinDS configuration in ProgramData and existing Windows user profiles (including the Default profile). Any previous configuration is backed up and restored on uninstall unless it is edited after installation.\n\n"
            L"Continue?\n\n"
            L"Para disponibilizar o HR7 em aplicativos TWAIN, a instalacao criara ou atualizara a configuracao do SANEWinDS em ProgramData e nos perfis de usuario do Windows. A configuracao anterior sera salva e restaurada ao desinstalar, a menos que seja editada depois da instalacao.\n\n"
            L"Continuar?";
        return MessageBoxW(NULL, message, L"Genius ColorPage-HR7 TWAIN configuration",
            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2 | MB_SETFOREGROUND) == IDYES;
    }

    bool InstallConfig(const std::wstring &installFolder)
    {
        const std::wstring templatePath = Join(Join(installFolder, L"config"), L"SANEWinDS.ini");
        std::vector<BYTE> templateBytes;
        if (!ReadBytes(templatePath, &templateBytes) || !IsHr7Template(templateBytes))
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }

        std::vector<std::wstring> previousTargets;
        bool alreadyInstalled = false;
        if (!ReadInstalledTargets(&previousTargets, &alreadyInstalled)) return false;
        if (!alreadyInstalled && !AskForConfigChange()) { SetLastError(ERROR_CANCELLED); return false; }

        std::vector<std::wstring> targets = previousTargets;
        std::vector<std::wstring> discovered;
        if (!CollectTargets(&discovered)) return false;
        for (const std::wstring &target : discovered) AddUnique(&targets, target);

        size_t configured = 0;
        for (const std::wstring &target : targets)
        {
            bool preserved = false;
            if (!PrepareTarget(target, templateBytes, &preserved))
            {
                const DWORD error = GetLastError();
                size_t ignored = 0;
                for (const std::wstring &applied : targets) RestoreTarget(applied, &ignored);
                SetLastError(error);
                return false;
            }
            if (!preserved) ++configured;
        }
        if (configured == 0 && !alreadyInstalled)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        if (!WriteInstalledState(targets))
        {
            const DWORD error = GetLastError();
            size_t ignored = 0;
            for (const std::wstring &target : targets) RestoreTarget(target, &ignored);
            SetLastError(error);
            return false;
        }
        return true;
    }

    bool RemoveConfig()
    {
        std::vector<std::wstring> targets;
        bool found = false;
        if (!ReadInstalledTargets(&targets, &found)) return false;
        if (!found) return ClearInstalledState();

        size_t preservedCount = 0;
        for (const std::wstring &target : targets)
        {
            if (!RestoreTarget(target, &preservedCount)) return false;
        }
        if (!ClearInstalledState()) return false;
        if (preservedCount != 0)
        {
            wchar_t message[256] = {};
            StringCchPrintfW(message, ARRAYSIZE(message),
                L"%lu user SANEWinDS configuration file(s) were edited after installation. They were left in place; the original backup is in the hidden .GeniusColorPageHR7-TWAIN folder beside each file.",
                static_cast<unsigned long>(preservedCount));
            MessageBoxW(NULL, message, L"Genius ColorPage-HR7 TWAIN settings preserved",
                MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
        }
        return true;
    }
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    if (!IsAdministrator())
    {
        MessageBoxW(NULL, L"Run this action only through the elevated Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 TWAIN setup", MB_OK | MB_ICONERROR);
        return ERROR_ELEVATION_REQUIRED;
    }
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 3 || (_wcsicmp(argv[1], L"install") != 0 && _wcsicmp(argv[1], L"remove") != 0))
    {
        if (argv) LocalFree(argv);
        MessageBoxW(NULL, L"This action is invoked by the Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 TWAIN setup", MB_OK | MB_ICONERROR);
        return ERROR_INVALID_PARAMETER;
    }
    const bool installing = _wcsicmp(argv[1], L"install") == 0;
    std::wstring installFolder = argv[2];
    LocalFree(argv);
    if (installFolder.empty()) { SetLastError(ERROR_INVALID_NAME); ShowFailure(L"Validate installation directory"); return ERROR_INVALID_NAME; }
    DWORD attributes = GetFileAttributesW(installFolder.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
    {
        SetLastError(ERROR_PATH_NOT_FOUND);
        ShowFailure(L"Validate installation directory");
        return ERROR_PATH_NOT_FOUND;
    }
    const bool ok = installing ? InstallConfig(installFolder) : RemoveConfig();
    if (!ok)
    {
        const DWORD error = GetLastError();
        ShowFailure(installing ? L"Configure SANEWinDS" : L"Restore SANEWinDS configuration");
        return error == ERROR_SUCCESS ? ERROR_INSTALL_FAILURE : error;
    }
    return ERROR_SUCCESS;
}
