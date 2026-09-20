#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <initguid.h>
#include <devpkey.h>
#include <shellapi.h>
#include <shlobj.h>
#include <objbase.h>
#include <strsafe.h>
#include <libwdi.h>

#include <cwchar>
#include <string>
#include <vector>

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "cfgmgr32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

#ifndef HR7_PACKAGE_VERSION
#define HR7_PACKAGE_VERSION L"1.0.0.1"
#endif

namespace
{
    const wchar_t kUsbPrefix[] = L"USB\\VID_0458&PID_2013";
    const wchar_t kProductRegistryPath[] = L"SOFTWARE\\Genius\\ColorPage-HR7";
    const wchar_t kRegistryPath[] = L"SOFTWARE\\Genius\\ColorPage-HR7\\WinUSB";
    const wchar_t kVersionValue[] = L"InstalledVersion";
    const wchar_t kManagedValue[] = L"ManagedByProduct";
    const wchar_t kPriorInfValue[] = L"PriorInfPath";
    const wchar_t kCurrentInfValue[] = L"CurrentInfPath";
    const wchar_t kHardwareIdValue[] = L"HardwareId";
    const wchar_t kInstanceIdValue[] = L"InstanceId";
    const wchar_t kStageDirectoryValue[] = L"StageDirectory";
    const wchar_t kStageInfName[] = L"hr7-winusb.inf";

    struct UsbDeviceSnapshot
    {
        std::wstring instanceId;
        std::wstring hardwareId;
        std::wstring service;
        std::wstring infPath;
    };

    struct WdiDeviceList
    {
        wdi_device_info *items;
        WdiDeviceList() : items(NULL) {}
        ~WdiDeviceList() { if (items) wdi_destroy_list(items); }
        WdiDeviceList(const WdiDeviceList &) = delete;
        WdiDeviceList &operator=(const WdiDeviceList &) = delete;
    };

    struct DriverState
    {
        bool found;
        bool managed;
        std::wstring installedVersion;
        std::wstring priorInfPath;
        std::wstring currentInfPath;
        std::wstring hardwareId;
        std::wstring instanceId;
        std::wstring stageDirectory;
        DriverState() : found(false), managed(false) {}
    };

