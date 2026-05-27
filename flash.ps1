#Requires -Version 5.1
<#
.SYNOPSIS
    Flash a LineageOS GSI build to an A/B device via fastboot.
.PARAMETER Out
    Path to the build output directory. Defaults to .\out relative to this script.
.PARAMETER NoReboot
    Skip the final reboot, leaving the device in fastboot mode.
.EXAMPLE
    .\flash.ps1
    .\flash.ps1 -Out C:\builds\lineage\out
    .\flash.ps1 -NoReboot
#>
param(
    [string]$Out,
    [switch]$NoReboot
)

if (-not $Out) {
    $Out = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "out"
}

$SystemImg      = Join-Path $Out "system.img"
$BootImg        = Join-Path $Out "boot-patched.img"
$VendorBootImg  = Join-Path $Out "vendor_boot-patched.img"

function Invoke-Fastboot {
    param([string[]]$Arguments)
    & fastboot @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Error "fastboot $($Arguments -join ' ') failed (exit code $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}

if (-not (Test-Path $SystemImg)) {
    Write-Error "$SystemImg not found. Build first or pass -Out as argument."
    exit 1
}

Write-Host "==> Deleting logical product partition (may fail on some devices -- that is OK)..."
& fastboot delete-logical-partition product
# Not checking exit code -- not all devices have this partition.

Write-Host "==> Erasing system_a..."
Invoke-Fastboot "erase","system_a"

Write-Host "==> Flashing system_a (this takes a while)..."
Invoke-Fastboot "flash","system_a",$SystemImg

Write-Host "==> Setting active slot to a..."
Invoke-Fastboot "--set-active=a"

if (Test-Path $BootImg) {
    Write-Host "==> Flashing patched boot_a..."
    Invoke-Fastboot "flash","boot_a",$BootImg
} else {
    Write-Warning "$BootImg not found -- skipping boot patch."
    Write-Warning "On devices without a standalone vbmeta partition, dm-verity will"
    Write-Warning "not be disabled and the system may fail to mount."
}

if (Test-Path $VendorBootImg) {
    Write-Host "==> Flashing patched vendor_boot_a..."
    Invoke-Fastboot "flash","vendor_boot_a",$VendorBootImg
} else {
    Write-Host "INFO: $VendorBootImg not found -- skipping vendor_boot flash (not all devices have this partition)."
}

Write-Host "==> Wiping userdata/cache/metadata (errors about missing partitions are normal)..."
& fastboot -w
# Not checking exit code -- partition absence is normal on some devices.

if ($NoReboot) {
    Write-Host ""
    Write-Host "Done. Device is still in fastboot mode (-NoReboot was passed)."
} else {
    Write-Host "==> Rebooting..."
    Invoke-Fastboot "reboot"
    Write-Host ""
    Write-Host "Done. Your device is rebooting into the new system."
}
