# epiconnect-k8s

[![CI](https://github.com/rayenmabrouk/epiconnect-k8s/actions/workflows/ci.yml/badge.svg)](https://github.com/rayenmabrouk/epiconnect-k8s/actions/workflows/ci.yml)

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
| 5 | Helm chart | done ([12/12 checks under Helm](evidence/04-app-verification/report.md)) |
| 6 | GitHub Actions CI + GHCR | done ([runs](https://github.com/rayenmabrouk/epiconnect-k8s/actions/workflows/ci.yml)) |
| 7 | Failure demonstrations with evidence | done ([results](#failure-demonstrations)) |
| 8 | Final documentation | done |

## What was built

- **Three Ubuntu 24.04 VMs on Hyper-V** (1 control-plane, 2 workers) on an isolated network with fixed IPs, created from scripts and cloud-init.
- **Ansible** (9 roles, Vault for secrets) that turns blank VMs into a hardened k3s cluster, and a proof that running it twice changes nothing.
- **EPIConnect on Kubernetes**: 3 web replicas, PostgreSQL as a StatefulSet, uploads on NFS shared by all replicas, TLS, default-deny NetworkPolicy, Pod Security *restricted*, probes, migrations as Jobs.
- **A Helm chart** that adopted the running raw-manifest deployment in place, without downtime.
- **GitHub Actions CI** that lints, validates, scans, smoke-tests on k3d and publishes an immutable image to GHCR. It does not deploy (see below).
- **Five failure demonstrations**, each with its raw evidence committed.

## Architecture

```
                         https://epiconnect.lab (lab CA, TLS terminated at Traefik)
                                         │
                      ┌──────────────────▼───────────────────┐
                      │ Traefik (Ingress) + ServiceLB (k3s)  │
                      └──────────────────┬───────────────────┘
                                         │ Service "epiconnect" (only Ready pods)
          ┌──────────────────────────────┼──────────────────────────────┐
          │ k3s-worker1  (pool=app)      │             k3s-worker2  (pool=app)
          │  web pod ─┐                  │                  web pod ─┐
          │  web pod ─┤  Deployment, 3 replicas, maxSurge 1 / maxUnavailable 0
          │           │                  │                           │
          └───────────┼──────────────────┴───────────────────────────┼──────┘
                      │ uploads (NFS, ReadWriteMany)                 │
                      ▼                                              ▼
          ┌───────────────────────────────────────────────────────────────┐
          │ k3s-server (pool=data, control plane)                         │
          │  NFS export (uploads)          PostgreSQL StatefulSet (RWO,   │
          │                                local-path volume), 1 replica  │
          │  API server + SQLite datastore, scheduler, controllers        │
          └───────────────────────────────────────────────────────────────┘
   NetworkPolicy: deny all; allow DNS; Traefik -> web; labelled web/Job pods -> PostgreSQL only.
   Image: CI -> ghcr.io/rayenmabrouk/epiconnect:<EPIConnect commit>; deploy: make deploy-helm.
```

## Why this design

| Choice | Reason (details and rejected alternatives in the [decision log](docs/DECISIONS.md)) |
|---|---|
| k3s, 1 server + 2 workers | Real multi-node scheduling and failure behaviour on a laptop; a single control plane is a documented, accepted single point of failure (D10) |
| Ansible for the nodes | Reviewable, re-runnable configuration; idempotency is demonstrable (D3, D6) |
| NFS for uploads, local disk for PostgreSQL | Replicas on different nodes must share files (RWX); a database needs real local-disk semantics (D11) |
| Raw manifests, then Helm | Each object understood before being templated; Helm removes the concrete duplication seen in the manifests (D18, D19) |
| Liveness without the database, readiness with it | A database outage removes pods from rotation instead of restarting all of them (D15) |
| CI stops at the registry | The cluster is private; giving GitHub a path into it would make GitHub part of its attack surface (D23) |

## Failure demonstrations

All demos run against the live lab with a client sending one HTTPS request every 0.2 s through Traefik. Scripts in [`demos/`](demos), raw logs in [`evidence/`](evidence). Numbers below are copied from the committed summaries.

| # | Demonstration | Result | Evidence |
|---|---|---|---|
| 1 | **Rolling update** A to B (`0b3cd06` to `b38f31a`) via `helm upgrade` | 227 requests, 227 HTTP 200, 0 failed; upgrade incl. migration Job 27 s. Two passing runs; one earlier run was a false FAIL in my script (it stopped measuring before old pods finished terminating), fixed | [summary](evidence/01-rolling-update/summary.md) |
| 2A | **Failed readiness**: PostgreSQL stopped for 30 s | All 3 web pods left the Service (0 Ready) and Traefik answered 503 at once; web container restarts 3 before and 3 after (liveness does not depend on the database); pods rejoined about 40 s after PostgreSQL returned, with no manual action. Honest cost: 43 HTTP 500 in the ~8 s before readiness failed (5 s probe period, 2 failures) | [summary](evidence/02-readiness-and-rollback/summary.md) |
| 2B | **Bad release** (`DB_HOST` typo), then `helm rollback` | New pod stuck in its init container, the 3 old pods kept serving (maxUnavailable 0); upgrade failed after its 2 min timeout; rollback restored the previous configuration. 579 requests, 0 failed | same |
| 3 | **Worker failure**: `k3s-worker2` (2 of 3 web pods) powered off hard | Node NotReady after 46 s; 3 Ready web pods on the surviving worker 81 s after the power cut, no intervention. 14 requests got no answer (3 s timeouts) while the dead pods were still in the Service; my client is sequential, so that window (about 44 s) was mostly degraded, not 14 isolated errors. Pods did not move back after the node returned | [summary](evidence/03-worker-failure/summary.md) |
| 4 | **Database persistence**: `postgres-0` deleted | New pod (new UID) claimed the same volume; the row written before was read back. Ready after 8 s. Web requests failed during the restart (single database instance) | [summary](evidence/04-database-persistence/summary.md) |
| 5 | **Ansible idempotency** from fresh VMs | Run 1: 32/26/26 changes (254 s); run 2: **0 changes** on all nodes (53 s) | [summary](evidence/05-ansible-idempotency/summary.md) |

Re-run: `demos/0N-*.sh` (each needs the lab up and `make verify` green).

## Limitations (stated, not hidden)

- **One control-plane node with SQLite.** If `k3s-server` is lost, the API and scheduling stop; running pods keep serving. It also hosts the database volume and the NFS export. Production: 3 control-plane nodes, replicated storage.
- **One PostgreSQL instance.** Demos 2 and 4 show the cost: requests fail while it restarts. High availability needs a replicated database (operator or managed service).
- **Volume reclaim policy is `Delete`** (local-path default): deleting the PVC deletes the data; deleting the pod does not.
- **Failover is not instant**: about 46 s to declare a node dead plus the 30 s toleration and the pod start. These are tunable, with the usual trade-off against false positives.
- **No deployment from CI**, no GitOps agent, no monitoring stack (Prometheus/Grafana were an optional extra and are not built).
- **k3s gap:** a new pod's own egress policy is not enforced for its first moments ([k3s #14711](https://github.com/k3s-io/k3s/issues/14711)); the database is protected by its ingress policy regardless.

## Kubernetes compared with the AWS deployment

The AWS version of the same application (ECS Fargate, RDS, ALB) is in the EPIConnect repository. This is a conceptual mapping, not a cost or performance claim: the two were not benchmarked against each other.

| Concern | AWS (EPIConnect repo) | This repository |
|---|---|---|
| Run containers | ECS service on Fargate (no nodes to manage) | Deployment on k3s nodes I install, patch and replace myself |
| Desired state / self-healing | ECS service scheduler | Deployment/ReplicaSet controllers (demo 3) |
| Load balancer + health | ALB, target-group health checks | Traefik Ingress, Service endpoints driven by readiness probes (demo 2) |
| Rolling deploy / rollback | ECS rolling deployment, circuit breaker | RollingUpdate with maxSurge/maxUnavailable, `helm rollback` (demos 1, 2B) |
| Database | RDS: backups, Multi-AZ, patching included | PostgreSQL StatefulSet: I own backups, failover and upgrades (demo 4 covers only pod loss) |
| Shared files | EFS or S3 | NFS export mounted ReadWriteMany |
| Network isolation | Security groups | NetworkPolicy (pod level) plus UFW (node level) |
| Secrets | Secrets Manager | Kubernetes Secret (base64, not encrypted at rest by default here), Ansible Vault for node secrets |
| Images | ECR | GHCR |
| Infrastructure as code | Terraform/CloudFormation | Ansible (hosts), Helm (workloads) |

What Kubernetes buys: portability, one API for every workload, scheduling control, no per-service fees. What it costs: the control plane and node lifecycle become my job, and every managed feature in the left column (database HA, backups, certificate renewal, node auto-replacement) must be built or accepted as missing.

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

The image is built by GitHub Actions (`.github/workflows/ci.yml`, see below) from the pinned `app/`
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

## Continuous integration (Milestone 6)

`.github/workflows/ci.yml` runs on every push and pull request:

```
 lint ─────────────────────────────────────────────┐
 manifests (helm lint, kubeconform) ──┐            ├─> publish to GHCR (main only,
 image (build, Trivy gate) ───────────┴─> smoke ───┘   existing tags never overwritten)
                                          (k3d)
```

| CI does | CI does not |
|---|---|
| lint YAML, Ansible (production profile), shell, PowerShell, the workflow itself (zizmor), git history (gitleaks) | run Ansible against the VMs |
| validate the raw manifests and the rendered chart against the Kubernetes 1.36 schemas; `helm lint` | talk to the lab cluster: it is on a laptop behind NAT, and giving GitHub credentials to it would widen its attack surface |
| build the image and fail on fixable HIGH/CRITICAL vulnerabilities (Trivy) | deploy: that is `make deploy-helm` on the control machine, with the tag CI published |
| install the chart **and the image just built** on a throwaway k3d cluster (k3s 1.36, Pod Security restricted, NetworkPolicy) and test: HTTPS through Traefik, DB isolation, upgrade, rollback | test NFS/ReadWriteMany or node failures (single node, no NFS server): those are the lab demos |
| push that exact image to GHCR, tagged with the EPIConnect commit | have the vault password: Ansible is linted against the example vault |

Every tool CI downloads is pinned to a version **and a SHA-256 committed in this repository**
(`scripts/install-tools.sh`); every action is pinned to a commit SHA. The same scripts run locally:

```bash
make lint           # also run by CI
make validate       # manifests + chart against the schemas, helm lint (no cluster needed)
make smoke          # the CI smoke test on a local k3d cluster (needs Docker + k3d)
```

`make help` lists every operation.

## Documentation

- [Decision log](docs/DECISIONS.md): every component, why it exists, what failure it addresses
- [Troubleshooting](docs/TROUBLESHOOTING.md)
