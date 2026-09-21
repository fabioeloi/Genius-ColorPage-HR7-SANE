#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <strsafe.h>
#include <shellapi.h>

#include <cwctype>
#include <cwchar>
#include <cstdlib>
#include <string>
#include <vector>

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "advapi32.lib")

namespace
{
    const GUID kImageClass =
        { 0x6bdd1fc6, 0x810f, 0x11d0, { 0xbe, 0xc7, 0x08, 0x00, 0x2b, 0xe2, 0x09, 0x2f } };
    const wchar_t kHardwareId[] = L"ROOT\\GENIUSCOLORPAGEHR7WIA";
    const wchar_t kGeneratedInstanceName[] = L"GENIUSCOLORPAGEHR7WIA";
    const wchar_t kDeviceName[] = L"Genius ColorPage-HR7 (WIA 2.0)";
    const wchar_t kInfFileName[] = L"GeniusColorPageHR7Wia.inf";
    const wchar_t kPackageVersion[] = L"1.0.0.10";
    const wchar_t kDriverProvider[] = L"Genius ColorPage-HR7 project";
    const wchar_t kRegistryPath[] = L"SOFTWARE\\Genius\\ColorPage-HR7\\WIA";
    const wchar_t kVersionValue[] = L"InstalledVersion";

    struct DeviceInfoSet
    {
        HDEVINFO handle;
        explicit DeviceInfoSet(HDEVINFO value) : handle(value) {}
        ~DeviceInfoSet() { if (handle != INVALID_HANDLE_VALUE) SetupDiDestroyDeviceInfoList(handle); }
        DeviceInfoSet(const DeviceInfoSet &) = delete;
        DeviceInfoSet &operator=(const DeviceInfoSet &) = delete;
    };

    bool GetRegistryMultiString(HDEVINFO set, SP_DEVINFO_DATA *device, DWORD property,
                                std::vector<std::wstring> *values)
    {
        DWORD required = 0;
        DWORD type = 0;
        if (SetupDiGetDeviceRegistryPropertyW(set, device, property, &type, NULL, 0, &required) ||
            GetLastError() != ERROR_INSUFFICIENT_BUFFER || type != REG_MULTI_SZ ||
            required < (2 * sizeof(wchar_t)) || required % sizeof(wchar_t) != 0)
        {
            return false;
        }

        std::vector<wchar_t> buffer(required / sizeof(wchar_t) + 1, L'\0');
        if (!SetupDiGetDeviceRegistryPropertyW(set, device, property, &type,
            reinterpret_cast<PBYTE>(buffer.data()), required, NULL) || type != REG_MULTI_SZ)
        {
            return false;
        }

        values->clear();
        for (const wchar_t *value = buffer.data(); *value; value += wcslen(value) + 1)
        {
            values->push_back(value);
        }
        return true;
    }

    bool GetInstanceId(HDEVINFO set, SP_DEVINFO_DATA *device, std::wstring *instanceId)
    {
        DWORD required = 0;
        if (SetupDiGetDeviceInstanceIdW(set, device, NULL, 0, &required) ||
            GetLastError() != ERROR_INSUFFICIENT_BUFFER || required == 0)
        {
            return false;
        }
        std::vector<wchar_t> buffer(required + 1, L'\0');
        if (!SetupDiGetDeviceInstanceIdW(set, device, buffer.data(),
            static_cast<DWORD>(buffer.size()), NULL))
        {
            return false;
        }
        *instanceId = buffer.data();
        return true;
    }

    bool GetDriverRegistryString(HDEVINFO set, SP_DEVINFO_DATA *device,
                                 const wchar_t *valueName, std::wstring *value)
    {
        HKEY key = SetupDiOpenDevRegKey(set, device, DICS_FLAG_GLOBAL, 0,
            DIREG_DRV, KEY_QUERY_VALUE);
        if (key == INVALID_HANDLE_VALUE)
        {
            return false;
        }

        DWORD type = 0;
        DWORD byteCount = 0;
        LONG status = RegQueryValueExW(key, valueName, NULL, &type, NULL, &byteCount);
        if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
            byteCount < sizeof(wchar_t) || byteCount % sizeof(wchar_t) != 0)
        {
            RegCloseKey(key);
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }

