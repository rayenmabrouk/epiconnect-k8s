# Decision log

Every component in this repository is here for a reason that can be stated in one
sentence, and each decision names the failure mode it prevents. Entries are added
as milestones land; nothing is listed before it is implemented.

Format: **Decision** / Why / Rejected alternatives / Failure mode it addresses / Cost.

---

## D1. Hyper-V as the hypervisor

- **Decision:** run the three lab VMs on Hyper-V (Windows 11 Pro), created by PowerShell scripts.
- **Why:** Hyper-V was already enabled on the laptop (WSL2 and Memory Integrity need it), so it is the only hypervisor with direct access to the CPU's virtualization extensions (AMD-V). It coexists with WSL2 by design.
- **Rejected:**
  - *VirtualBox 7.2*: its log showed `HM: HMR3Init: Attempting fall back to NEM: AMD-V is not available`. With Hyper-V active, VirtualBox has to run on top of it through the Windows Hypervisor Platform API: slower, with more timer and networking quirks. Disabling Hyper-V to fix that would break WSL2, the Ansible control machine.
  - *VMware Workstation*: same situation as VirtualBox (it also runs on top of Hyper-V here).
  - *Multipass*: convenient, but on Hyper-V it uses the "Default Switch", whose DHCP addresses change after a host reboot. k3s agents join the server by IP, so the cluster would break on every reboot.
- **Failure mode addressed:** an unstable or slow virtualization layer that causes cluster problems unrelated to Kubernetes.
- **Cost:** Windows-only lab scripts (PowerShell). Linux users would swap `infra/hyperv/` for libvirt/KVM; everything from Ansible upwards is unchanged.

## D2. Dedicated internal switch, static IPs, WinNAT

- **Decision:** an *Internal* Hyper-V switch `k3s-lab`; the host is `192.168.50.1` (gateway); nodes are `.10/.11/.12`, fixed; WinNAT gives outbound internet access.
- **Why:** Kubernetes node identity is tied to its IP (the agent join URL, node IP, certificates). Fixed addresses are how on-prem server networks are normally run.
- **Rejected:** Default Switch (IPs change on reboot); External switch bridged to Wi-Fi (Wi-Fi bridging is unreliable in Hyper-V and would put the lab on the home LAN).
- **Failure mode addressed:** a node IP that changes after a reboot, which breaks agent registration and the kubeconfig endpoint.
- **Address plan:** `192.168.50.0/24` does not overlap the VirtualBox (192.168.56/24), VMware (192.168.182/24, 192.168.230/24) or home LAN (192.168.0/24) networks on this laptop, nor k3s's pod (10.42/16) and service (10.43/16) ranges.

## D3. Ubuntu cloud image + minimal cloud-init; Ansible owns configuration

- **Decision:** VMs boot from Canonical's Ubuntu 24.04 cloud image. cloud-init only sets the static IP and creates the `ansible` account with an SSH key. Everything else is done by Ansible.
- **Why:** cloud-init runs once per instance; Ansible can be re-run at any time and reports what it changed (idempotency). Keeping the bootstrap minimal means configuration lives in one reviewable place.
- **Rejected:** manual Ubuntu ISO installs (not reproducible); doing everything in cloud-init (no drift detection, no re-run, harder to test).
- **Failure mode addressed:** configuration drift and "snowflake" servers that nobody can rebuild.
- **Supply chain:** the image is only used if `SHA256SUMS` has a valid Canonical GPG signature and the image matches its checksum.

## D4. WSL2 as the Ansible control machine, in mirrored networking mode

- **Decision:** Ansible, kubectl and helm run in WSL2 Ubuntu 24.04. WSL uses `networkingMode=mirrored`.
- **Why:** Ansible does not support Windows as a control node. Mirrored mode makes WSL share Windows' interfaces and routes, so WSL reaches `192.168.50.0/24` exactly like Windows does, with no extra routing rules.
- **Rejected:** default NAT mode plus IP forwarding between the two Hyper-V vEthernet adapters (works, but must be reapplied whenever WSL restarts and depends on WinNAT behaviour); a separate Linux VM as control node (more RAM, one more machine to maintain).
- **Failure mode addressed:** a control machine that cannot reach the nodes.

