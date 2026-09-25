# Milestones 0-1: the lab infrastructure

What was built: a WSL2 control machine and three Ubuntu 24.04 VMs on Hyper-V with
fixed addresses on a private network, reachable over SSH with a dedicated key.

Every topic follows the same nine points: what, why, problem solved, how it works
internally, commands, what can go wrong, troubleshooting, interview question, answer.

---

## 1. Hyper-V (virtualization layer)

1. **What:** Microsoft's type-1 hypervisor, running the three lab VMs.
2. **Why:** it already owned the CPU's virtualization extensions on this laptop, and WSL2 runs on it.
3. **Problem solved:** fast, stable VMs without disabling WSL2.
4. **How it works:** when Hyper-V is enabled, the hypervisor boots first and Windows itself becomes the "root partition". Each VM is a "child partition". Linux guests use *synthetic* devices (`hv_netvsc` for network, `hv_storvsc` for disk) that talk to the host over **VMBus**, a shared-memory channel, instead of emulating real hardware. That is why they are fast. VirtualBox, when Hyper-V is on, cannot use AMD-V directly and falls back to the Windows Hypervisor Platform API ("NEM" in its log): every VM exit makes an extra trip through user mode.
5. **Commands:** `Get-VM`, `Get-VMSwitch`, `Get-VMNetworkAdapter -VMName k3s-server`, `vmconnect localhost k3s-server` (console), `make status`.
6. **What can go wrong:** "access denied" right after joining *Hyper-V Administrators* (group membership only applies after signing out); Secure Boot template wrong (UEFI boot fails, shim rejected); a VHDX stored as an NTFS *sparse* file cannot be attached.
7. **Troubleshoot:** Hyper-V Manager > VM > Connect to watch the boot; `Get-VM | Select Name,State,Status`; Event Viewer > Applications and Services Logs > Microsoft > Windows > Hyper-V-VMMS.
8. **Interview:** "Type 1 vs type 2 hypervisor? Why Hyper-V and not VirtualBox here?"
9. **Answer:** "A type-1 hypervisor runs directly on the hardware and the host OS becomes a privileged guest. A type-2 runs as an application on a host OS. Here Hyper-V was already active for WSL2, which means VirtualBox could only run on top of it through an API, and its own log confirmed that fallback. So Hyper-V was the only option with native performance that kept WSL2 working."

## 2. Virtual switch, static addressing, NAT

1. **What:** an *Internal* virtual switch `k3s-lab`; the host has `192.168.50.1`; nodes `.10`, `.11`, `.12`; WinNAT for internet access.
2. **Why:** Kubernetes nodes need stable identities. The join URL, node IP and certificates all carry the IP.
3. **Problem solved:** Hyper-V's Default Switch hands out DHCP leases that change after a reboot, which would silently break the cluster.
4. **How it works:** the switch is a virtual layer-2 Ethernet switch; VMs and one host adapter (`vEthernet (k3s-lab)`) plug into it. VM traffic to other subnets goes to the default gateway 192.168.50.1 (the host). WinNAT rewrites the *source* address of outbound packets from 192.168.50.x to the laptop's Wi-Fi address and keeps a translation table so replies find their way back. Nothing outside the laptop can open a connection into the lab: NAT gives outbound access only.
5. **Commands:**
   - Windows: `Get-VMSwitch k3s-lab`, `Get-NetIPAddress -InterfaceAlias 'vEthernet (k3s-lab)'`, `Get-NetNat`, `ping 192.168.50.10`
   - Linux: `ip -br addr`, `ip route`, `resolvectl status`, `ping -c1 1.1.1.1`, `getent hosts ubuntu.com`, `tracepath 1.1.1.1`
6. **What can go wrong:** an overlapping NAT prefix (Windows refuses to create it); VM has an IP but no internet (NAT missing); can ping 1.1.1.1 but not resolve names (DNS); NIC attached to the wrong switch.
7. **Troubleshoot bottom-up:** link (`ip link`: is eth0 UP?) → address (`ip addr`: 192.168.50.x?) → gateway (`ping 192.168.50.1`) → routing/NAT (`ping 1.1.1.1`) → DNS (`getent hosts ubuntu.com`). The first step that fails is the layer to fix.
8. **Interview:** "Why static IPs for cluster nodes? How does your lab reach the internet?"
9. **Answer:** "Node identity in Kubernetes is tied to the IP: the agent joins the server's URL and certificates include node addresses, so changing IPs break the cluster. I used a private internal switch with a fixed address plan, the host as gateway, and source NAT on the host for outbound traffic, the same pattern as a private server network behind a NAT gateway."

## 3. Cloud image + cloud-init (first boot)

