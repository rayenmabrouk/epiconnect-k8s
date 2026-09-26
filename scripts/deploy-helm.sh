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

# First Helm deployment over a raw-manifest deployment: adopt, don't recreate
# (labels/annotations Helm requires + kubectl's field ownership removed, see
# scripts/adopt-into-helm.sh).
if ! helm -n "${ns}" status "${release}" >/dev/null 2>&1; then
  scripts/adopt-into-helm.sh
fi

# --wait / --wait-for-jobs: return only when the Deployment and StatefulSet
# are ready and the migration Job has completed (or fail after the timeout)
helm upgrade --install "${release}" helm/epiconnect \
  --namespace "${ns}" --wait --wait-for-jobs --timeout 10m "$@"

kubectl -n "${ns}" get pods -o wide
helm -n "${ns}" history "${release}" --max 5
