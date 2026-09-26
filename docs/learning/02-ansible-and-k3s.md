# Milestone 2: Ansible configuration and the k3s cluster

What was built: one command (`make provision`) that takes three fresh Ubuntu VMs to a
hardened, firewalled, three-node Kubernetes cluster with an NFS share, and that can be
re-run at any time with nothing changing (`changed=0`).

```
ansible/
├── ansible.cfg                  settings (inventory path, vault password file, SSH pipelining)
├── requirements.yml             pinned collections: ansible.posix, community.general
├── inventory/
│   ├── hosts.yml                WHICH machines, in which groups
│   └── group_vars/              WHAT values each group gets
│       ├── all/main.yml         lab-wide settings (k3s version, CIDRs, users)
│       ├── all/vault.yml        ENCRYPTED secrets (join token, admin password hash)
│       ├── k3s_servers.yml      k3s_mode: server
│       └── k3s_agents.yml       k3s_mode: agent
├── playbooks/
│   ├── site.yml                 = base + storage + k3s, in order
│   ├── base.yml                 roles: common, users, ssh_hardening, firewall
│   ├── storage.yml              roles: nfs_client (all), nfs_server (k3s-server)
│   └── k3s.yml                  roles: k3s_server, then k3s_agent (one at a time), kubeconfig
└── roles/<role>/{tasks,handlers,templates,defaults,meta}/
```

---

## 1. Ansible fundamentals: inventory, playbooks, roles, modules

1. **What:** Ansible connects to each node over SSH and runs small programs (*modules*) that bring one piece of the system to a declared state: "package X present", "file Y has this content", "service Z running".
2. **Why:** configuration becomes code: reviewed, versioned, repeatable on any number of machines.
3. **Problem solved:** hand-configured servers drift apart and cannot be rebuilt ("snowflakes"). A shell script can do the steps once, but it does not check state first, so running it twice often breaks things.
4. **How it works:** `ansible-playbook` reads the *inventory* (hosts and groups), merges variables (role defaults < group_vars/all < group_vars/<group> < host vars < `-e`), and for each *play* (hosts + roles) runs tasks in order on all hosts in parallel (`forks`). For each task it sends the module over SSH (pipelining: through the open connection, no temp file), runs it with Python on the node, and gets back JSON: `ok` (already in the desired state), `changed` (it changed something), `failed`, or `skipped`. The first task of each play, *Gathering Facts*, collects OS, IPs and memory into `ansible_facts`. *Roles* package the tasks, templates, handlers and defaults for one concern; `meta/main.yml` declares dependencies (`k3s_server` depends on `k3s_install`).
5. **Commands:**
   `make provision` · `make provision TAGS=k3s` · `make provision-check` (`--check --diff`: report, change nothing) · `cd ansible && ansible all -m ping` · `ansible-inventory --graph` · `ansible k3s-server -m setup -a 'filter=ansible_default_ipv4'`
6. **What can go wrong:** `UNREACHABLE` (SSH: network, key, host key); an undefined variable (group_vars in the wrong place: they must sit next to the inventory or the playbook); a task that reports `changed` every run (not idempotent).
7. **Troubleshoot:** `-v`/`-vvv` for details; `--start-at-task "name"`; `--limit k3s-worker1`; `ansible-inventory --host k3s-worker1` shows the merged variables of one host.
8. **Interview:** "Why Ansible instead of shell scripts?"
9. **Answer:** "Ansible modules are declarative and check state before acting, so the same playbook converges a fresh machine and does nothing on a configured one. It also gives me an inventory model, variables per group, secrets handling with Vault, dry runs with --check --diff, and a per-task report of what changed. A shell script gives none of that unless I rewrite it myself."

## 2. Idempotency and handlers

