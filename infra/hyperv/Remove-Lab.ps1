<#
.SYNOPSIS
    Deletes the lab VMs and their disks. -Network also removes the switch and NAT
    (needs an elevated shell). The base image and seed ISOs are kept for a rebuild.

.EXAMPLE
    .\Remove-Lab.ps1            # asks for confirmation
    .\Remove-Lab.ps1 -Force -Network
#>
[CmdletBinding()]
param([switch]$Force, [switch]$Network)

$ErrorActionPreference = 'Stop'
$lab = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..\lab.json') | ConvertFrom-Json
$names = @($lab.nodes | ForEach-Object { $_.name })

if (-not $Force) {
    $answer = Read-Host "Delete VMs $($names -join ', ') and their disks? Type yes"
    if ($answer -ne 'yes') { Write-Host 'Nothing deleted.'; exit 0 }
}

foreach ($n in $names) {
    $vm = Get-VM -Name $n -ErrorAction SilentlyContinue
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $n -TurnOff -Force }
        Get-VMSnapshot -VMName $n | Remove-VMSnapshot
        # Snapshot removal merges .avhdx files in the background; wait for it
        while ((Get-VM -Name $n).Status -match 'Merging') { Start-Sleep -Seconds 2 }
        Remove-VM -Name $n -Force
        Write-Host "==> removed VM $n"
    }
    Get-ChildItem -Path (Join-Path $lab.labRoot 'disks') -Filter "$n*" -ErrorAction SilentlyContinue | Remove-Item -Force
    Remove-Item -Recurse -Force -Path (Join-Path $lab.labRoot "vms\$n") -ErrorAction SilentlyContinue
}

if ($Network) {
    Get-NetNat -Name $lab.natName -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false
    Get-VMSwitch -Name $lab.switchName -ErrorAction SilentlyContinue | Remove-VMSwitch -Force
    Write-Host '==> removed NAT and switch'
}
Write-Host "Done. In WSL, forget the old host keys:  make forget-hosts"
