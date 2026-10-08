#include <windows.h>
#include <winioctl.h>
#include <winspd/winspd.h>

#include "translation.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum wslpart_sync_policy {
    WSLPART_SYNC_ALWAYS,
    WSLPART_SYNC_GUEST,
} WSLPART_SYNC_POLICY;

#define WSLPART_IOCP_BATCH_SIZE 64

typedef struct wslpart_async_io WSLPART_ASYNC_IO;

typedef struct wslpart_source {
    HANDLE handle;
    HANDLE fua_handle;
    HANDLE iocp;
    HANDLE iocp_thread;
    UINT64 capacity_bytes;
    LARGE_INTEGER io_stats_frequency;
    UINT32 logical_sector_size;
    UINT32 physical_sector_size;
    UINT32 physical_block_offset;
    UINT64 partition_start_bytes;
    UINT32 disk_number;
    UINT32 partition_number;
    BOOL writable;
    BOOL locked;
    BOOL windows_volume;
    BOOL no_buffering;
    BOOL overlapped;
    BOOL fua_supported;
    BOOL exclusive_lock;
    BOOL shared_ring;
    BOOL io_stats;
    WSLPART_SYNC_POLICY sync_policy;
    SRWLOCK io_lock;
    SRWLOCK flush_lock;
    volatile LONG gate_closed;
    volatile LONG writes_in_flight;
    volatile LONG iocp_pending;
    volatile LONG iocp_stop;
    SRWLOCK iocp_lock;
    SLIST_HEADER async_io_free;
    WSLPART_ASYNC_IO *async_io_pool;
    UINT32 async_io_capacity;
    volatile LONG64 io_stats_submitted[2];
    volatile LONG64 io_stats_completed[2];
    volatile LONG64 io_stats_slow[2];
    volatile LONG64 io_stats_buckets[2][5];
    volatile LONG64 io_stats_max_us[2];
    volatile LONG64 io_stats_response_slow;
    volatile LONG64 io_stats_response_max_us;
    volatile LONG io_stats_pending_max;
} WSLPART_SOURCE;

typedef enum wslpart_lifecycle {
    WSLPART_SOURCE_OPENED,
    WSLPART_SOURCE_LOCKED,
    WSLPART_UNIT_CREATED,
    WSLPART_DISPATCHER_STARTED,
    WSLPART_DISPATCHER_STOPPED,
    WSLPART_UNIT_REMOVED,
    WSLPART_SOURCE_CLOSED,
} WSLPART_LIFECYCLE;

typedef enum wslpart_buffering {
    WSLPART_BUFFERED,
    WSLPART_UNBUFFERED,
} WSLPART_BUFFERING;

typedef enum wslpart_io_mode {
    WSLPART_IO_SYNCHRONOUS,
    WSLPART_IO_OVERLAPPED,
} WSLPART_IO_MODE;

#define WSLPART_MAX_TRANSFER_LENGTH (1024 * 1024)

static SPD_GUARD shutdown_guard = SPD_GUARD_INIT;
static HANDLE shutdown_event;
static HANDLE debug_log_handle = INVALID_HANDLE_VALUE;
static WSLPART_SOURCE *shutdown_source;

static void stop_source_iocp(WSLPART_SOURCE *source);

static void shutdown_storage_unit(PVOID context)
{
    if (0 != shutdown_source)
        stop_source_iocp(shutdown_source);
    SpdStorageUnitShutdown(context);
}

