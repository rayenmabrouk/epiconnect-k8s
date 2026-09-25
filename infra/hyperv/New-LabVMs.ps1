<#
.SYNOPSIS
    Creates and starts the lab VMs defined in infra/lab.json on Hyper-V.

.DESCRIPTION
    For each node:
      - disk: Hyper-V converts the base VHDX (built by prepare-image.sh) into the
        node's own dynamic VHDX, then grows it to diskSizeGB. cloud-init grows the
        root filesystem on first boot.
      - VM: Generation 2 (UEFI), Secure Boot with the Microsoft UEFI CA template
        (the one that trusts Linux shim), static memory (Kubernetes schedules
        against memory it assumes is really there), no automatic checkpoints.
      - NIC: attached to the k3s-lab switch with the static MAC from lab.json,
        which cloud-init's network-config matches to assign the static IP.
      - DVD: the node's cloud-init seed ISO (volume label "cidata").
    Then waits until SSH answers on every node.

    Needs membership of "Hyper-V Administrators" (Initialize-LabHost.ps1), not elevation.
    Idempotent: existing VMs are left untouched.

.EXAMPLE
    make vms                       (from WSL)
    .\New-LabVMs.ps1 -Name k3s-worker2
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$lab = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..\lab.json') | ConvertFrom-Json
$nodes = @($lab.nodes | Where-Object { -not $Name -or $Name -contains $_.name })
$base = Join-Path $lab.labRoot 'base\ubuntu-24.04-base.vhdx'

function Test-TcpPort([string]$Ip, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Ip, $Port)
        return ($task.Wait(2000) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

if (-not (Get-VMSwitch -Name $lab.switchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$($lab.switchName)' not found. Run Initialize-LabHost.ps1 as Administrator first."
}
if (-not (Test-Path $base)) {
    throw "$base not found. Run 'make image' in WSL first."
}

foreach ($n in $nodes) {
    if (Get-VM -Name $n.name -ErrorAction SilentlyContinue) {
        Write-Host "==> $($n.name): exists, skipping" -ForegroundColor Yellow
        continue
    }
    $seed = Join-Path $lab.labRoot "seed\$($n.name).iso"
    $disk = Join-Path $lab.labRoot "disks\$($n.name).vhdx"
    if (-not (Test-Path $seed)) { throw "$seed not found. Run 'make image' in WSL first." }
    if (Test-Path $disk) { throw "$disk already exists without a VM. Remove it (Remove-Lab.ps1) and retry." }

    Write-Host "==> $($n.name): $($n.ip), $($n.cpus) vCPU, $($n.memoryMB) MB" -ForegroundColor Cyan
    Convert-VHD -Path $base -DestinationPath $disk -VHDType Dynamic
    Resize-VHD -Path $disk -SizeBytes ([int64]$lab.diskSizeGB * 1GB)

    New-VM -Name $n.name -Generation 2 -MemoryStartupBytes ([int64]$n.memoryMB * 1MB) `
        -VHDPath $disk -SwitchName $lab.switchName -Path (Join-Path $lab.labRoot 'vms') | Out-Null
    Set-VM -Name $n.name -ProcessorCount $n.cpus -StaticMemory `
        -AutomaticCheckpointsEnabled $false -CheckpointType Standard `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
        -Notes "epiconnect-k8s lab node ($($n.role)), $($n.ip)"
    Set-VMNetworkAdapter -VMName $n.name -StaticMacAddress $n.mac
    Set-VMFirmware -VMName $n.name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
    Add-VMDvdDrive -VMName $n.name -Path $seed
    Set-VMFirmware -VMName $n.name -FirstBootDevice (Get-VMHardDiskDrive -VMName $n.name)
    Start-VM -Name $n.name
}

Write-Host "==> Waiting for SSH (up to $TimeoutSeconds s; first boot runs cloud-init)" -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$pending = @($nodes)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $pending = @($pending | Where-Object {
        if (Test-TcpPort $_.ip 22) { Write-Host "    $($_.name) ($($_.ip)): SSH up" -ForegroundColor Green; $false } else { $true }
    })
    if ($pending.Count -gt 0) { Start-Sleep -Seconds 5 }
}
if ($pending.Count -gt 0) {
    Write-Warning ("No SSH on: " + (($pending | ForEach-Object { $_.name }) -join ', ') + ". Open the VM console in Hyper-V Manager (docs/TROUBLESHOOTING.md).")
    exit 1
}
Write-Host 'All nodes reachable. Next, in WSL:  make ping' -ForegroundColor Green