1. **What:** running the playbook a second time changes nothing (`changed=0`). Handlers restart a service **only** when something it depends on changed.
2. **Why:** it makes re-running safe, which is the only way automation stays in use.
3. **Problem solved:** drift detection. On a converged lab, any `changed` item means someone or something modified a node.
4. **How it works:** every task describes an end state. `apt state=present` installs only if missing; `template` compares a checksum of the rendered file with the one on disk; `get_url` with `checksum:` skips the download when the file already matches; `command` tasks that only *read* are marked `changed_when: false`. A changed task can `notify` a handler; handlers run once, at the end of the play or at `meta: flush_handlers`. Example: changing `k3s_version` → `get_url` downloads the new binary (changed) → notifies `Restart k3s` → one restart. On an unchanged run the handler never fires.
5. **Commands:** `demos/05-ansible-idempotency.sh --fresh` (roll back to the fresh checkpoint, run twice, write evidence) · `make provision-check`
6. **What can go wrong:** `command`/`shell` tasks report `changed` every time unless you tell Ansible how to judge them; templates with timestamps or random values; `update_password: always` with a password that is re-hashed on each run (here the hash itself is stored, so it is stable).
7. **Troubleshoot:** in the second run's log, search `changed:`. The task name tells you which part is not idempotent.
8. **Interview:** "What is idempotency? What are handlers?"
9. **Answer:** "Idempotent means applying the same operation again leaves the system unchanged. The playbook describes a state, so a second run reports changed=0. I prove it by rolling the VMs back to a clean checkpoint, running twice and keeping both logs. Handlers are tasks that run only when notified by a task that changed something, for example restart k3s only if its config file or binary changed, and only once even if several tasks notify it."

## 3. Secrets: Ansible Vault

1. **What:** `inventory/group_vars/all/vault.yml` is encrypted with AES-256. It holds the k3s join token and the hash of your admin password. The vault password lives only in `~/.config/epiconnect-k8s/vault-pass` (never in Git).
2. **Why:** secrets are versioned with the code that uses them, without being readable in the repository.
3. **Problem solved:** plaintext credentials in Git, the most common real-world leak.
4. **How it works:** `ansible-vault encrypt` derives a key from the vault password (PBKDF2) and encrypts the file (AES-256-CTR + HMAC-SHA256). `ansible.cfg` points to the password file, so playbooks decrypt in memory at run time. The `vault_` prefix convention: `main.yml` says `k3s_token: "{{ vault_k3s_token }}"`, so you can see where every secret is used without opening the vault.
5. **Commands:** `make vault-init` · `cd ansible && ansible-vault view inventory/group_vars/all/vault.yml` · `ansible-vault edit ...` · `ansible-vault rekey ...`
6. **What can go wrong:** losing the vault password (the vault is unrecoverable: regenerate it); committing the password file (it is outside the repo on purpose).
7. **Troubleshoot:** "Attempting to decrypt but no vault secrets found" → `~/.config/epiconnect-k8s/vault-pass` is missing.
8. **Interview:** "How do you handle secrets in Ansible? Is an encrypted file in a public repo safe?"
9. **Answer:** "Ansible Vault with the password kept outside the repo. The encrypted file is AES-256, so committing it is fine as long as the vault password is strong and secret; I generate it randomly. In a team I would keep the vault password in a secrets manager or use an external secrets backend, and rotate the values if the password leaks."

## 4. Accounts, SSH hardening, least privilege

1. **What:** two accounts. `ansible` (automation: key only, passwordless sudo) and `rayen` (human: key only, sudo **asks for a password**). SSH allows only members of `ssh-users`, keys only, no root, no forwarding.
2. **Why:** each identity gets the access it needs and no more; a stolen key alone does not give the human account root.
3. **Problem solved:** brute-force (no passwords accepted), privilege escalation from a stolen key, lateral movement (no agent/TCP forwarding: a node cannot be used as a jump host).
4. **How it works:** sshd reads `sshd_config`, which includes `sshd_config.d/*.conf` in name order, and keeps the **first** value for each option. Our `10-hardening.conf` therefore wins over the image's `50-`/`60-` files. The template is validated with `sshd -t -f <file>` before it is written, and the handler runs `sshd -t` on the full configuration before `reload`. A broken config can never replace a working one, and reload keeps existing sessions (including Ansible's) open. The sudo rule is validated with `visudo -cf` for the same reason.
5. **Commands:** `ssh k3s-server 'sudo sshd -T | grep -E "permitrootlogin|passwordauthentication|allowgroups"'` (effective config) · `ssh rayen@192.168.50.10` · `sudo -l`
6. **What can go wrong:** locking yourself out (AllowGroups before the user is in the group: the role checks this first); a sudoers syntax error (breaks sudo for everyone: hence `validate`).
7. **Troubleshoot:** Hyper-V console + break-glass password; `journalctl -u ssh`; `sshd -t`.
8. **Interview:** "How did you harden SSH? How do permissions work for sudo?"
9. **Answer:** "Key-only authentication, no root login, only an explicit group may log in, low MaxAuthTries, no forwarding. The drop-in is validated before it is written and the whole config is tested before reload. For privilege: the automation account has passwordless sudo because it runs unattended, but only its key can log in; my human account needs a password for sudo, so a stolen key alone does not give root."