static PVOID aligned_io_buffer_alloc(size_t size)
{
    return VirtualAlloc(0, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
}

static VOID aligned_io_buffer_free(PVOID buffer)
{
    if (0 != buffer)
        VirtualFree(buffer, 0, MEM_RELEASE);
}

static DWORD WINAPI shutdown_event_thread(PVOID context)
{
    UNREFERENCED_PARAMETER(context);
    WaitForSingleObject(shutdown_event, INFINITE);
    SpdDebugLog("wslpart shutdown event received\n");
    SpdGuardExecute(&shutdown_guard, shutdown_storage_unit);
    SpdDebugLog("wslpart shutdown request sent\n");
    return 0;
}

static void print_win32_error(const wchar_t *operation, DWORD error)
{
    fwprintf(stderr, L"%ls failed: error %lu\n", operation, error);
}

static void set_illegal_block(SPD_STORAGE_UNIT_STATUS *status, UINT64 block)
{
    SpdStorageUnitStatusSetSense(status,
        SCSI_SENSE_ILLEGAL_REQUEST, SCSI_ADSENSE_ILLEGAL_BLOCK, &block);
}

static void set_medium_error(SPD_STORAGE_UNIT_STATUS *status)
{
    SpdStorageUnitStatusSetSense(status,
        SCSI_SENSE_MEDIUM_ERROR, SCSI_ADSENSE_UNRECOVERED_ERROR, 0);
}

static LONG source_gate_state(WSLPART_SOURCE *source)
{
    return InterlockedCompareExchange(&source->gate_closed, 0, 0);
}

static LONG source_writes_in_flight(WSLPART_SOURCE *source)
{
    return InterlockedCompareExchange(&source->writes_in_flight, 0, 0);
}

static void begin_source_write(WSLPART_SOURCE *source)
{
    for (;;)
    {
        LONG closed = 1;
        while (0 != source_gate_state(source))
            WaitOnAddress(&source->gate_closed, &closed, sizeof closed,
                INFINITE);

        InterlockedIncrement(&source->writes_in_flight);
        if (0 == source_gate_state(source))
            return;

        if (0 == InterlockedDecrement(&source->writes_in_flight))
            WakeByAddressAll((PVOID)&source->writes_in_flight);
    }
}

static void complete_source_write(WSLPART_SOURCE *source)
{
    if (0 == InterlockedDecrement(&source->writes_in_flight))
        WakeByAddressAll((PVOID)&source->writes_in_flight);
}

static void close_source_write_gate(WSLPART_SOURCE *source)
{
    InterlockedExchange(&source->gate_closed, 1);
    for (;;)
    {
        LONG observed = source_writes_in_flight(source);
        if (0 == observed)
            return;
        WaitOnAddress(&source->writes_in_flight, &observed,
            sizeof observed, INFINITE);
    }
}

static void open_source_write_gate(WSLPART_SOURCE *source)
{
    InterlockedExchange(&source->gate_closed, 0);
    WakeByAddressAll((PVOID)&source->gate_closed);
}

static BOOL source_io_at(
    WSLPART_SOURCE *source,
    HANDLE handle,
    BOOL write,
    PVOID buffer,
    DWORD length,
    UINT64 offset,
    DWORD *transferred)
{
    LARGE_INTEGER file_offset;
    OVERLAPPED overlapped;
    HANDLE event;
    DWORD error;
    BOOL ok;

    *transferred = 0;
    if (!source->overlapped)
    {
        file_offset.QuadPart = offset;
        if (!SetFilePointerEx(handle, file_offset, 0, FILE_BEGIN))
            return FALSE;
        return write ? WriteFile(handle, buffer, length,
            transferred, 0) : ReadFile(handle, buffer, length,
            transferred, 0);
    }

    memset(&overlapped, 0, sizeof overlapped);
    overlapped.Offset = (DWORD)offset;
    overlapped.OffsetHigh = (DWORD)(offset >> 32);
    event = CreateEventW(0, TRUE, FALSE, 0);
    if (0 == event)
        return FALSE;
    overlapped.hEvent = event;
    ok = write ? WriteFile(handle, buffer, length, transferred,
        &overlapped) : ReadFile(handle, buffer, length, transferred,
        &overlapped);
    error = ok ? ERROR_SUCCESS : GetLastError();
    if (!ok && ERROR_IO_PENDING == error)
    {
        ok = GetOverlappedResult(handle, &overlapped,
            transferred, TRUE);
        if (!ok)
            error = GetLastError();
    }
    CloseHandle(event);
    if (!ok)
        SetLastError(error);
    return ok;
}

static BOOL flush_backing_store(WSLPART_SOURCE *source, DWORD *error);

typedef struct
__declspec(align(MEMORY_ALLOCATION_ALIGNMENT))
wslpart_async_io
{
    SLIST_ENTRY free_entry;
    OVERLAPPED overlapped;
    WSLPART_SOURCE *source;
    SPD_STORAGE_UNIT *storage_unit;
    SPD_IOCTL_TRANSACT_RSP response;
    PVOID buffer;
    HANDLE io_handle;
    DWORD length;
    UINT64 offset;
    LARGE_INTEGER submitted_qpc;
    BOOL write;
    BOOL force_unit_access;
    BOOL flush_after;
    BOOL write_gate_held;
} WSLPART_ASYNC_IO;

static DWORD source_async_pool_create(
    WSLPART_SOURCE *source,
    UINT32 capacity)
{
    SIZE_T bytes;

    if (0 == capacity ||
        capacity > SIZE_MAX / sizeof(WSLPART_ASYNC_IO))
        return ERROR_INVALID_PARAMETER;

    bytes = (SIZE_T)capacity * sizeof(WSLPART_ASYNC_IO);

    source->async_io_pool = VirtualAlloc(
        0,
        bytes,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE);

    if (0 == source->async_io_pool)
        return GetLastError();

    source->async_io_capacity = capacity;

    InitializeSListHead(&source->async_io_free);

    for (UINT32 i = 0; i < capacity; i++)
    {
        InterlockedPushEntrySList(
            &source->async_io_free,
            &source->async_io_pool[i].free_entry);
    }

    return ERROR_SUCCESS;
}

static VOID source_async_pool_destroy(WSLPART_SOURCE *source)
{
    if (0 != source->async_io_pool)
    {
        VirtualFree(source->async_io_pool, 0, MEM_RELEASE);
        source->async_io_pool = 0;
        source->async_io_capacity = 0;
    }
}

static WSLPART_ASYNC_IO *source_async_alloc(
    WSLPART_SOURCE *source)
{
    PSLIST_ENTRY entry = InterlockedPopEntrySList(
        &source->async_io_free);

    if (0 == entry)
        return 0;

    WSLPART_ASYNC_IO *io = CONTAINING_RECORD(
        entry,
        WSLPART_ASYNC_IO,
        free_entry);

    memset(io, 0, sizeof *io);

    return io;
}

static VOID source_async_free(WSLPART_ASYNC_IO *io)
{
    WSLPART_SOURCE *source = io->source;

    memset(io, 0, sizeof *io);

    InterlockedPushEntrySList(
        &source->async_io_free,
        &io->free_entry);
}

static LONG64 read_counter64(volatile LONG64 *counter)
{
    return InterlockedCompareExchange64(counter, 0, 0);
}

static void update_max64(volatile LONG64 *maximum, LONG64 value)
{
    LONG64 current = read_counter64(maximum);
    while (value > current)
    {
        LONG64 observed = InterlockedCompareExchange64(maximum,
            value, current);
        if (observed == current)
            break;
        current = observed;
    }
}

static void update_max32(volatile LONG *maximum, LONG value)
{
    LONG current = InterlockedCompareExchange(maximum, 0, 0);
    while (value > current)
    {
        LONG observed = InterlockedCompareExchange(maximum, value, current);
        if (observed == current)
            break;
        current = observed;
    }
}

static void record_io_latency(WSLPART_SOURCE *source,
    const WSLPART_ASYNC_IO *io)
{
    LARGE_INTEGER now;
    UINT64 elapsed_us;
    UINT32 type = io->write ? 1 : 0;
    UINT32 bucket;

    if (!source->io_stats ||
        !QueryPerformanceCounter(&now) ||
        0 >= io->submitted_qpc.QuadPart)
        return;

    elapsed_us = ((UINT64)(now.QuadPart - io->submitted_qpc.QuadPart) *
        1000000ULL) / (UINT64)source->io_stats_frequency.QuadPart;
    InterlockedIncrement64(&source->io_stats_completed[type]);
    if (1000000ULL <= elapsed_us)
    {
        InterlockedIncrement64(&source->io_stats_slow[type]);
        SpdDebugLog("wslpart io-stats slow %s offset=%I64u length=%lu "
            "submit-to-iocp-us=%I64u pending=%ld\n",
            io->write ? "write" : "read", io->offset,
            (unsigned long)io->length, elapsed_us,
            (long)InterlockedCompareExchange(&source->iocp_pending, 0, 0));
    }

    bucket = elapsed_us < 1000 ? 0 : elapsed_us < 10000 ? 1 :
        elapsed_us < 100000 ? 2 : elapsed_us < 1000000 ? 3 : 4;
    InterlockedIncrement64(&source->io_stats_buckets[type][bucket]);
    update_max64(&source->io_stats_max_us[type], (LONG64)elapsed_us);
}

static void log_io_stats(WSLPART_SOURCE *source)
{
    if (!source->io_stats)
        return;

    SpdDebugLog("wslpart io-stats submitted read=%I64d write=%I64d "
        "completed read=%I64d write=%I64d pending-max=%ld\n",
        read_counter64(&source->io_stats_submitted[0]),
        read_counter64(&source->io_stats_submitted[1]),
        read_counter64(&source->io_stats_completed[0]),
        read_counter64(&source->io_stats_completed[1]),
        (long)InterlockedCompareExchange(&source->io_stats_pending_max, 0, 0));
    for (UINT32 type = 0; type < 2; type++)
        SpdDebugLog("wslpart io-stats %s latency-us buckets=<1k:%I64d "
            "1k-10k:%I64d 10k-100k:%I64d 100k-1m:%I64d >=1m:%I64d "
            "slow>=1m:%I64d max:%I64d\n",
            0 == type ? "read" : "write",
            read_counter64(&source->io_stats_buckets[type][0]),
            read_counter64(&source->io_stats_buckets[type][1]),
            read_counter64(&source->io_stats_buckets[type][2]),
            read_counter64(&source->io_stats_buckets[type][3]),
            read_counter64(&source->io_stats_buckets[type][4]),
            read_counter64(&source->io_stats_slow[type]),
            read_counter64(&source->io_stats_max_us[type]));
    SpdDebugLog("wslpart io-stats response-post slow>=1ms:%I64d max-us:%I64d\n",
        read_counter64(&source->io_stats_response_slow),
        read_counter64(&source->io_stats_response_max_us));
}

static VOID complete_source_async(
    WSLPART_ASYNC_IO *io,
    DWORD transferred,
    DWORD error)
{
    WSLPART_SOURCE *source = io->source;
    BOOL io_ok = ERROR_SUCCESS == error &&
        transferred == io->length;
    BOOL response_timing = FALSE;
    LARGE_INTEGER response_start = { 0 };
    LARGE_INTEGER response_end = { 0 };

    if (!io_ok && ERROR_SUCCESS == error)
        error = ERROR_HANDLE_EOF;

    record_io_latency(source, io);

    if (io->write && io->write_gate_held)
    {
        /* The data I/O is complete before a post-write flush. */
        complete_source_write(source);
        io->write_gate_held = FALSE;
    }

    if (io_ok && io->write && io->flush_after)
    {
        DWORD flush_error = ERROR_SUCCESS;
        if (!flush_backing_store(source, &flush_error))
        {
            io_ok = FALSE;
            error = flush_error;
        }
    }

    if (!io_ok)
    {
        SpdDebugLog("wslpart async %s completion "
            "length=%lu transferred=%lu error=%lu "
            "fua=%u flush_after=%u\n",
            io->write ? "write" : "read",
            (unsigned long)io->length,
            (unsigned long)transferred,
            (unsigned long)error,
            (unsigned)io->force_unit_access,
            (unsigned)io->flush_after);

        SpdStorageUnitStatusSetSense(
            &io->response.Status,
            SCSI_SENSE_MEDIUM_ERROR,
            io->write ?
                SCSI_ADSENSE_WRITE_ERROR :
                SCSI_ADSENSE_UNRECOVERED_ERROR,
            0);
    }

    if (source->io_stats)
        response_timing = QueryPerformanceCounter(&response_start);

    SpdStorageUnitSendResponse(
        io->storage_unit,
        &io->response,
        io->buffer);

    if (response_timing && QueryPerformanceCounter(&response_end))
    {
        UINT64 response_us =
            ((UINT64)(response_end.QuadPart -
                response_start.QuadPart) * 1000000ULL) /
            (UINT64)source->io_stats_frequency.QuadPart;

        update_max64(
            &source->io_stats_response_max_us,
            (LONG64)response_us);

        if (1000ULL <= response_us)
            InterlockedIncrement64(
                &source->io_stats_response_slow);
    }

    source_async_free(io);

    InterlockedDecrement(&source->iocp_pending);
}

static DWORD WINAPI source_iocp_thread(PVOID context)
{
    WSLPART_SOURCE *source = context;
    OVERLAPPED_ENTRY entries[WSLPART_IOCP_BATCH_SIZE];

    for (;;)
    {
        ULONG removed = 0;
        BOOL ok = GetQueuedCompletionStatusEx(
            source->iocp,
            entries,
            ARRAYSIZE(entries),
            &removed,
            INFINITE,
            FALSE);

        if (!ok)
        {
            DWORD error = GetLastError();

            if (0 != source->iocp_stop &&
                0 == InterlockedCompareExchange(
                    &source->iocp_pending,
                    0,
                    0))
                break;

            SpdDebugLog(
                "wslpart IOCP dequeue failed error=%lu\n",
                (unsigned long)error);

            return error;
        }

        for (ULONG i = 0; i < removed; i++)
        {
            OVERLAPPED_ENTRY *entry = &entries[i];

            if (0 == entry->lpOverlapped)
                continue;

            WSLPART_ASYNC_IO *io = CONTAINING_RECORD(
                entry->lpOverlapped,
                WSLPART_ASYNC_IO,
                overlapped);
            DWORD transferred = entry->dwNumberOfBytesTransferred;
            DWORD error = ERROR_SUCCESS;

            /* Successful asynchronous file I/O normally has
             * Internal == STATUS_SUCCESS == 0. Only failures need
             * the slower GetOverlappedResult path. */
            if (0 != entry->Internal)
            {
                DWORD actual = transferred;

                if (!GetOverlappedResult(
                        io->io_handle,
                        &io->overlapped,
                        &actual,
                        FALSE))
                    error = GetLastError();
                else
                    transferred = actual;
            }

            complete_source_async(io, transferred, error);
        }

        if (0 != source->iocp_stop &&
            0 == InterlockedCompareExchange(
                &source->iocp_pending,
                0,
                0))
            break;
    }

    return ERROR_SUCCESS;
}

static DWORD start_source_iocp(
    WSLPART_SOURCE *source,
    UINT32 max_outstanding)
{
    DWORD error;

    if (!source->overlapped || 0 != source->iocp)
        return source->overlapped ? ERROR_SUCCESS : ERROR_INVALID_PARAMETER;

    error = source_async_pool_create(source, max_outstanding);
    if (ERROR_SUCCESS != error)
        return error;

    source->iocp = CreateIoCompletionPort(source->handle, 0, 0, 0);
    if (0 == source->iocp)
    {
        error = GetLastError();
        goto fail;
    }

    if (INVALID_HANDLE_VALUE != source->fua_handle &&
        0 == CreateIoCompletionPort(source->fua_handle, source->iocp, 0, 0))
    {
        error = GetLastError();
        CloseHandle(source->iocp);
        source->iocp = 0;
        goto fail;
    }

    InterlockedExchange(&source->iocp_pending, 0);
    InterlockedExchange(&source->iocp_stop, 0);
    source->iocp_thread = CreateThread(0, 0, source_iocp_thread, source,
        0, 0);
    if (0 == source->iocp_thread)
    {
        error = GetLastError();
        CloseHandle(source->iocp);
        source->iocp = 0;
        goto fail;
    }
    return ERROR_SUCCESS;

fail:
    source_async_pool_destroy(source);
    return error;
}

static void stop_source_iocp(WSLPART_SOURCE *source)
{
    AcquireSRWLockExclusive(&source->iocp_lock);
    if (0 == source->iocp)
    {
        ReleaseSRWLockExclusive(&source->iocp_lock);
        return;
    }

    InterlockedExchange(&source->iocp_stop, 1);
    CancelIoEx(source->handle, 0);
    if (INVALID_HANDLE_VALUE != source->fua_handle)
        CancelIoEx(source->fua_handle, 0);
    PostQueuedCompletionStatus(source->iocp, 0, 0, 0);
    if (0 != source->iocp_thread)
    {
        WaitForSingleObject(source->iocp_thread, INFINITE);
        CloseHandle(source->iocp_thread);
        source->iocp_thread = 0;
    }
    CloseHandle(source->iocp);
    source->iocp = 0;
    source_async_pool_destroy(source);
    ReleaseSRWLockExclusive(&source->iocp_lock);
}

static BOOLEAN submit_source_async(
    SPD_STORAGE_UNIT *storage_unit,
    WSLPART_SOURCE *source,
    PVOID buffer,
    UINT64 offset,
    DWORD length,
    BOOL write,
    BOOL force_unit_access,
    BOOL flush_after,
    SPD_STORAGE_UNIT_STATUS *status)
{
    SPD_STORAGE_UNIT_OPERATION_CONTEXT *operation;
    WSLPART_ASYNC_IO *io;
    HANDLE handle;
    BOOL ok;
    DWORD error;

    operation = SpdStorageUnitGetOperationContext();
    if (0 == operation || 0 == operation->Response)
    {
        SpdStorageUnitStatusSetSense(status,
            SCSI_SENSE_HARDWARE_ERROR, SCSI_ADSENSE_INTERNAL_TARGET_FAILURE,
            0);
        if (write)
            complete_source_write(source);
        return TRUE;
    }

    handle = write && force_unit_access &&
        INVALID_HANDLE_VALUE != source->fua_handle ? source->fua_handle :
        source->handle;

    AcquireSRWLockShared(&source->iocp_lock);
    if (0 == source->iocp)
    {
        ReleaseSRWLockShared(&source->iocp_lock);
        if (write)
            complete_source_write(source);
        SpdStorageUnitStatusSetSense(status,
            SCSI_SENSE_HARDWARE_ERROR, SCSI_ADSENSE_INTERNAL_TARGET_FAILURE,
            0);
        return TRUE;
    }

    io = source_async_alloc(source);
    if (0 == io)
    {
        ReleaseSRWLockShared(&source->iocp_lock);
        SpdStorageUnitStatusSetSense(status,
            SCSI_SENSE_HARDWARE_ERROR, SCSI_ADSENSE_INTERNAL_TARGET_FAILURE,
            0);
        if (write)
            complete_source_write(source);
        return TRUE;
    }

    io->source = source;
    io->storage_unit = storage_unit;
    io->response = *operation->Response;
    io->buffer = buffer;
    io->io_handle = handle;
    io->length = length;
    io->offset = offset;
    io->write = write;
    io->force_unit_access = force_unit_access;
    io->flush_after = flush_after;
    io->write_gate_held = write;
    io->overlapped.Offset = (DWORD)offset;
    io->overlapped.OffsetHigh = (DWORD)(offset >> 32);
    if (source->io_stats)
        QueryPerformanceCounter(&io->submitted_qpc);

    InterlockedIncrement(&source->iocp_pending);
    if (source->io_stats)
        update_max32(&source->io_stats_pending_max,
            InterlockedCompareExchange(&source->iocp_pending, 0, 0));
    ok = write ? WriteFile(handle, buffer, length, 0, &io->overlapped) :
        ReadFile(handle, buffer, length, 0, &io->overlapped);
    error = ok ? ERROR_SUCCESS : GetLastError();
    if (!ok && ERROR_IO_PENDING != error)
    {
        InterlockedDecrement(&source->iocp_pending);
        ReleaseSRWLockShared(&source->iocp_lock);
        source_async_free(io);
        if (write)
            complete_source_write(source);
        SpdStorageUnitStatusSetSense(status,
            SCSI_SENSE_MEDIUM_ERROR, SCSI_ADSENSE_WRITE_ERROR, 0);
        SetLastError(error);
        return TRUE;
    }

    if (source->io_stats)
    {
        InterlockedIncrement64(&source->io_stats_submitted[write ? 1 : 0]);
    }

    ReleaseSRWLockShared(&source->iocp_lock);

    return FALSE;
}

static BOOLEAN read_source(
    SPD_STORAGE_UNIT *storage_unit,
    WSLPART_SOURCE *source,
    PVOID buffer,
    UINT64 block_address,
    UINT32 block_count,
    SPD_STORAGE_UNIT_STATUS *status)
{
    WSLPART_BYTE_RANGE range;
    DWORD requested;
    DWORD transferred = 0;
    BOOL ok;

    if (!wslpart_translate_range(source->capacity_bytes,
        source->logical_sector_size, block_address, block_count, &range))
    {
        set_illegal_block(status, block_address);
        return TRUE;
    }

    if (0 == range.length)
        return TRUE;

    if (range.length > MAXDWORD)
    {
        set_illegal_block(status, block_address);
        return TRUE;
    }
    requested = (DWORD)range.length;

    if (source->shared_ring && 0 != source->iocp)
        return submit_source_async(storage_unit, source, buffer,
            range.offset, requested, FALSE, FALSE, FALSE, status);

    /* Synchronous handles share a file pointer; overlapped handles do not. */
    if (!source->overlapped)
        AcquireSRWLockExclusive(&source->io_lock);
    ok = source_io_at(source, source->handle, FALSE, buffer, requested,
        range.offset,
        &transferred);
    if (!source->overlapped)
        ReleaseSRWLockExclusive(&source->io_lock);

    if (!ok || transferred != requested)
    {
        DWORD error = GetLastError();
        SpdDebugLog("wslpart read offset=%I64u length=%lu transferred=%lu error=%lu\n",
            range.offset, (unsigned long)requested,
            (unsigned long)transferred, (unsigned long)error);
        set_medium_error(status);
    }

    return TRUE;
}

static BOOL flush_backing_store(WSLPART_SOURCE *source, DWORD *error)
{
    BOOL ok;
    BOOL fua_ok = TRUE;
    DWORD first_error = ERROR_SUCCESS;

    AcquireSRWLockExclusive(&source->flush_lock);
    close_source_write_gate(source);
    if (!source->overlapped)
        AcquireSRWLockExclusive(&source->io_lock);
    ok = FlushFileBuffers(source->handle);
    if (!ok)
        first_error = GetLastError();
    if (INVALID_HANDLE_VALUE != source->fua_handle)
    {
        fua_ok = FlushFileBuffers(source->fua_handle);
        if (!fua_ok && ERROR_SUCCESS == first_error)
            first_error = GetLastError();
    }
    if (!source->overlapped)
        ReleaseSRWLockExclusive(&source->io_lock);
    open_source_write_gate(source);
    *error = first_error;
    ReleaseSRWLockExclusive(&source->flush_lock);
    return ok && fua_ok;
}

static BOOLEAN flush_source(
    WSLPART_SOURCE *source,
    UINT64 block_address,
    UINT32 block_count,
    SPD_STORAGE_UNIT_STATUS *status)
{
    DWORD error = ERROR_SUCCESS;

    UNREFERENCED_PARAMETER(block_address);
    UNREFERENCED_PARAMETER(block_count);

    if (source->writable && !flush_backing_store(source, &error))
    {
        SpdDebugLog("wslpart flush ok=0 error=%lu\n",
            (unsigned long)error);
        SpdStorageUnitStatusSetSense(status,
            SCSI_SENSE_MEDIUM_ERROR, SCSI_ADSENSE_WRITE_ERROR, 0);
    }
    else
        SpdDebugLog("wslpart flush ok=1 error=0\n");

    return TRUE;
}

static BOOLEAN Read(
    SPD_STORAGE_UNIT *storage_unit,
    PVOID buffer,
    UINT64 block_address,
    UINT32 block_count,
    BOOLEAN flush,
    SPD_STORAGE_UNIT_STATUS *status)
{
    WSLPART_SOURCE *source = storage_unit->UserContext;
    if (flush)
    {
        flush_source(source, block_address, block_count, status);
        if (SCSISTAT_GOOD != status->ScsiStatus)
            return TRUE;
    }
    return read_source(storage_unit, source, buffer, block_address,
        block_count, status);
}

static BOOLEAN Write(
    SPD_STORAGE_UNIT *storage_unit,
    PVOID buffer,
    UINT64 block_address,
    UINT32 block_count,
    BOOLEAN flush,
    SPD_STORAGE_UNIT_STATUS *status)
{
    WSLPART_SOURCE *source = storage_unit->UserContext;
    WSLPART_BYTE_RANGE range;
    DWORD requested;
    DWORD transferred = 0;
    BOOL ok;
    BOOL flush_ok = TRUE;
    BOOL force_unit_access = source->fua_supported && flush;
    HANDLE write_handle = force_unit_access &&
        INVALID_HANDLE_VALUE != source->fua_handle ? source->fua_handle :
        source->handle;

    if (!wslpart_translate_range(source->capacity_bytes,
        source->logical_sector_size, block_address, block_count, &range) ||
        range.length > MAXDWORD)
    {
        set_illegal_block(status, block_address);
        return TRUE;
    }
    if (0 == range.length)
        return TRUE;

    requested = (DWORD)range.length;

    if (source->shared_ring && 0 != source->iocp)
    {
        begin_source_write(source);
        return submit_source_async(storage_unit, source, buffer,
            range.offset, requested, TRUE, force_unit_access,
            source->writable && !force_unit_access &&
                (WSLPART_SYNC_ALWAYS == source->sync_policy || flush),
            status);
    }

    begin_source_write(source);
    if (!source->overlapped)
        AcquireSRWLockExclusive(&source->io_lock);
    ok = source_io_at(source, write_handle, TRUE, buffer, requested,
        range.offset, &transferred);
    if (!source->overlapped)
        ReleaseSRWLockExclusive(&source->io_lock);
    complete_source_write(source);

    if (ok && transferred == requested && source->writable &&
        !force_unit_access &&
        (WSLPART_SYNC_ALWAYS == source->sync_policy || flush))
    {
        DWORD error = ERROR_SUCCESS;
        flush_ok = flush_backing_store(source, &error);
        ok = flush_ok;
        if (!flush_ok)
            SetLastError(error);
    }

    {
        DWORD error = ok ? ERROR_SUCCESS : GetLastError();
        SpdDebugLog("wslpart write offset=%I64u length=%lu transferred=%lu "
            "guest_flush=%u fua=%u write_ok=%u flush_ok=%u error=%lu\n",
            range.offset, (unsigned long)requested,
            (unsigned long)transferred, (unsigned)flush,
            (unsigned)force_unit_access,
            (unsigned)ok,
            (unsigned)flush_ok, (unsigned long)error);
    }

    if (!ok || transferred != requested)
        SpdStorageUnitStatusSetSense(status,
            SCSI_SENSE_MEDIUM_ERROR, SCSI_ADSENSE_WRITE_ERROR, 0);
    return TRUE;
}

static BOOLEAN Flush(
    SPD_STORAGE_UNIT *storage_unit,
    UINT64 block_address,
    UINT32 block_count,
    SPD_STORAGE_UNIT_STATUS *status)
{
    WSLPART_SOURCE *source = storage_unit->UserContext;
    return flush_source(source, block_address, block_count, status);
}

static SPD_STORAGE_UNIT_INTERFACE source_interface =
{
    Read,
    0,
    Flush,
    0,
};

static SPD_STORAGE_UNIT_INTERFACE writable_source_interface =
{
    Read,
    Write,
    Flush,
    0,
};

static const wchar_t *partition_style_name(PARTITION_STYLE style)
{
    switch (style)
    {
    case PARTITION_STYLE_MBR:
        return L"MBR";
    case PARTITION_STYLE_GPT:
        return L"GPT";
    case PARTITION_STYLE_RAW:
        return L"RAW";
    default:
        return L"unknown";
    }
}

static int list_physical_partitions(void)
{
    BYTE layout_buffer[sizeof(DRIVE_LAYOUT_INFORMATION_EX) +
        255 * sizeof(PARTITION_INFORMATION_EX)];
    UINT32 partition_count = 0;

    wprintf(L"Disk Partition StartSector SizeBytes LogicalSector PhysicalSector Style PartitionDevice\n");
    for (UINT32 disk = 0; 256 > disk; disk++)
    {
        wchar_t path[64];
        HANDLE handle;
        DISK_GEOMETRY_EX geometry;
        STORAGE_PROPERTY_QUERY alignment_query;
        STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR alignment;
        UINT32 physical_sector_size;
        DRIVE_LAYOUT_INFORMATION_EX *layout =
            (DRIVE_LAYOUT_INFORMATION_EX *)layout_buffer;
        DWORD returned;

        swprintf_s(path, sizeof path / sizeof path[0],
            L"\\\\.\\PhysicalDrive%lu", (unsigned long)disk);
        handle = CreateFileW(path, 0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (INVALID_HANDLE_VALUE == handle)
            continue;

        memset(&geometry, 0, sizeof geometry);
        if (!DeviceIoControl(handle, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,
            0, 0, &geometry, sizeof geometry, &returned, 0) ||
            !DeviceIoControl(handle, IOCTL_DISK_GET_DRIVE_LAYOUT_EX,
                0, 0, layout, sizeof layout_buffer, &returned, 0))
        {
            CloseHandle(handle);
            continue;
        }
        if (0 == geometry.Geometry.BytesPerSector)
        {
            CloseHandle(handle);
            continue;
        }

        physical_sector_size = geometry.Geometry.BytesPerSector;
        memset(&alignment_query, 0, sizeof alignment_query);
        alignment_query.PropertyId = StorageAccessAlignmentProperty;
        alignment_query.QueryType = PropertyStandardQuery;
        memset(&alignment, 0, sizeof alignment);
        if (DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY,
            &alignment_query, sizeof alignment_query, &alignment,
            sizeof alignment, &returned, 0) &&
            0 != alignment.BytesPerPhysicalSector)
            physical_sector_size = alignment.BytesPerPhysicalSector;

        for (DWORD i = 0; layout->PartitionCount > i; i++)
        {
            PARTITION_INFORMATION_EX *partition = &layout->PartitionEntry[i];
            if (0 == partition->PartitionLength.QuadPart ||
                0 == partition->PartitionNumber)
                continue;
            wprintf(L"%lu %lu %llu %llu %lu %lu %ls \\\\.\\Harddisk%luPartition%lu\n",
                (unsigned long)disk,
                (unsigned long)partition->PartitionNumber,
                (unsigned long long)(partition->StartingOffset.QuadPart /
                    geometry.Geometry.BytesPerSector),
                (unsigned long long)partition->PartitionLength.QuadPart,
                (unsigned long)geometry.Geometry.BytesPerSector,
                (unsigned long)physical_sector_size,
                partition_style_name(partition->PartitionStyle),
                (unsigned long)disk,
                (unsigned long)partition->PartitionNumber);
            partition_count++;
        }
        CloseHandle(handle);
    }
    if (0 == partition_count)
        wprintf(L"No readable physical-disk partition layouts found. "
            L"Run list elevated if required by Windows.\n");
    return 0;
}

static BOOL is_wslpart_disk(HANDLE handle)
{
    STORAGE_PROPERTY_QUERY query;
    BYTE buffer[4096];
    STORAGE_DEVICE_DESCRIPTOR *descriptor =
        (STORAGE_DEVICE_DESCRIPTOR *)buffer;
    DWORD returned;
    const char *product;

    memset(&query, 0, sizeof query);
    query.PropertyId = StorageDeviceProperty;
    query.QueryType = PropertyStandardQuery;
    if (!DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY,
        &query, sizeof query, buffer, sizeof buffer, &returned, 0))
        return FALSE;
    if (returned < sizeof *descriptor ||
        0 == descriptor->ProductIdOffset ||
        descriptor->ProductIdOffset >= returned)
        return FALSE;
    product = (const char *)buffer + descriptor->ProductIdOffset;
    if (0 == memchr(product, '\0', returned - descriptor->ProductIdOffset))
        return FALSE;
    return 0 == _strnicmp(product, "WslPart", 7);
}

