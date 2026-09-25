# Troubleshooting

Organised by symptom. Rule for every section: find the lowest layer that is broken
and fix that first.

## Lab host and VMs (Hyper-V)

### `make vms` says "You do not have the required permission"
You were added to *Hyper-V Administrators* but have not signed out since. Sign out of
Windows and back in (a reboot also works), then `make vms` again.

### `Convert-VHD` / VM start fails: "virtual disk system limitation... must not be sparse"
The base VHDX ended up as an NTFS sparse file. Delete
`C:\HyperV\k3s-lab\base\ubuntu-24.04-base.*` and run `make image` again (it copies with
`--sparse=never`).

### VM starts but never boots (UEFI screen, "No operating system was loaded")
Secure Boot template must be *Microsoft UEFI Certificate Authority* (the default,
"Microsoft Windows", rejects Linux's shim):
```powershell
Set-VMFirmware -VMName k3s-server -SecureBootTemplate MicrosoftUEFICertificateAuthority
```

### `New-LabVMs.ps1` times out waiting for SSH
1. Open the console: Hyper-V Manager > `k3s-server` > Connect. Log in as `ansible` with
   the password in `~/.config/epiconnect-k8s/console-password` (in WSL).
2. `cloud-init status --long`. If it says `error`, read `sudo less /var/log/cloud-init.log`.
3. `ip -br addr`: `eth0` must have `192.168.50.x`. If not, the MAC in `infra/lab.json`
   does not match the VM's adapter (`Get-VMNetworkAdapter -VMName k3s-server`).
4. `ping 192.168.50.1` from the VM: fails means the switch or host IP is missing (re-run
   `Initialize-LabHost.ps1`).

### VM has an IP but no internet
From the VM: `ping 192.168.50.1` (gateway) → `ping 1.1.1.1` (NAT) → `getent hosts ubuntu.com` (DNS).
- Gateway fails: host adapter IP missing: `Get-NetIPAddress -InterfaceAlias 'vEthernet (k3s-lab)'`.
- 1.1.1.1 fails: NAT missing: `Get-NetNat`. Re-run `Initialize-LabHost.ps1`.
- DNS fails only: check `resolvectl status`; the netplan file should list 1.1.1.1 and 8.8.8.8.

## Control machine (WSL)

### Windows can `ping 192.168.50.10` but WSL cannot
WSL is not in mirrored mode.
```bash
wslinfo --networking-mode      # must print: mirrored
```
If it prints `nat`: check `%USERPROFILE%\.wslconfig` contains `networkingMode=mirrored`
under `[wsl2]`, then run `wsl --shutdown` in PowerShell and reopen Ubuntu.

Fallback if mirrored mode is not usable: stay in NAT mode and let Windows route between
the WSL and lab adapters (elevated PowerShell; repeat after WSL restarts):
```powershell
Get-NetIPInterface | Where-Object InterfaceAlias -in 'vEthernet (WSL (Hyper-V firewall))','vEthernet (k3s-lab)' |
  Set-NetIPInterface -Forwarding Enabled
```

### `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`
Expected after recreating the VMs (new VM = new host key): `make forget-hosts`.
Unexpected otherwise: stop and find out why the key changed.

### `Permission denied (publickey)`
`ssh -v k3s-server` shows which key is offered. It must be `~/.ssh/k3s_lab_ed25519`.
If the right key is rejected, cloud-init did not apply user-data: check it from the
console (see above).
