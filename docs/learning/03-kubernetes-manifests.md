# Milestones 3-4: EPIConnect on Kubernetes with raw manifests

What was built: EPIConnect running as 3 replicas behind an Ingress with TLS, PostgreSQL
in a StatefulSet with its own disk, uploads on a shared NFS volume, migrations as a Job,
default-deny network policies and the strictest Pod Security level. Then a script that
proves it works end to end (`make verify`).

```
                 https://epiconnect.lab
                          │ (Windows hosts file -> 192.168.50.10; any node works)
      ┌───────────────────▼──────────────────┐   kube-system
      │ ServiceLB (80/443 on every node)     │
      │   -> Traefik (Ingress controller)    │   TLS ends here (Secret epiconnect-tls)
      └───────────────────┬──────────────────┘
 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─   namespace epiconnect (PSA: restricted)
                          ▼ NetworkPolicy: only Traefik -> 8000
      Service epiconnect (ClusterIP) ─┬─> web pod (worker1)  ┐ Deployment, 3 replicas
                                      ├─> web pod (worker2)  │ probes, init gate,
                                      └─> web pod (worker1)  ┘ /app/media = NFS (RWX)
                                               │ NetworkPolicy: only db-client label -> 5432
      Service postgres (headless) ──────> postgres-0 (k3s-server)  StatefulSet, local-path PVC (RWO)
      Job epiconnect-migrate ──────────────────┘ (runs once per release)
```

Apply order (`scripts/deploy-manifests.sh`): namespace, config, identity, storage,
policies → PostgreSQL (wait) → migration Job (wait) → admin Job → Deployment, Service,
Ingress (wait for rollout).

---

## 1. Namespace and Pod Security Admission

1. **What:** namespace `epiconnect` labelled `pod-security.kubernetes.io/enforce: restricted`.
2. **Why:** isolation boundary for names, policies and security rules.
3. **Problem solved:** one careless manifest (root user, privileged container) weakening the whole cluster.
4. **How it works:** Pod Security Admission is built into the API server. When a pod is created in the namespace, it is checked against the *restricted* profile (non-root, no privilege escalation, all capabilities dropped, seccomp RuntimeDefault) and **rejected** if it does not comply. Deployments are checked too, with a warning, because they create pods.
5. **Commands:** `kubectl get ns epiconnect --show-labels` · try it: `kubectl -n epiconnect run test --image=busybox -- sleep 60` → *forbidden: violates PodSecurity "restricted"*.
6. **What can go wrong:** a third-party image that needs root cannot run here (by design).
7. **Troubleshoot:** the rejection message lists every violated field; `kubectl get events -n epiconnect` shows ReplicaSets failing to create pods (`FailedCreate`).
8. **Interview:** "How do you enforce security standards for workloads?"
9. **Answer:** "At the platform level with Pod Security Admission: the namespace enforces the restricted profile, so the API server rejects any pod that runs as root, keeps capabilities or can escalate privileges. My manifests comply: UID 10001, read-only root filesystem, all capabilities dropped, seccomp RuntimeDefault, and no service-account token."

## 2. ConfigMap and Secret

1. **What:** `epiconnect-config` (non-secret settings) and `epiconnect-secrets` (Django key, DB password, admin password), both injected as environment variables.
2. **Why:** the same image runs on AWS and here; only configuration differs (12-factor).
3. **Problem solved:** configuration baked into images, or credentials committed to Git.
4. **How it works:** `envFrom: configMapRef` turns every key into an env var; `secretKeyRef` picks individual secret keys. Secrets are only **base64-encoded** in the API, not encrypted, so the protections are elsewhere: k3s **encrypts Secrets at rest** in its datastore (`secrets-encryption: true`), RBAC controls who can read them, and the values are generated in the cluster by `make secrets`, never written to a file in the repo. Env vars are read at container start, so a changed ConfigMap needs a pod restart (`kubectl rollout restart`).
5. **Commands:** `kubectl -n epiconnect get cm epiconnect-config -o yaml` · `kubectl -n epiconnect get secret epiconnect-secrets -o jsonpath='{.data.db-password}' | base64 -d` (shows what "base64" means) · `ssh k3s-server 'sudo k3s secrets-encrypt status'`
6. **What can go wrong:** pod stuck in `CreateContainerConfigError` (Secret or key missing).
7. **Troubleshoot:** `kubectl describe pod` → Events names the missing key.
8. **Interview:** "What is a ConfigMap? A Secret? Is a Secret secure?"
9. **Answer:** "Both hold configuration outside the image; Secrets are meant for sensitive values and are handled more carefully: RBAC, not shown by default, encryption at rest if the cluster enables it, which mine does. Base64 is encoding, not encryption. In production I would also keep them out of Git entirely with something like External Secrets or Sealed Secrets."

