import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "hash-winspd-pe-image.py"
SPEC = importlib.util.spec_from_file_location("pe_image_hash", SCRIPT)
PE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PE)


class PeImageHashTest(unittest.TestCase):
    def fixture(self):
        data = bytearray(1024)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<H", data, 134, 1)
        struct.pack_into("<H", data, 148, 240)
        struct.pack_into("<H", data, 152, 0x20B)
        struct.pack_into("<II", data, 152 + 112 + 6 * 8, 0x1040, 28)
        struct.pack_into("<IIII", data, 400, 512, 0x1000, 512, 512)
        struct.pack_into("<IIII", data, 576 + 12, 2, 32, 0x1080, 640)
        data[640:644] = b"RSDS"
        return data

    def digest(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.dll"
            path.write_bytes(data)
            return PE.image_hash(path)

    def test_timestamps_and_pdb_age_do_not_change_image_identity(self):
        original = self.fixture()
        changed = original.copy()
        for offset in (136, 580, 660):
            struct.pack_into("<I", changed, offset, 12345)
        self.assertEqual(self.digest(original), self.digest(changed))

    def test_code_and_pdb_guid_changes_remain_visible(self):
        original = self.fixture()
        for offset in (528, 644):
            changed = original.copy()
            changed[offset] = 42
            self.assertNotEqual(self.digest(original), self.digest(changed))

    def test_out_of_bounds_debug_payload_is_rejected(self):
        data = self.fixture()
        struct.pack_into("<I", data, 576 + 24, 1000)
        with self.assertRaisesRegex(ValueError, "payload exceeds"):
            self.digest(data)


if __name__ == "__main__":
    unittest.main()
