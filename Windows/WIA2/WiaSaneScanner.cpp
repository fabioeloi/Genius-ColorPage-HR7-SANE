#include <winsock2.h>
#include "stdafx.h"
#include "WiaSaneScanner.h"

#include <math.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include "winsane.h"

namespace
{
    const ULONG kMaximumImageBytes = 512UL * 1024UL * 1024UL;
    const DWORD kSaneChunkBytes = 128UL * 1024UL;
    const ULONGLONG kMaximumScanMilliseconds = 10ULL * 60ULL * 1000ULL;

    HRESULT MapSaneFailure(SANE_Status status)
    {
        switch (status)
        {
        case SANE_STATUS_NO_MEM:
            return E_OUTOFMEMORY;
        case SANE_STATUS_CANCELLED:
            return S_FALSE;
        case SANE_STATUS_DEVICE_BUSY:
            return HRESULT_FROM_WIN32(ERROR_BUSY);
        case SANE_STATUS_INVAL:
        case SANE_STATUS_UNSUPPORTED:
            return E_INVALIDARG;
        default:
            return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
        }
    }

    HRESULT RefreshOptions(PWINSANE_Device device)
    {
        if (!device || device->FetchOptions() != SANE_STATUS_GOOD)
        {
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        return S_OK;
    }

    HRESULT SetMode(PWINSANE_Device device, BOOL grayscale)
    {
        static const char *const grayNames[] = { "Gray", "Grey", "Grayscale", "Greyscale", NULL };
        static const char *const colorNames[] = { "Color", "Colour", "RGB", NULL };
        const char *const *candidates = grayscale ? grayNames : colorNames;
        PWINSANE_Option option = device ? device->GetOption("mode") : NULL;
        const char *selected = NULL;

        if (!option || option->GetType() != SANE_TYPE_STRING ||
            (option->GetCapabilities() & SANE_CAP_INACTIVE))
        {
            return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        }

        if (option->GetConstraintType() == SANE_CONSTRAINT_STRING_LIST)
        {
            PSANE_String_Const values = option->GetConstraintStringList();
            if (!values)
            {
                return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
            }

            for (const char *const *candidate = candidates; *candidate && !selected; ++candidate)
            {
                for (LONG index = 0; values[index]; ++index)
                {
                    if (_stricmp(values[index], *candidate) == 0)
                    {
                        selected = values[index];
                        break;
                    }
                }
            }
        }
        else
        {
            selected = grayscale ? "Gray" : "Color";
        }

        if (!selected)
        {
            return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        }

        HRESULT hr = option->SetValueString(selected);
        if (FAILED(hr))
        {
            return hr;
        }
        return RefreshOptions(device);
    }

    HRESULT SetPreview(PWINSANE_Device device, BOOL preview)
    {
        PWINSANE_Option option = device ? device->GetOption("preview") : NULL;
        if (!option || (option->GetCapabilities() & SANE_CAP_INACTIVE))
        {
            // SANE preview is optional. WIA clients can still request a lower
            // resolution for preview when the backend does not expose it.
            return S_OK;
        }
        if (option->GetType() != SANE_TYPE_BOOL)
        {
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }

        HRESULT hr = option->SetValueBool(preview ? SANE_TRUE : SANE_FALSE);
        if (FAILED(hr))
        {
            return hr;
        }
        return RefreshOptions(device);
    }

    HRESULT SetNumericOption(PWINSANE_Device device, const char *name, double value, double tolerance)
    {
        PWINSANE_Option option = device ? device->GetOption(name) : NULL;
        double actual = 0.0;
        HRESULT hr;

        if (!option || (option->GetCapabilities() & SANE_CAP_INACTIVE) ||
            (option->GetType() != SANE_TYPE_INT && option->GetType() != SANE_TYPE_FIXED))
        {
            return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        }

        hr = option->SetValue(value);
        if (FAILED(hr))
        {
            return hr;
        }

        hr = option->GetValue(&actual);
        if (FAILED(hr) || fabs(actual - value) > tolerance)
        {
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        return RefreshOptions(device);
    }

    HRESULT SetResolution(PWINSANE_Device device, const HR7_SCAN_REQUEST &request)
    {
        PWINSANE_Option option = device ? device->GetOption("resolution") : NULL;
        if (option)
        {
            if (request.xResolution != request.yResolution)
            {
                return E_INVALIDARG;
            }
            return SetNumericOption(device, "resolution", (double)request.xResolution, 0.5);
        }

        HRESULT hr = SetNumericOption(device, "x-resolution", (double)request.xResolution, 0.5);
        if (FAILED(hr))
        {
            return hr;
        }
        return SetNumericOption(device, "y-resolution", (double)request.yResolution, 0.5);
    }

    HRESULT SetAreaOption(PWINSANE_Device device, const char *name, LONG pixels, LONG dpi)
    {
        PWINSANE_Option option = device ? device->GetOption(name) : NULL;
        double value;

        if (!option || dpi <= 0 || pixels < 0)
        {
            return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        }

        value = (double)pixels;
        switch (option->GetUnit())
        {
        case SANE_UNIT_PIXEL:
            break;
        case SANE_UNIT_MM:
            value = value * 25.4 / (double)dpi;
            break;
        default:
            return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        }

        // Scanner coordinates are quantized mechanically; allow at most a
        // quarter millimetre while rejecting materially clamped selections.
        const double tolerance = option->GetUnit() == SANE_UNIT_MM ? 0.25 : 1.0;
        return SetNumericOption(device, name, value, tolerance);
    }

    HRESULT FindHr7(PWINSANE_Session session, PWINSANE_Device *device)
    {
        LONG matches = 0;
        if (!session || !device)
        {
            return E_POINTER;
        }
        *device = NULL;

        for (LONG index = 0; index < session->GetDevices(); ++index)
        {
            PWINSANE_Device candidate = session->GetDevice(index);
            const char *vendor = candidate ? candidate->GetVendor() : NULL;
            const char *model = candidate ? candidate->GetModel() : NULL;
            if (vendor && model && _stricmp(vendor, "KYE/Genius") == 0 &&
                _stricmp(model, "ColorPage-HR7") == 0)
            {
                *device = candidate;
                ++matches;
            }
        }
        return matches == 1 ? S_OK : HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
    }

    HRESULT CreateBitmap(LONG width, LONG height, LONG dpiX, LONG dpiY,
                         HBITMAP *bitmap, BYTE **bits, LONG *stride)
    {
        BITMAPINFO info = {};
        uint64_t rowBytes;
        uint64_t imageBytes;
        void *dibBits = NULL;

        if (!bitmap || !bits || !stride || width <= 0 || height <= 0 || dpiX <= 0 || dpiY <= 0)
        {
            return E_INVALIDARG;
        }

        rowBytes = (((uint64_t)width * 3ULL) + 3ULL) & ~3ULL;
        imageBytes = rowBytes * (uint64_t)height;
        if (rowBytes > LONG_MAX || imageBytes == 0 || imageBytes > kMaximumImageBytes || imageBytes > MAXDWORD)
        {
            return HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
        }

        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height; // top-down; SANE frames are top-to-bottom
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 24;
        info.bmiHeader.biCompression = BI_RGB;
        info.bmiHeader.biSizeImage = (DWORD)imageBytes;
        info.bmiHeader.biXPelsPerMeter = (LONG)((double)dpiX / 0.0254 + 0.5);
        info.bmiHeader.biYPelsPerMeter = (LONG)((double)dpiY / 0.0254 + 0.5);

        *bitmap = CreateDIBSection(NULL, &info, DIB_RGB_COLORS, &dibBits, NULL, 0);
        if (!*bitmap || !dibBits)
        {
            if (*bitmap)
            {
                DeleteObject(*bitmap);
                *bitmap = NULL;
            }
            DWORD error = GetLastError();
            return HRESULT_FROM_WIN32(error ? error : ERROR_NOT_ENOUGH_MEMORY);
        }

        *bits = (BYTE *)dibBits;
        *stride = (LONG)rowBytes;
        return S_OK;
    }

    BYTE AdjustTone(BYTE input, LONG brightness, LONG contrast)
    {
        // WIA brightness and contrast use a -1000..1000 range. Apply the
        // controls to returned pixels so behavior is independent of optional
        // vendor-specific controls on the loopback SANE backend.
        const double scale = (1000.0 + (double)contrast) / 1000.0;
        double value = (((double)input - 127.5) * scale) + 127.5 +
            ((double)brightness * 255.0 / 1000.0);
        if (value <= 0.0) return 0;
        if (value >= 255.0) return 255;
        return (BYTE)(value + 0.5);
    }

    HRESULT CopyFrame(PWINSANE_Device device, PWINSANE_Scan scan,
                      BOOL grayscale, LONG brightness, LONG contrast,
                      LONG dpiX, LONG dpiY,
                      HR7_SCAN_PROGRESS_CALLBACK progress, void *progressContext,
                      BOOL *scanEnded,
                      HBITMAP *bitmap)
    {
        PWINSANE_Params params = NULL;
        SANE_Status status;
        SANE_Frame format;
        SANE_Int bytesPerLine, width, height, depth;
        LONG destinationStride = 0;
        BYTE *destinationBits = NULL;
        BYTE *row = NULL;
        DWORD rowOffset = 0;
        LONG completedRows = 0;
        ULONG transferred = 0;
        ULONG totalBytes = 0;
        ULONG emptyReads = 0;
        BYTE chunk[kSaneChunkBytes];
        ULONGLONG startedAt = GetTickCount64();
        HRESULT hr = S_OK;

        if (!scanEnded)
        {
            return E_POINTER;
        }
        *scanEnded = FALSE;

        // The first call establishes the separate scan-data socket.
        DWORD length = 0;
        status = scan->AquireImage(chunk, &length);
        if (status != SANE_STATUS_GOOD)
        {
            return MapSaneFailure(status);
        }
        if (length != 0)
        {
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }

        status = device->GetParams(&params);
        if (status != SANE_STATUS_GOOD || !params)
        {
            return MapSaneFailure(status);
        }

        format = params->GetFormat();
        bytesPerLine = params->GetBytesPerLine();
        width = params->GetPixelsPerLine();
        height = params->GetLines();
        depth = params->GetDepth();
        if (params->IsLastFrame() == FALSE)
        {
            delete params;
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        if (depth != 8)
        {
            delete params;
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        if ((grayscale && format != SANE_FRAME_GRAY) ||
            (!grayscale && format != SANE_FRAME_RGB))
        {
            delete params;
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        if (width <= 0 || height <= 0)
        {
            delete params;
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        if (bytesPerLine <= 0 ||
            (uint64_t)bytesPerLine < (uint64_t)width * (grayscale ? 1ULL : 3ULL))
        {
            delete params;
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }

        uint64_t expected = (uint64_t)bytesPerLine * (uint64_t)height;
        if (expected == 0 || expected > kMaximumImageBytes || expected > ULONG_MAX)
        {
            delete params;
            return HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
        }
        totalBytes = (ULONG)expected;

        hr = CreateBitmap(width, height, dpiX, dpiY, bitmap, &destinationBits, &destinationStride);
        if (FAILED(hr))
        {
            delete params;
            return hr;
        }

        row = (BYTE *)HeapAlloc(GetProcessHeap(), 0, (SIZE_T)bytesPerLine);
        if (!row)
        {
            delete params;
            DeleteObject(*bitmap);
            *bitmap = NULL;
            return E_OUTOFMEMORY;
        }

        while (TRUE)
        {
            length = sizeof(chunk);
            status = scan->AquireImage(chunk, &length);
            if (status == SANE_STATUS_EOF)
            {
                *scanEnded = TRUE;
                break;
            }
            if (status != SANE_STATUS_GOOD)
            {
                hr = MapSaneFailure(status);
                break;
            }
            if (length == 0)
            {
                if (++emptyReads > 1000)
                {
                    hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                    break;
                }
                continue;
            }
            emptyReads = 0;

            if ((uint64_t)transferred + length > expected)
            {
                hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                break;
            }
            transferred += length;

            DWORD offset = 0;
            while (offset < length)
            {
                DWORD copyBytes = min((DWORD)bytesPerLine - rowOffset, length - offset);
                memcpy(row + rowOffset, chunk + offset, copyBytes);
                rowOffset += copyBytes;
                offset += copyBytes;

                if (rowOffset == (DWORD)bytesPerLine)
                {
                    BYTE *out = destinationBits + (SIZE_T)completedRows * destinationStride;
                    memset(out, 0, (SIZE_T)destinationStride);
                    if (grayscale)
                    {
                        for (LONG x = 0; x < width; ++x)
                        {
                            BYTE value = AdjustTone(row[x], brightness, contrast);
                            out[x * 3 + 0] = value;
                            out[x * 3 + 1] = value;
                            out[x * 3 + 2] = value;
                        }
                    }
                    else
                    {
                        for (LONG x = 0; x < width; ++x)
                        {
                            out[x * 3 + 0] = AdjustTone(row[x * 3 + 2], brightness, contrast); // B
                            out[x * 3 + 1] = AdjustTone(row[x * 3 + 1], brightness, contrast); // G
                            out[x * 3 + 2] = AdjustTone(row[x * 3 + 0], brightness, contrast); // R
                        }
                    }
                    ++completedRows;
                    rowOffset = 0;
                    if (completedRows > height)
                    {
                        hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
                        break;
                    }
                }
            }
            if (FAILED(hr))
            {
                break;
            }

            if (GetTickCount64() - startedAt > kMaximumScanMilliseconds)
            {
                hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                break;
            }

            if (progress)
            {
                ULONG percent = (ULONG)(((uint64_t)transferred * 100ULL) / totalBytes);
                hr = progress(progressContext, min(percent, 99UL), transferred);
                if (hr != S_OK)
                {
                    break;
                }
            }
        }

        HeapFree(GetProcessHeap(), 0, row);
        delete params;

        if (hr == S_OK && (transferred != totalBytes || completedRows != height || rowOffset != 0))
        {
            hr = HRESULT_FROM_WIN32(ERROR_HANDLE_EOF);
        }
        if (hr == S_OK && progress)
        {
            hr = progress(progressContext, 100, transferred);
        }
        return hr;
    }
}

HRESULT AcquireHR7ScanBitmap(
    _In_ const HR7_SCAN_REQUEST *request,
    _In_opt_ HR7_SCAN_PROGRESS_CALLBACK progress,
    _In_opt_ void *progressContext,
    _Outptr_result_maybenull_ HBITMAP *bitmap)
{
    WSADATA winsockData = {};
    BOOL winsockStarted = FALSE;
    BOOL scanStarted = FALSE;
    BOOL scanEnded = FALSE;
    PWINSANE_Session session = NULL;
    PWINSANE_Device device = NULL;
    PWINSANE_Scan scan = NULL;
    HRESULT hr = E_FAIL;
    SANE_Status status;

    if (!request || !bitmap)
    {
        return E_INVALIDARG;
    }
    *bitmap = NULL;
    if (request->xResolution < 75 || request->yResolution < 75 ||
        request->xResolution > 600 || request->yResolution > 600 ||
        request->brightness < -1000 || request->brightness > 1000 ||
        request->contrast < -1000 || request->contrast > 1000 ||
        request->xPosition < 0 || request->yPosition < 0 ||
        request->xExtent <= 0 || request->yExtent <= 0 ||
        request->xPosition > LONG_MAX - request->xExtent ||
        request->yPosition > LONG_MAX - request->yExtent)
    {
        return E_INVALIDARG;
    }

    if (WSAStartup(MAKEWORD(2, 2), &winsockData) != 0)
    {
        return HRESULT_FROM_WIN32(ERROR_SERVICE_NOT_ACTIVE);
    }
    winsockStarted = TRUE;

    TCHAR loopbackAddress[] = TEXT("127.0.0.1");
    session = WINSANE_Session::Remote(loopbackAddress, 6566);
    if (!session)
    {
        hr = HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
        goto Cleanup;
    }
    status = session->Init(NULL, NULL);
    if (status != SANE_STATUS_GOOD)
    {
        hr = MapSaneFailure(status);
        goto Cleanup;
    }
    status = session->FetchDevices();
    if (status != SANE_STATUS_GOOD)
    {
        hr = MapSaneFailure(status);
        goto Cleanup;
    }
    hr = FindHr7(session, &device);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    status = device->Open();
    if (status != SANE_STATUS_GOOD)
    {
        hr = MapSaneFailure(status);
        goto Cleanup;
    }
    hr = RefreshOptions(device);
    if (FAILED(hr))
    {
        goto Cleanup;
    }

    hr = SetMode(device, request->grayscale);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    hr = SetPreview(device, request->preview);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    hr = SetResolution(device, *request);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    hr = SetAreaOption(device, "tl-x", request->xPosition, request->xResolution);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    hr = SetAreaOption(device, "tl-y", request->yPosition, request->yResolution);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    hr = SetAreaOption(device, "br-x", request->xPosition + request->xExtent, request->xResolution);
    if (FAILED(hr))
    {
        goto Cleanup;
    }
    hr = SetAreaOption(device, "br-y", request->yPosition + request->yExtent, request->yResolution);
    if (FAILED(hr))
    {
        goto Cleanup;
    }

    status = device->Start(&scan);
    if (status != SANE_STATUS_GOOD || !scan)
    {
        hr = MapSaneFailure(status);
        goto Cleanup;
    }
    scanStarted = TRUE;
    hr = CopyFrame(device, scan, request->grayscale, request->brightness,
                   request->contrast, request->xResolution,
                   request->yResolution, progress, progressContext,
                   &scanEnded, bitmap);
    if (scanEnded)
    {
        scanStarted = FALSE;
    }
    if (hr == S_OK)
    {
        scanStarted = FALSE;
    }

Cleanup:
    if (scanStarted && device && device->IsOpen())
    {
        device->Cancel();
    }
    if (scan)
    {
        delete scan;
    }
    if (session)
    {
        delete session;
    }
    if (winsockStarted)
    {
        WSACleanup();
    }
    if (hr != S_OK && *bitmap)
    {
        DeleteObject(*bitmap);
        *bitmap = NULL;
    }
    return hr;
}
