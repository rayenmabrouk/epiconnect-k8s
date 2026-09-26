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

## Ansible

### `UNREACHABLE! ... Permission denied (publickey)`
The inventory uses user `ansible` and key `~/.ssh/k3s_lab_ed25519`. Test the same thing
by hand: `ssh -i ~/.ssh/k3s_lab_ed25519 ansible@192.168.50.10`. If that works, run the
playbook with `-vvv` to see the exact SSH command.

### `Attempting to decrypt but no vault secrets found`
`~/.config/epiconnect-k8s/vault-pass` is missing. Restore it from your backup. If it is
lost, delete `ansible/inventory/group_vars/all/vault.yml` and run `make vault-init`, then
`make provision` (the agents restart with the new token).

### A task reports `changed` on every run
It is not idempotent. Find it in the second run:
`grep -B2 '^changed:' evidence/05-ansible-idempotency/run-2.log`.

### Locked out of SSH after a hardening change
Log in on the Hyper-V console as `ansible` with the break-glass password
(`~/.config/epiconnect-k8s/console-password` in WSL), then `sudo sshd -t` and
`sudo journalctl -u ssh -n 50`. Or roll back everything: `make restore`.

## k3s

### A worker never becomes Ready / "Wait for this node to join" times out
On the worker: `sudo journalctl -u k3s-agent -n 100 --no-pager`
- `401 Unauthorized` / token errors: the agent's token differs from the server's. Re-run `make provision`.
- `connection refused` / timeouts to `192.168.50.10:6443`: from the worker, `nc -zv 192.168.50.10 6443`; check `sudo ufw status` on the server.
- Node registered but `NotReady`: `kubectl describe node k3s-worker1` → Conditions. Usually flannel: `8472/udp` must be open between nodes.

### `kubectl` from WSL: "Unable to connect to the server"
`echo $KUBECONFIG` must print `/home/<you>/.kube/epiconnect-lab.yaml` (open a new shell
after `make bootstrap`). The file is written by the last play of `make provision`.

### Pods cannot resolve DNS or reach pods on another node
`kubectl -n kube-system logs deploy/coredns`; on the nodes, `sudo journalctl -k | grep 'UFW BLOCK'`
shows dropped packets. The firewall role must allow 10.42.0.0/16 and 10.43.0.0/16 (input and route).

## Application on Kubernetes

Start every investigation with:
```bash
kubectl -n epiconnect get pods -o wide
kubectl -n epiconnect describe pod <pod>          # Events at the bottom
kubectl get events -n epiconnect --sort-by=.lastTimestamp | tail -20
```

| Symptom | Likely cause | Look at / fix |
|---|---|---|
| `ImagePullBackOff` | image tag not built yet, or the GHCR package is private | GitHub → Actions → Image run; package settings → visibility Public |
| `CreateContainerConfigError` | Secret or key missing | `make secrets`; `kubectl -n epiconnect get secret` |
| web pods stay in `Init:0/1` | migrations not applied | `kubectl -n epiconnect logs job/epiconnect-migrate`; logs of the `wait-for-migrations` container |
| Job `epiconnect-migrate` failed | DB unreachable or migration error | Job logs; `kubectl -n epiconnect logs postgres-0` |
| `Pending` pod | no node matches `nodeSelector`/resources, or PVC not bound | `describe pod` → FailedScheduling message; `make nodes` shows the pool labels |
| `ContainerCreating` for minutes | NFS mount failing | `describe pod` → MountVolume errors; `ssh k3s-worker1 'showmount -e 192.168.50.10'` |
| `CrashLoopBackOff` | app exits on start (config) | `kubectl -n epiconnect logs <pod> -c web --previous` |
| Running but `0/1` READY | readiness `/readyz/` failing (DB down, or NetworkPolicy) | Events `Readiness probe failed`; `kubectl -n epiconnect get pod postgres-0` |
| Browser: 404 page not found (Traefik) | Host header does not match the Ingress | the Windows hosts entry: `make host-init`; `ping epiconnect.lab` from PowerShell |
| Browser: certificate warning | lab CA not trusted | expected, or `make trust-ca` |
| Django `Bad Request (400)` | hostname not in `ALLOWED_HOSTS` | `kubernetes/configmap.yaml`, then `kubectl -n epiconnect rollout restart deploy/epiconnect` |
| `CSRF verification failed` on login | origin not in `CSRF_TRUSTED_ORIGINS`, or HTTP instead of HTTPS | use `https://epiconnect.lab` |

### PostgreSQL password mismatch after re-creating the Secret
PostgreSQL keeps the password it was initialised with (inside its volume). A new random
Secret no longer matches. Lab fix (destroys the data): delete the StatefulSet **and** the
claim `data-postgres-0`, then `make deploy-manifests`. Otherwise, set the old password
back in the Secret.

### A debug pod cannot resolve a Service name that the application resolves fine
busybox-based images do not apply the pod's DNS search domains reliably, so short
names like `postgres` fail there while they work in the application (glibc). Use the
full name: `postgres.epiconnect.svc.cluster.local`. When testing a NetworkPolicy,
always run a positive control too (a pod that *should* connect): "blocked" only means
something if the allowed case succeeds under the same conditions.

## Helm

| Symptom | Cause | Fix |
|---|---|---|
| `invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by"` | object created by `kubectl apply`, not yet adopted | `scripts/adopt-into-helm.sh` (run automatically by `make deploy-helm` on the first deploy) |
| `Apply failed with N conflicts` / `conflict with "kubectl-..."` | server-side apply: a field is owned by another manager with a different value (e.g. a manual `kubectl edit`) | inspect with `kubectl get <obj> -o yaml --show-managed-fields`; revert the manual change, or re-run once with `ARGS=--force-conflicts` if the chart is right |
| `spec: Forbidden: updates to statefulset spec for fields other than ...` | an immutable field changed (volumeClaimTemplates, selector) | revert the value; changing PostgreSQL's storage size needs a new volume, not an upgrade |
| `context deadline exceeded` after `--wait` | a resource never became ready within `--timeout` | `kubectl -n epiconnect get pods`, events, Job logs; then `helm rollback` if needed |
| release `pending-upgrade` / `another operation is in progress` | an interrupted helm command | `helm -n epiconnect history epiconnect`, then `helm -n epiconnect rollback epiconnect <last deployed revision>` |
| `make deploy-manifests` refuses to run | the app is owned by the Helm release now | use `make deploy-helm` |
