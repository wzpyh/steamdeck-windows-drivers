"""
Patch AMD Adrenalin amdkmdag.sys for Steam Deck OLED (DEV_1435 Sephiroth).

Replaces all VanGogh (0x163F) device-ID entries with Sephiroth (0x1435),
enabling Adrenalin drivers to run on the Steam Deck OLED's exclusive APU.

Usage:
    1. Copy the original amdkmdag.sys from the Adrenalin installer to this directory
    2. Run: python patch.py
    3. Deploy the patched file with deploy.ps1

Tested with Adrenalin 26.10.1 (32.0.21045.16010). Other versions should work
if the device-ID field structure is similar — the script auto-discovers patch
locations rather than using hardcoded offsets.
"""
import hashlib
import struct
import sys
from pathlib import Path

OLD_ID = 0x163F  # VanGogh
NEW_ID = 0x1435  # Sephiroth

KNOWN_HASHES = {
    'e679979fa9989acb5e3e3f4290e1e9cc98f8d0701d161702d7f4984096585671':
        'Adrenalin 26.10.1 (32.0.21045.16010)',
}

# PAGEDCIR entries are internal hardware block IDs — never patch these.
# They have the pattern: 00000000 0000163F 00001620
PAGEDCIR_SIGNATURE = struct.pack('<III', 0, OLD_ID, 0x1620)


def find_section(data, offset):
    pe_offset = struct.unpack_from('<I', data, 0x3C)[0]
    num_sections = struct.unpack_from('<H', data, pe_offset + 6)[0]
    opt_size = struct.unpack_from('<H', data, pe_offset + 20)[0]
    sec_start = pe_offset + 24 + opt_size
    for i in range(num_sections):
        s = sec_start + i * 40
        name = data[s:s+8].rstrip(b'\x00').decode('ascii', errors='replace')
        raw_offset = struct.unpack_from('<I', data, s + 20)[0]
        raw_size = struct.unpack_from('<I', data, s + 16)[0]
        if raw_offset <= offset < raw_offset + raw_size:
            return name
    return '?'


def is_false_positive(data, offset):
    val = struct.unpack_from('<I', data, offset)[0]
    if val != OLD_ID:
        return True
    if offset >= 4:
        context = data[offset - 4:offset + 8]
        if context == PAGEDCIR_SIGNATURE[0:4] + struct.pack('<I', OLD_ID) + PAGEDCIR_SIGNATURE[8:12]:
            pass
    if offset >= 4 and offset + 8 <= len(data):
        before = struct.unpack_from('<I', data, offset - 4)[0]
        after = struct.unpack_from('<I', data, offset + 4)[0]
        if before == 0 and after == 0x1620:
            return True
    return False


def find_device_id_fields(data):
    needle = struct.pack('<H', OLD_ID)
    fields = []
    pos = 0
    while True:
        pos = data.find(needle, pos)
        if pos == -1:
            break
        val = struct.unpack_from('<I', data, pos)[0]
        if val == OLD_ID and not is_false_positive(data, pos):
            section = find_section(data, pos)
            fields.append((pos, section))
        pos += 2
    return fields


def main():
    src = Path(__file__).parent / 'amdkmdag.sys'
    if not src.exists():
        print('ERROR: amdkmdag.sys not found in this directory.')
        print('Copy the original Adrenalin amdkmdag.sys here first.')
        sys.exit(1)

    data = src.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    version = KNOWN_HASHES.get(sha)
    if version:
        print('Source: %s' % version)
    else:
        print('WARNING: Unknown driver version (SHA256: %s)' % sha)
        print('Proceeding with auto-discovery — verify results carefully.')

    fields = find_device_id_fields(data)
    if not fields:
        print('ERROR: No 163F device-ID fields found. Wrong binary?')
        sys.exit(1)

    patched = bytearray(data)
    print('\nPatching %d device-ID fields:' % len(fields))
    for offset, section in sorted(fields):
        struct.pack_into('<I', patched, offset, NEW_ID)
        print('  0x%08X [%-10s] %04X -> %04X' % (offset, section, OLD_ID, NEW_ID))

    changed = sum(1 for a, b in zip(data, patched) if a != b)
    print('\n%d bytes changed in %d fields' % (changed, len(fields)))

    out = Path(__file__).parent / 'amdkmdag.sys.patched'
    out.write_bytes(patched)
    print('Output: %s' % out)
    print('SHA256: %s' % hashlib.sha256(patched).hexdigest())
    print('\nNext: run deploy.ps1 as Administrator to sign and install.')


if __name__ == '__main__':
    main()
