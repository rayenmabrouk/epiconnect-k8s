#!/usr/bin/env bash
# Deploys (or upgrades) EPIConnect with the Helm chart.
#
#   scripts/deploy-helm.sh                          chart defaults (pinned image)
#   scripts/deploy-helm.sh --set image.tag=<commit> any helm upgrade option
#
# Namespace and Secrets stay outside the chart: the namespace carries the Pod
# Security policy (a platform decision), and secret values must never pass
# through Helm values or release history.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ns=epiconnect
release=epiconnect

kubectl apply -f kubernetes/namespace.yaml
for s in epiconnect-secrets epiconnect-tls; do
  kubectl -n "${ns}" get secret "${s}" >/dev/null 2>&1 \
    || { echo "Secret ${s} missing: run 'make secrets' and 'make tls' first" >&2; exit 1; }
done

# First Helm deployment over a raw-manifest deployment: adopt, don't recreate.
# Helm 4 applies objects with server-side apply, which records an owner
# ("field manager") per field. The adopted objects' fields are owned by
# kubectl; --force-conflicts makes the Helm release their owner. Only on this
# first run: afterwards a conflict means someone changed the live objects by
# hand, and that should stop the upgrade rather than be overwritten silently.
first_run_args=()
if ! helm -n "${ns}" status "${release}" >/dev/null 2>&1; then
  scripts/adopt-into-helm.sh
  first_run_args=(--force-conflicts)
fi

# --wait / --wait-for-jobs: return only when the Deployment and StatefulSet
# are ready and the migration Job has completed (or fail after the timeout)
helm upgrade --install "${release}" helm/epiconnect \
  --namespace "${ns}" --wait --wait-for-jobs --timeout 10m "${first_run_args[@]}" "$@"

kubectl -n "${ns}" get pods -o wide
helm -n "${ns}" history "${release}" --max 5
