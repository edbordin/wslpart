"""Hash a PE image ignoring link/debug timestamps and CodeView PDB age only.

All code, data, resources, image layout, PDB GUID/path and other metadata remain
part of the hash. Full file hashes are retained separately in measurements.
"""

import argparse
import hashlib
import struct
from pathlib import Path


def image_hash(path):
    data = bytearray(Path(path).read_bytes())
    if data[:2] != b"MZ":
        raise ValueError("Not a PE image")
    pe = struct.unpack_from("<I", data, 60)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Missing PE signature")
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic not in (0x10B, 0x20B):
        raise ValueError("Unsupported optional header")
    directories = optional + (112 if magic == 0x20B else 96)
    sections = []
    for index in range(count):
        entry = optional + optional_size + index * 40
        _, rva, size, raw = struct.unpack_from("<IIII", data, entry + 8)
        if raw + size > len(data):
            raise ValueError("Section exceeds file")
        sections.append((rva, size, raw))

    def offset(rva, length):
        for start, size, raw in sections:
            if start <= rva and rva + length <= start + size:
                return raw + rva - start
        raise ValueError("Directory exceeds section")

    data[pe + 8:pe + 12] = b"\0" * 4
    debug_rva, debug_size = struct.unpack_from("<II", data, directories + 6 * 8)
    if debug_size:
        if debug_size % 28:
            raise ValueError("Invalid debug directory size")
        debug = offset(debug_rva, debug_size)
        for entry in range(debug, debug + debug_size, 28):
            data[entry + 4:entry + 8] = b"\0" * 4
            kind, size, _, raw = struct.unpack_from("<IIII", data, entry + 12)
            if raw + size > len(data):
                raise ValueError("Debug payload exceeds file")
            if kind == 2 and size >= 24 and data[raw:raw + 4] == b"RSDS":
                data[raw + 20:raw + 24] = b"\0" * 4
    return hashlib.sha256(data).hexdigest().upper()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    print(image_hash(parser.parse_args().image))
