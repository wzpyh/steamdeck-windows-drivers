"""
Patch amdkmdag.sys v32.0.11002.3007 (Valve AMD GPU driver) for Steam Deck OLED.

Fixes EPROCESS reference leak caused by PsSetCreateProcessNotifyRoutineEx
callbacks that are registered but never unregistered. Each process exit leaks
a kernel EPROCESS object (~0.78 KB), accumulating over days.

The three call sites are Valve's telemetry/debug hooks — not required for
GPU operation. Each 6-byte `call [IAT]` is replaced with `xor eax,eax; nop*4`
(return STATUS_SUCCESS, skip registration).

Usage:
  1. Place the original amdkmdag.sys in this directory
  2. python patch.py
  3. Deploy the patched output with deploy.ps1 (admin)
"""
import hashlib, sys, os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(SCRIPT_DIR, 'amdkmdag.sys')
DST = os.path.join(SCRIPT_DIR, 'amdkmdag.sys.patched')
EXPECTED_SHA256 = '0b446cba31e21e3d90d921919a180201c4b2ea76b064296f116508b984c79319'

PATCHES = [
    # All three PsSetCreateProcessNotifyRoutineEx registration calls
    # replaced with xor eax,eax (STATUS_SUCCESS) + 4x NOP.
    (0xDFA8E, bytes.fromhex('FF1564876D00'),
              bytes.fromhex('33C090909090'),
              'NOP callback A registration'),
    (0x11AC36, bytes.fromhex('FF15BCD56900'),
               bytes.fromhex('33C090909090'),
               'NOP callback B registration'),
    (0x61C07C, bytes.fromhex('FF1576C11900'),
               bytes.fromhex('33C090909090'),
               'NOP callback C registration'),
]


def main():
    if not os.path.exists(SRC):
        print(f'ERROR: Place the original amdkmdag.sys in {SCRIPT_DIR}')
        sys.exit(1)

    with open(SRC, 'rb') as f:
        data = bytearray(f.read())

    h = hashlib.sha256(data).hexdigest()
    if h != EXPECTED_SHA256:
        print(f'ERROR: source hash mismatch\n  got:      {h}\n  expected: {EXPECTED_SHA256}')
        sys.exit(1)
    print(f'Source hash OK: {h[:16]}...')

    for off, orig, patch, desc in PATCHES:
        actual = bytes(data[off:off + len(orig)])
        if actual != orig:
            print(f'ERROR at 0x{off:05x}: bytes don\'t match original — wrong driver version?')
            sys.exit(1)
        data[off:off + len(patch)] = patch
        print(f'  0x{off:05x}: {desc}')

    with open(DST, 'wb') as f:
        f.write(data)

    new_hash = hashlib.sha256(data).hexdigest()
    print(f'\nPatched driver: {DST}')
    print(f'SHA256: {new_hash}')


if __name__ == '__main__':
    main()
