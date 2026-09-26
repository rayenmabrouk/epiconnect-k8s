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
| 0 | WSL2 control machine (pinned Ansible, kubectl, helm) | done |
| 1 | Hyper-V network + 3 Ubuntu VMs (cloud image, cloud-init, static IPs) | done |
| 2 | Ansible roles: users, SSH hardening, UFW, NFS, k3s server/agents | done ([evidence](evidence/05-ansible-idempotency/summary.md)) |
| 3 | Raw Kubernetes manifests | done |
| 4 | Application verification | done ([12/12 checks](evidence/04-app-verification/report.md)) |
| 5 | Helm chart | in progress |
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

## Configure the nodes and build the cluster (Milestone 2)

```bash
make vault-init     # once: encrypted vault with the k3s join token + your admin password hash
make provision      # base OS, users, SSH hardening, firewall, NFS, k3s server + agents
make nodes          # 3 nodes Ready
demos/05-ansible-idempotency.sh --fresh   # evidence: rebuild from clean VMs, 2nd run changed=0
```

## Deploy EPIConnect with raw manifests (Milestones 3-4)

The image is built by GitHub Actions (`.github/workflows/image.yml`) from the pinned `app/`
submodule and published to `ghcr.io/rayenmabrouk/epiconnect:<EPIConnect commit>`.

```bash
make host-init        # once more: adds "192.168.50.10 epiconnect.lab" to the Windows hosts file
make secrets          # application Secret (random, created once)
make tls              # lab CA + certificate for epiconnect.lab
make deploy-manifests # everything in kubernetes/, in dependency order
make verify           # 12 end-to-end checks -> evidence/04-app-verification/report.md
```

Then open https://epiconnect.lab (admin password in `~/.config/epiconnect-k8s/admin-password`).

## Move to Helm (Milestone 5)

The chart in `helm/epiconnect` renders the same objects from one `values.yaml`. The first
Helm deployment **adopts** the running raw-manifest deployment in place: no downtime, the
database and uploads stay where they are.

```bash
make helm-check     # helm lint + server-side validation of the rendered chart
make helm-diff      # what the chart would change on the live cluster
make deploy-helm    # adopt (first time) + helm upgrade --install --wait --wait-for-jobs
make verify         # the same 12 checks, now against the Helm release
make helm-history
```

`make help` lists every operation.

## Documentation

- [Decision log](docs/DECISIONS.md): every component, why it exists, what failure it addresses
- [Study notes: lab infrastructure](docs/learning/01-lab-infrastructure.md)
- [Study notes: Ansible and k3s](docs/learning/02-ansible-and-k3s.md)
- [Study notes: Kubernetes manifests and verification](docs/learning/03-kubernetes-manifests.md)
- [Study notes: Helm](docs/learning/04-helm.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
