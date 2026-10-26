#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Revert qcbtuart.sys to the original unpatched version.
#>
$ErrorActionPreference = 'Stop'

$backupSys = Join-Path $PSScriptRoot 'qcbtuart.sys.original'
$expectedOrigHash = 'F52EF4CACA48AE59C61D18FCF3722308BC19D1C24C6605D4BA66C26EF78AA744'

if (-not (Test-Path $backupSys)) { throw "No backup found: $backupSys" }

$bkHash = (Get-FileHash $backupSys -Algorithm SHA256).Hash
if ($bkHash -ne $expectedOrigHash) {
    throw "Backup hash mismatch! Got $bkHash — backup may be corrupt"
}
Write-Host "Backup hash verified." -ForegroundColor Green

$driverDst = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'qcbtuart.sys' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $driverDst) { throw 'qcbtuart.sys not found in DriverStore' }
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