1. **What:** Canonical's generic Ubuntu 24.04 cloud image, converted to VHDX, plus a per-node "seed" ISO read by cloud-init at first boot.
2. **Why:** a reproducible, pre-installed OS in seconds instead of three manual installs.
3. **Problem solved:** cloud images ship with no users and no network configuration; cloud-init supplies them for each machine.
4. **How it works:** at boot, cloud-init looks for a *datasource*. The **NoCloud** datasource is a disk labelled `cidata` holding three files: `meta-data` (instance-id, hostname), `user-data` (users, keys), `network-config` (netplan v2). cloud-init runs in stages (local: network config before the network comes up; then config and final). It remembers the `instance-id`, so "once per instance" steps do not repeat on reboot. The NIC is matched by its MAC address (set statically in Hyper-V), so the IP plan does not depend on interface naming.
5. **Commands:** `cloud-init status --long`, `sudo cat /var/log/cloud-init-output.log`, `sudo cloud-init schema --system`, `cat /etc/netplan/50-cloud-init.yaml`; image verification in `prepare-image.sh` (`gpgv`, `sha256sum --check`).
6. **What can go wrong:** YAML error in user-data (cloud-init ignores it: no user, no key); MAC mismatch (no static IP); `status: error`.
7. **Troubleshoot:** log in on the Hyper-V console with the break-glass password (`~/.config/epiconnect-k8s/console-password`, user `ansible`), then `cloud-init status --long` and `/var/log/cloud-init.log`.
8. **Interview:** "What does cloud-init do, and why not configure everything with it?"
9. **Answer:** "cloud-init is the first-boot agent of cloud images: it reads a datasource and applies users, keys and network configuration. I kept it to the minimum Ansible needs to connect, because cloud-init runs once, while Ansible can be re-run to detect and correct drift, and it tells me what changed. Bootstrap and configuration management are separate concerns."

## 4. WSL2 control machine, mirrored networking, SSH keys

1. **What:** Ubuntu 24.04 in WSL2 running Ansible, kubectl and helm; a dedicated ed25519 key; SSH aliases (`ssh k3s-server`).
2. **Why:** Ansible's control node must be Linux/Unix.
3. **Problem solved:** one Linux workstation that reaches every node, with pinned tool versions.
4. **How it works:** WSL2 is a lightweight VM on the same hypervisor. In the default NAT mode it sits behind its own private subnet; in **mirrored** mode it shares Windows' network interfaces and routing table, so any address Windows can reach (including 192.168.50.x) is reachable from WSL. SSH public-key authentication: the node stores the *public* key in `~/.ssh/authorized_keys`; during login the client signs a challenge with the *private* key and the server checks the signature. The private key never crosses the network. The node also proves *its* identity with a host key; `StrictHostKeyChecking accept-new` trusts it on first connection and refuses it if it later changes (possible man-in-the-middle, or the VM was rebuilt: `make forget-hosts`).
5. **Commands:** `wslinfo --networking-mode`, `ip route`, `ssh -v k3s-server`, `ssh-keygen -lf ~/.ssh/k3s_lab_ed25519.pub`, `make ping`.
6. **What can go wrong:** WSL still in NAT mode (`.wslconfig` not applied: `wsl --shutdown`); "REMOTE HOST IDENTIFICATION HAS CHANGED" after recreating VMs; "Permission denied (publickey)" (wrong key, or cloud-init did not apply user-data).
7. **Troubleshoot:** check from Windows first (`ping 192.168.50.10`). If Windows works and WSL does not, it is a WSL networking problem, not the lab. Then `ssh -v` shows which key is offered and why it is rejected.
8. **Interview:** "What happens when SSH connects?"
9. **Answer:** "TCP to port 22, then a protocol and algorithm negotiation and a Diffie-Hellman key exchange that creates the session keys. The server proves its identity with its host key, which the client checks against known_hosts. Then the user authenticates: with keys, the client signs data with its private key and the server verifies it with the public key in authorized_keys. After that, everything, including the commands Ansible sends, runs inside the encrypted channel."

---

## Study checkpoint (Milestones 0-1)

Be able to do these without notes:

- [ ] Draw the lab: laptop, `k3s-lab` switch, 192.168.50.1 gateway, three nodes, NAT to Wi-Fi, WSL.
- [ ] Explain why the IPs are static and what would break with DHCP.
- [ ] Explain type-1 vs type-2 hypervisors and why VirtualBox fell back to NEM.
- [ ] Walk through what cloud-init did on first boot, and where its logs are.
- [ ] Explain the SSH login sequence, host keys vs user keys, and what `accept-new` does.
- [ ] Troubleshoot "a VM has no internet" bottom-up (link, IP, gateway, NAT, DNS).

Run these yourself and read the output:

```bash
make status
make ping
ssh k3s-server 'ip -br addr; ip route; resolvectl status | head -20'
ssh k3s-worker1 'cloud-init status --long; sudo head -30 /var/log/cloud-init-output.log'
ssh k3s-server 'cat /etc/netplan/50-cloud-init.yaml'
ssh -v k3s-worker2 true 2>&1 | grep -E "Authenticating|Offering|Server accepts|Authenticated"
```

```powershell
Get-VMSwitch k3s-lab; Get-NetNat; Get-VMNetworkAdapter -VMName k3s-server | Select Name,SwitchName,MacAddress,IPAddresses
```
