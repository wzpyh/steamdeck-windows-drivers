# Steam Deck OLED Windows Driver Fixes

Binary patches for drivers on the **Steam Deck OLED running Windows 11** that cause blue-screens, kernel memory leaks, or lack hardware support.

> **Which OLED do you have?** The Steam Deck OLED shipped with two different APU variants. Check Device Manager &rarr; Display adapters &rarr; Properties &rarr; Details &rarr; Hardware Ids:
>
> | Device ID | APU Codename | Notes |
> |---|---|---|
> | `DEV_163F` | **VanGogh** | Same as LCD. Third-party drivers (Ally2Deck, ASUS ROG) may work. |
> | `DEV_1435` | **Sephiroth** | Valve-exclusive silicon. **No third-party driver supports this chip** &mdash; these patches are your only option. |
>
> The Bluetooth patch applies to all Steam Deck OLEDs regardless of APU variant.

## What's in this repo

| Directory | Driver | What it does |
|---|---|---|
| [`bluetooth/`](#the-bluetooth-problem) | `qcbtuart.sys` 1.0.0.14 | Fixes two BSOD paths (0x10D pool exhaustion + 0x9F power timeout) with self-healing PnP restart |
| [`gpu/`](#the-gpu-problem) | `amdkmdag.sys` 32.0.11002.3007 (Valve) | NOPs leaked `PsSetCreateProcessNotifyRoutineEx` callbacks that exhaust nonpaged pool |
| [`adrenalin/`](#adrenalin-on-sephiroth) | `amdkmdag.sys` from AMD Adrenalin | **Enables AMD Adrenalin drivers on the Sephiroth APU** &mdash; D3D12 FL 12_2, WDDM 3.2, H.264/HEVC encode |

## Adrenalin on Sephiroth

**The big one.** If your Steam Deck OLED has `DEV_1435` (Sephiroth), no AMD driver &mdash; not Valve's, not ASUS's, not any OEM's &mdash; has ever shipped with support for your hardware. Valve's driver caps you at D3D12 Feature Level 12_0 and WDDM 2.0. Community projects like Ally2Deck patch ASUS drivers for VanGogh (`DEV_163F`) but fail with Code 10 on Sephiroth because the binary has no code paths for `DEV_1435`.

This patch changes that. It takes AMD's **Adrenalin 26.10.1** (`amdkmdag.sys` 32.0.21045.16010) and replaces 11 device-ID fields from VanGogh (`0x163F`) to Sephiroth (`0x1435`). That's it &mdash; 22 bytes changed, zero code modifications. The VanGogh initialization path works natively on Sephiroth hardware.

### Result

| | Valve OEM | Adrenalin 26.10.1 (patched) |
|---|---|---|
| D3D12 Feature Level | 12_0 | **12_2** |
| WDDM | 2.0 | **3.2** |
| H.264/HEVC Encode | No | **Yes** |
| Adrenalin Software UI | No | **Yes** |
| Driver Date | 2023 | **2026** |

### How it works

The patch auto-discovers all `0x0000163F` (VanGogh) DWORD entries in the binary and replaces them with `0x00001435` (Sephiroth), skipping false positives and PAGEDCIR hardware block IDs (which are internal register addresses, not device IDs). The result is that AMD's driver recognizes Sephiroth as a supported device and initializes it through the VanGogh code path, which is architecturally compatible.

### Installation

```powershell
# 1. Download AMD Adrenalin 26.10.1 installer and extract amdkmdag.sys
#    (Run the installer, it extracts to C:\AMD\... — find amdkmdag.sys in the extracted files)

# 2. Copy it here and patch
copy <path-to-extracted>\amdkmdag.sys adrenalin\amdkmdag.sys
python adrenalin\patch.py

# 3. Deploy (Admin PowerShell)
.\adrenalin\deploy.ps1

# 4. COLD BOOT — shut down fully, then power on
#    Do NOT use Restart. Hot restart will BSOD.
```

### Limitations

- **Cold boot required.** Hot restart (`pnputil /restart-device`, Windows Restart with fast startup) crashes with BSOD 0x7E due to stale adapter state in the display stack. Always shut down fully and power back on.
- Requires Windows test signing mode (adds a "Test Mode" watermark).
- Tested with Adrenalin 26.10.1 (32.0.21045.16010). Other versions should work if the device-ID structure is similar &mdash; the script auto-discovers patch locations.
- Sleep/resume, hibernate, and GPU-intensive workloads are untested but expected to work (same silicon, same init path).

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

## Why not just use a newer AMD driver?

**Short answer:** if your OLED has the Sephiroth APU (`DEV_1435`), no other driver exists &mdash; until now.

Valve stopped updating their Windows drivers for the Steam Deck. Community projects like [Ally2Deck-v3](https://github.com/steminvader/Ally2Deck-v3) can patch ASUS ROG Ally drivers to work on the Deck &mdash; but only for the **VanGogh** variant (`DEV_163F`), because that's what the ROG Ally also uses.

I tested Ally2Deck-v3 with the ASUS driver on my Sephiroth OLED after adding `DEV_1435` to `amdgcf.dat` and the INF files. The driver loaded but failed during initialization with **CM_PROB_FAILED_POST_START** (Code 10). The ASUS binary has no code paths for `DEV_1435` &mdash; the `cmp edi,1435h` instructions that exist in Valve's driver are completely absent. No amount of INF/whitelist patching can fix this.

The Adrenalin patch in this repo solves this by going straight to AMD's own driver and teaching it about Sephiroth. The VanGogh init path is architecturally compatible, so a pure data patch &mdash; 11 device-ID fields, 22 bytes &mdash; is all it takes.

## Requirements

- **Steam Deck OLED** running Windows 11
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

Each patcher needs the **original unpatched** `.sys` file.

- **Bluetooth:** `qcbtuart.sys` &mdash; usually at `C:\Windows\System32\DriverStore\FileRepository\qcbtuart.inf_amd64_*\qcbtuart.sys`
- **GPU (Valve):** `amdkmdag.sys` &mdash; usually at `C:\Windows\System32\DriverStore\FileRepository\u0403558.inf_amd64_*\B403937\amdkmdag.sys`
- **Adrenalin:** `amdkmdag.sys` &mdash; extract from the AMD Adrenalin installer package

### 3. Patch

```powershell
# Bluetooth
copy <path-to-original>\qcbtuart.sys bluetooth\qcbtuart.sys
python bluetooth\patch.py

# GPU (Valve memory leak fix)
copy <path-to-original>\amdkmdag.sys gpu\amdkmdag.sys
python gpu\patch.py

# Adrenalin (Sephiroth device-ID patch)
copy <path-to-extracted>\amdkmdag.sys adrenalin\amdkmdag.sys
python adrenalin\patch.py
```

### 4. Sign and deploy

```powershell
# Admin PowerShell
.\bluetooth\deploy.ps1
.\gpu\deploy.ps1
.\adrenalin\deploy.ps1
```

**Adrenalin requires a cold boot** (full shutdown + power on). The other patches activate on any reboot.

### 5. Verify

- **Bluetooth:** After an adapter hang (BthMini Event ID 3), the adapter should disappear and reappear in Device Manager within ~40 seconds. No BSOD.
- **GPU:** `Proc` tag allocations in `poolmon` should show frees keeping pace with allocations.
- **Adrenalin:** DxDiag should show Feature Level **12_2**, WDDM 3.2, and the Adrenalin driver version.

## Reverting

Each directory contains a `revert.ps1` that restores the original driver.

```powershell
# Admin PowerShell
.\bluetooth\revert.ps1
.\gpu\revert.ps1
.\adrenalin\revert.ps1
# Reboot (cold boot for Adrenalin)
```

## Technical Details

### Adrenalin patch map (amdkmdag.sys 32.0.21045.16010)

11 DWORD fields where `0x0000163F` (VanGogh) is replaced with `0x00001435` (Sephiroth):

| Section | Count | Purpose |
|---|---|---|
| `.text` | 4 | Device classification comparisons |
| `.rdata` | 2 | ASIC factory table entries (rev=AE, rev=AF) |
| `.data` | 2 | Supported-device array + family-0x90 record |
| `PAGEKMDD` | 1 | Device slot |
| `PAGED3PR` | 2 | Display controller + parameter tables |

The script auto-discovers these locations by scanning for `0x0000163F` DWORDs and filtering out:
- **PAGEDCIR entries** (4&times;): internal hardware block IDs paired with `0x1620` &mdash; patching these would break register access
- **Byte-aligned false positives**: coincidental byte patterns in float/string data

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

Self-healing caves use **INT3 padding** between function stubs in the `.text` section.

### GPU patch map (amdkmdag.sys 32.0.11002.3007)

| Patch | File Offset | Size | Description |
|---|---|---|---|
| Callback A | `0xDFA8E` | 6 B | `call [IAT PsSetCreate...]` &rarr; `xor eax,eax; nop*4` |
| Callback B | `0x11AC36` | 6 B | Same |
| Callback C | `0x61C07C` | 6 B | Same |

## Disclaimer

These patches modify kernel-mode drivers. They were developed through reverse engineering of the specific driver versions shipped by Valve and AMD for the Steam Deck OLED. **Use at your own risk.** The authors are not responsible for any damage. Always keep backups of your original drivers.

## License

MIT