static BOOL is_matching_wslpart_disk(HANDLE handle, const char *serial)
{
    STORAGE_PROPERTY_QUERY query;
    BYTE buffer[4096];
    STORAGE_DEVICE_DESCRIPTOR *descriptor =
        (STORAGE_DEVICE_DESCRIPTOR *)buffer;
    DWORD returned;
    const char *product;
    const char *disk_serial;

    memset(&query, 0, sizeof query);
    query.PropertyId = StorageDeviceProperty;
    query.QueryType = PropertyStandardQuery;
    if (!DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY,
        &query, sizeof query, buffer, sizeof buffer, &returned, 0) ||
        returned < sizeof *descriptor ||
        0 == descriptor->ProductIdOffset ||
        descriptor->ProductIdOffset >= returned ||
        0 == descriptor->SerialNumberOffset ||
        descriptor->SerialNumberOffset >= returned)
        return FALSE;
    product = (const char *)buffer + descriptor->ProductIdOffset;
    disk_serial = (const char *)buffer + descriptor->SerialNumberOffset;
    if (0 == memchr(product, '\0', returned - descriptor->ProductIdOffset) ||
        0 == memchr(disk_serial, '\0', returned - descriptor->SerialNumberOffset))
        return FALSE;
    return 0 == _strnicmp(product, "WslPart", 7) &&
        0 == _stricmp(disk_serial, serial);
}