    bool IsProductStagePath(const std::wstring &path)
    {
        wchar_t programData[MAX_PATH] = {};
        if (FAILED(SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL, SHGFP_TYPE_CURRENT, programData)))
            return false;
        std::wstring expected(programData);
        expected += L"\\GeniusColorPage-HR7\\WinUSB\\";
        if (path.size() < expected.size() || _wcsnicmp(path.c_str(), expected.c_str(), expected.size()) != 0)
            return false;
        const std::wstring versionPrefix = expected + HR7_PACKAGE_VERSION + L"\\";
        if (path.size() <= versionPrefix.size() ||
            _wcsnicmp(path.c_str(), versionPrefix.c_str(), versionPrefix.size()) != 0)
        {
            return false;
        }
        const std::wstring guidText = path.substr(versionPrefix.size());
        GUID id = {};
        return guidText.find_first_of(L"\\/") == std::wstring::npos &&
            CLSIDFromString(guidText.c_str(), &id) == S_OK;
    }

    bool RemoveTreeEntries(const std::wstring &path)
    {
        const DWORD rootAttributes = GetFileAttributesW(path.c_str());
        if (rootAttributes == INVALID_FILE_ATTRIBUTES ||
            (rootAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (rootAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }
        WIN32_FIND_DATAW data = {};
        HANDLE find = FindFirstFileW((path + L"\\*").c_str(), &data);
        if (find == INVALID_HANDLE_VALUE)
            return GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND;

        bool success = true;
        do
        {
            if (wcscmp(data.cFileName, L".") == 0 || wcscmp(data.cFileName, L"..") == 0) continue;
            std::wstring child = path + L"\\" + data.cFileName;
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            {
                if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
                {
                    SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_DIRECTORY);
                    if (!RemoveDirectoryW(child.c_str())) success = false;
                }
                else if (!RemoveTreeEntries(child) || !RemoveDirectoryW(child.c_str()))
                {
                    success = false;
                }
            }
            else
            {
                SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
                if (!DeleteFileW(child.c_str())) success = false;
            }
        } while (FindNextFileW(find, &data));
        DWORD error = GetLastError();
        FindClose(find);
        return success && error == ERROR_NO_MORE_FILES;
    }

    void RemoveProductStageDirectory(const std::wstring &path)
    {
        if (!IsProductStagePath(path)) return;
        if (RemoveTreeEntries(path)) RemoveDirectoryW(path.c_str());
    }

    struct ScopedStageDirectory
    {
        std::wstring path;
        ~ScopedStageDirectory() { RemoveProductStageDirectory(path); }
    };

    bool IsHr7HardwareId(const std::wstring &value)
    {
        const size_t prefixLength = wcslen(kUsbPrefix);
        return value.size() >= prefixLength &&
            _wcsnicmp(value.c_str(), kUsbPrefix, prefixLength) == 0 &&
            (value.size() == prefixLength || value[prefixLength] == L'&' || value[prefixLength] == L'\\');
    }

    bool GetMultiStringProperty(HDEVINFO set, SP_DEVINFO_DATA *device, DWORD property,
                                std::vector<std::wstring> *values)
    {
        DWORD required = 0;
        DWORD type = 0;
        if (SetupDiGetDeviceRegistryPropertyW(set, device, property, &type, NULL, 0, &required) ||
            GetLastError() != ERROR_INSUFFICIENT_BUFFER || type != REG_MULTI_SZ ||
            required < 2 * sizeof(wchar_t) || required % sizeof(wchar_t) != 0)
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

    bool GetStringProperty(HDEVINFO set, SP_DEVINFO_DATA *device, DWORD property,
                           std::wstring *value)
    {
        DWORD required = 0;
        DWORD type = 0;
        if (SetupDiGetDeviceRegistryPropertyW(set, device, property, &type, NULL, 0, &required) ||
            GetLastError() != ERROR_INSUFFICIENT_BUFFER || type != REG_SZ || required < sizeof(wchar_t))
        {
            return false;
        }
        std::vector<wchar_t> buffer(required / sizeof(wchar_t) + 1, L'\0');
        if (!SetupDiGetDeviceRegistryPropertyW(set, device, property, &type,
            reinterpret_cast<PBYTE>(buffer.data()), required, NULL) || type != REG_SZ)
        {
            return false;
        }
        *value = buffer.data();
        return true;
    }

    bool GetDriverInfPath(HDEVINFO set, SP_DEVINFO_DATA *device, std::wstring *value)
    {
        DEVPROPTYPE type = 0;
        DWORD required = 0;
        if (SetupDiGetDevicePropertyW(set, device, &DEVPKEY_Device_DriverInfPath,
            &type, NULL, 0, &required, 0) || GetLastError() != ERROR_INSUFFICIENT_BUFFER ||
            type != DEVPROP_TYPE_STRING || required < sizeof(wchar_t))
        {
            return false;
        }
        std::vector<wchar_t> buffer(required / sizeof(wchar_t) + 1, L'\0');
        if (!SetupDiGetDevicePropertyW(set, device, &DEVPKEY_Device_DriverInfPath,
            &type, reinterpret_cast<PBYTE>(buffer.data()), required, NULL, 0) ||
            type != DEVPROP_TYPE_STRING)
        {
            return false;
        }
        *value = buffer.data();
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

    std::wstring MakeFullInfPath(const std::wstring &infName)
    {
        if (infName.find(L'\\') != std::wstring::npos || infName.find(L'/') != std::wstring::npos)
        {
            DWORD required = GetFullPathNameW(infName.c_str(), 0, NULL, NULL);
            if (required == 0 || required > 32767) return std::wstring();
            std::vector<wchar_t> buffer(required + 1, L'\0');
            DWORD written = GetFullPathNameW(infName.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), NULL);
            return (written != 0 && written < buffer.size()) ? std::wstring(buffer.data()) : std::wstring();
        }

        wchar_t windowsDirectory[MAX_PATH] = {};
        UINT length = GetWindowsDirectoryW(windowsDirectory, ARRAYSIZE(windowsDirectory));
        if (length == 0 || length >= ARRAYSIZE(windowsDirectory)) return std::wstring();
        std::wstring result(windowsDirectory);
        result += L"\\INF\\";
        result += infName;
        return result;
    }

    bool FindHr7Device(UsbDeviceSnapshot *snapshot)
    {
        HDEVINFO rawSet = SetupDiGetClassDevsW(NULL, NULL, NULL,
            DIGCF_ALLCLASSES | DIGCF_PRESENT);
        if (rawSet == INVALID_HANDLE_VALUE) return false;

        size_t matches = 0;
        for (DWORD index = 0; ; ++index)
        {
            SP_DEVINFO_DATA device = {};
            device.cbSize = sizeof(device);
            if (!SetupDiEnumDeviceInfo(rawSet, index, &device))
            {
                DWORD error = GetLastError();
                SetupDiDestroyDeviceInfoList(rawSet);
                if (error != ERROR_NO_MORE_ITEMS) { SetLastError(error); return false; }
                break;
            }

            std::vector<std::wstring> hardwareIds;
            if (!GetMultiStringProperty(rawSet, &device, SPDRP_HARDWAREID, &hardwareIds)) continue;
            std::wstring productHardwareId;
            for (const std::wstring &hardwareId : hardwareIds)
            {
                if (IsHr7HardwareId(hardwareId))
                {
                    productHardwareId = hardwareId;
                    break;
                }
            }
            if (productHardwareId.empty()) continue;

            UsbDeviceSnapshot candidate = {};
            candidate.hardwareId = productHardwareId;
            if (!GetInstanceId(rawSet, &device, &candidate.instanceId))
            {
                SetupDiDestroyDeviceInfoList(rawSet);
                SetLastError(ERROR_INVALID_DATA);
                return false;
            }
            GetStringProperty(rawSet, &device, SPDRP_SERVICE, &candidate.service);
            std::wstring inf;
            if (GetDriverInfPath(rawSet, &device, &inf)) candidate.infPath = MakeFullInfPath(inf);
            *snapshot = candidate;
            ++matches;
        }
        if (matches != 1)
        {
            SetLastError(matches == 0 ? ERROR_DEVICE_NOT_CONNECTED : ERROR_DUP_NAME);
            return false;
        }
        return true;
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

    bool ReadRegistryString(HKEY key, const wchar_t *name, std::wstring *value)
    {
        DWORD type = 0;
        DWORD bytes = 0;
        LONG status = RegQueryValueExW(key, name, NULL, &type, NULL, &bytes);
        if (status != ERROR_SUCCESS || type != REG_SZ || bytes < sizeof(wchar_t)) return false;
        std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
        status = RegQueryValueExW(key, name, NULL, &type,
            reinterpret_cast<BYTE *>(buffer.data()), &bytes);
        if (status != ERROR_SUCCESS || type != REG_SZ) return false;
        *value = buffer.data();
        return true;
    }

    bool ReadDriverState(DriverState *state)
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }

        state->found = ReadRegistryString(key, kVersionValue, &state->installedVersion);
        if (!state->found)
        {
            RegCloseKey(key);
            return true;
        }
        std::wstring managedValue;
        DWORD managed = 0;
        DWORD type = 0;
        DWORD bytes = sizeof(managed);
        status = RegQueryValueExW(key, kManagedValue, NULL, &type,
            reinterpret_cast<BYTE *>(&managed), &bytes);
        state->managed = status == ERROR_SUCCESS && type == REG_DWORD && managed != 0;
        if (!ReadRegistryString(key, kPriorInfValue, &state->priorInfPath)) state->priorInfPath.clear();
        if (!ReadRegistryString(key, kCurrentInfValue, &state->currentInfPath)) state->currentInfPath.clear();
        if (!ReadRegistryString(key, kHardwareIdValue, &state->hardwareId)) state->hardwareId.clear();
        if (!ReadRegistryString(key, kInstanceIdValue, &state->instanceId)) state->instanceId.clear();
        if (!ReadRegistryString(key, kStageDirectoryValue, &state->stageDirectory)) state->stageDirectory.clear();
        RegCloseKey(key);
        return true;
    }

    bool SetRegistryString(HKEY key, const wchar_t *name, const std::wstring &value)
    {
        LONG status = RegSetValueExW(key, name, 0, REG_SZ,
            reinterpret_cast<const BYTE *>(value.c_str()),
            static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
        if (status != ERROR_SUCCESS) SetLastError(static_cast<DWORD>(status));
        return status == ERROR_SUCCESS;
    }

    bool WriteDriverState(const DriverState &state, const wchar_t *version)
    {
        HKEY key = NULL;
        LONG status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0, NULL, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &key, NULL);
        if (status != ERROR_SUCCESS) { SetLastError(static_cast<DWORD>(status)); return false; }

        DWORD managed = state.managed ? 1U : 0U;
        status = RegSetValueExW(key, kManagedValue, 0, REG_DWORD,
            reinterpret_cast<const BYTE *>(&managed), sizeof(managed));
        bool ok = status == ERROR_SUCCESS &&
            SetRegistryString(key, kPriorInfValue, state.priorInfPath) &&
            SetRegistryString(key, kCurrentInfValue, state.currentInfPath) &&
            SetRegistryString(key, kHardwareIdValue, state.hardwareId) &&
            SetRegistryString(key, kInstanceIdValue, state.instanceId) &&
            SetRegistryString(key, kStageDirectoryValue, state.stageDirectory);
        if (ok)
        {
            ok = SetRegistryString(key, kVersionValue, version); // marker last, for Burn detection
        }
        else if (status != ERROR_SUCCESS)
        {
            SetLastError(static_cast<DWORD>(status));
        }
        RegCloseKey(key);
        return ok;
    }

    bool DeleteRegistryKeyIfEmpty(const wchar_t *path)
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, path, 0,
            KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND) return true;
        if (status != ERROR_SUCCESS)
        {
            SetLastError(static_cast<DWORD>(status));
            return false;
        }

        DWORD subKeyCount = 0;
        DWORD valueCount = 0;
        status = RegQueryInfoKeyW(key, NULL, NULL, NULL, &subKeyCount, NULL, NULL,
            &valueCount, NULL, NULL, NULL, NULL);
        RegCloseKey(key);
        if (status != ERROR_SUCCESS)
        {
            SetLastError(static_cast<DWORD>(status));
            return false;
        }
        if (subKeyCount != 0 || valueCount != 0) return true;

        status = RegDeleteKeyExW(HKEY_LOCAL_MACHINE, path, KEY_WOW64_64KEY, 0);
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
        {
            SetLastError(static_cast<DWORD>(status));
            return false;
        }
        return true;
    }

    bool DeleteDriverState()
    {
        HKEY key = NULL;
        LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegistryPath, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, &key);
        if (status == ERROR_FILE_NOT_FOUND)
            return DeleteRegistryKeyIfEmpty(kRegistryPath) && DeleteRegistryKeyIfEmpty(kProductRegistryPath);
        if (status != ERROR_SUCCESS)
        {
            SetLastError(static_cast<DWORD>(status));
            return false;
        }
        const wchar_t *const values[] = {
            kVersionValue, kManagedValue, kPriorInfValue, kCurrentInfValue,
            kHardwareIdValue, kInstanceIdValue, kStageDirectoryValue
        };
        DWORD error = ERROR_SUCCESS;
        for (const wchar_t *value : values)
        {
            status = RegDeleteValueW(key, value);
            if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND && error == ERROR_SUCCESS)
                error = static_cast<DWORD>(status);
        }
        RegCloseKey(key);
        if (error != ERROR_SUCCESS) SetLastError(error);
        if (error != ERROR_SUCCESS) return false;
        return DeleteRegistryKeyIfEmpty(kRegistryPath) && DeleteRegistryKeyIfEmpty(kProductRegistryPath);
    }

    std::wstring WideFromUtf8(const char *value)
    {
        if (!value || !*value) return std::wstring();
        int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
        if (required <= 0) return std::wstring();
        std::vector<wchar_t> buffer(required, L'\0');
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, buffer.data(), required))
            return std::wstring();
        return buffer.data();
    }

    bool FindMatchingWdiDevice(wdi_device_info *list, const UsbDeviceSnapshot &snapshot,
                               wdi_device_info **match)
    {
        *match = NULL;
        size_t matches = 0;
        for (wdi_device_info *device = list; device; device = device->next)
        {
            if (device->vid != 0x0458 || device->pid != 0x2013) continue;
            const std::wstring hardwareId = WideFromUtf8(device->hardware_id);
            const std::wstring instanceId = WideFromUtf8(device->device_id);
            if (_wcsicmp(hardwareId.c_str(), snapshot.hardwareId.c_str()) == 0 ||
                _wcsicmp(instanceId.c_str(), snapshot.instanceId.c_str()) == 0)
            {
                *match = device;
                ++matches;
            }
        }
        if (matches != 1)
        {
            SetLastError(matches == 0 ? ERROR_DEVICE_NOT_CONNECTED : ERROR_DUP_NAME);
            return false;
        }
        return true;
    }

    std::wstring MakeStageDirectory()
    {
        wchar_t programData[MAX_PATH] = {};
        if (FAILED(SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL, SHGFP_TYPE_CURRENT, programData)))
            return std::wstring();

        GUID id = {};
        if (FAILED(CoCreateGuid(&id))) return std::wstring();
        wchar_t guidText[40] = {};
        if (StringFromGUID2(id, guidText, ARRAYSIZE(guidText)) == 0) return std::wstring();

        const DWORD rootAttributes = GetFileAttributesW(programData);
        if (rootAttributes == INVALID_FILE_ATTRIBUTES ||
            (rootAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (rootAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            SetLastError(ERROR_INVALID_DATA);
            return std::wstring();
        }

        std::wstring parent(programData);
        const wchar_t *const directories[] = {
            L"GeniusColorPage-HR7", L"WinUSB", HR7_PACKAGE_VERSION
        };
        for (const wchar_t *directory : directories)
        {
            parent += L"\\";
            parent += directory;
            if (!CreateDirectoryW(parent.c_str(), NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
                return std::wstring();
            const DWORD attributes = GetFileAttributesW(parent.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES ||
                (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            {
                SetLastError(ERROR_INVALID_DATA);
                return std::wstring();
            }
        }

        std::wstring folder = parent + L"\\" + guidText;
        if (!CreateDirectoryW(folder.c_str(), NULL)) return std::wstring();
        const DWORD folderAttributes = GetFileAttributesW(folder.c_str());
        if (folderAttributes == INVALID_FILE_ATTRIBUTES ||
            (folderAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (folderAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            SetLastError(ERROR_INVALID_DATA);
            return std::wstring();
        }
        return folder;
    }

    bool AskForDriverChange()
    {
        const wchar_t message[] =
            L"The Genius ColorPage-HR7 installer needs to associate WinUSB with USB device 0458:2013.\n\n"
            L"This replaces the current USB driver for this scanner only. libwdi will create and sign a "
            L"device-specific driver package and may add its device-specific certificate to Windows trust stores. "
            L"Windows may show an additional certificate or driver-trust warning.\n\n"
            L"Continue with this scanner-only change?\n\n"
            L"O instalador precisa associar o WinUSB ao dispositivo USB 0458:2013. A alteracao afeta somente este scanner. "
            L"Um certificado especifico do dispositivo podera ser adicionado aos repositorios de confianca do Windows.\n\n"
            L"Continue / Continuar?";
        return MessageBoxW(NULL, message, L"Genius ColorPage-HR7 — WinUSB driver",
            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2 | MB_SETFOREGROUND) == IDYES;
    }

    bool RestoreDriver(const std::wstring &hardwareId, const std::wstring &infPath)
    {
        if (infPath.empty() || GetFileAttributesW(infPath.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            SetLastError(ERROR_FILE_NOT_FOUND);
            return false;
        }
        BOOL reboot = FALSE;
        return UpdateDriverForPlugAndPlayDevicesW(NULL, hardwareId.c_str(), infPath.c_str(),
            INSTALLFLAG_FORCE, &reboot) != FALSE;
    }

    bool InstallWinUsb(const UsbDeviceSnapshot &before, const DriverState &previous,
                       DriverState *updated)
    {
        if (!AskForDriverChange())
        {
            SetLastError(ERROR_CANCELLED);
            return false;
        }

        WdiDeviceList list;
        wdi_options_create_list listOptions = {};
        listOptions.list_all = TRUE;
        listOptions.list_hubs = FALSE;
        listOptions.trim_whitespaces = TRUE;
        int wdiError = wdi_create_list(&list.items, &listOptions);
        if (wdiError != WDI_SUCCESS)
        {
            MessageBoxA(NULL, wdi_strerror(wdiError), "Could not enumerate the HR7 USB device", MB_OK | MB_ICONERROR);
            SetLastError(ERROR_DEVICE_NOT_CONNECTED);
            return false;
        }
        wdi_device_info *device = NULL;
        if (!FindMatchingWdiDevice(list.items, before, &device)) return false;

        ScopedStageDirectory stage;
        stage.path = MakeStageDirectory();
        if (stage.path.empty()) return false;
        const std::wstring stageInf = stage.path + L"\\" + kStageInfName;
        int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, stage.path.c_str(), -1, NULL, 0, NULL, NULL);
        if (required <= 0) return false;
        std::vector<char> utf8Path(required, '\0');
        if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, stage.path.c_str(), -1,
            utf8Path.data(), required, NULL, NULL)) return false;

        wdi_options_prepare_driver prepareOptions = {};
        prepareOptions.driver_type = WDI_WINUSB;
        prepareOptions.vendor_name = const_cast<char *>("Genius");
        prepareOptions.disable_cat = FALSE;
        prepareOptions.disable_signing = FALSE;
        prepareOptions.use_wcid_driver = FALSE;
        prepareOptions.external_inf = FALSE;
        wdiError = wdi_prepare_driver(device, utf8Path.data(),
            const_cast<char *>("hr7-winusb.inf"), &prepareOptions);
        if (wdiError != WDI_SUCCESS)
        {
            MessageBoxA(NULL, wdi_strerror(wdiError), "Could not prepare the HR7 WinUSB package", MB_OK | MB_ICONERROR);
            SetLastError(ERROR_INSTALL_FAILURE);
            return false;
        }

        wdi_options_install_driver installOptions = {};
        installOptions.hWnd = GetForegroundWindow();
        installOptions.install_filter_driver = FALSE;
        installOptions.pending_install_timeout = 60000;
        wdiError = wdi_install_driver(device, utf8Path.data(),
            const_cast<char *>("hr7-winusb.inf"), &installOptions);
        if (wdiError != WDI_SUCCESS)
        {
            MessageBoxA(NULL, wdi_strerror(wdiError), "Could not install WinUSB for the HR7", MB_OK | MB_ICONERROR);
            // wdi_install_driver may have changed the binding before an error.
            if (previous.managed && !previous.currentInfPath.empty())
                RestoreDriver(before.hardwareId, previous.currentInfPath);
            else if (!previous.priorInfPath.empty())
                RestoreDriver(before.hardwareId, previous.priorInfPath);
            DiUninstallDriverW(NULL, stageInf.c_str(), 0, NULL);
            SetLastError(ERROR_INSTALL_FAILURE);
            return false;
        }

        UsbDeviceSnapshot after = {};
        bool found = false;
        for (int attempt = 0; attempt < 30; ++attempt)
        {
            if (FindHr7Device(&after) && _wcsicmp(after.service.c_str(), L"WinUSB") == 0 && !after.infPath.empty())
            {
                found = true;
                break;
            }
            Sleep(1000);
        }
        if (!found)
        {
            if (previous.managed && !previous.currentInfPath.empty())
                RestoreDriver(before.hardwareId, previous.currentInfPath);
            else if (!previous.priorInfPath.empty())
                RestoreDriver(before.hardwareId, previous.priorInfPath);
            DiUninstallDriverW(NULL, stageInf.c_str(), 0, NULL);
            SetLastError(ERROR_DEVICE_NOT_CONNECTED);
            return false;
        }

        updated->found = true;
        updated->managed = true;
        updated->priorInfPath = previous.managed ? previous.priorInfPath : before.infPath;
        updated->currentInfPath = after.infPath;
        updated->hardwareId = before.hardwareId;
        updated->instanceId = after.instanceId;
        updated->stageDirectory.clear(); // libwdi copied the signed package into Driver Store.
        return true;
    }

    bool InstallOrRepair()
    {
        DriverState previous;
        if (!ReadDriverState(&previous)) return false;

        UsbDeviceSnapshot before = {};
        if (!FindHr7Device(&before)) return false;
        if (previous.found && !previous.managed)
        {
            if (_wcsicmp(before.service.c_str(), L"WinUSB") == 0)
                return WriteDriverState(previous, HR7_PACKAGE_VERSION);
        }
        if (!previous.managed && _wcsicmp(before.service.c_str(), L"WinUSB") == 0)
        {
            // Zadig/libwdi or another administrator already installed WinUSB.
            // Record that the package relies on, but does not own, this binding.
            DriverState unmanaged;
            unmanaged.found = true;
            unmanaged.managed = false;
            unmanaged.hardwareId = before.hardwareId;
            unmanaged.instanceId = before.instanceId;
            unmanaged.currentInfPath = before.infPath;
            return WriteDriverState(unmanaged, HR7_PACKAGE_VERSION);
        }

        if (previous.managed &&
            (_wcsicmp(before.service.c_str(), L"WinUSB") != 0 || before.infPath.empty() ||
             _wcsicmp(before.infPath.c_str(), previous.currentInfPath.c_str()) != 0))
        {
            // Never replace a binding that the user or another installer changed.
            SetLastError(ERROR_INVALID_STATE);
            return false;
        }

        DriverState updated;
        if (!InstallWinUsb(before, previous, &updated)) return false;
        if (!WriteDriverState(updated, HR7_PACKAGE_VERSION))
        {
            DWORD markerError = GetLastError();
            const std::wstring &rollbackInf = previous.managed
                ? previous.currentInfPath : previous.priorInfPath;
            if (!rollbackInf.empty()) RestoreDriver(before.hardwareId, rollbackInf);
            DiUninstallDriverW(NULL, updated.currentInfPath.c_str(), 0, NULL);
            SetLastError(markerError);
            return false;
        }
        if (previous.managed && !previous.currentInfPath.empty() &&
            _wcsicmp(previous.currentInfPath.c_str(), updated.currentInfPath.c_str()) != 0)
        {
            // The scanner now uses the new package; retire only the old
            // product-owned package from the Driver Store.
            DiUninstallDriverW(NULL, previous.currentInfPath.c_str(), 0, NULL);
        }
        return true;
    }

    bool RemoveOwnedDriver()
    {
        DriverState state;
        if (!ReadDriverState(&state)) return false;
        if (!state.found) return true;
        if (!state.managed)
        {
            return DeleteDriverState();
        }
        if (state.currentInfPath.empty() || state.hardwareId.empty())
        {
            SetLastError(ERROR_INVALID_DATA);
            return false;
        }

        UsbDeviceSnapshot current = {};
        const bool devicePresent = FindHr7Device(&current);
        if (devicePresent)
        {
            if (_wcsicmp(current.service.c_str(), L"WinUSB") != 0 ||
                _wcsicmp(current.infPath.c_str(), state.currentInfPath.c_str()) != 0)
            {
                SetLastError(ERROR_INVALID_STATE);
                return false; // Do not overwrite a driver another tool installed later.
            }
            if (!state.priorInfPath.empty())
            {
                if (!RestoreDriver(state.hardwareId, state.priorInfPath)) return false;
            }
        }
        else if (GetLastError() != ERROR_DEVICE_NOT_CONNECTED)
        {
            return false;
        }

        BOOL reboot = FALSE;
        if (!DiUninstallDriverW(NULL, state.currentInfPath.c_str(), 0, &reboot)) return false;
        return DeleteDriverState();
    }

    void ShowFailure(const wchar_t *operation)
    {
        DWORD error = GetLastError();
        wchar_t message[512] = {};
        StringCchPrintfW(message, ARRAYSIZE(message),
            L"%ls failed with Windows error %lu (0x%08lx).\n\n"
            L"The installer did not intentionally change any USB device other than the Genius HR7.\n"
            L"Reconnect the scanner and review Windows SetupAPI logs before retrying.",
            operation, error, error);
        MessageBoxW(NULL, message, L"Genius ColorPage-HR7 setup", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    }
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    if (!IsAdministrator())
    {
        MessageBoxW(NULL, L"Run this action only through the elevated Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 setup", MB_OK | MB_ICONERROR);
        return ERROR_ELEVATION_REQUIRED;
    }

    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 2 || (_wcsicmp(argv[1], L"install") != 0 && _wcsicmp(argv[1], L"remove") != 0))
    {
        if (argv) LocalFree(argv);
        MessageBoxW(NULL, L"This helper is invoked by the Genius ColorPage-HR7 GUI installer.",
            L"Genius ColorPage-HR7 setup", MB_OK | MB_ICONERROR);
        return ERROR_INVALID_PARAMETER;
    }

    const bool installing = _wcsicmp(argv[1], L"install") == 0;
    LocalFree(argv);
    const bool ok = installing ? InstallOrRepair() : RemoveOwnedDriver();
    if (!ok)
    {
        ShowFailure(installing ? L"WinUSB installation" : L"WinUSB restoration/removal");
        DWORD error = GetLastError();
        return error == ERROR_SUCCESS ? ERROR_INSTALL_FAILURE : error;
    }
    return ERROR_SUCCESS;
}
