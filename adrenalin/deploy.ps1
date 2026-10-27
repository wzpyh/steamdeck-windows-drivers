#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Sign and deploy patched Adrenalin amdkmdag.sys for Steam Deck OLED.

.DESCRIPTION
  1. Verify patched driver exists
  2. Ensure test signing enabled
  3. Create/reuse self-signed test certificate
  4. Sign patched driver
  5. Back up original driver
  6. Schedule boot-time replacement (MoveFileEx)
  7. Reboot to activate

  The driver cannot be replaced while the GPU is running, so this script
  schedules the replacement for next boot via MoveFileEx.

  IMPORTANT: Cold boot required. Hot restart (pnputil /restart-device) will
  BSOD with 0x7E. After the script completes, shut down fully and power back on.

  Revert: run revert.ps1 from this directory.
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$patchedSys = Join-Path $scriptDir 'amdkmdag.sys.patched'
$signedSys  = Join-Path $scriptDir 'amdkmdag.sys.signed'
$backupSys  = Join-Path $scriptDir 'amdkmdag.sys.original'
$certName   = 'AmdKmdagTestPatch'

# Find signtool
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found. Install the Windows SDK.' }
$signtool = $signtool.FullName

# Find installed amdkmdag.sys via the display adapter's driver store path
$displayDev = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
if ($displayDev) {
    $drvInf = (Get-PnpDeviceProperty -InstanceId $displayDev.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
    if ($drvInf) {
        $driverDst = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Recurse -Filter 'amdkmdag.sys' -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match [regex]::Escape(($drvInf -replace '\.inf$','')) } | Select-Object -First 1
    }
}
if (-not $driverDst) {
    $driverDst = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'amdkmdag.sys' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $driverDst) { throw 'amdkmdag.sys not found in DriverStore' }
$driverDst = $driverDst.FullName
Write-Host "Target: $driverDst"

# --- Pre-flight ---
if (-not (Test-Path $patchedSys)) {
    throw "Patched driver not found. Run: python patch.py"
}

# --- Test signing ---
Write-Host "`n--- Test signing ---"
$bcd = bcdedit /enum '{current}' 2>&1 | Out-String
if ($bcd -match 'testsigning\s+Yes') {
    Write-Host "Already enabled."
} else {
    bcdedit /set testsigning on
    if ($LASTEXITCODE -ne 0) { throw 'bcdedit failed' }
    Write-Host "Enabled (takes effect after reboot)." -ForegroundColor Yellow
}

# --- Certificate ---
Write-Host "`n--- Certificate ---"
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$certName" } | Select-Object -First 1
if (-not $cert) {
    Write-Host "Creating certificate '$certName'..."
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=$certName" `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(5)
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
    $rootStore.Open('ReadWrite'); $rootStore.Add($cert); $rootStore.Close()
    $pubStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine')
    $pubStore.Open('ReadWrite'); $pubStore.Add($cert); $pubStore.Close()
    Write-Host "Created. Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "Using existing cert: $($cert.Thumbprint)"
}

# --- Sign ---
Write-Host "`n--- Sign ---"
Copy-Item $patchedSys $signedSys -Force
& $signtool sign /fd sha256 /a /s My /n $certName /t http://timestamp.digicert.com $signedSys
if ($LASTEXITCODE -ne 0) {
    Write-Host "Timestamp unreachable, signing without..." -ForegroundColor Yellow
    & $signtool sign /fd sha256 /a /s My /n $certName $signedSys
    if ($LASTEXITCODE -ne 0) { throw 'signtool sign failed' }
}
Write-Host "Signed." -ForegroundColor Green

# --- Backup ---
Write-Host "`n--- Backup ---"
if (-not (Test-Path $backupSys)) {
    Copy-Item $driverDst $backupSys -Force
    Write-Host "Original backed up to: $backupSys" -ForegroundColor Green
} else {
    Write-Host "Backup already exists: $backupSys"
}

# --- Deploy via MoveFileEx (boot-time replacement) ---
Write-Host "`n--- Deploy ---"
Add-Type @'
using System; using System.Runtime.InteropServices;
public class BootReplace {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool MoveFileEx(string src, string dst, int flags);
}
'@

$dir = Split-Path $driverDst
& takeown /F $driverDst 2>&1 | Out-Null
& icacls $driverDst /grant Administrators:F 2>&1 | Out-Null
& takeown /F $dir 2>&1 | Out-Null
& icacls $dir /grant Administrators:F 2>&1 | Out-Null

$stagePath = "$driverDst.pending"
Copy-Item $signedSys $stagePath -Force
$ok = [BootReplace]::MoveFileEx($stagePath, $driverDst, 5)  # REPLACE | DELAY_UNTIL_REBOOT
if (-not $ok) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "MoveFileEx failed (Win32 error $err)"
}

Write-Host "`nDriver scheduled for replacement on next boot." -ForegroundColor Green
Write-Host "  Backup: $backupSys"
Write-Host "  Revert: .\revert.ps1 (after reboot)"
Write-Host "`n=== IMPORTANT: Cold boot required ===" -ForegroundColor Cyan
Write-Host "Shut down fully (Start > Shut down), then power back on." -ForegroundColor Cyan
Write-Host "Do NOT use Restart — fast startup may skip the file replacement." -ForegroundColor Yellow