## 3. Deployment, ReplicaSet, Pod, and scheduling

1. **What:** Deployment `epiconnect`, 3 replicas, rolling updates with `maxSurge: 1`, `maxUnavailable: 0`.
2. **Why:** declare "3 copies of this pod template" and let controllers keep it true.
3. **Problem solved:** a crashed process or a lost node reducing capacity until someone notices.
4. **How it works:** the Deployment owns a **ReplicaSet** per version of the pod template; the ReplicaSet creates pods until the count matches. The **scheduler** picks a node for each new pod: it filters (`nodeSelector epiconnect.io/pool=app` → only workers; enough CPU/memory *requests* free) and then scores (topology spread prefers the worker with fewer replicas, giving 2 + 1). The **kubelet** on that node starts the containers. On an update, a new ReplicaSet scales up one pod at a time while the old one scales down, **only after the new pod is Ready**. The `tolerations` shorten how long pods stay bound to an unreachable node (30 s instead of 300 s) before they are evicted and recreated elsewhere.
5. **Commands:** `kubectl -n epiconnect get deploy,rs,pods -o wide` · `kubectl -n epiconnect rollout status deploy/epiconnect` · `kubectl -n epiconnect rollout history deploy/epiconnect` · `kubectl -n epiconnect rollout undo deploy/epiconnect`
6. **What can go wrong:** `Pending` (no node satisfies selector/resources), `ImagePullBackOff`, `CrashLoopBackOff`.
7. **Troubleshoot:** `kubectl describe pod <p>` (Events: scheduler and kubelet messages) · `kubectl logs <p> -c web --previous` (last crash).
8. **Interview:** "What happens when a pod dies? How does Kubernetes schedule pods?"
9. **Answer:** "The pod is not repaired, it is replaced: the ReplicaSet controller sees 2 of 3 and creates a new pod, the scheduler filters nodes by constraints and free requested resources and scores the rest, and the kubelet on the chosen node starts it. If only the container crashed, the kubelet restarts it in place with back-off, which is CrashLoopBackOff when it keeps failing."

## 4. Probes and graceful shutdown

1. **What:** startup + liveness on `/healthz/` (no database), readiness on `/readyz/` (runs `SELECT 1`), and a 5 s `preStop` sleep.
2. **Why:** the kubelet must know when a pod can take traffic, and when it is broken beyond recovery.
3. **Problem solved:** traffic sent to pods that are still starting or cannot reach the database; hung processes that never recover.
4. **How it works:** the kubelet calls each probe periodically. **Startup** runs first; liveness/readiness only begin when it succeeds (slow boots do not get killed). **Liveness** failure → the container is **restarted**. **Readiness** failure → the pod is **removed from the Service endpoints** (no restart). Liveness deliberately ignores the database: if PostgreSQL goes down, all pods become *unready* (correctly, since they cannot serve) but none are restarted, which would only cause a restart storm. On deletion, the pod is removed from the endpoints *at the same time* SIGTERM would be sent; `preStop: sleep 5` delays SIGTERM so Traefik stops routing to it first, then Gunicorn finishes in-flight requests.
5. **Commands:** `kubectl -n epiconnect describe pod <p> | grep -A3 -E "Liveness|Readiness|Startup"` · `kubectl -n epiconnect get endpointslices -l kubernetes.io/service-name=epiconnect -o wide` · `kubectl get events -n epiconnect --field-selector reason=Unhealthy`
6. **What can go wrong:** liveness that depends on a dependency (restart storms); readiness too strict (flapping); probes blocked by a NetworkPolicy.
7. **Troubleshoot:** Events show `Liveness probe failed: ...`/`Readiness probe failed: HTTP probe failed with statuscode: 503`; run the probe by hand: `kubectl exec <p> -- python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/readyz/').read())"`.
8. **Interview:** "Readiness vs liveness? What happens when a readiness probe fails?"
9. **Answer:** "Liveness answers 'is the process broken?' and failing it restarts the container. Readiness answers 'can it take traffic now?' and failing it only removes the pod from the Service's endpoints until it passes again. My liveness endpoint does not touch the database, so a database outage makes pods unready instead of restarting all of them."

