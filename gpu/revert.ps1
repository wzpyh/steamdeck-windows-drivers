#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Revert amdkmdag.sys to the original unpatched version.
#>
$ErrorActionPreference = 'Stop'

$backupSys = Join-Path $PSScriptRoot 'amdkmdag.sys.original'
$expectedOrigHash = '0B446CBA31E21E3D90D921919A180201C4B2EA76B064296F116508B984C79319'

if (-not (Test-Path $backupSys)) { throw "No backup found: $backupSys" }

$bkHash = (Get-FileHash $backupSys -Algorithm SHA256).Hash
if ($bkHash -ne $expectedOrigHash) {
    throw "Backup hash mismatch! Got $bkHash — backup may be corrupt"
}
Write-Host "Backup hash verified." -ForegroundColor Green

$driverDst = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'amdkmdag.sys' -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match 'u0403558' } | Select-Object -First 1
if (-not $driverDst) {
    $driverDst = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'amdkmdag.sys' -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if (-not $driverDst) { throw 'amdkmdag.sys not found in DriverStore' }
$driverDst = $driverDst.FullName

$acl = Get-Acl $driverDst
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id,'FullControl','Allow')
$acl.SetAccessRule($rule)
Set-Acl $driverDst $acl

$tmpDst = "$driverDst.tmp"
Copy-Item $backupSys $tmpDst -Force
Move-Item $tmpDst $driverDst -Force

$h = (Get-FileHash $driverDst -Algorithm SHA256).Hash
if ($h -ne $expectedOrigHash) {
    throw "Post-copy hash mismatch! Got $h — DO NOT reboot"
}
Write-Host "Reverted to original. Hash: $h" -ForegroundColor Green
Write-Host "Reboot to load original driver." -ForegroundColor Yellow
