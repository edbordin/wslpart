#ifndef WSLPART_TRANSLATION_H
#define WSLPART_TRANSLATION_H

#include <stdint.h>

typedef struct wslpart_byte_range {
    uint64_t offset;
    uint64_t length;
} WSLPART_BYTE_RANGE;

/*
 * Translate virtual disk sectors to a byte range in the selected source
 * partition. Returns nonzero only when the complete range is valid.
 */
int wslpart_translate_range(
    uint64_t capacity_bytes,
    uint32_t sector_size,
    uint64_t block_address,
    uint32_t block_count,
    WSLPART_BYTE_RANGE *range);

#endif