## 5. Service, DNS and Ingress

1. **What:** Service `epiconnect` (ClusterIP), Ingress `epiconnect.lab` handled by Traefik with TLS.
2. **Why:** pods come and go with new IPs; clients need one stable name. And HTTP routing by hostname needs a layer-7 proxy.
3. **Problem solved:** addressing ephemeral pods; exposing only one HTTPS entry point instead of every pod.
4. **How it works:** a Service gets a virtual IP (10.43.x) and a DNS name (`epiconnect.epiconnect.svc.cluster.local`) from CoreDNS. The endpoints controller keeps the list of **ready** pod IPs; kube-proxy programs iptables so connections to the VIP go to one of them. **NodePort** would open a port on every node; **ClusterIP** keeps it internal. The **Ingress** is only a routing rule; Traefik (the Ingress controller) implements it. k3s's **ServiceLB** exposes Traefik's LoadBalancer Service on 80/443 of every node, so any node IP works. Traefik terminates TLS, adds `X-Forwarded-Proto/For`, and sends requests straight to the ready pod IPs.
5. **Commands:** `kubectl -n epiconnect get svc,endpointslices,ingress` · `kubectl -n kube-system get svc traefik` · `curl --resolve epiconnect.lab:443:192.168.50.11 --cacert ~/.config/epiconnect-k8s/tls/ca.crt https://epiconnect.lab/readyz/` · DNS from a pod: `kubectl -n epiconnect exec deploy/epiconnect -- python -c "import socket;print(socket.gethostbyname('postgres'))"`
6. **What can go wrong:** Traefik 404 (Host header does not match: missing hosts entry); 503 (no ready endpoints); certificate warning (lab CA not trusted: `make trust-ca`).
7. **Troubleshoot:** `kubectl -n kube-system logs deploy/traefik`; empty endpoints → check readiness and the Service selector labels.
8. **Interview:** "Service vs Ingress? ClusterIP vs NodePort? How does service discovery work?"
9. **Answer:** "A Service is a stable layer-4 address for a set of pods selected by label; ClusterIP is internal only, NodePort also opens a port on every node. An Ingress is a layer-7 rule (host, path, TLS) implemented by a controller like Traefik, which gives one HTTPS entry for many Services. Discovery is DNS: CoreDNS resolves the Service name to its ClusterIP, or, for a headless Service like my postgres one, directly to the pod IPs."

## 6. StatefulSet, headless Service, PersistentVolumeClaim (RWO)

