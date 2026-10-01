#include <windows.h>
#include <bcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#pragma comment(lib, "bcrypt.lib")

static void usage(void)
{
    fwprintf(stderr,
        L"usage: wslpart-read --device Path --offset Bytes --length Bytes\n");
    ExitProcess(ERROR_INVALID_PARAMETER);
}

static UINT64 parse_u64(const wchar_t *text)
{
    wchar_t *end = 0;
    unsigned __int64 value;

    if (0 == text || L'\0' == text[0])
        usage();
    value = _wcstoui64(text, &end, 0);
    if (end == text || L'\0' != *end)
        usage();
    return (UINT64)value;
}

static void print_error(const wchar_t *operation)
{
    fwprintf(stderr, L"%ls failed: error %lu\n", operation, GetLastError());
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *device = 0;
    UINT64 offset = 0;
    UINT64 length = 0;
    HANDLE file = INVALID_HANDLE_VALUE;
    BCRYPT_ALG_HANDLE algorithm = 0;
    BCRYPT_HASH_HANDLE hash = 0;
    PUCHAR hash_object = 0;
    PUCHAR buffer = 0;
    DWORD object_length = 0;
    DWORD hash_length = 0;
    DWORD result_length = 0;
    UINT64 remaining;
    DWORD error = ERROR_SUCCESS;
    NTSTATUS status;
    UCHAR digest[32];

    for (int i = 1; i < argc; i++)
    {
        if (0 == wcscmp(argv[i], L"--device") && i + 1 < argc)
            device = argv[++i];
        else if (0 == wcscmp(argv[i], L"--offset") && i + 1 < argc)
            offset = parse_u64(argv[++i]);
        else if (0 == wcscmp(argv[i], L"--length") && i + 1 < argc)
            length = parse_u64(argv[++i]);
        else
            usage();
    }

    if (0 == device || 0 == length)
        usage();

    file = CreateFileW(device, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (INVALID_HANDLE_VALUE == file)
    {
        print_error(L"open device");
        return 1;
    }

    status = BCryptOpenAlgorithmProvider(&algorithm,
        BCRYPT_SHA256_ALGORITHM, 0, 0);
    if (!BCRYPT_SUCCESS(status))
    {
        error = ERROR_FUNCTION_FAILED;
        goto exit;
    }
    status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
        (PUCHAR)&object_length, sizeof object_length, &result_length, 0);
    if (!BCRYPT_SUCCESS(status))
    {
        error = ERROR_FUNCTION_FAILED;
        goto exit;
    }
    status = BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
        (PUCHAR)&hash_length, sizeof hash_length, &result_length, 0);
    if (!BCRYPT_SUCCESS(status) || sizeof digest != hash_length)
    {
        error = ERROR_FUNCTION_FAILED;
        goto exit;
    }
    hash_object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_length);
    buffer = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, 1024 * 1024);
    if (0 == hash_object || 0 == buffer)
    {
        error = ERROR_NOT_ENOUGH_MEMORY;
        goto exit;
    }
    status = BCryptCreateHash(algorithm, &hash, hash_object,
        object_length, 0, 0, 0);
    if (!BCRYPT_SUCCESS(status))
    {
        error = ERROR_FUNCTION_FAILED;
        goto exit;
    }

    {
        LARGE_INTEGER position;
        position.QuadPart = (LONGLONG)offset;
        if (!SetFilePointerEx(file, position, 0, FILE_BEGIN))
        {
            error = GetLastError();
            goto exit;
        }
    }

    remaining = length;
    while (0 != remaining)
    {
        DWORD request = remaining > 1024 * 1024 ? 1024 * 1024 : (DWORD)remaining;
        DWORD transferred = 0;
        if (!ReadFile(file, buffer, request, &transferred, 0) ||
            transferred != request)
        {
            error = GetLastError();
            if (ERROR_SUCCESS == error)
                error = ERROR_HANDLE_EOF;
            goto exit;
        }
        status = BCryptHashData(hash, buffer, transferred, 0);
        if (!BCRYPT_SUCCESS(status))
        {
            error = ERROR_FUNCTION_FAILED;
            goto exit;
        }
        remaining -= transferred;
    }

    status = BCryptFinishHash(hash, digest, sizeof digest, 0);
    if (!BCRYPT_SUCCESS(status))
    {
        error = ERROR_FUNCTION_FAILED;
        goto exit;
    }
    for (DWORD i = 0; i < sizeof digest; i++)
        wprintf(L"%02x", digest[i]);
    wprintf(L"  offset=%llu length=%llu\n",
        (unsigned long long)offset, (unsigned long long)length);

exit:
    if (ERROR_SUCCESS != error)
        print_error(L"read/hash");
    if (0 != hash)
        BCryptDestroyHash(hash);
    if (0 != algorithm)
        BCryptCloseAlgorithmProvider(algorithm, 0);
    if (0 != buffer)
        HeapFree(GetProcessHeap(), 0, buffer);
    if (0 != hash_object)
        HeapFree(GetProcessHeap(), 0, hash_object);
    if (INVALID_HANDLE_VALUE != file)
        CloseHandle(file);
    return ERROR_SUCCESS == error ? 0 : 1;
}
