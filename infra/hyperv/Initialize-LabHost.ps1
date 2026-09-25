#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time Windows host preparation for the k3s lab. Run in an elevated PowerShell.

.DESCRIPTION
    1. Adds you to "Hyper-V Administrators", so VM scripts (and the failure demos
       started from WSL) can manage VMs without an elevated shell.
    2. Creates the internal virtual switch "k3s-lab" and gives the host
       192.168.50.1 on it. That address is the lab's default gateway.
    3. Creates a WinNAT rule: VMs on 192.168.50.0/24 reach the internet through
       whatever uplink the laptop has (Wi-Fi today), while their own addresses
       never change.
    4. Creates the lab folder (VM disks, seed ISOs) writable by you.
    5. Enables WSL mirrored networking so WSL can reach 192.168.50.0/24.

    Idempotent: each step checks the current state and only changes what differs.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Initialize-LabHost.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$lab = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..\lab.json') | ConvertFrom-Json
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$hostAlias = "vEthernet ($($lab.switchName))"

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok([string]$msg)   { Write-Host "    $msg" -ForegroundColor Green }

# 1. Hyper-V Administrators (well-known SID, works on any Windows display language)
Step 'Hyper-V Administrators membership'
$hvAdmins = 'S-1-5-32-578'
$isMember = $me.Groups | Where-Object { $_.Value -eq $hvAdmins }
if ($isMember) {
    Ok "$($me.Name) is already a member"
} else {
    try {
        Add-LocalGroupMember -SID $hvAdmins -Member $me.Name
        Ok "added $($me.Name) - SIGN OUT AND BACK IN for it to take effect"
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        Ok "$($me.Name) already added (sign out and back in if VM commands are denied)"
    }
}

# 2. Internal switch + host gateway address
Step "Virtual switch '$($lab.switchName)'"
if (-not (Get-VMSwitch -Name $lab.switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $lab.switchName -SwitchType Internal -Notes 'k3s lab network (epiconnect-k8s)' | Out-Null
    Ok 'created (Internal: VMs + host only, no direct bridge to the physical network)'
} else {
    Ok 'exists'
}

Step "Host gateway $($lab.gateway)/$($lab.prefixLength) on '$hostAlias'"
$existing = Get-NetIPAddress -InterfaceAlias $hostAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
if ($existing | Where-Object { $_.IPAddress -eq $lab.gateway }) {
    Ok 'already configured'
} else {
    # Drop the automatic 169.254.x.x address Windows assigns to a fresh adapter
    $existing | Where-Object { $_.IPAddress -like '169.254.*' } | Remove-NetIPAddress -Confirm:$false
    New-NetIPAddress -InterfaceAlias $hostAlias -IPAddress $lab.gateway -PrefixLength $lab.prefixLength | Out-Null
    Ok 'configured'
}

# 3. NAT for outbound internet access
Step "NAT '$($lab.natName)' for $($lab.subnet)"
$nat = Get-NetNat -ErrorAction SilentlyContinue
if ($nat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $lab.subnet }) {
    Ok 'exists'
} else {
    New-NetNat -Name $lab.natName -InternalIPInterfaceAddressPrefix $lab.subnet | Out-Null
    Ok 'created'
}

# 4. Lab folder
Step "Lab folder $($lab.labRoot)"
foreach ($d in 'base', 'seed', 'disks', 'vms') {
    New-Item -ItemType Directory -Force -Path (Join-Path $lab.labRoot $d) | Out-Null
}
# Grant the (non-elevated) user Modify so WSL and later scripts can write here
& icacls $lab.labRoot /grant "$($me.User.Value.Insert(0,'*')):(OI)(CI)M" /T /Q | Out-Null
Ok 'ready'

# 5. WSL mirrored networking
Step 'WSL networking mode'
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
if (-not (Test-Path $wslConfig)) {
    @(
        '[wsl2]',
        '# Mirrored networking: WSL uses the same interfaces and routes as Windows,',
        '# so the Ansible control machine can reach the lab VMs on 192.168.50.0/24.',
        'networkingMode=mirrored'
    ) | Set-Content -Path $wslConfig -Encoding ASCII
    Ok "wrote $wslConfig - run 'wsl --shutdown' before opening WSL again"
} elseif (Select-String -Path $wslConfig -Pattern '^\s*networkingMode\s*=\s*mirrored' -Quiet) {
    Ok 'mirrored mode already set'
} else {
    Write-Warning "$wslConfig exists without networkingMode=mirrored. Add it under [wsl2] yourself, then run 'wsl --shutdown'."
}

Write-Host ''
Write-Host 'Host ready. Next, in WSL:  make image   then   make vms' -ForegroundColor Green