1. **What:** `postgres` StatefulSet (1 replica) with a `volumeClaimTemplate` (2 Gi, `local-path`), headless Service `postgres`, pinned to `k3s-server`.
2. **Why:** a database needs a stable identity and its own disk that survives restarts.
3. **Problem solved:** with a Deployment and no volume, every restart would start from an empty database.
4. **How it works:** the StatefulSet names pods predictably (`postgres-0`) and creates one claim per pod (`data-postgres-0`) that is **not deleted** with the pod. The `local-path` provisioner waits until the pod is scheduled (`WaitForFirstConsumer`) and then creates a directory on that node's disk: fast and real local I/O, but **ReadWriteOnce** and tied to that node. A pod recreated later reattaches to the same claim, so the same data. `PGDATA` is a subdirectory because `initdb` needs an empty directory it owns.
5. **Commands:** `kubectl -n epiconnect get sts,pvc,pod -o wide` · `kubectl get pv` · where the data lives: `ssh k3s-server 'sudo ls /var/lib/rancher/k3s/storage/'` · `kubectl -n epiconnect exec -it postgres-0 -- psql -U epiconnect -c '\dt'`
6. **What can go wrong:** PVC `Pending` (no node matches, provisioner not running); if `k3s-server` dies the database cannot move (the disk is there), a documented limit (DECISIONS D10/D11).
7. **Troubleshoot:** `kubectl -n epiconnect describe pvc data-postgres-0`; `kubectl -n kube-system logs deploy/local-path-provisioner`.
8. **Interview:** "Deployment vs StatefulSet? What is a PVC? Why does PostgreSQL need persistent storage?"
9. **Answer:** "A Deployment manages interchangeable pods; a StatefulSet gives each pod a stable name, ordered start/stop and its own persistent volume. A PVC is a request for storage ('2 Gi, ReadWriteOnce'); Kubernetes binds it to a PersistentVolume, provisioned dynamically here by local-path. PostgreSQL writes its data files to disk; without a persistent volume they live in the container's writable layer and are lost when the pod is replaced."

## 7. Shared uploads: static NFS PersistentVolume (RWX)

1. **What:** PersistentVolume `epiconnect-media` (NFS, `192.168.50.10:/srv/nfs/epiconnect-media`, ReadWriteMany) bound to claim `epiconnect-media`, mounted at `/app/media` in every web pod.
2. **Why / 3. Problem solved:** replicas on two nodes must see the same uploaded files; with RWO the upload would exist only on one node.
4. **How it works:** static provisioning: the PV is written by hand and the claim binds to it by name (`volumeName`, `claimRef`). When a web pod starts on a worker, that node's kubelet mounts the NFS export (with the node's NFS client from Ansible) and bind-mounts it into the container. `Retain` keeps the files even if the claim is deleted.
5. **Commands:** `kubectl get pv epiconnect-media` · `kubectl -n epiconnect exec <pod> -- df -h /app/media` · `ssh k3s-worker1 'mount | grep nfs'`
6. **What can go wrong:** pods stuck in `ContainerCreating` with `MountVolume.SetUp failed` (NFS server unreachable, 2049 blocked, export missing).
7. **Troubleshoot:** `kubectl describe pod` events; on the node `showmount -e 192.168.50.10`.
8. **Interview:** "Which access mode for which workload?"
9. **Answer:** "RWO for a single writer like a database, RWX when several pods on different nodes must share files, like uploads here. RWX needs a network filesystem (NFS, CephFS, EFS on AWS); I used NFS, which is a single point of failure I would replace with object storage or a managed file service in production."

## 8. Jobs and the migration gate

1. **What:** Job `epiconnect-migrate` (runs `migrate` + `createcachetable` once), Job `epiconnect-bootstrap-admin`, and an init container in each web pod waiting for `migrate --check` to pass.
2. **Why:** schema changes must happen exactly once per release, before the new code serves traffic.
3. **Problem solved:** three replicas racing to migrate the same tables; new pods becoming Ready against an old schema.
4. **How it works:** a Job runs pods until one completes successfully (`backoffLimit` retries, e.g. while PostgreSQL is still starting). Init containers run to completion before the main container starts; `manage.py migrate --check` exits non-zero while migrations are pending, so the pod waits (status `Init:0/1`). Jobs are immutable, so each release deletes the previous Job and creates a new one. Rolling updates assume backward-compatible migrations: old pods keep running against the new schema until they are replaced.
5. **Commands:** `kubectl -n epiconnect get jobs` · `kubectl -n epiconnect logs job/epiconnect-migrate` · `kubectl -n epiconnect logs <web-pod> -c wait-for-migrations`
6. **What can go wrong:** Job `Failed` (DB unreachable, migration error); web pods stuck in `Init` (migrations never ran).
7. **Troubleshoot:** Job logs; `kubectl describe job`.
8. **Interview:** "How do you run database migrations on Kubernetes?"
9. **Answer:** "As a Job once per release, not in every container. The deploy waits for it to complete; web pods also have an init container that blocks until no migrations are pending, so even out of order nothing serves traffic on the wrong schema. Migrations must be backward compatible because old and new pods overlap during a rolling update."

