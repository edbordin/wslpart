#include "../src/wslpart/translation.h"

#include <windows.h>
#define _NTSCSI_USER_MODE_
#include <scsi.h>
#undef _NTSCSI_USER_MODE_
#include <winspd/ioctl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

static int failures;

static uint64_t ring_align_up(uint64_t value, uint64_t alignment)
{
    uint64_t remainder = value % alignment;
    return 0 == remainder ? value : value + alignment - remainder;
}

static void expect_true(const char *name, int condition)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL %s\n", name);
        failures++;
    }
}

static void test_ring_abi(void)
{
    const uint32_t queue_depth = 64;
    const uint32_t buffer_count = 64;
    const uint32_t buffer_size = 1024 * 1024;
    uint64_t request_offset;
    uint64_t completion_offset;
    uint64_t buffer_offset;
    uint64_t section_size;

    request_offset = ring_align_up(sizeof(SPD_RING_HEADER), 64);
    completion_offset = ring_align_up(request_offset +
        (uint64_t)queue_depth * sizeof(SPD_RING_REQUEST), 64);
    buffer_offset = ring_align_up(completion_offset +
        (uint64_t)queue_depth * sizeof(SPD_RING_COMPLETION), 4096);
    section_size = ring_align_up(buffer_offset +
        (uint64_t)buffer_count * buffer_size, 4096);

    expect_true("ring ref has no payload", sizeof(SPD_RING_BUFFER_REF) == 16);
    expect_true("ring request is envelope only", sizeof(SPD_RING_REQUEST) ==
        sizeof(SPD_IOCTL_TRANSACT_REQ) + sizeof(SPD_RING_BUFFER_REF));
    expect_true("ring completion envelopes response", sizeof(SPD_RING_COMPLETION) ==
        sizeof(SPD_IOCTL_TRANSACT_RSP) + sizeof(SPD_RING_BUFFER_REF));
    expect_true("cursor occupies cache line", sizeof(SPD_RING_CURSOR) == 64);
    expect_true("request head cache line",
        0 == offsetof(SPD_RING_HEADER, RequestHead) % 64);
    expect_true("request tail cache line",
        0 == offsetof(SPD_RING_HEADER, RequestTail) % 64);
    expect_true("completion head cache line",
        0 == offsetof(SPD_RING_HEADER, CompletionHead) % 64);
    expect_true("completion tail cache line",
        0 == offsetof(SPD_RING_HEADER, CompletionTail) % 64);
    expect_true("request alignment", 0 == request_offset % 64);
    expect_true("completion alignment", 0 == completion_offset % 64);
    expect_true("buffer alignment", 0 == buffer_offset % 4096);
    expect_true("section below ABI limit", section_size <=
        SPD_RING_MAX_SECTION_BYTES);
    expect_true("no-buffer sentinel", SPD_RING_NO_BUFFER == UINT32_MAX);
    expect_true("minimum queue depth", SPD_RING_MIN_QUEUE_DEPTH == 2);
    expect_true("maximum queue depth", SPD_RING_MAX_QUEUE_DEPTH == 4096);
    expect_true("equal request and buffer capacities", queue_depth == buffer_count);
    expect_true("buffer zero starts at buffer offset", buffer_offset < section_size);
    expect_true("last buffer is in section", buffer_offset +
        (uint64_t)(buffer_count - 1) * buffer_size + buffer_size <= section_size);
    expect_true("cursor subtraction wraps", (uint32_t)(5 - (UINT32_MAX - 3)) == 9);
    expect_true("request cursor wrap stays within depth",
        (uint32_t)(1 - (UINT32_MAX - 1)) == 3 &&
        (uint32_t)(1 - (UINT32_MAX - 1)) <= 4);
    expect_true("completion cursor wrap stays within depth",
        (uint32_t)(2 - (UINT32_MAX - 2)) == 5 &&
        (uint32_t)(2 - (UINT32_MAX - 2)) <= 8);
}

static void expect_valid(
    const char *name,
    uint64_t capacity,
    uint32_t sector,
    uint64_t address,
    uint32_t count,
    uint64_t expected_offset,
    uint64_t expected_length)
{
    WSLPART_BYTE_RANGE range;
    if (!wslpart_translate_range(capacity, sector, address, count, &range) ||
        range.offset != expected_offset || range.length != expected_length)
    {
        fprintf(stderr, "FAIL %s\n", name);
        failures++;
    }
}

static void expect_invalid(
    const char *name,
    uint64_t capacity,
    uint32_t sector,
    uint64_t address,
    uint32_t count)
{
    WSLPART_BYTE_RANGE range;
    if (wslpart_translate_range(capacity, sector, address, count, &range))
    {
        fprintf(stderr, "FAIL %s\n", name);
        failures++;
    }
}

int main(void)
{
    const uint64_t capacity = 4096;

    expect_valid("first sector", capacity, 512, 0, 1, 0, 512);
    expect_valid("last sector", capacity, 512, 7, 1, 3584, 512);
    expect_valid("entire device", capacity, 512, 0, 8, 0, 4096);
    expect_valid("zero length at capacity", capacity, 512, 8, 0, 4096, 0);
    expect_invalid("request at capacity", capacity, 512, 8, 1);
    expect_invalid("cross capacity", capacity, 512, 7, 2);
    expect_invalid("misaligned capacity", 4097, 512, 0, 1);
    expect_invalid("zero sector size", capacity, 0, 0, 1);
    expect_invalid("LBA multiplication overflow", UINT64_MAX, 512,
        UINT64_MAX, 1);
    expect_invalid("large block range", UINT64_MAX - 1, UINT32_MAX,
        2, UINT32_MAX);

    test_ring_abi();

    if (failures != 0)
        return 1;

    puts("translation tests passed");
    return 0;
}
