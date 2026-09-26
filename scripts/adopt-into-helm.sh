#!/usr/bin/env bash
# Hands the objects created by `make deploy-manifests` over to the Helm
# release, so the switch from raw YAML to Helm happens in place: no deletion,
# no downtime, the database and uploaded files stay where they are.
#
# Helm refuses to touch an object it did not create unless the object carries
#   label       app.kubernetes.io/managed-by=Helm
#   annotations meta.helm.sh/release-name / meta.helm.sh/release-namespace
# This script adds exactly those, then removes the two one-off Jobs of the
# raw deployment (the chart runs its own, one per release revision).
#
# Safe to re-run: objects already owned by the release are left as they are.
set -euo pipefail

release="${RELEASE:-epiconnect}"
ns="${NAMESPACE:-epiconnect}"

namespaced=(
  configmap/epiconnect-config serviceaccount/epiconnect pvc/epiconnect-media
  service/postgres statefulset/postgres
  deployment/epiconnect service/epiconnect ingress/epiconnect
  networkpolicy/default-deny-all networkpolicy/allow-dns-egress networkpolicy/web-from-ingress
  networkpolicy/postgres-from-db-clients networkpolicy/db-clients-to-postgres
)

adopt() {  # adopt <kubectl namespace args...> <object>
  local obj="${*: -1}" args=("${@:1:$#-1}") owner
  kubectl "${args[@]}" get "${obj}" >/dev/null 2>&1 || { echo "  ${obj}: not present (fresh install)"; return 0; }
  owner="$(kubectl "${args[@]}" get "${obj}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')"
  if [[ "${owner}" == "${release}" ]]; then echo "  ${obj}: already in release ${release}"; return 0; fi
  kubectl "${args[@]}" annotate "${obj}" --overwrite \
    "meta.helm.sh/release-name=${release}" "meta.helm.sh/release-namespace=${ns}" >/dev/null
  kubectl "${args[@]}" label "${obj}" --overwrite app.kubernetes.io/managed-by=Helm >/dev/null
  echo "  ${obj}: adopted"
}

echo "==> Adopting existing objects into Helm release '${release}' (namespace ${ns})"
for obj in "${namespaced[@]}"; do adopt -n "${ns}" "${obj}"; done
adopt persistentvolume/epiconnect-media        # cluster-scoped

echo "==> Removing the raw deployment's one-off Jobs (the chart creates its own)"
kubectl -n "${ns}" delete job epiconnect-migrate epiconnect-bootstrap-admin --ignore-not-found