## 9. NetworkPolicy

1. **What:** default deny (ingress **and** egress) for every pod in the namespace; allowed: DNS to CoreDNS, Traefik → web:8000, `db-client`-labelled pods → postgres:5432.
2. **Why:** by default every pod can talk to every other pod in the cluster.
3. **Problem solved:** a compromised or misconfigured pod reaching the database directly.
4. **How it works:** a NetworkPolicy selects pods by label and lists allowed peers/ports; once a pod is selected by any policy for a direction, everything not allowed is dropped. The rules are enforced by the node's network policy controller (kube-router, built into k3s) with iptables/ipsets. A connection needs *both* the client's egress and the server's ingress to allow it. Enforcement is **eventually consistent**: kube-router adds a new pod's IP to the allowed-client set on the database's node a few seconds after the pod starts, so a brand-new client can be refused for that window (the verification probe retries for ~20 s and records the attempt that succeeded). Allowing by **label** (`epiconnect.io/db-client: "true"`) instead of pod name keeps it valid as pods are replaced.
5. **Commands:** `kubectl -n epiconnect get networkpolicy` · `kubectl -n epiconnect describe networkpolicy postgres-from-db-clients` · proof: the NetworkPolicy check in `make verify` (probe pod without label: BLOCKED; with label: REACHABLE).
6. **What can go wrong:** forgetting DNS egress (everything fails with name-resolution errors); policies with typos select nothing (silently no protection); **a broken test that looks like a working policy**. The first version of the check reported "BLOCKED" for both probe pods, but the labelled pod was failing on DNS, not on the policy: busybox does not apply the pod's DNS search domains reliably, so the short name `postgres` never resolved. A positive control (the labelled pod that *must* connect) exposed it; the check now uses the full name and requires DNS to work before "BLOCKED" counts.
7. **Troubleshoot:** test with a throw-away pod against the full service name (`nc -w 3 postgres.epiconnect.svc.cluster.local 5432`), always with a positive and a negative case; check labels with `kubectl get pods --show-labels`.
8. **Interview:** "What is a NetworkPolicy? How did you restrict database access?"
9. **Answer:** "A label-based pod firewall. I start with default deny in both directions, then allow DNS, ingress-controller to web, and only pods labelled as database clients to reach PostgreSQL on 5432. I prove it with a probe pod: without the label the connection times out, with it the connection succeeds."

## 10. Resource requests and limits

1. **What:** web: requests 100m CPU / 256 Mi, limits 1 CPU / 512 Mi. PostgreSQL: 100m / 256 Mi, limits 1 CPU / 512 Mi.
2. **Why / 3. Problem solved:** the scheduler places pods using **requests** (no overcommitted node); **limits** stop one pod from starving the others (a memory leak cannot take a node down).
4. **How it works:** requests are reserved on the node at scheduling time. At runtime, CPU above the limit is **throttled**; memory above the limit gets the container **OOM-killed** (then restarted). Requests below limits = QoS class *Burstable*.
5. **Commands:** `kubectl top pods -n epiconnect` · `kubectl describe node k3s-worker1 | grep -A8 "Allocated resources"` · `kubectl get pod <p> -o jsonpath='{.status.qosClass}'`
6. **What can go wrong:** `Pending` with "Insufficient memory"; `OOMKilled` in `kubectl describe pod`.
7. **Troubleshoot:** compare `kubectl top` with the limits; raise limits or fix the leak.
8. **Interview:** "Requests vs limits?"
9. **Answer:** "Requests are what the scheduler reserves and guarantees; limits are the ceiling enforced at runtime: CPU is throttled, memory over the limit is OOM-killed. I size requests from observed usage and set a memory limit so a leak affects only its own pod."

