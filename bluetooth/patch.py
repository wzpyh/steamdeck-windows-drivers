"""
Patch qcbtuart.sys v1.0.0.14 (Qualcomm QCA206x Bluetooth UART) for Steam Deck OLED.

Fixes two BSOD paths triggered when the BT adapter enters an unresponsive state,
plus adds self-healing via PnP device restart.

Path B (D3 block): NOP Cherokee PowerDown calls in FdoDevD0Exit_SwInband.
  Prevents 0x9F BSOD from D3 power transition blocking on dead adapter.

Path A (pool exhaustion): Replace infinite KeWaitForSingleObject in
  IoWorkerPerformUartWrite with a 30-second timeout.  On timeout:
  1. WdfIoTargetStop(CancelSentIo) cancels the pending UART request
  2. WdfDeviceSetFailed(AttemptRestart) triggers PnP re-enumeration
  The PnP manager tears down the device stack and rebuilds it,
  reloading the BT adapter firmware automatically.

Usage:
  1. Place the original qcbtuart.sys in this directory
  2. python patch.py
  3. Deploy the patched output with deploy.ps1 (admin)
"""
import hashlib, sys, os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(SCRIPT_DIR, 'qcbtuart.sys')
DST = os.path.join(SCRIPT_DIR, 'qcbtuart.sys.patched')
EXPECTED_SHA256 = 'f52ef4caca48ae59c61d18fcf3722308bc19d1c24c6605d4ba66c26ef78aa744'

PATCHES = [
    # --- Path B: NOP Cherokee PowerDown in D3 exit ---
    (0xD13B, bytes.fromhex('E87061FFFF'),
             bytes.fromhex('9090909090'),
             'NOP Cherokee PowerDown A'),
    (0xD142, bytes.fromhex('E80944FFFF'),
             bytes.fromhex('9090909090'),
             'NOP Cherokee PowerDown B'),

    # --- Path A: 30s write timeout + WdfIoTargetStop + self-heal ---
    # Replaces 94 bytes of dead debug-trace + infinite-wait setup
    (0x17D48,
     bytes.fromhex(
         '0FBA25A4B1020008'
         '7319'
         '8B0D98B10200'
         '4C8D0581CD0100'
         '488D155ACD0100'
         'E811910000'
         '488364242000'
         '488D4F50'
         '4533C9'
         '4533C0'
         '33D2'
         'FF15BD360200'
         '0FBA2569B1020008'
         '7319'
         '8B0D5DB10200'
         '4C8D0576CD0100'
         '488D151FCD0100'
         'E8D6900000'
     ),
     bytes.fromhex(
         '48C7C0005D1EEE'    # mov rax, -30s (100ns units)
         '4889442428'        # mov [rsp+0x28], rax  (timeout on stack)
         '488D442428'        # lea rax, [rsp+0x28]
         '4889442420'        # mov [rsp+0x20], rax  (5th param)
         '488D4F50'          # lea rcx, [rdi+0x50]  (event)
         '4531C9'            # xor r9d, r9d
         '4531C0'            # xor r8d, r8d
         '31D2'              # xor edx, edx
         'FF15D0360200'      # call KeWaitForSingleObject
         '85C0'              # test eax, eax
         '7432'              # jz +0x32 (success → normal flow)
         '488B05ADBD0200'    # mov rax, [WDF function table]
         '41B801000000'      # mov r8d, 1  (WdfIoTargetCancelSentIo)
         '488B5630'          # mov rdx, [rsi+0x30]  (WDFIOTARGET)
         '488B0DA4BD0200'    # mov rcx, [WDF globals]
         '488B8038070000'    # mov rax, [rax+0x738]  (WdfIoTargetStop)
         'FF15BF380200'      # call dispatch thunk
         'BBB50000C0'        # mov ebx, STATUS_IO_TIMEOUT
         'E9C31F0100'        # jmp → cave 1 (WdfDeviceSetFailed)
         '909090'            # padding
     ),
     'Write timeout 30s + WdfIoTargetStop + self-heal jump'),

    # --- Self-healing: save WDFDEVICE during init ---

    # Trampoline in DriverDeviceAdd: redirect context-store to cave
    (0x098A1,
     bytes.fromhex('48890538A50300'),    # mov [rip+0x3A538], rax
     bytes.fromhex('E8000702009090'),    # call cave_c; nop; nop
     'Trampoline → Cave C'),

    # Cave C: execute original store + save WDFDEVICE in unused global
    (0x29FA6,
     b'\xcc' * 22,
     bytes.fromhex(
         '488905339E0100'    # mov [rip+0x19E33], rax  (original: FDO ctx → 0x449E0)
         '50'                # push rax
         '488B442450'        # mov rax, [rsp+0x50]     (WDFDEVICE on stack)
         '488905369E0100'    # mov [rip+0x19E36], rax  (save → unused global 0x449F0)
         '58'                # pop rax
         'C3'                # ret
     ),
     'Cave C: store FDO context + WDFDEVICE'),

    # Cave 1: load saved WDFDEVICE + WDF globals
    (0x29D66,
     b'\xcc' * 16,
     bytes.fromhex(
         '488B1583A00100'    # mov rdx, [rip+0x1A083]  (WDFDEVICE from 0x449F0)
         '488B0DBC9D0100'    # mov rcx, [rip+0x19DBC]  (WDF globals from 0x44730)
         'EB0C'              # jmp +12 → cave 2
     ),
     'Cave 1: load WDFDEVICE + WDF globals'),

    # Cave 2: load WdfDeviceSetFailed function pointer
    (0x29D82,
     b'\xcc' * 20,
     bytes.fromhex(
         '488B059F9D0100'    # mov rax, [rip+0x19D9F]  (function table from 0x44728)
         '488B80E0020000'    # mov rax, [rax+0x2E0]    (WdfDeviceSetFailed)
         'EB14'              # jmp +20 → cave 3
         '90909090'          # padding
     ),
     'Cave 2: load WdfDeviceSetFailed ptr'),

    # Cave 3: NULL-guard + call WdfDeviceSetFailed + return
    (0x29DA6,
     b'\xcc' * 22,
     bytes.fromhex(
         '4885D2'            # test rdx, rdx  (WDFDEVICE NULL check)
         '740C'              # jz +12 → skip call
         '41B801000000'      # mov r8d, 1  (WdfDeviceFailedAttemptRestart)
         'FF15A1180100'      # call [rip+0x118A1]  (dispatch thunk)
         'E9EADFFEFF'        # jmp back to error path at 0x189A6
     ),
     'Cave 3: WdfDeviceSetFailed + return'),
]


def main():
    if not os.path.exists(SRC):
        print(f'ERROR: Place the original qcbtuart.sys in {SCRIPT_DIR}')
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
