#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Sign and deploy patched amdkmdag.sys for Steam Deck OLED.

.DESCRIPTION
  1. Ensure test signing enabled
  2. Create/reuse self-signed test certificate
  3. Sign patched driver
  4. Back up original, replace in DriverStore
  5. Reboot to activate

  Revert: run revert.ps1 from this directory.
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$scriptDir  = $PSScriptRoot
$patchedSys = Join-Path $scriptDir 'amdkmdag.sys.patched'
$signedSys  = Join-Path $scriptDir 'amdkmdag.sys.signed'
$backupSys  = Join-Path $scriptDir 'amdkmdag.sys.original'
$certName   = 'SteamDeckDriverPatch'

$expectedOrigHash = '0B446CBA31E21E3D90D921919A180201C4B2EA76B064296F116508B984C79319'

# Find signtool
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found. Install the Windows SDK.' }
$signtool = $signtool.FullName

# Find installed driver (Valve's inf name: u0403558.inf)
$driverDst = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'amdkmdag.sys' -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match 'u0403558' } | Select-Object -First 1
if (-not $driverDst) {
    $driverDst = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'amdkmdag.sys' -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if (-not $driverDst) { throw 'amdkmdag.sys not found in DriverStore' }
$driverDst = $driverDst.FullName
Write-Host "Target: $driverDst"

# --- Pre-flight ---
if (-not (Test-Path $patchedSys)) {
    throw "Patched driver not found. Run: python patch.py"
}

$installedHash = (Get-FileHash $driverDst -Algorithm SHA256).Hash
if ($installedHash -ne $expectedOrigHash -and -not $Force) {
    Write-Host "WARNING: Installed driver hash doesn't match expected original." -ForegroundColor Red
    Write-Host "  Got:      $installedHash" -ForegroundColor Red
    Write-Host "  Expected: $expectedOrigHash" -ForegroundColor Red
    Write-Host "  Use -Force to override, or the driver version may be different." -ForegroundColor Yellow
    exit 1
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

# --- Deploy ---
Write-Host "`n--- Deploy ---"
$acl = Get-Acl $driverDst
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id,'FullControl','Allow')
$acl.SetAccessRule($rule)
Set-Acl $driverDst $acl

$tmpDst = "$driverDst.tmp"
Copy-Item $signedSys $tmpDst -Force
Move-Item $tmpDst $driverDst -Force

Write-Host "`nDriver replaced." -ForegroundColor Green
Write-Host "  Backup: $backupSys"
Write-Host "  Revert: .\revert.ps1"
Write-Host "`n=== Reboot to activate ===" -ForegroundColor Cyan