## D5. Dedicated SSH key, no passwords over SSH, break-glass console password

- **Decision:** a lab-only ed25519 key; SSH password login is disabled from the first boot; a random console password (Hyper-V console only) is generated locally and never committed.
- **Why:** key-based authentication cannot be brute-forced like a password. The console password guarantees a way in if SSH or networking is broken, the same role as an out-of-band management port in a datacentre.
- **Failure mode addressed:** being locked out of a VM with broken networking; credential exposure in Git.
- **Trade-off:** the `ansible` account has passwordless sudo, as automation accounts usually do. It is reachable only with the lab key; that is the least-privilege boundary.

## D6. Own Ansible roles for k3s, not the `curl | sh` installer or k3s-ansible

- **Decision:** roles `k3s_install` (pinned binary verified against the release checksum file, systemd unit), `k3s_server`, `k3s_agent` (config file, start, verify Ready).
- **Why:** each step is visible and explainable; the configuration is a reviewed file (`/etc/rancher/k3s/config.yaml`), not flags inside a script; upgrades are a one-line version change.
- **Rejected:** `curl -sfL https://get.k3s.io | sh -` (runs an unpinned remote script as root, not idempotent); the community `k3s-ansible` playbook (fine in production, but hides exactly what this project is meant to show I understand).
- **Failure mode addressed:** unverified binaries, unreviewable configuration, "it worked when I ran the script" drift.

## D7. Secrets in Ansible Vault; vault password outside the repository

- **Decision:** join token and admin password hash in an encrypted, committed `vault.yml`; the random vault password in `~/.config/epiconnect-k8s/vault-pass`.
- **Rejected:** HashiCorp Vault (a whole service to run for two values; out of scope by design); plaintext in group_vars; environment variables typed by hand.
- **Failure mode addressed:** credentials leaked through Git.

## D8. Two accounts: automation vs human

- **Decision:** `ansible` (key, passwordless sudo) and `rayen` (key, sudo with password); SSH limited to the `ssh-users` group.
- **Failure mode addressed:** a stolen human key giving root directly; shared accounts with no attribution.

## D9. Host firewall on every node, rules scoped to the lab subnet

- **Decision:** UFW default-deny inbound; only the ports Kubernetes needs, only from `192.168.50.0/24`; pod/service ranges allowed so cluster traffic works.
- **Failure mode addressed:** kubelet/API/NFS reachable from anywhere that can route to a node.
- **Note:** the host firewall protects *nodes*. Traffic *between pods* is controlled by Kubernetes NetworkPolicy (Milestone 3): a different layer, and both are needed.

## D10. One control-plane node with SQLite (not HA)

- **Decision:** a single `k3s server` with its default embedded SQLite datastore.
- **Why:** three VMs on a laptop; the goal is to demonstrate scheduling, rescheduling and storage across nodes, which one server plus two workers already shows.
- **Rejected:** three servers with embedded etcd (HA control plane; it would leave no dedicated workers and triple the control-plane memory).
- **Failure mode accepted and documented:** losing `k3s-server` stops scheduling and the API (running pods keep serving). Production answer: 3 (odd number, for etcd quorum) control-plane nodes.

## D11. NFS for uploaded files (RWX); local disk for PostgreSQL (RWO)

