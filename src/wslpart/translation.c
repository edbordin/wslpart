#include "translation.h"

#include <limits.h>

int wslpart_translate_range(
    uint64_t capacity_bytes,
    uint32_t sector_size,
    uint64_t block_address,
    uint32_t block_count,
    WSLPART_BYTE_RANGE *range)
{
    uint64_t offset;
    uint64_t length;

    if (0 == range || 0 == sector_size ||
        0 != capacity_bytes % sector_size)
        return 0;

    if (block_address > UINT64_MAX / sector_size)
        return 0;
    offset = block_address * sector_size;

    if ((uint64_t)block_count > UINT64_MAX / sector_size)
        return 0;
    length = (uint64_t)block_count * sector_size;

    if (offset > capacity_bytes || length > capacity_bytes - offset)
        return 0;

    range->offset = offset;
    range->length = length;
    return 1;
}