static void format_unit_serial(const GUID *guid, char serial[37])
{
    sprintf_s(serial, 37,
        "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        guid->Data1, guid->Data2, guid->Data3,
        guid->Data4[0], guid->Data4[1], guid->Data4[2], guid->Data4[3],
        guid->Data4[4], guid->Data4[5], guid->Data4[6], guid->Data4[7]);
}

static BOOL query_disk_capacity(HANDLE handle, UINT64 *capacity_bytes)
{
    GET_LENGTH_INFORMATION length;
    DWORD returned;

    memset(&length, 0, sizeof length);
    if (!DeviceIoControl(handle, IOCTL_DISK_GET_LENGTH_INFO,
        0, 0, &length, sizeof length, &returned, 0) ||
        length.Length.QuadPart <= 0)
        return FALSE;
    *capacity_bytes = (UINT64)length.Length.QuadPart;
    return TRUE;
}

static BOOL validate_single_volume_extent(
    HANDLE handle,
    UINT32 expected_disk,
    UINT64 expected_offset,
    UINT64 expected_length)
{
    BYTE buffer[sizeof(VOLUME_DISK_EXTENTS) +
        15 * sizeof(DISK_EXTENT)];
    VOLUME_DISK_EXTENTS *extents = (VOLUME_DISK_EXTENTS *)buffer;
    DWORD returned;

    memset(buffer, 0, sizeof buffer);
    if (!DeviceIoControl(handle, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,
        0, 0, buffer, sizeof buffer, &returned, 0) ||
        1 != extents->NumberOfDiskExtents)
        return FALSE;
    return expected_disk == extents->Extents[0].DiskNumber &&
        expected_offset == (UINT64)extents->Extents[0].StartingOffset.QuadPart &&
        expected_length == (UINT64)extents->Extents[0].ExtentLength.QuadPart;
}