        std::vector<wchar_t> buffer(byteCount / sizeof(wchar_t) + 1, L'\0');
        status = RegQueryValueExW(key, valueName, NULL, &type,
            reinterpret_cast<LPBYTE>(buffer.data()), &byteCount);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ))
        {
            SetLastError(status == ERROR_SUCCESS ? ERROR_INVALID_DATA : static_cast<DWORD>(status));
            return false;
        }

        *value = buffer.data();
        return true;
    }

    bool ParseFourPartVersion(const std::wstring &text, unsigned long parts[4])
    {
        const wchar_t *cursor = text.c_str();
        for (size_t index = 0; index < 4; ++index)
        {
            if (*cursor < L'0' || *cursor > L'9')
            {
                return false;
            }
            wchar_t *end = NULL;
            unsigned long part = wcstoul(cursor, &end, 10);
            if (end == cursor)
            {
                return false;
            }
            parts[index] = part;
            if (index == 3)
            {
                return *end == L'\0';
            }
            if (*end != L'.')
            {
                return false;
            }
            cursor = end + 1;
        }
        return false;
    }

    bool IsHr7DriverAtLeastPackageVersion(HDEVINFO set, SP_DEVINFO_DATA *device)
    {
        std::wstring provider;
        std::wstring version;
        if (!GetDriverRegistryString(set, device, L"ProviderName", &provider) ||
            _wcsicmp(provider.c_str(), kDriverProvider) != 0 ||
            !GetDriverRegistryString(set, device, L"DriverVersion", &version))
        {
            return false;
        }

        unsigned long installedParts[4] = {};
        unsigned long packageParts[4] = {};
        if (!ParseFourPartVersion(version, installedParts) ||
            !ParseFourPartVersion(kPackageVersion, packageParts))
        {
            return false;
        }
        for (size_t index = 0; index < 4; ++index)
        {
            if (installedParts[index] > packageParts[index]) return true;
            if (installedParts[index] < packageParts[index]) return false;
        }
        return true;
    }

    bool IsGeneratedRootInstance(const std::wstring &instanceId)
    {
        const size_t expectedLength = wcslen(kHardwareId);
        return instanceId.size() > expectedLength &&
            _wcsnicmp(instanceId.c_str(), kHardwareId, expectedLength) == 0 &&
            instanceId[expectedLength] == L'\\';
    }

    bool FindWiaDevices(HDEVINFO set, std::vector<SP_DEVINFO_DATA> *matches,
                        std::vector<std::wstring> *instanceIds)
    {
        matches->clear();
        instanceIds->clear();
        for (DWORD index = 0; ; ++index)
        {
            SP_DEVINFO_DATA device = {};
            device.cbSize = sizeof(device);
            if (!SetupDiEnumDeviceInfo(set, index, &device))
            {
                return GetLastError() == ERROR_NO_MORE_ITEMS;
            }

            std::vector<std::wstring> hardwareIds;
            if (!GetRegistryMultiString(set, &device, SPDRP_HARDWAREID, &hardwareIds))
            {
                continue;
            }
            bool exactMatch = false;
            for (const std::wstring &hardwareId : hardwareIds)
            {
                if (_wcsicmp(hardwareId.c_str(), kHardwareId) == 0)
                {
                    exactMatch = true;
                    break;
                }
            }
            if (!exactMatch)
            {
                continue;
            }

            std::wstring instanceId;
            if (!GetInstanceId(set, &device, &instanceId))
            {
                return false;
            }
            if (!IsGeneratedRootInstance(instanceId))
            {
        SetLastError(ERROR_INVALID_STATE);
                return false;
            }
            matches->push_back(device);
            instanceIds->push_back(instanceId);
        }
    }

    bool IsAdministrator()
    {
        HANDLE token = NULL;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
        {
            return false;
        }
        TOKEN_ELEVATION elevation = {};
        DWORD size = 0;
        const bool elevated = GetTokenInformation(token, TokenElevation, &elevation,
            sizeof(elevation), &size) && elevation.TokenIsElevated != 0;
        CloseHandle(token);
        return elevated;
    }

    std::wstring FullPath(const wchar_t *path)
    {
        DWORD required = GetFullPathNameW(path, 0, NULL, NULL);
        if (required == 0 || required > 32767)
        {
            return std::wstring();
        }
        std::vector<wchar_t> buffer(required + 1, L'\0');
        DWORD written = GetFullPathNameW(path, static_cast<DWORD>(buffer.size()), buffer.data(), NULL);
        if (written == 0 || written >= buffer.size())
        {
            return std::wstring();
        }
        return buffer.data();
    }

    bool HasExpectedInfName(const std::wstring &infPath)
    {
        const size_t separator = infPath.find_last_of(L"\\/");
        const wchar_t *fileName = separator == std::wstring::npos
            ? infPath.c_str() : infPath.c_str() + separator + 1;
        return _wcsicmp(fileName, kInfFileName) == 0;
    }

    bool MarkInstalled()
    {
        HKEY key = NULL;
        LONG status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0, NULL, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &key, NULL);
        if (status != ERROR_SUCCESS)
        {
            SetLastError(static_cast<DWORD>(status));
            return false;
        }
        status = RegSetValueExW(key, kVersionValue, 0, REG_SZ,
            reinterpret_cast<const BYTE *>(kPackageVersion),
            static_cast<DWORD>((wcslen(kPackageVersion) + 1) * sizeof(wchar_t)));
        RegCloseKey(key);
        if (status != ERROR_SUCCESS)
        {
            SetLastError(static_cast<DWORD>(status));
            return false;
        }
        return true;
    }

    bool ClearInstalledMarker()
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }
        status = RegDeleteValueW(key, kVersionValue);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
            SetLastError(static_cast<DWORD>(status));
        return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
    }

    void PrintFailure(const wchar_t *operation)
    {
        DWORD error = GetLastError();
        wchar_t message[512] = {};
        StringCchPrintfW(message, ARRAYSIZE(message),
            L"%ls failed with Windows error %lu (0x%08lx).\n\n"
            L"The physical USB driver binding was not touched.", operation, error, error);
        MessageBoxW(NULL, message, L"Genius ColorPage-HR7 WIA setup",
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    }

    bool CreateWiaDevice()
    {
        DeviceInfoSet set(SetupDiCreateDeviceInfoList(&kImageClass, NULL));
        if (set.handle == INVALID_HANDLE_VALUE)
        {
            return false;
        }

        SP_DEVINFO_DATA device = {};
        device.cbSize = sizeof(device);
        if (!SetupDiCreateDeviceInfoW(set.handle, kGeneratedInstanceName, &kImageClass,
            kDeviceName, NULL, DICD_GENERATE_ID, &device))
        {
            return false;
        }

        const wchar_t hardwareIdMultiSz[] = L"ROOT\\GENIUSCOLORPAGEHR7WIA\0";
        if (!SetupDiSetDeviceRegistryPropertyW(set.handle, &device, SPDRP_HARDWAREID,
            reinterpret_cast<const BYTE *>(hardwareIdMultiSz), sizeof(hardwareIdMultiSz)) ||
            !SetupDiSetDeviceRegistryPropertyW(set.handle, &device, SPDRP_FRIENDLYNAME,
                reinterpret_cast<const BYTE *>(kDeviceName),
                static_cast<DWORD>((wcslen(kDeviceName) + 1) * sizeof(wchar_t))))
        {
            return false;
        }
        return SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set.handle, &device) != FALSE;
    }

    bool RemoveWiaDevice(const std::wstring &instanceId)
    {
        DeviceInfoSet set(SetupDiGetClassDevsW(&kImageClass, NULL, NULL, 0));
        if (set.handle == INVALID_HANDLE_VALUE)
        {
            return false;
        }

        std::vector<SP_DEVINFO_DATA> devices;
        std::vector<std::wstring> instanceIds;
        if (!FindWiaDevices(set.handle, &devices, &instanceIds))
        {
            return false;
        }
        if (devices.size() != 1 || _wcsicmp(instanceIds[0].c_str(), instanceId.c_str()) != 0)
        {
            SetLastError(ERROR_DEVICE_NOT_CONNECTED);
            return false;
        }

        SP_REMOVEDEVICE_PARAMS remove = {};
        remove.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        remove.ClassInstallHeader.InstallFunction = DIF_REMOVE;
        remove.Scope = DI_REMOVEDEVICE_GLOBAL;
        remove.HwProfile = 0;
        if (!SetupDiSetClassInstallParamsW(set.handle, &devices[0],
            &remove.ClassInstallHeader, sizeof(remove)))
        {
            return false;
        }
        return SetupDiCallClassInstaller(DIF_REMOVE, set.handle, &devices[0]) != FALSE;
    }

    bool InstallWiaDriver(const std::wstring &infPath, bool *rebootRequired)
    {
        *rebootRequired = false;
        DeviceInfoSet current(SetupDiGetClassDevsW(&kImageClass, NULL, NULL, 0));
        if (current.handle == INVALID_HANDLE_VALUE)
        {
            return false;
        }
        std::vector<SP_DEVINFO_DATA> devices;
        std::vector<std::wstring> instanceIds;
        if (!FindWiaDevices(current.handle, &devices, &instanceIds))
        {
            return false;
        }
        if (devices.size() > 1)
        {
            SetLastError(ERROR_DUP_NAME);
            return false;
        }

        BOOL stageReboot = FALSE;
        if (!DiInstallDriverW(NULL, infPath.c_str(), 0, &stageReboot))
        {
            return false;
        }
        *rebootRequired = stageReboot != FALSE;

        bool created = false;
        if (devices.empty())
        {
            if (!CreateWiaDevice())
            {
                DWORD createError = GetLastError();
                DiUninstallDriverW(NULL, infPath.c_str(), 0, NULL);
                SetLastError(createError);
                return false;
            }
            created = true;
        }

        BOOL updateReboot = FALSE;
        if (!UpdateDriverForPlugAndPlayDevicesW(NULL, kHardwareId, infPath.c_str(),
            INSTALLFLAG_FORCE, &updateReboot))
        {
            DWORD updateError = GetLastError();
            // SetupAPI returns ERROR_NO_MORE_ITEMS when the exact same
            // package is already active and therefore has no better match.
            // Treat that as idempotent success only after verifying the
            // registered HR7 device is using this provider at this version
            // or newer; unrelated failures still roll back as before.
            if (updateError == ERROR_NO_MORE_ITEMS && devices.size() == 1 &&
                IsHr7DriverAtLeastPackageVersion(current.handle, &devices[0]))
            {
                return true;
            }
            if (created)
            {
                DeviceInfoSet registered(SetupDiGetClassDevsW(&kImageClass, NULL, NULL, 0));
                if (registered.handle != INVALID_HANDLE_VALUE)
                {
                    std::vector<SP_DEVINFO_DATA> registeredDevices;
                    std::vector<std::wstring> registeredIds;
                    if (FindWiaDevices(registered.handle, &registeredDevices, &registeredIds) &&
                        registeredDevices.size() == 1)
                    {
                        RemoveWiaDevice(registeredIds[0]);
                    }
                }
            }
            DiUninstallDriverW(NULL, infPath.c_str(), 0, NULL);
            SetLastError(updateError);
            return false;
        }
        *rebootRequired = *rebootRequired || updateReboot != FALSE;
        return true;
    }

    bool RemoveWiaDriver(const std::wstring &infPath, bool *rebootRequired)
    {
        *rebootRequired = false;
        DeviceInfoSet set(SetupDiGetClassDevsW(&kImageClass, NULL, NULL, 0));
        if (set.handle == INVALID_HANDLE_VALUE)
        {
            return false;
        }
        std::vector<SP_DEVINFO_DATA> devices;
        std::vector<std::wstring> instanceIds;
        if (!FindWiaDevices(set.handle, &devices, &instanceIds))
        {
            return false;
        }
        if (devices.size() > 1)
        {
            SetLastError(ERROR_DUP_NAME);
            return false;
        }
        if (devices.size() == 1 && !RemoveWiaDevice(instanceIds[0]))
        {
            return false;
        }

        BOOL removeReboot = FALSE;
        if (!DiUninstallDriverW(NULL, infPath.c_str(), 0, &removeReboot))
        {
            return false;
        }
        *rebootRequired = removeReboot != FALSE;
        return true;
    }
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 3 || (_wcsicmp(argv[1], L"install") != 0 && _wcsicmp(argv[1], L"remove") != 0))
    {
        if (argv) LocalFree(argv);
        MessageBoxW(NULL, L"This action is invoked by the Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 WIA setup", MB_OK | MB_ICONERROR);
        return ERROR_INVALID_PARAMETER;
    }
    if (!IsAdministrator())
    {
        LocalFree(argv);
        MessageBoxW(NULL, L"Run this action only through the elevated Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 WIA setup", MB_OK | MB_ICONERROR);
        return ERROR_ELEVATION_REQUIRED;
    }

    const bool installing = _wcsicmp(argv[1], L"install") == 0;
    std::wstring infPath = FullPath(argv[2]);
    LocalFree(argv);
    if (infPath.empty() || !HasExpectedInfName(infPath) || GetFileAttributesW(infPath.c_str()) == INVALID_FILE_ATTRIBUTES)
    {
        SetLastError(ERROR_INVALID_NAME);
        PrintFailure(L"Validate WIA package path");
        return ERROR_INVALID_NAME;
    }

    bool rebootRequired = false;
    bool ok = installing
        ? InstallWiaDriver(infPath, &rebootRequired)
        : RemoveWiaDriver(infPath, &rebootRequired);
    if (!ok)
    {
        DWORD error = GetLastError();
        PrintFailure(installing ? L"Install WIA device" : L"Remove WIA device");
        return error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error;
    }

    if (installing && !MarkInstalled())
    {
        DWORD markerError = GetLastError();
        if (!RemoveWiaDriver(infPath, &rebootRequired))
        {
            DWORD cleanupError = GetLastError();
            wchar_t message[768] = {};
            StringCchPrintfW(message, ARRAYSIZE(message),
                L"WIA registration succeeded but installation-state recording failed (Windows error %lu). Cleanup also failed (Windows error %lu).\n\n"
                L"The installer must be repaired or removed before retrying.", markerError, cleanupError);
            MessageBoxW(NULL, message, L"Genius ColorPage-HR7 WIA setup", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
            return cleanupError == ERROR_SUCCESS ? ERROR_INSTALL_FAILURE : cleanupError;
        }
        SetLastError(markerError);
        PrintFailure(L"Record WIA installation state");
        return markerError;
    }
    if (!installing)
    {
        if (!ClearInstalledMarker())
        {
            DWORD error = GetLastError();
            PrintFailure(L"Clear WIA installation state");
            return error == ERROR_SUCCESS ? ERROR_INSTALL_FAILURE : error;
        }
    }

    return rebootRequired ? ERROR_SUCCESS_REBOOT_REQUIRED : ERROR_SUCCESS;
}