- **Decision:** `k3s-server` exports one NFS share for uploads; PostgreSQL uses a local-path volume on the same node.
- **Why:** the 3 app replicas run on 2 workers and must see the same uploaded files; a node-local volume cannot be mounted on two nodes. Databases need local-disk semantics (fsync, locking) that NFS does not guarantee.
- **Rejected:** Longhorn/Ceph (distributed block storage: correct in production, far too heavy for a 3-VM lab); MinIO/S3-style object storage (would require changing the application's storage configuration and adds a service to operate).
- **Failure mode accepted and documented:** `k3s-server` is a single point of failure for both shares.

## D12. Image built in CI from the pinned submodule, tagged with the application commit

- **Decision:** GitHub Actions builds `app/` and pushes `ghcr.io/rayenmabrouk/epiconnect:<EPIConnect commit>`; manifests reference that exact tag.
- **Rejected:** `:latest` (which version runs is unknowable, rollbacks are ambiguous); building on the nodes (no provenance, not reproducible); a registry inside the cluster (one more service to run).
- **Failure mode addressed:** unknown or drifting application versions.

## D13. Pod Security "restricted" enforced on the namespace

- **Decision:** the namespace label makes the API server reject non-compliant pods; every workload runs non-root, read-only root filesystem, no capabilities, seccomp RuntimeDefault, no service-account token.
- **Failure mode addressed:** a container compromise turning into node compromise through root or extra privileges.

## D14. Migrations as a Job per release, plus an init-container gate

- **Decision:** `epiconnect-migrate` Job before the web rollout; web pods wait in an init container until `migrate --check` passes. No Helm hooks.
- **Rejected:** migrating in the container entrypoint (replicas race each other); Helm pre-install hooks (deadlock with `--wait` on first install, since the database is part of the same release).
- **Failure mode addressed:** concurrent schema changes; pods serving on an outdated schema.

## D15. Liveness without the database, readiness with it

- **Decision:** `/healthz/` (process only) for startup and liveness; `/readyz/` (`SELECT 1`) for readiness.
- **Failure mode addressed:** a database outage restarting every web pod (restart storm) instead of simply taking them out of rotation.

## D16. NetworkPolicy default deny in both directions

- **Decision:** deny all ingress and egress, then allow DNS, Traefik → web, labelled clients → PostgreSQL.
- **Failure mode addressed:** any pod in the cluster reaching the database or making arbitrary outbound connections.
- **Accepted:** no TLS between the app and PostgreSQL (in-cluster traffic, restricted by policy); production would add `sslmode=require` or a service mesh's mTLS.

## D17. TLS with a private lab CA

- **Decision:** `scripts/gen-tls.sh` creates a CA and a certificate for `epiconnect.lab`; Traefik terminates TLS; `make trust-ca` optionally trusts the CA for the current Windows user.
- **Rejected:** plain HTTP (the app's Secure cookies and CSRF protection expect HTTPS); cert-manager with Let's Encrypt (needs a public domain and inbound reachability).
- **Production answer:** cert-manager + ACME with a real domain.

## D18. Raw manifests before Helm

- **Decision:** deploy with plain YAML first; convert to a Helm chart only once it works (Milestone 5).
- **Why:** each object is understood on its own before being templated; the duplication visible here (image tag in 4 places, repeated pod security blocks, ordering in a script) is the concrete reason for Helm.

## D19. Own Helm chart, written to adopt the running deployment

- **Decision:** `helm/epiconnect` renders the same names, selectors and StatefulSet claim templates as `kubernetes/`; `scripts/adopt-into-helm.sh` hands the live objects to the release; the first deploy uses `--force-conflicts` once (Helm 4 server-side apply).
- **Rejected:** delete and reinstall (downtime; the database volume would have to be re-bound by hand); a community PostgreSQL chart (hides the StatefulSet this project exists to show, and its images and defaults change outside my control).
- **Failure mode addressed:** "switching tools" turning into an outage or a data loss.
- **Accepted:** one release per namespace (fixed object names such as `postgres`).

## D20. Namespace and Secrets outside the chart

- **Decision:** the chart references `existingSecret`; secret values and the namespace's Pod Security label are managed separately.
- **Failure mode addressed:** secret values stored in Helm release history, values files or shell history; an application chart weakening a platform security policy.
