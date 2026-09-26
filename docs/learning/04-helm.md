# Milestone 5: Helm

What was built: `helm/epiconnect`, a chart that produces exactly the objects of
`kubernetes/` from one `values.yaml`, and an **in-place migration** of the running
raw-manifest deployment into a Helm release (no downtime, no data loss).

```
helm/epiconnect/
├── Chart.yaml          chart name, chart version, appVersion (= EPIConnect commit)
├── values.yaml         every setting that can differ between installs
└── templates/
    ├── _helpers.tpl    shared snippets: labels, image, security contexts, env
    ├── configmap.yaml  data rendered from values.config
    ├── deployment.yaml web tier (+ checksum/config annotation)
    ├── jobs.yaml       migrate + bootstrap-admin, one per release revision
    ├── postgres.yaml   headless Service + StatefulSet (if postgres.enabled)
    ├── media-storage.yaml, service.yaml, ingress.yaml, serviceaccount.yaml, network-policy.yaml
    └── NOTES.txt       printed after install/upgrade
```

What the raw manifests forced us to repeat, and where it went:

| Raw manifests | Chart |
|---|---|
| image tag in 4 places | `image.tag` once (default: `Chart.appVersion`) |
| pod/container security block copied 4× | `epiconnect.podSecurityContext`, `epiconnect.containerSecurityContext` |
| secret env vars copied 4× | `epiconnect.appSecretEnv` |
| deploy order in a shell script | not needed: web pods wait for migrations themselves; `--wait --wait-for-jobs` |
| Jobs deleted by hand before each release | Job name includes the release revision |
| "which version is running?" | `helm history`, one revision per upgrade, `helm rollback` |

---

## 1. Chart, values, templates, release

