<#
.SYNOPSIS
    Lifecycle actions on the lab VMs (used by the Makefile and the failure demos).

.DESCRIPTION
    status      Name, state, uptime, memory of each lab VM
    start       Start VMs
    stop        Graceful shutdown (the guest OS shuts down cleanly)
    poweroff    Hard power-off: simulates a node crash / pulled power cable
    checkpoint  Shut down, take a checkpoint named -Snapshot, start again
    restore     Return to checkpoint -Snapshot and start

    Without -Node, the action applies to every node in infra/lab.json.

.EXAMPLE
    .\Invoke-LabVM.ps1 -Action poweroff -Node k3s-worker1
    .\Invoke-LabVM.ps1 -Action checkpoint -Snapshot fresh
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'start', 'stop', 'poweroff', 'checkpoint', 'restore')]
    [string]$Action,
    [string[]]$Node,
    [string]$Snapshot = 'fresh'
)

$ErrorActionPreference = 'Stop'
$lab = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..\lab.json') | ConvertFrom-Json
$names = @($lab.nodes | ForEach-Object { $_.name } | Where-Object { -not $Node -or $Node -contains $_ })
if ($names.Count -eq 0) { throw "No lab node matches '$Node'." }

switch ($Action) {
    'status' {
        Get-VM -Name $names -ErrorAction SilentlyContinue |
            Select-Object Name, State,
                @{ n = 'Uptime'; e = { '{0:dd\.hh\:mm\:ss}' -f $_.Uptime } },
                @{ n = 'MemoryGB'; e = { [math]::Round($_.MemoryAssigned / 1GB, 1) } },
                @{ n = 'Checkpoints'; e = { (Get-VMSnapshot -VMName $_.Name | ForEach-Object { $_.Name }) -join ',' } } |
            Format-Table -AutoSize
    }
    'start'    { Start-VM -Name $names }
    'stop'     { Stop-VM -Name $names }
    'poweroff' { Stop-VM -Name $names -TurnOff -Force }
    'checkpoint' {
        Stop-VM -Name $names
        foreach ($n in $names) {
            Get-VMSnapshot -VMName $n -Name $Snapshot -ErrorAction SilentlyContinue | Remove-VMSnapshot
            Checkpoint-VM -Name $n -SnapshotName $Snapshot
        }
        Start-VM -Name $names
    }
    'restore' {
        foreach ($n in $names) {
            Restore-VMSnapshot -VMName $n -Name $Snapshot -Confirm:$false
        }
        Start-VM -Name $names
    }
}
if ($Action -ne 'status') { Write-Host "$Action done: $($names -join ', ')" }
