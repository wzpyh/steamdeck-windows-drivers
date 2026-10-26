# Steam Deck OLED Windows Driver Fixes

Binary patches for two Valve-shipped drivers on the **Steam Deck OLED running Windows 11** that cause blue-screens (BSODs) after the Bluetooth adapter enters an unresponsive state.

| Driver | Bug | BSOD | Patch |
|---|---|---|---|
| `qcbtuart.sys` 1.0.0.14 (Qualcomm QCA206x Bluetooth UART) | Infinite wait on dead adapter &rarr; nonpaged pool exhaustion | 0x10D after 9-18 h | 30 s timeout + I/O cancel + **automatic PnP device restart** |
| `qcbtuart.sys` 1.0.0.14 | D3 power transition blocks on dead adapter | 0x9F (immediate) | NOP the blocking calls |
| `amdkmdag.sys` 32.0.11002.3007 (Valve AMD GPU) | `PsSetCreateProcessNotifyRoutineEx` callbacks never unregistered &rarr; EPROCESS reference leak | Gradual memory exhaustion | NOP all 3 registration call sites |

All patches are applied by a Python script that reads the **original** `.sys` from Valve's driver package, verifies its SHA-256, writes the patched bytes, and outputs a new `.sys` ready for test-signing.

## The Bluetooth Problem

The QCA206x Bluetooth adapter on the Steam Deck OLED occasionally enters an unresponsive state (visible as **BthMini Event ID 3** in the System log: *"A command sent to the adapter has timed out"*). Once this happens, `qcbtuart.sys` has two fatal code paths:

### Path A: Nonpaged Pool Exhaustion (0x10D)

`IoWorkerPerformUartWrite` (RVA `0x1897D`) calls `KeWaitForSingleObject` with a **NULL timeout** (infinite wait) on an I/O completion event. When the adapter is dead, the UART write never completes. The WDF framework keeps dispatching new write requests, each allocating nonpaged pool for IRP buffers. Over 9-18 hours, the nonpaged pool grows to 8-10 GB until `INSUFFICIENT_RESOURCES` (0x10D) blue-screens the machine.

**Fix:** Replace the infinite wait with a **30-second timeout**. On timeout:
1. Call `WdfIoTargetStop(CancelSentIo)` to cancel the pending UART request
2. Set `STATUS_IO_TIMEOUT` and fall through to the existing error path
3. Call `WdfDeviceSetFailed(WdfDeviceFailedAttemptRestart)` to trigger **PnP re-enumeration** &mdash; the device stack is torn down and rebuilt, reloading the adapter firmware automatically

This is a **self-healing** patch: Bluetooth recovers without any external scripts, scheduled tasks, or user intervention.

### Path B: D3 Power BSOD (0x9F)

When anything triggers a D3 (power-off) transition on the dead adapter &mdash; sleep, radio toggle, or a recovery script &mdash; `FdoDevD0Exit_SwInband` calls `ResetCherokee` / `CherokeePowerDown`, which try to send HCI commands over the broken UART. The power IRP never completes, and after ~2 minutes the system watchdog fires `DRIVER_POWER_STATE_FAILURE` (0x9F).

**Fix:** NOP the two `CherokeePowerDown` calls (RVA `0xDD3B`, `0xDD42`). The D3 transition completes immediately, and PnP restart (from Path A) handles the actual recovery.

## The GPU Problem

Valve's `amdkmdag.sys` registers three `PsSetCreateProcessNotifyRoutineEx` callbacks during initialization but **never unregisters them**, even when the callbacks are functionally dead. Each process exit leaks an `EPROCESS` reference (~0.78 KB/process). On a machine running browsers and Electron apps that spawn many short-lived processes, this accumulates over days.

**Fix:** NOP all three `PsSetCreateProcessNotifyRoutineEx` call sites (RVA `0xDFE8E`, `0x11B036`, `0x61C47C`), replacing each 6-byte `call [IAT]` with `xor eax, eax; nop*4`. The callbacks were Valve's telemetry/debug hooks and are not required for GPU operation.

## Requirements

- **Steam Deck OLED** running Windows 11 (other hardware will have different driver binaries)
- Python 3.10+
- Windows SDK (`signtool.exe`) for test-signing
- Administrator access