## 11. Where the image comes from, and why deployment is local

1. **What:** `.github/workflows/image.yml` builds EPIConnect from the pinned `app/` submodule and pushes `ghcr.io/rayenmabrouk/epiconnect:<EPIConnect commit>`; the manifests pin that tag.
2. **Why:** build once in CI, run the identical image everywhere; the tag says exactly which application commit runs.
3. **Problem solved:** "works on my machine" images; `:latest` drift.
4. **How it works:** GitHub Actions authenticates to GHCR with the workflow's own token (`packages: write`). The cluster pulls anonymously, so the package is public. GitHub's runners cannot reach a cluster on a laptop behind NAT (and should not: no inbound exposure), so `make deploy-manifests` is the local deployment step.
5. **Commands:** `kubectl -n epiconnect get deploy epiconnect -o jsonpath='{.spec.template.spec.containers[0].image}'` · on a node: `sudo crictl images | grep epiconnect`
6. **What can go wrong:** `ImagePullBackOff` (tag not built yet, or package still private).
7. **Troubleshoot:** `kubectl describe pod` → the pull error; check the package page on GitHub.
8. **Interview:** "Why doesn't your pipeline deploy to your cluster?"
9. **Answer:** "The cluster is on a private network on my laptop. A GitHub-hosted runner cannot reach it, and opening it to the internet to allow that would be the wrong trade-off. So CI builds, validates and publishes the image; deployment is a reproducible local command. In a real environment I would use a pull-based approach (a GitOps agent inside the cluster) or a self-hosted runner inside the network."

---

## Why raw manifests first (and what Helm will fix)

Writing every object by hand shows what Helm would generate. It also exposes the pain
Helm solves: the image tag appears in **4 places** (Deployment, init container, two Jobs),
the pod security settings and environment are **copied** into 4 pod templates, and the
deploy order lives in a shell script. Milestone 5 turns these into one `values.yaml`
and shared templates.

---

## Study checkpoint (Milestones 3-4)

Be able to explain without notes:
- [ ] Draw the request path from the browser to PostgreSQL and name each hop.
- [ ] Deployment vs ReplicaSet vs Pod; what happens when a pod or a whole node dies.
- [ ] Liveness vs readiness vs startup, and why `/healthz/` does not check the database.
- [ ] Service vs Ingress; ClusterIP vs NodePort vs LoadBalancer; headless Service.
- [ ] Deployment vs StatefulSet; PVC vs PV; RWO vs RWX; static vs dynamic provisioning.
- [ ] Why migrations are a Job, and what the init container protects against.
- [ ] Each NetworkPolicy and the flow it allows; why DNS egress is needed.
- [ ] ConfigMap vs Secret; what base64 is and is not; encryption at rest.
- [ ] Requests vs limits; what OOMKilled means.
- [ ] Why CI does not deploy to this cluster.

Run these yourself:
```bash
kubectl -n epiconnect get all,pvc,ingress,networkpolicy -o wide
kubectl -n epiconnect describe pod -l app.kubernetes.io/component=web | grep -E "Node:|Liveness|Readiness|Startup|Limits|Requests" -A1
kubectl -n epiconnect get endpointslices -o wide
kubectl -n epiconnect logs deploy/epiconnect -c web --tail=5
kubectl -n epiconnect exec -it postgres-0 -- psql -U epiconnect -c '\dt'
kubectl get events -n epiconnect --sort-by=.lastTimestamp | tail -20
kubectl top nodes; kubectl top pods -n epiconnect
```