1. **What:** a *chart* is a package of templated Kubernetes manifests; *values* fill the templates; an installed chart is a *release*, and every install/upgrade creates a new *revision*.
2. **Why:** one source of truth for the manifests, many configurations (lab, staging, external DB) without copy-paste.
3. **Problem solved:** duplicated YAML drifting apart; no record of what was deployed when.
4. **How it works:** `helm upgrade --install` renders the templates (Go templates + Sprig functions) with `values.yaml` merged with any `--set`/`-f` overrides, then sends the objects to the API server. Helm stores the rendered manifest of each revision in a Secret in the namespace (`sh.helm.release.v1.epiconnect.vN`). Helm 4 applies objects with **server-side apply** (the default for new releases): the API server merges the change and records an owner ("field manager") for every field. If another manager (say, someone's `kubectl edit`) owns a field with a different value, the upgrade stops with a *conflict* instead of silently overwriting it. (Helm 3 computed a three-way patch on the client instead.)
5. **Commands:** `helm template epiconnect helm/epiconnect -n epiconnect` (render only) · `helm lint helm/epiconnect --strict` · `make helm-check` · `helm -n epiconnect get values epiconnect --all` · `helm -n epiconnect get manifest epiconnect` · `kubectl -n epiconnect get secrets -l owner=helm`
6. **What can go wrong:** template syntax/indentation errors (invalid YAML), a values typo silently producing an empty field, an immutable field changed by an upgrade (e.g. a StatefulSet's volumeClaimTemplates).
7. **Troubleshoot:** `helm template ... --debug` shows the rendered YAML even when it is invalid; `make helm-diff` shows the change before it is applied.
8. **Interview:** "Why Helm? What is values.yaml? What does Helm template?"
9. **Answer:** "Helm packages Kubernetes manifests as templates with a values file, so one chart can be deployed with different settings, and every deployment becomes a numbered revision I can inspect and roll back. values.yaml holds everything that varies (image tag, replicas, resources, hostnames, feature switches like the bundled database); the templates hold the structure. Helm renders templates into plain YAML, and the cluster only ever sees plain Kubernetes objects."

## 2. install vs upgrade vs rollback

1. **What:** `install` creates a release; `upgrade` creates a new revision of it; `upgrade --install` does whichever is needed; `rollback N` re-applies revision N's manifest as a new revision.
2. **Why:** the same command works for the first deployment and every later one (idempotent deployment command).
3. **Problem solved:** "is this a first deploy or an update?" logic in scripts; no audit trail.
4. **How it works:** `--wait` (in Helm 4: the *watcher* strategy, kstatus) returns only when every resource is ready; `--wait-for-jobs` also waits for Jobs to complete; failure after `--timeout` marks the revision *failed*. `rollback` does not rewind the cluster's history: it deploys the old manifest as revision N+1. It does not roll back the database schema either, which is why migrations must be backward compatible.
5. **Commands:** `make deploy-helm ARGS="--set image.tag=<commit>"` · `make helm-history` · `helm -n epiconnect rollback epiconnect <rev>`
6. **What can go wrong:** a release stuck in `pending-upgrade` after an interrupted command; a rollback to a version whose code does not understand the newer schema.
7. **Troubleshoot:** `helm -n epiconnect status epiconnect`; `helm history`; for a stuck release, roll back to the last `deployed` revision.
8. **Interview:** "Helm install vs upgrade? How do you roll back?"
9. **Answer:** "install creates the release, upgrade adds a revision; I always use upgrade --install so the same command works every time. helm rollback redeploys an earlier revision's manifest as a new revision. It restores the Kubernetes objects, not the data, so database migrations have to stay backward compatible."

## 3. Templating details worth knowing

1. **What:** named templates in `_helpers.tpl` (`define`/`include`), `nindent` for indentation, `toYaml` for structured values, `default` for fallbacks, `range` for loops.
2. **Why / 3. Problem solved:** one definition of the security context and secret env, reused by the Deployment, both Jobs and the init container.
4. **How it works:** `include "name" .` renders a named template to a string, and `| nindent 8` indents it to the right YAML depth. The context (`.`) must be passed explicitly: inside `range` it changes, which is why `jobs.yaml` uses `$` (the root context). `checksum/config` is the SHA-256 of the rendered ConfigMap put in the pod template: when any config value changes, the pod template changes, and Kubernetes rolls the pods. Without it, pods would keep the old environment variables forever.
5. **Commands:** `helm template epiconnect helm/epiconnect --set replicaCount=2 --show-only templates/deployment.yaml`
6. **What can go wrong:** wrong `nindent` → YAML that parses into the wrong structure; using `.` inside `range` instead of `$`.
7. **Troubleshoot:** render one file with `--show-only`; compare with the raw manifest.
8. **Interview:** "Why not just use YAML?" · "How do you make pods pick up a changed ConfigMap?"
9. **Answer:** "Plain YAML is fine for one environment. Here it already repeated the image tag four times and the security settings in four pod templates, and every release needed hand edits. With Helm those live once in values and helpers. For ConfigMap changes, env vars are read at start, so I add a checksum of the ConfigMap to the pod template annotations; a config change changes the template and triggers a rolling update."

## 4. Migrating a live deployment into Helm (adoption)

1. **What:** `scripts/adopt-into-helm.sh` labels/annotates the objects created by `kubectl apply` so the first `helm upgrade --install` takes them over instead of failing with "resource already exists".
2. **Why:** deleting and recreating would lose the database volume's binding and cause downtime.
3. **Problem solved:** introducing Helm to a system that is already running, which is the realistic case.
4. **How it works:** Helm accepts an existing object only if it has `app.kubernetes.io/managed-by=Helm` and the annotations `meta.helm.sh/release-name`/`release-namespace` naming this release. The chart was written to render *the same names, selectors and volumeClaimTemplates* as the raw manifests (checked field by field before delivery): selectors and StatefulSet claim templates are immutable, so any difference would make the upgrade fail. Because Helm 4 uses server-side apply, the adopted objects' fields are still owned by `kubectl`; the first, adopting deploy passes `--force-conflicts` so the release becomes their owner (later upgrades do not, so hand edits surface as conflicts). Result: PostgreSQL's pod template is unchanged (no restart); the Deployment gets the new checksum annotation, so its pods roll once, with zero downtime (`maxUnavailable: 0`).
5. **Commands:** `make helm-diff` (before) · `make deploy-helm` · `kubectl -n epiconnect get statefulset postgres -o jsonpath='{.metadata.annotations}'`
6. **What can go wrong:** `invalid ownership metadata` (object not annotated), `spec: Forbidden: updates to statefulset spec...` (an immutable field differs).
7. **Troubleshoot:** the error names the object and field; compare `helm template` output with `kubectl get -o yaml`.
8. **Interview:** "How would you move an existing application to Helm without downtime?"
9. **Answer:** "Write the chart to render exactly the existing objects (same names, selectors, and anything immutable), diff it against the live cluster, then add Helm's ownership label and annotations to the existing objects so the first upgrade adopts them instead of recreating them. The database kept its volume and was not restarted; the web tier did one zero-downtime rolling update."

## 5. What deliberately stays outside the chart

1. **What:** the Namespace (with its Pod Security label) and the Secrets.
2. **Why:** the namespace policy is a platform decision, not the application's; secret values passed as Helm values end up in the release history Secret and in shell history.
3. **How it works:** the chart takes `existingSecret: epiconnect-secrets` and only references key names.
4. **Interview:** "How do you handle secrets with Helm?"
5. **Answer:** "The chart never receives secret values; it references an existing Secret by name. The Secret is created by a separate process (a script here; External Secrets or Sealed Secrets in a team), so values are not stored in Helm's release history or passed on the command line."

---

## Study checkpoint (Milestone 5)

- [ ] Chart vs release vs revision; where Helm stores release history.
- [ ] What `helm template`, `helm lint`, `helm upgrade --install --wait --wait-for-jobs` each do.
- [ ] Why the Jobs have the revision in their name, and why there are no Helm hooks.
- [ ] What the `checksum/config` annotation is for.
- [ ] How the running app was adopted by Helm, and why immutable fields had to match.
- [ ] Why Secrets and the Namespace are not in the chart.
- [ ] What `helm rollback` does and does not restore.

Run these yourself:
```bash
make helm-check
helm template epiconnect helm/epiconnect -n epiconnect --show-only templates/deployment.yaml | head -40
helm template epiconnect helm/epiconnect -n epiconnect --set replicaCount=2 --set postgres.enabled=false | grep -E "^kind:|replicas:"
make helm-history
helm -n epiconnect get values epiconnect --all | head -20
kubectl -n epiconnect get secrets -l owner=helm
```