## Installation

### 1. Enable test signing (one-time)

```powershell
# Admin PowerShell
bcdedit /set testsigning on
# Reboot
```

This adds a "Test Mode" watermark to the desktop (cosmetic only).

### 2. Obtain the original drivers

The patcher needs the **original unpatched** `.sys` files from Valve's driver package.

- **Bluetooth:** `qcbtuart.sys` SHA-256: `f52ef4caca48ae59c61d18fcf3722308bc19d1c24c6605d4ba66c26ef78aa744`
  - Usually at: `C:\Windows\System32\DriverStore\FileRepository\qcbtuart.inf_amd64_*\qcbtuart.sys`
- **GPU:** `amdkmdag.sys` SHA-256: `0b446cba31e21e3d90d921919a180201c4b2ea76b064296f116508b984c79319`
  - Usually at: `C:\Windows\System32\DriverStore\FileRepository\u0403558.inf_amd64_*\B403937\amdkmdag.sys`

### 3. Patch

```powershell
# Bluetooth
copy <path-to-original>\qcbtuart.sys bluetooth\qcbtuart.sys
python bluetooth\patch.py

# GPU
copy <path-to-original>\amdkmdag.sys gpu\amdkmdag.sys
python gpu\patch.py
```

Each script verifies the source hash, applies patches, and writes the patched `.sys` to the same directory.

### 4. Sign and deploy

```powershell
# Admin PowerShell — Bluetooth
.\bluetooth\deploy.ps1

# Admin PowerShell — GPU
.\gpu\deploy.ps1
```

The deploy scripts handle certificate creation, signing, backup of the original, and driver replacement. **Reboot** to activate.

### 5. Verify

- **Bluetooth:** After an adapter hang (BthMini Event ID 3), watch Device Manager &mdash; the Bluetooth adapter should disappear and reappear within ~40 seconds as PnP re-enumerates it. No BSOD.
- **GPU:** Run `poolmon` or check Task Manager over several days &mdash; `Proc` tag allocations should show frees keeping pace with allocations.

## Reverting

Each directory contains a `revert.ps1` that restores the original driver from the backup created during deployment.

```powershell
# Admin PowerShell
.\bluetooth\revert.ps1   # or .\gpu\revert.ps1
# Reboot
```

## Technical Details

### Bluetooth patch map (qcbtuart.sys 1.0.0.14)

| Patch | File Offset | Size | Description |
|---|---|---|---|
| Path B: NOP #1 | `0xD13B` | 5 B | `call CherokeePowerDown` &rarr; `nop*5` |
| Path B: NOP #2 | `0xD142` | 5 B | `call CherokeePowerDown` &rarr; `nop*5` |
| Path A: Timeout | `0x17D48` | 94 B | Infinite wait &rarr; 30 s timeout + WdfIoTargetStop |
| Trampoline | `0x098A1` | 7 B | Redirect DriverDeviceAdd context store to Cave C |
| Cave C | `0x29FA6` | 22 B | Store WDFDEVICE handle in unused global |
| Cave 1 | `0x29D66` | 16 B | Load WDFDEVICE + WDF framework globals |
| Cave 2 | `0x29D82` | 20 B | Load WdfDeviceSetFailed function pointer |
| Cave 3 | `0x29DA6` | 22 B | NULL check + call WdfDeviceSetFailed + return |

The self-healing caves use **INT3 padding** between function stubs in the `.text` section (dead space inserted by the linker for alignment). No existing code is displaced.

### GPU patch map (amdkmdag.sys 32.0.11002.3007)

| Patch | File Offset | Size | Description |
|---|---|---|---|
| Callback A | `0xDFA8E` | 6 B | `call [IAT PsSetCreate...]` &rarr; `xor eax,eax; nop*4` |
| Callback B | `0x11AC36` | 6 B | Same |
| Callback C | `0x61C07C` | 6 B | Same |

## Disclaimer

These patches modify kernel-mode drivers. They were developed through reverse engineering of the specific driver versions shipped by Valve for the Steam Deck OLED. **Use at your own risk.** The authors are not responsible for any damage. Always keep backups of your original drivers.

These patches are specific to the exact driver versions listed above. Different versions will have different hashes and the patcher will refuse to run.

## License

MIT