## 5. Host firewall (UFW) for Kubernetes nodes

1. **What:** default deny inbound; explicit exceptions, all limited to `192.168.50.0/24`: 22 (SSH), 6443 (API server, server only), 10250 (kubelet), 8472/udp (flannel VXLAN), 80/443 (ingress), 2049 (NFS, server only), plus the pod (10.42/16) and service (10.43/16) ranges.
2. **Why:** only the ports the cluster needs are reachable, and only from the lab network.
3. **Problem solved:** exposed services (e.g. the kubelet API, which can run commands in pods) reachable by anything that can reach the node.
4. **How it works:** UFW is a front end that writes iptables (nftables backend on 24.04) rules. INPUT rules cover traffic *to* the node. Traffic *through* the node (pod to pod across nodes, ingress to a pod behind a hostPort) goes through the FORWARD chain: UFW's "route" rules. k3s adds its own chains (flannel, kube-proxy, network policy) alongside UFW's.
5. **Commands:** `ssh k3s-server 'sudo ufw status verbose'` · `sudo ufw status numbered` · `sudo iptables -S | head` · `sudo journalctl -k | grep UFW` (blocked packets)
6. **What can go wrong:** agents cannot join (6443 blocked); nodes `NotReady` or pods on different nodes cannot talk (8472/udp); pods cannot resolve DNS (pod CIDR not allowed to reach the node).
7. **Troubleshoot:** `nc -zv 192.168.50.10 6443` from a worker; `[UFW BLOCK]` lines in the kernel log show exactly which port and source were dropped.
8. **Interview:** "Which ports does a Kubernetes node need? How would you investigate a networking issue?"
9. **Answer:** "API server 6443 on the control plane, kubelet 10250 on every node, the CNI's overlay port (8472/udp for flannel VXLAN), plus whatever ingress exposes. For an issue I go bottom-up: link and IP, route, can I reach the port (nc), is the firewall dropping it (kernel log), then DNS, then the application."

## 6. k3s: what a server and an agent actually are

1. **What:** k3s is a CNCF-certified Kubernetes distribution packaged as one binary. `k3s server` = control plane + a kubelet (the server is also a node); `k3s agent` = worker node.
2. **Why:** full Kubernetes API with a small footprint (fits 3 VMs on a laptop) and batteries included (ingress, load balancer, storage provisioner, network policy).
3. **Problem solved:** running upstream Kubernetes components by hand (kubeadm, etcd, CNI, ingress…) is a lot of moving parts for a 3-node lab.
4. **How it works:**
   - **Server process:** kube-apiserver (the only component that talks to storage), scheduler (picks a node for each pod), controller-manager (reconcile loops: Deployments, ReplicaSets, node lifecycle), **kine + SQLite** as the datastore instead of etcd, **containerd** (runs containers), **flannel** (pod network: VXLAN between nodes), **CoreDNS**, **Traefik** (ingress), **ServiceLB/klipper** (LoadBalancer Services via hostPorts on nodes), **local-path provisioner** (PVs on node disks), **metrics-server**, and an embedded **network policy controller** (kube-router).
   - **Agent process:** kubelet (starts the pods the scheduler assigned to this node, runs probes), kube-proxy (Service IP → pod IP rules), containerd, flannel.
   - **Join:** the agent connects to `https://192.168.50.10:6443` with the shared **token**. The token authenticates the agent and lets it verify the server's CA, then the agent gets its own certificates and registers its Node object.
   - **Our config:** `node-ip` and `flannel-iface` pin everything to the lab network; `tls-san` puts the lab IP into the API certificate; `secrets-encryption` encrypts Secret objects at rest; the `epiconnect.io/pool` label (data/app) lets workloads choose nodes.
