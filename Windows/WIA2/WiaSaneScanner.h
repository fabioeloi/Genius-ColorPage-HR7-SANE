#pragma once

typedef HRESULT (*HR7_SCAN_PROGRESS_CALLBACK)(
    _In_opt_ void *context,
    _In_ ULONG percentComplete,
    _In_ ULONG bytesTransferred);

typedef struct _HR7_SCAN_REQUEST
{
    BOOL grayscale;
    BOOL preview;
    LONG brightness;
    LONG contrast;
    LONG xResolution;
    LONG yResolution;
    LONG xPosition;
    LONG yPosition;
    LONG xExtent;
    LONG yExtent;
} HR7_SCAN_REQUEST, *PHR7_SCAN_REQUEST;

// Acquires only from the product's loopback SANE endpoint. The network client
// verifies the advertised KYE/Genius ColorPage-HR7 before opening a device.
HRESULT AcquireHR7ScanBitmap(
    _In_ const HR7_SCAN_REQUEST *request,
    _In_opt_ HR7_SCAN_PROGRESS_CALLBACK progress,
    _In_opt_ void *progressContext,
    _Outptr_result_maybenull_ HBITMAP *bitmap);
