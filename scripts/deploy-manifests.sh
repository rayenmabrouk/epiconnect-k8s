#!/usr/bin/env bash
# Deploys EPIConnect from the raw manifests in kubernetes/, in dependency order,
# waiting at each step so a failure stops the deployment where it happened:
#
#   namespace, config, identity, storage, network policies
#   -> PostgreSQL (wait until Ready)
#   -> migration Job (wait until Complete)
#   -> admin bootstrap Job
#   -> web Deployment, Service, Ingress (wait for the rollout)
#
# Re-running it is safe: unchanged objects are reported "unchanged".
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ns=epiconnect
m=kubernetes

step() { printf '\n==> %s\n' "$*"; }

# Waits for a Job to finish; on failure shows its logs and stops
wait_job() {
  local job="$1" timeout="${2:-600}" start
  start=$(date +%s)
  while true; do
    if [[ "$(kubectl -n "${ns}" get job "${job}" -o jsonpath='{.status.succeeded}')" == "1" ]]; then
      echo "job/${job} complete"; return 0
    fi
    if kubectl -n "${ns}" get job "${job}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' | grep -q True; then
      echo "job/${job} FAILED:" >&2
      kubectl -n "${ns}" logs "job/${job}" --all-containers --tail=50 >&2 || true
      return 1
    fi
    if (( $(date +%s) - start > timeout )); then
      echo "job/${job} did not finish within ${timeout}s" >&2
      kubectl -n "${ns}" describe job "${job}" | tail -20 >&2
      return 1
    fi
    sleep 3
  done
}

# Once the Helm release owns these objects, applying raw YAML over them would
# have two tools fighting over the same state
if command -v helm >/dev/null && helm -n "${ns}" status epiconnect >/dev/null 2>&1; then
  echo "EPIConnect is managed by the Helm release 'epiconnect' now: use 'make deploy-helm'." >&2
  exit 1
fi

step "Namespace, configuration, identity, storage, network policies"
kubectl apply -f "${m}/namespace.yaml"
for s in epiconnect-secrets epiconnect-tls; do
  kubectl -n "${ns}" get secret "${s}" >/dev/null 2>&1 \
    || { echo "Secret ${s} missing: run 'make secrets' and 'make tls' first" >&2; exit 1; }
done
kubectl apply -f "${m}/configmap.yaml" -f "${m}/serviceaccount.yaml" \
              -f "${m}/media-storage.yaml" -f "${m}/network-policy.yaml"

step "PostgreSQL"
kubectl apply -f "${m}/postgres/"
kubectl -n "${ns}" rollout status statefulset/postgres --timeout=300s

step "Database migrations (Job)"
# Jobs are immutable: delete the previous run so this release's image runs
kubectl -n "${ns}" delete job epiconnect-migrate --ignore-not-found --wait=true
kubectl apply -f "${m}/migration-job.yaml"
wait_job epiconnect-migrate

step "Admin account (Job, idempotent)"
kubectl -n "${ns}" delete job epiconnect-bootstrap-admin --ignore-not-found --wait=true
kubectl apply -f "${m}/admin-job.yaml"
wait_job epiconnect-bootstrap-admin

step "Web tier"
kubectl apply -f "${m}/deployment.yaml" -f "${m}/service.yaml" -f "${m}/ingress.yaml"
kubectl -n "${ns}" rollout status deployment/epiconnect --timeout=300s

step "Result"
kubectl -n "${ns}" get pods -o wide
echo
echo "Open https://epiconnect.lab (needs the hosts entry: make host-init) - admin password: ~/.config/epiconnect-k8s/admin-password"