static void snapshot_wslpart_disks(BOOL present[256])
{
    memset(present, 0, 256 * sizeof present[0]);
    for (UINT32 disk = 0; 256 > disk; disk++)
    {
        wchar_t path[64];
        HANDLE handle;

        swprintf_s(path, sizeof path / sizeof path[0],
            L"\\\\.\\PhysicalDrive%lu", (unsigned long)disk);
        handle = CreateFileW(path, GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (INVALID_HANDLE_VALUE == handle)
            continue;
        present[disk] = is_wslpart_disk(handle);
        CloseHandle(handle);
    }
}

static int find_new_wslpart_disk(
    UINT64 expected_capacity,
    const char *expected_serial,
    const BOOL before[256],
    BOOL *ambiguous)
{
    int match = -1;

    *ambiguous = FALSE;
    for (UINT32 disk = 0; 256 > disk; disk++)
    {
        wchar_t path[64];
        HANDLE handle;
        UINT64 capacity;

        if (before[disk])
            continue;
        swprintf_s(path, sizeof path / sizeof path[0],
            L"\\\\.\\PhysicalDrive%lu", (unsigned long)disk);
        handle = CreateFileW(path, GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (INVALID_HANDLE_VALUE == handle)
            continue;
        if (is_matching_wslpart_disk(handle, expected_serial) &&
            query_disk_capacity(handle, &capacity) &&
            expected_capacity == capacity)
        {
            if (0 <= match)
                *ambiguous = TRUE;
            else
                match = (int)disk;
        }
        CloseHandle(handle);
    }
    return *ambiguous ? -2 : match;
}

static BOOL query_source_geometry(
    HANDLE handle,
    UINT64 *capacity_bytes,
    UINT32 *logical_sector_size,
    UINT32 *physical_sector_size,
    UINT32 *physical_block_offset,
    UINT64 *partition_start_bytes,
    UINT32 *partition_number,
    UINT32 *disk_number)
{
    PARTITION_INFORMATION_EX partition;
    DISK_GEOMETRY_EX geometry;
    STORAGE_DEVICE_NUMBER device_number;
    UINT32 reported_offset = UINT32_MAX;
    DWORD returned;

    memset(&partition, 0, sizeof partition);
    if (!DeviceIoControl(handle, IOCTL_DISK_GET_PARTITION_INFO_EX,
        0, 0, &partition, sizeof partition, &returned, 0))
        return FALSE;

    memset(&geometry, 0, sizeof geometry);
    if (!DeviceIoControl(handle, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,
        0, 0, &geometry, sizeof geometry, &returned, 0))
        return FALSE;

    if ((PARTITION_STYLE_GPT != partition.PartitionStyle &&
        PARTITION_STYLE_MBR != partition.PartitionStyle) ||
        0 == partition.PartitionNumber ||
        0 == partition.PartitionLength.QuadPart ||
        0 == geometry.Geometry.BytesPerSector ||
        0 != (UINT64)partition.PartitionLength.QuadPart %
            geometry.Geometry.BytesPerSector)
        return FALSE;

    *capacity_bytes = (UINT64)partition.PartitionLength.QuadPart;
    *logical_sector_size = geometry.Geometry.BytesPerSector;
    *physical_sector_size = geometry.Geometry.BytesPerSector;
    {
        STORAGE_PROPERTY_QUERY query;
        STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR alignment;

        memset(&query, 0, sizeof query);
        query.PropertyId = StorageAccessAlignmentProperty;
        query.QueryType = PropertyStandardQuery;
        memset(&alignment, 0, sizeof alignment);
        if (DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY,
            &query, sizeof query, &alignment, sizeof alignment,
            &returned, 0) &&
            0 != alignment.BytesPerPhysicalSector &&
            alignment.BytesPerPhysicalSector >=
            alignment.BytesPerLogicalSector)
        {
            *physical_sector_size = alignment.BytesPerPhysicalSector;
            if (alignment.BytesPerLogicalSector == *logical_sector_size &&
                alignment.BytesOffsetForSectorAlignment <
                    *physical_sector_size &&
                0 == alignment.BytesOffsetForSectorAlignment %
                    *logical_sector_size)
                reported_offset = alignment.BytesOffsetForSectorAlignment;
        }
    }
    *physical_block_offset = UINT32_MAX != reported_offset ? reported_offset :
        (UINT32)(partition.StartingOffset.QuadPart % *physical_sector_size);
    *partition_start_bytes = (UINT64)partition.StartingOffset.QuadPart;
    *partition_number = partition.PartitionNumber;
    *disk_number = UINT32_MAX;
    memset(&device_number, 0, sizeof device_number);
    if (DeviceIoControl(handle, IOCTL_STORAGE_GET_DEVICE_NUMBER,
        0, 0, &device_number, sizeof device_number, &returned, 0) &&
        FILE_DEVICE_DISK == device_number.DeviceType &&
        UINT32_MAX != device_number.DeviceNumber)
        *disk_number = device_number.DeviceNumber;
    return TRUE;
}

static void close_source(WSLPART_SOURCE *source);

static BOOL control_ioctl(
    HANDLE handle,
    BOOL overlapped_mode,
    DWORD code,
    DWORD *returned)
{
    OVERLAPPED overlapped;
    HANDLE event;
    DWORD error;
    BOOL ok;

    if (!overlapped_mode)
        return DeviceIoControl(handle, code, 0, 0, 0, 0, returned, 0);

    memset(&overlapped, 0, sizeof overlapped);
    event = CreateEventW(0, TRUE, FALSE, 0);
    if (0 == event)
        return FALSE;
    overlapped.hEvent = event;
    ok = DeviceIoControl(handle, code, 0, 0, 0, 0, returned,
        &overlapped);
    error = ok ? ERROR_SUCCESS : GetLastError();
    if (!ok && ERROR_IO_PENDING == error)
    {
        ok = GetOverlappedResult(handle, &overlapped, returned, TRUE);
        if (!ok)
            error = GetLastError();
    }
    CloseHandle(event);
    if (!ok)
        SetLastError(error);
    return ok;
}

static HANDLE open_source(
    const wchar_t *volume_path,
    BOOL writable,
    WSLPART_BUFFERING buffering,
    WSLPART_SYNC_POLICY sync_policy,
    WSLPART_IO_MODE io_mode,
    BOOL fua_supported,
    BOOL exclusive_lock,
    const wchar_t **failure_stage,
    WSLPART_SOURCE *source)
{
    HANDLE query_handle;
    HANDLE read_handle;
    BOOL direct_partition_path;
    wchar_t path[512];
    wchar_t device_name[128];
    wchar_t device_target[512];
    wchar_t device_path[512];
    wchar_t *volume_name;
    wchar_t *volume_end;
    DWORD target_length;
    const wchar_t *open_path = path;

    *failure_stage = L"opening source query handle";

    if (wcslen(volume_path) + 2 > sizeof path / sizeof path[0])
        return INVALID_HANDLE_VALUE;
    wcscpy_s(path, sizeof path / sizeof path[0], volume_path);
    direct_partition_path =
        0 == wcsncmp(path, L"\\\\.\\Harddisk", 12) &&
        0 != wcsstr(path, L"Partition");
    if (L'\\' != path[wcslen(path) - 1] &&
        0 != wcsncmp(path, L"\\\\.\\Harddisk", 12))
        wcscat_s(path, sizeof path / sizeof path[0], L"\\");

    query_handle = CreateFileW(path, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (INVALID_HANDLE_VALUE == query_handle)
    {
        /*
         * Windows can publish a Volume GUID for an unrecognized filesystem
         * (for example ext4) while refusing to open that DOS path with
         * ERROR_UNRECOGNIZED_VOLUME. QueryDosDevice gives us the underlying
         * volume device, which can still be opened as a raw read handle.
         */
        volume_name = wcsstr(path, L"Volume{");
        if (0 == volume_name || 0 == (volume_end = wcschr(volume_name, L'}')))
        {
            *failure_stage = L"resolving unrecognized volume device name";
            return INVALID_HANDLE_VALUE;
        }
        if ((size_t)(volume_end - volume_name + 1) >=
            sizeof device_name / sizeof device_name[0])
        {
            *failure_stage = L"copying volume device name";
            return INVALID_HANDLE_VALUE;
        }
        wcsncpy_s(device_name, sizeof device_name / sizeof device_name[0],
            volume_name, volume_end - volume_name + 1);
        target_length = QueryDosDeviceW(device_name, device_target,
            sizeof device_target / sizeof device_target[0]);
        if (0 == target_length ||
            0 != wcsncmp(device_target, L"\\Device\\", 8) ||
            wcslen(device_target) + 4 >= sizeof device_path / sizeof device_path[0])
        {
            *failure_stage = L"resolving volume device target";
            return INVALID_HANDLE_VALUE;
        }
        wcscpy_s(device_path, sizeof device_path / sizeof device_path[0],
            L"\\\\.\\");
        wcscat_s(device_path, sizeof device_path / sizeof device_path[0],
            device_target + 8);
        query_handle = CreateFileW(device_path, GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (INVALID_HANDLE_VALUE == query_handle)
        {
            *failure_stage = L"opening resolved volume query handle";
            return INVALID_HANDLE_VALUE;
        }
        open_path = device_path;
        source->windows_volume = FALSE;
    }
    else
        source->windows_volume = !direct_partition_path;

    if (!query_source_geometry(query_handle, &source->capacity_bytes,
        &source->logical_sector_size, &source->physical_sector_size,
        &source->physical_block_offset,
        &source->partition_start_bytes,
        &source->partition_number, &source->disk_number))
    {
        *failure_stage = L"querying source geometry";
        CloseHandle(query_handle);
        SetLastError(ERROR_INVALID_DATA);
        return INVALID_HANDLE_VALUE;
    }

    if (!direct_partition_path &&
        !validate_single_volume_extent(query_handle, source->disk_number,
            source->partition_start_bytes, source->capacity_bytes))
    {
        *failure_stage = L"validating source volume extent";
        CloseHandle(query_handle);
        SetLastError(ERROR_INVALID_DATA);
        return INVALID_HANDLE_VALUE;
    }
    CloseHandle(query_handle);

    if (UINT32_MAX == source->disk_number || 0 == source->partition_number ||
        0 == source->logical_sector_size ||
        0 != source->partition_start_bytes % source->logical_sector_size)
    {
        *failure_stage = L"validating source identity";
        SetLastError(ERROR_INVALID_DATA);
        return INVALID_HANDLE_VALUE;
    }

    source->no_buffering = fua_supported || WSLPART_UNBUFFERED == buffering;
    source->overlapped = fua_supported || WSLPART_IO_OVERLAPPED == io_mode;
    source->sync_policy = sync_policy;
    source->fua_supported = fua_supported;
    source->exclusive_lock = exclusive_lock;
    read_handle = CreateFileW(open_path,
        writable ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        0, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL |
            (writable && (WSLPART_SYNC_ALWAYS == sync_policy ||
                (fua_supported && exclusive_lock)) ?
                FILE_FLAG_WRITE_THROUGH : 0) |
            (source->no_buffering ? FILE_FLAG_NO_BUFFERING : 0) |
            (source->overlapped ? FILE_FLAG_OVERLAPPED : 0), 0);
    if (INVALID_HANDLE_VALUE == read_handle)
    {
        *failure_stage = L"opening normal source handle";
        return INVALID_HANDLE_VALUE;
    }

    if (fua_supported && !exclusive_lock)
    {
        source->fua_handle = CreateFileW(open_path,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            0, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING |
                FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED, 0);
        if (INVALID_HANDLE_VALUE == source->fua_handle)
        {
            DWORD error = GetLastError();
            *failure_stage = L"opening unlocked FUA source handle";
            CloseHandle(read_handle);
            SetLastError(error);
            return INVALID_HANDLE_VALUE;
        }
    }

    InitializeSRWLock(&source->io_lock);
    InitializeSRWLock(&source->flush_lock);
    source->writable = writable;
    if (writable && exclusive_lock)
    {
        DWORD returned;
        if (!control_ioctl(read_handle, source->overlapped,
            FSCTL_LOCK_VOLUME, &returned))
        {
            DWORD error = GetLastError();
            *failure_stage = L"locking source volume";
            CloseHandle(read_handle);
            SetLastError(error);
            return INVALID_HANDLE_VALUE;
        }
        source->locked = TRUE;

        if (source->windows_volume &&
            !control_ioctl(read_handle, source->overlapped,
            FSCTL_DISMOUNT_VOLUME, &returned))
        {
            DWORD error = GetLastError();
            *failure_stage = L"dismounting source volume";
            control_ioctl(read_handle, source->overlapped,
                FSCTL_UNLOCK_VOLUME, &returned);
            CloseHandle(read_handle);
            source->locked = FALSE;
            SetLastError(error);
            return INVALID_HANDLE_VALUE;
        }

        /*
         * Some unrecognized-filesystem volume devices reject this optional
         * control with ERROR_INVALID_PARAMETER. The partition device still
         * enforces its extent, and every request is independently bounded
         * before I/O. Treat only this known unsupported case as non-fatal.
         */
        if (!control_ioctl(read_handle, source->overlapped,
            FSCTL_ALLOW_EXTENDED_DASD_IO, &returned))
        {
            DWORD error = GetLastError();
            if (ERROR_INVALID_PARAMETER != error &&
                ERROR_INVALID_FUNCTION != error)
            {
                *failure_stage = L"enabling extended DASD I/O";
                control_ioctl(read_handle, source->overlapped,
                    FSCTL_UNLOCK_VOLUME, &returned);
                CloseHandle(read_handle);
                source->locked = FALSE;
                SetLastError(error);
                return INVALID_HANDLE_VALUE;
            }
        }
    }

    source->handle = read_handle;
    return read_handle;
}

static void close_source(WSLPART_SOURCE *source)
{
    DWORD returned;

    if (INVALID_HANDLE_VALUE == source->handle)
        return;
    stop_source_iocp(source);
    if (source->writable)
    {
        DWORD error = ERROR_SUCCESS;
        if (!flush_backing_store(source, &error))
            print_win32_error(L"flush source before close", error);
    }
    if (source->locked)
    {
        control_ioctl(source->handle, source->overlapped,
            FSCTL_UNLOCK_VOLUME, &returned);
        source->locked = FALSE;
    }
    if (INVALID_HANDLE_VALUE != source->fua_handle)
    {
        CloseHandle(source->fua_handle);
        source->fua_handle = INVALID_HANDLE_VALUE;
    }
    CloseHandle(source->handle);
    source->handle = INVALID_HANDLE_VALUE;
}

static void print_usage(FILE *stream)
{
    fwprintf(stream,
        L"usage: wslpart-ARM64.exe list\n"
        L"       wslpart-ARM64.exe attach -d Disk -n Partition [options]\n"
        L"       wslpart-ARM64.exe attach -v VolumePath [options]\n"
        L"       wslpart-ARM64.exe -v VolumePath [-o StartSector] [options]\n"
        L"       wslpart-ARM64.exe -d Disk -n Partition [-o StartSector] [options]\n"
        L"\n"
        L"Options:\n"
        L"  -w, --readwrite enable read/write mode and exclusive volume lock\n"
        L"      --readonly read-only mode (default)\n"
        L"      --sync-policy always|guest  write flush policy (default: guest)\n"
        L"      --buffering cached|none     Windows source-handle buffering\n"
        L"      --fua                      enable native FUA writes\n"
        L"                                  (forces unbuffered overlapped I/O)\n"
        L"      --fua-unlocked             FUA experiment without volume lock\n"
        L"                                  (unsafe; ext4 test volumes only)\n"
        L"      --io-mode sync|overlapped  partition I/O completion mode\n"
        L"      --transport legacy|shared-ring\n"
        L"                                  WinSpd request transport\n"
        L"      --ring-depth N              SharedRing V3 queue and buffer count\n"
        L"                                  (default: 64; power of two, 2..4096)\n"
        L"      --max-transfer-length N    max SCSI transfer (4K..1M, 4K aligned)\n"
        L"      --dispatcher-threads N     WinSpd userspace dispatcher count\n"
        L"                                  (default: 2)\n"
        L"      --shared-ring-test        test SharedRing V3 mapping only\n"
        L"  -o Sector       verify the source partition start\n"
        L"  --shutdown-event Name  named event for graceful shutdown\n"
        L"  -D Path         append WinSpd/backend diagnostics to a file\n"
        L"      --debug-log-events         omit per-request diagnostics\n"
        L"      --io-stats                log overlapped I/O latency counters\n"
        L"  -p PipeName     use a named pipe instead of the WinSpd driver\n"
        L"  --help          show this help\n");
}

static void usage(void)
{
    print_usage(stderr);
    ExitProcess(ERROR_INVALID_PARAMETER);
}

static BOOL parse_uint32(const wchar_t *text, UINT32 *value)
{
    wchar_t *end = 0;
    unsigned long parsed = wcstoul(text, &end, 10);
    if (0 == end || L'\0' != *end || parsed > UINT32_MAX)
        return FALSE;
    *value = (UINT32)parsed;
    return TRUE;
}

static BOOL WINAPI console_control_handler(DWORD control_type)
{
    UNREFERENCED_PARAMETER(control_type);
    SpdGuardExecute(&shutdown_guard, shutdown_storage_unit);
    return TRUE;
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *volume_path = 0;
    const wchar_t *pipe_name = 0;
    const wchar_t *shutdown_event_name = 0;
    const wchar_t *debug_log_path = 0;
    const wchar_t *failure_stage = L"opening source";
    wchar_t constructed_path[128];
    UINT64 expected_start_sector = 0;
    BOOL check_start_sector = FALSE;
    BOOL writable = FALSE;
    WSLPART_SYNC_POLICY sync_policy = WSLPART_SYNC_GUEST;
    WSLPART_BUFFERING buffering = WSLPART_BUFFERED;
    WSLPART_IO_MODE io_mode = WSLPART_IO_OVERLAPPED;
    BOOL fua_requested = FALSE;
    BOOL fua_unlocked_requested = FALSE;
    BOOL exclusive_lock = TRUE;
    UINT32 dispatcher_thread_count = 0;
    BOOL dispatcher_threads_specified = FALSE;
    BOOL shared_ring_requested = FALSE;
    BOOL shared_ring_test = FALSE;
    UINT32 ring_depth = 64;
    UINT32 max_transfer_length = WSLPART_MAX_TRANSFER_LENGTH;
    UINT64 shared_ring_section_size = 0;
    BOOL debug_log_events_only = FALSE;
    BOOL io_stats_requested = FALSE;
    UINT32 disk_number = 0;
    UINT32 partition_number = 0;
    BOOL have_disk = FALSE;
    BOOL have_partition = FALSE;
    BOOL attach_command = FALSE;
    int first_option = 1;
    WSLPART_SOURCE source;
    SPD_STORAGE_UNIT_PARAMS params;
    SPD_STORAGE_UNIT *storage_unit = 0;
    BOOL wslpart_before[256];
    BOOL have_wslpart_snapshot = FALSE;
    BOOL ambiguous_proxy_disk = FALSE;
    int proxy_disk = -1;
    char unit_serial[37];
    WSLPART_LIFECYCLE lifecycle = WSLPART_SOURCE_OPENED;
    HANDLE handle;
    DWORD error;

    memset(&source, 0, sizeof source);
    source.handle = INVALID_HANDLE_VALUE;
    source.fua_handle = INVALID_HANDLE_VALUE;
    InitializeSRWLock(&source.iocp_lock);

    if (2 == argc && 0 == wcscmp(argv[1], L"list"))
        return list_physical_partitions();

    if (2 == argc && 0 == wcscmp(argv[1], L"--help"))
    {
        print_usage(stdout);
        return 0;
    }
    if (argc > 1 && 0 == wcscmp(argv[1], L"attach"))
    {
        attach_command = TRUE;
        first_option = 2;
    }

    for (int i = first_option; i < argc; i++)
    {
        if ((0 == wcscmp(argv[i], L"-v") ||
            0 == wcscmp(argv[i], L"--volume")) && i + 1 < argc)
            volume_path = argv[++i];
        else if ((0 == wcscmp(argv[i], L"-d") ||
            0 == wcscmp(argv[i], L"--disk")) && i + 1 < argc)
        {
            if (!parse_uint32(argv[++i], &disk_number))
                usage();
            have_disk = TRUE;
        }
        else if ((0 == wcscmp(argv[i], L"-n") ||
            0 == wcscmp(argv[i], L"--partition")) && i + 1 < argc)
        {
            if (!parse_uint32(argv[++i], &partition_number))
                usage();
            have_partition = TRUE;
        }
        else if ((0 == wcscmp(argv[i], L"-o") ||
            0 == wcscmp(argv[i], L"--expected-start-sector")) && i + 1 < argc)
        {
            wchar_t *end = 0;
            expected_start_sector = _wcstoui64(argv[++i], &end, 10);
            if (0 == end || L'\0' != *end)
                usage();
            check_start_sector = TRUE;
        }
        else if ((0 == wcscmp(argv[i], L"-p") ||
            0 == wcscmp(argv[i], L"--pipe")) && i + 1 < argc)
            pipe_name = argv[++i];
        else if (0 == wcscmp(argv[i], L"--shutdown-event") && i + 1 < argc)
            shutdown_event_name = argv[++i];
        else if ((0 == wcscmp(argv[i], L"-D") ||
            0 == wcscmp(argv[i], L"--debug-log")) && i + 1 < argc)
            debug_log_path = argv[++i];
        else if (0 == wcscmp(argv[i], L"--debug-log-events"))
            debug_log_events_only = TRUE;
        else if (0 == wcscmp(argv[i], L"--io-stats"))
            io_stats_requested = TRUE;
        else if (0 == wcscmp(argv[i], L"-w") ||
            0 == wcscmp(argv[i], L"--readwrite"))
            writable = TRUE;
        else if (0 == wcscmp(argv[i], L"--readonly"))
            writable = FALSE;
        else if (0 == wcscmp(argv[i], L"--fua"))
            fua_requested = TRUE;
        else if (0 == wcscmp(argv[i], L"--fua-unlocked"))
        {
            fua_requested = TRUE;
            fua_unlocked_requested = TRUE;
            exclusive_lock = FALSE;
        }
        else if (0 == wcscmp(argv[i], L"--sync-policy") && i + 1 < argc)
        {
            const wchar_t *value = argv[++i];
            if (0 == wcscmp(value, L"always"))
                sync_policy = WSLPART_SYNC_ALWAYS;
            else if (0 == wcscmp(value, L"guest"))
                sync_policy = WSLPART_SYNC_GUEST;
            else
                usage();
        }
        else if (0 == wcscmp(argv[i], L"--buffering") && i + 1 < argc)
        {
            const wchar_t *value = argv[++i];
            if (0 == wcscmp(value, L"cached"))
                buffering = WSLPART_BUFFERED;
            else if (0 == wcscmp(value, L"none"))
                buffering = WSLPART_UNBUFFERED;
            else
                usage();
        }
        else if (0 == wcscmp(argv[i], L"--dispatcher-threads") && i + 1 < argc)
        {
            if (!parse_uint32(argv[++i], &dispatcher_thread_count) ||
                0 == dispatcher_thread_count)
                usage();
            dispatcher_threads_specified = TRUE;
        }
        else if (0 == wcscmp(argv[i], L"--io-mode") && i + 1 < argc)
        {
            const wchar_t *value = argv[++i];
            if (0 == wcscmp(value, L"sync"))
                io_mode = WSLPART_IO_SYNCHRONOUS;
            else if (0 == wcscmp(value, L"overlapped"))
                io_mode = WSLPART_IO_OVERLAPPED;
            else
                usage();
        }
        else if (0 == wcscmp(argv[i], L"--transport") && i + 1 < argc)
        {
            const wchar_t *value = argv[++i];
            if (0 == wcscmp(value, L"legacy"))
                shared_ring_requested = FALSE;
            else if (0 == wcscmp(value, L"shared-ring"))
                shared_ring_requested = TRUE;
            else
                usage();
        }
        else if (0 == wcscmp(argv[i], L"--ring-depth") && i + 1 < argc)
        {
            if (!parse_uint32(argv[++i], &ring_depth) ||
                ring_depth < SPD_RING_MIN_QUEUE_DEPTH ||
                ring_depth > SPD_RING_MAX_QUEUE_DEPTH ||
                0 != (ring_depth & (ring_depth - 1)))
                usage();
        }
        else if (0 == wcscmp(argv[i], L"--max-transfer-length") &&
            i + 1 < argc)
        {
            if (!parse_uint32(argv[++i], &max_transfer_length) ||
                4096 > max_transfer_length ||
                WSLPART_MAX_TRANSFER_LENGTH < max_transfer_length ||
                0 != (max_transfer_length & 4095))
                usage();
        }
        else if (0 == wcscmp(argv[i], L"--shared-ring-test"))
            shared_ring_test = TRUE;
        else
            usage();
    }
    if (shared_ring_requested)
        io_mode = WSLPART_IO_OVERLAPPED;
    source.io_stats = io_stats_requested;
    if (source.io_stats && !QueryPerformanceFrequency(
        &source.io_stats_frequency))
    {
        print_win32_error(L"query performance counter frequency",
            GetLastError());
        return 1;
    }
    if (0 == volume_path && (!have_disk || !have_partition))
        usage();
    if (0 != volume_path && (have_disk || have_partition))
        usage();
    if (0 == volume_path)
    {
        swprintf_s(constructed_path, sizeof constructed_path /
            sizeof constructed_path[0],
            L"\\\\.\\Harddisk%luPartition%lu",
            (unsigned long)disk_number, (unsigned long)partition_number);
        volume_path = constructed_path;
    }

    if (0 == volume_path)
        usage();
    if (fua_requested && !writable)
        usage();
    if (fua_requested)
    {
        buffering = WSLPART_UNBUFFERED;
        io_mode = WSLPART_IO_OVERLAPPED;
    }
    if (fua_unlocked_requested)
        fwprintf(stderr,
            L"WARNING: --fua-unlocked does not acquire an exclusive volume "
            L"lock; use only with a Windows-unused test volume.\n");

    handle = open_source(volume_path, writable, buffering, sync_policy,
        io_mode, fua_requested, exclusive_lock, &failure_stage, &source);
    if (INVALID_HANDLE_VALUE == handle)
    {
        DWORD open_error = GetLastError();
        fwprintf(stderr, L"%ls failed: error %lu\n",
            failure_stage, (unsigned long)open_error);
        return (int)open_error;
    }
    source.handle = handle;
    lifecycle = source.locked ? WSLPART_SOURCE_LOCKED :
        WSLPART_SOURCE_OPENED;

    if ((have_disk && source.disk_number != disk_number) ||
        (have_partition && source.partition_number != partition_number))
    {
        fwprintf(stderr,
            L"source identity mismatch: requested disk %lu partition %lu, "
            L"opened disk %lu partition %lu\n",
            (unsigned long)disk_number, (unsigned long)partition_number,
            (unsigned long)source.disk_number,
            (unsigned long)source.partition_number);
        close_source(&source);
        return 1;
    }

    if (check_start_sector &&
        source.partition_start_bytes / 512 != expected_start_sector)
    {
        fwprintf(stderr,
            L"source start sector mismatch: expected %llu, got %llu\n",
            (unsigned long long)expected_start_sector,
            (unsigned long long)(source.partition_start_bytes / 512));
        close_source(&source);
        return 1;
    }

    if (0 == pipe_name)
    {
        snapshot_wslpart_disks(wslpart_before);
        have_wslpart_snapshot = TRUE;
    }

    memset(&params, 0, sizeof params);
    UuidCreate(&params.Guid);
    format_unit_serial(&params.Guid, unit_serial);
    params.BlockCount = source.capacity_bytes / source.logical_sector_size;
    params.BlockLength = source.logical_sector_size;
    params.PhysicalBlockLength = source.physical_sector_size;
    params.PhysicalBlockOffset = source.physical_block_offset;
    memcpy(params.ProductId, "WslPart", 7);
    memcpy(params.ProductRevisionLevel, "1.0", 3);
    params.WriteProtected = !writable;
    /* Advertise write caching. Native FUA is advertised only in explicit
     * --fua mode, where FUA writes use the write-through source handle.
     */
    params.CacheSupported = TRUE;
    params.FuaSupported = source.fua_supported;
    params.UnmapSupported = 0;
    params.EjectDisabled = 1;
    params.MaxTransferLength = max_transfer_length;

    error = SpdStorageUnitCreate((PWSTR)pipe_name, &params,
        writable ? &writable_source_interface : &source_interface,
        &storage_unit);
    if (ERROR_SUCCESS != error)
    {
        print_win32_error(L"create WinSpd storage unit", error);
        close_source(&source);
        return 1;
    }
    storage_unit->UserContext = &source;
    if (source.no_buffering)
        SpdStorageUnitSetBufferAllocator(storage_unit,
            aligned_io_buffer_alloc, aligned_io_buffer_free);
    lifecycle = WSLPART_UNIT_CREATED;

    if (shared_ring_requested || shared_ring_test)
    {
        SPD_IOCTL_RING_OPEN_PARAMS ring_params;
        SPD_RING_HEADER *ring_header;

        memset(&ring_params, 0, sizeof ring_params);
        ring_params.Version = SPD_RING_VERSION_3;
        ring_params.QueueDepth = ring_depth;
        ring_params.BufferSize = max_transfer_length;

        error = SpdStorageUnitOpenSharedRing(storage_unit, &ring_params);
        if (ERROR_SUCCESS != error)
        {
            print_win32_error(L"open SharedRing V3 mapping", error);
            SpdStorageUnitDelete(storage_unit);
            close_source(&source);
            return 1;
        }

        ring_header = storage_unit->SharedRingHeader;
        if (0 == ring_header ||
            SPD_RING_VERSION_3 != ring_header->Version ||
            ring_params.QueueDepth != ring_header->QueueDepth ||
            ring_params.QueueDepth != ring_header->BufferCount ||
            ring_params.BufferSize != ring_header->BufferSize)
        {
            fwprintf(stderr, L"SharedRing V3 header validation failed\n");
            SpdStorageUnitCloseSharedRing(storage_unit);
            SpdStorageUnitDelete(storage_unit);
            close_source(&source);
            return 1;
        }
        shared_ring_section_size = ring_params.SectionSize;

        if (shared_ring_test)
        {
            fwprintf(stdout,
                L"SharedRing V3 mapping OK: address=0x%llx size=%llu "
                L"depth=%lu buffers=%lu buffer_size=%lu\n",
                (unsigned long long)ring_params.UserAddress,
                (unsigned long long)ring_params.SectionSize,
                (unsigned long)ring_header->QueueDepth,
                (unsigned long)ring_header->BufferCount,
                (unsigned long)ring_header->BufferSize);
            SpdStorageUnitCloseSharedRing(storage_unit);
            SpdStorageUnitDelete(storage_unit);
            close_source(&source);
            return 0;
        }

        source.shared_ring = TRUE;
        error = start_source_iocp(&source, ring_depth);
        if (ERROR_SUCCESS != error)
        {
            print_win32_error(L"start source IOCP", error);
            SpdStorageUnitCloseSharedRing(storage_unit);
            SpdStorageUnitDelete(storage_unit);
            close_source(&source);
            return 1;
        }
    }

    if (0 != debug_log_path)
    {
        debug_log_handle = CreateFileW(debug_log_path, FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL, 0);
        if (INVALID_HANDLE_VALUE == debug_log_handle)
        {
            error = GetLastError();
            print_win32_error(L"open debug log", error);
            SpdStorageUnitDelete(storage_unit);
            close_source(&source);
            return 1;
        }
        SpdDebugLogSetHandle(debug_log_handle);
        if (!debug_log_events_only)
            SpdStorageUnitSetDebugLog(storage_unit, 0x7);
    }

    if (0 != shutdown_event_name)
    {
        shutdown_event = CreateEventW(0, TRUE, FALSE, shutdown_event_name);
        if (0 == shutdown_event)
        {
            error = GetLastError();
            print_win32_error(L"create shutdown event", error);
            SpdStorageUnitDelete(storage_unit);
            if (INVALID_HANDLE_VALUE != debug_log_handle)
            {
                CloseHandle(debug_log_handle);
                debug_log_handle = INVALID_HANDLE_VALUE;
            }
            close_source(&source);
            return 1;
        }
    }

    if (!dispatcher_threads_specified)
        dispatcher_thread_count = 2;

    fwprintf(stdout,
        L"Source volume: %ls\n"
        L"Capacity: %llu bytes (%llu sectors)\n"
        L"Logical sector: %lu bytes\n"
        L"Physical sector: %lu bytes\n"
        L"Physical alignment offset: %lu bytes\n"
        L"Partition start: %llu bytes (%llu 512-byte sectors)\n"
        L"Source identity: disk %lu partition %lu\n"
        L"Max transfer: %lu bytes\n"
        L"Mode: %ls; Sync policy: %ls; Windows buffering: %ls; "
        L"I/O mode: %ls; "
        L"FUA: %ls; "
        L"Transport: %ls; "
        L"Dispatcher threads: %lu; "
        L"Cache: enabled; UNMAP disabled\n",
        volume_path,
        (unsigned long long)source.capacity_bytes,
        (unsigned long long)params.BlockCount,
        (unsigned long)source.logical_sector_size,
        (unsigned long)source.physical_sector_size,
        (unsigned long)source.physical_block_offset,
        (unsigned long long)source.partition_start_bytes,
        (unsigned long long)(source.partition_start_bytes / 512),
        (unsigned long)source.disk_number,
        (unsigned long)source.partition_number,
        (unsigned long)max_transfer_length,
        writable ? (source.exclusive_lock ?
            L"read/write (volume locked)" :
            L"read/write (UNLOCKED FUA EXPERIMENT)") : L"read-only",
        WSLPART_SYNC_ALWAYS == sync_policy ? L"always" : L"guest",
        WSLPART_BUFFERED == buffering ? L"cached" : L"none",
        WSLPART_IO_OVERLAPPED == io_mode ? L"overlapped" : L"sync",
        source.fua_supported ? L"enabled" : L"disabled",
        shared_ring_requested ? L"SharedRingV3" : L"legacy",
        (unsigned long)dispatcher_thread_count);
    if (shared_ring_requested || shared_ring_test)
        wprintf(L"SharedRing pinned section: %llu MiB; data pool: %llu MiB (%lu buffers x %lu bytes)\n",
            (unsigned long long)(shared_ring_section_size / (1024 * 1024)),
            (unsigned long long)(((UINT64)ring_depth * max_transfer_length) /
                (1024 * 1024)),
            (unsigned long)ring_depth,
            (unsigned long)max_transfer_length);

    /* Ordinary requests may run concurrently. The write gate orders only
     * writers against explicit flushes; it does not impose submission order. */
    error = SpdStorageUnitStartDispatcher(storage_unit, dispatcher_thread_count);
    if (ERROR_SUCCESS != error)
    {
        print_win32_error(L"start WinSpd dispatcher", error);
        if (0 != shutdown_event)
        {
            CloseHandle(shutdown_event);
            shutdown_event = 0;
        }
        if (INVALID_HANDLE_VALUE != debug_log_handle)
        {
            CloseHandle(debug_log_handle);
            debug_log_handle = INVALID_HANDLE_VALUE;
        }
        SpdStorageUnitDelete(storage_unit);
        close_source(&source);
        return 1;
    }
    lifecycle = WSLPART_DISPATCHER_STARTED;
    wprintf(L"Lifecycle: source %ls, storage unit created, dispatcher started\n",
        writable ? (source.exclusive_lock ? L"locked" : L"UNLOCKED") :
            L"opened");

    if (0 == pipe_name && have_wslpart_snapshot)
    {
        for (int attempt = 0; 20 > attempt && 0 > proxy_disk; attempt++)
        {
            proxy_disk = find_new_wslpart_disk(source.capacity_bytes,
                unit_serial, wslpart_before, &ambiguous_proxy_disk);
            if (0 > proxy_disk)
                Sleep(250);
        }
        if (0 <= proxy_disk)
            wprintf(L"Proxy disk: \\\\.\\PHYSICALDRIVE%d\n", proxy_disk);
        else if (ambiguous_proxy_disk)
            wprintf(L"Proxy disk: ambiguous; more than one new WslPart disk "
                L"has the expected capacity\n");
        else
            wprintf(L"Proxy disk: not discovered yet\n");
    }
    wprintf(L"WinSpd serial: %hs\n", unit_serial);
    if (attach_command && 0 <= proxy_disk)
        wprintf(L"Attach to WSL with: wsl.exe --mount \\\\.\\PHYSICALDRIVE%d "
            L"--bare\n", proxy_disk);

    SetConsoleCtrlHandler(console_control_handler, TRUE);
    shutdown_source = &source;
    SpdGuardSet(&shutdown_guard, storage_unit);
    HANDLE shutdown_thread = 0;
    if (0 != shutdown_event)
    {
        shutdown_thread = CreateThread(0, 0, shutdown_event_thread,
            storage_unit, 0, 0);
        if (0 == shutdown_thread)
        {
            error = GetLastError();
            print_win32_error(L"create shutdown-event thread", error);
            shutdown_storage_unit(storage_unit);
        }
    }
    SpdStorageUnitWaitDispatcher(storage_unit);
    {
        DWORD dispatcher_error = ERROR_SUCCESS;
        SpdStorageUnitGetDispatcherError(storage_unit, &dispatcher_error);
        SpdDebugLog("wslpart dispatcher error=%lu\n",
            (unsigned long)dispatcher_error);
        if (ERROR_SUCCESS != dispatcher_error && ERROR_SUCCESS == error)
            error = dispatcher_error;
    }
    stop_source_iocp(&source);
    log_io_stats(&source);
    lifecycle = WSLPART_DISPATCHER_STOPPED;
    SpdDebugLog("wslpart dispatcher stopped\n");
    if (0 != shutdown_thread)
    {
        SetEvent(shutdown_event);
        WaitForSingleObject(shutdown_thread, INFINITE);
        CloseHandle(shutdown_thread);
    }
    SpdGuardSet(&shutdown_guard, 0);
    shutdown_source = 0;

    /*
     * WinSpd also flushes on dispatcher exit when CacheSupported is set, but
     * make the ownership boundary explicit: the source is flushed while it
     * is still locked and before the storage unit is deleted/unlocked.
     */
    if (source.writable)
    {
        SPD_STORAGE_UNIT_STATUS final_flush_status;
        memset(&final_flush_status, 0, sizeof final_flush_status);
        SpdDebugLog("wslpart final flush begin\n");
        flush_source(&source, 0, 0, &final_flush_status);
        SpdDebugLog("wslpart final flush end\n");
        if (SCSISTAT_GOOD != final_flush_status.ScsiStatus)
        {
            fwprintf(stderr, L"final source flush failed: SCSI status %u\n",
                (unsigned)final_flush_status.ScsiStatus);
            error = ERROR_WRITE_FAULT;
        }
    }
    if (0 != shutdown_event)
    {
        CloseHandle(shutdown_event);
        shutdown_event = 0;
    }
    SpdStorageUnitDelete(storage_unit);
    lifecycle = WSLPART_UNIT_REMOVED;
    if (INVALID_HANDLE_VALUE != debug_log_handle)
    {
        CloseHandle(debug_log_handle);
        debug_log_handle = INVALID_HANDLE_VALUE;
    }
    close_source(&source);
    lifecycle = WSLPART_SOURCE_CLOSED;
    UNREFERENCED_PARAMETER(lifecycle);
    return ERROR_SUCCESS == error ? 0 : (int)error;
}
