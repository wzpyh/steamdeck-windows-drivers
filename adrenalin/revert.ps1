#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Revert amdkmdag.sys to the backup saved during Adrenalin patch deployment.
#>
$ErrorActionPreference = 'Stop'

$backupSys = Join-Path $PSScriptRoot 'amdkmdag.sys.original'

if (-not (Test-Path $backupSys)) { throw "No backup found: $backupSys" }

Write-Host "Backup: $backupSys"
Write-Host "Hash:   $((Get-FileHash $backupSys -Algorithm SHA256).Hash)"

# Find installed driver
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

# Schedule boot-time replacement
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
Copy-Item $backupSys $stagePath -Force
$ok = [BootReplace]::MoveFileEx($stagePath, $driverDst, 5)
if (-not $ok) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "MoveFileEx failed (Win32 error $err)"
}

Write-Host "`nOriginal driver scheduled for restoration on next boot." -ForegroundColor Green
Write-Host "Cold boot to activate (shut down fully, then power on)." -ForegroundColor Cyan