5. **Commands:** `make nodes` · `kubectl get pods -A -o wide` · `ssh k3s-server 'sudo systemctl status k3s'` · `ssh k3s-worker1 'sudo journalctl -u k3s-agent -f'` · `ssh k3s-server 'sudo k3s secrets-encrypt status'` · `ssh k3s-server 'sudo crictl ps'`
6. **What can go wrong:** agent never joins (token mismatch, 6443 blocked, wrong server URL); node `NotReady` (flannel cannot reach other nodes: 8472/udp); a single server is a single point of failure for the control plane (running pods keep running; nothing new can be scheduled).
7. **Troubleshoot:** `journalctl -u k3s-agent` on the worker (look for "Waiting to retrieve agent configuration" / 401 = token); `kubectl describe node k3s-worker1` (Conditions); `kubectl get events -A --sort-by=.lastTimestamp`.
8. **Interview:** "Why k3s instead of full Kubernetes? Why three nodes? What happens if the server dies?"
9. **Answer:** "k3s is certified Kubernetes. The API, objects and kubectl behaviour are the same, but packaged as one binary with SQLite instead of etcd, which suits a 3-VM lab on a laptop. Three nodes because one control plane plus two workers is the smallest setup where scheduling, spreading replicas and losing a worker are meaningful. The control plane is not HA: if the server dies, running pods on workers keep serving, but nothing can be rescheduled until it returns. For HA I would run three servers with embedded etcd, since etcd needs a quorum of an odd number of members."

## 7. NFS share (preparing ReadWriteMany storage)

1. **What:** `k3s-server` exports `/srv/nfs/epiconnect-media` to the lab network; every node has the NFS client.
2. **Why:** EPIConnect's uploaded files must be visible to all 3 app replicas on 2 different workers.
3. **Problem solved:** a node-local disk (local-path) can be mounted by pods on **one node** only (ReadWriteOnce). Uploads made through a pod on worker1 would be missing on worker2.
4. **How it works:** the NFS server (kernel `nfsd`) exports a directory; `all_squash,anonuid=10001` makes every write owned by the app's user (UID 10001 in the EPIConnect image). In Milestone 3, a PersistentVolume of type `nfs` points at `192.168.50.10:/srv/nfs/epiconnect-media`; the kubelet on whichever node runs a pod mounts it with the node's NFS client.
5. **Commands:** `ssh k3s-server 'sudo exportfs -v'` · `ssh k3s-worker1 'showmount -e 192.168.50.10'` · test mount: `ssh k3s-worker1 'sudo mount -t nfs4 192.168.50.10:/srv/nfs/epiconnect-media /mnt && touch /mnt/t && ls -ln /mnt && sudo rm /mnt/t && sudo umount /mnt'`
6. **What can go wrong:** 2049 blocked; export not reloaded (`exportfs -ra`); permission denied (ownership/squash).
7. **Troubleshoot:** `exportfs -v` on the server, `rpcinfo -p 192.168.50.10`, `dmesg` on the client.
8. **Interview:** "RWO vs RWX? Why not put PostgreSQL on NFS too?"
9. **Answer:** "ReadWriteOnce: one node can mount the volume read-write; ReadWriteMany: many nodes at once. Uploads need RWX because replicas on different nodes serve them. PostgreSQL needs RWO block-like storage with reliable fsync and locking semantics; databases on NFS risk corruption and are slow, so it gets a local volume. The trade-off is that the NFS server is a single point of failure; in production I would use a managed or replicated file service, or object storage like S3 as the AWS version does."

---

## Study checkpoint (Milestone 2)

Be able to explain without notes:
- [ ] Inventory vs group_vars vs roles vs playbooks: where does `k3s_token` come from, step by step?
- [ ] Why the second run reports `changed=0`, and what a handler is (example: k3s version upgrade).
- [ ] How the vault works and what must never be committed.
- [ ] The two accounts and why only one of them has passwordless sudo.
- [ ] Why `sshd -t` runs before `reload`, and why reload rather than restart.
- [ ] Every port in the firewall and the component behind it.
- [ ] What runs in `k3s server` vs `k3s agent`, and how an agent joins.
- [ ] What happens to the cluster if `k3s-server` goes down.
- [ ] RWO vs RWX and why uploads and the database use different storage.

Run these yourself:
```bash
cd ~/epiconnect-k8s/ansible
ansible-inventory --graph
ansible-inventory --host k3s-worker1 | jq '{k3s_mode, k3s_node_pool, k3s_version}'
ansible all -m ping
cd .. && make provision-check          # expect: changed=0 everywhere
make nodes
kubectl get pods -A -o wide           # which component runs where?
ssh k3s-server 'sudo cat /etc/rancher/k3s/config.yaml | grep -v token'
ssh k3s-worker1 'sudo ufw status verbose'
ssh k3s-server 'sudo exportfs -v'
```
