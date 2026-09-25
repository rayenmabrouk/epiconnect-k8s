# epiconnect-k8s

**EPIConnect on a self-hosted, three-node Kubernetes (k3s) cluster, provisioned with Ansible on Ubuntu VMs, deployed with raw manifests and then Helm, at zero cost.**

The same application already runs on AWS (ECS Fargate, RDS, ALB) in the
[EPIConnect](https://github.com/rayenmabrouk/EPIConnect) repository. This repository is the
infrastructure and delivery work that runs it without any managed cloud service:
Linux hosts, configuration management, container orchestration, cluster networking and storage.

> EPIConnect is the application (included as a pinned git submodule in `app/`).
> Everything else in this repository is the infrastructure/DevOps work.

## Status

| Milestone | Content | State |
|---|---|---|
| 0 | WSL2 control machine (pinned Ansible, kubectl, helm) | in progress |
| 1 | Hyper-V network + 3 Ubuntu VMs (cloud image, cloud-init, static IPs) | in progress |
| 2 | Ansible roles: users, SSH hardening, UFW, NFS, k3s server/agents | next |
| 3 | Raw Kubernetes manifests | |
| 4 | Application verification | |
| 5 | Helm chart | |
| 6 | GitHub Actions CI + GHCR | |
| 7 | Failure demonstrations with evidence | |
| 8 | Final documentation | |

## Lab topology

```
 Windows 11 laptop (Hyper-V)
 ┌──────────────────────────────────────────────────────────────┐
 │  WSL2 Ubuntu 24.04: Ansible, kubectl, helm (control machine) │
 │        │ (mirrored networking)                               │
 │  vEthernet (k3s-lab) 192.168.50.1 ── WinNAT ── Wi-Fi ── internet
 │        │                                                     │
 │  ┌─────┴──────── Hyper-V internal switch "k3s-lab" ───────┐  │
 │  │                      │                     │           │  │
 │  k3s-server         k3s-worker1           k3s-worker2      │  │
 │  192.168.50.10      192.168.50.11         192.168.50.12    │  │
 │  2 vCPU / 4 GB      2 vCPU / 3 GB         2 vCPU / 3 GB    │  │
 └──────────────────────────────────────────────────────────────┘
```

## Build the lab (Milestones 0-1)

Prerequisites: Windows 11 Pro with Hyper-V enabled, ~12 GB free RAM, ~100 GB disk.

1. **WSL Ubuntu** (PowerShell): `wsl --install -d Ubuntu-24.04`
2. **Get the repository** (in Ubuntu), then install the tooling:
   ```bash
   git clone https://github.com/rayenmabrouk/epiconnect-k8s.git ~/epiconnect-k8s
   cd ~/epiconnect-k8s && git submodule update --init
   ./scripts/bootstrap-wsl.sh && source ~/.bashrc
   ```
3. **Prepare the Windows host** (Ubuntu; opens an elevated PowerShell, accept the UAC prompt):
   ```bash
   make host-init
   ```
   Then **sign out of Windows and back in** (Hyper-V group membership and WSL mirrored networking take effect).
4. **Create the VMs** (Ubuntu):
   ```bash
   make image        # verify + convert the Ubuntu cloud image, build seed ISOs
   make vms          # create/start 3 VMs, wait for SSH
   make ping         # hostname, IP, cloud-init status of every node
   make checkpoint   # "fresh" checkpoint: roll back here any time with make restore
   ```

`make help` lists every operation.

## Documentation

- [Decision log](docs/DECISIONS.md): every component, why it exists, what failure it addresses
- [Study notes: lab infrastructure](docs/learning/01-lab-infrastructure.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
