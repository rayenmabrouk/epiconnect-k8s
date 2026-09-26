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
# It also removes kubectl's field-ownership records (metadata.managedFields
# entries of managers named kubectl*). Helm 4 applies with server-side apply:
# a field still co-owned by "kubectl-client-side-apply" makes every later
# change to it a conflict ("Apply failed with 2 conflicts ... image"), even
# after a --force-conflicts deploy, because forcing only takes over fields
# whose values differ; fields with equal values stay shared. Removing the
# records leaves those fields unowned, so Helm becomes their only owner on its
# next apply. Controller entries (k3s, kube-controller-manager) are kept.
#
# Safe to re-run.
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

# Keep every managedFields entry except kubectl's. An empty list would be
# ignored by the API server; [{}] is the documented way to clear the field.
drop_kubectl_ownership() {  # drop_kubectl_ownership <kubectl args...> <object>
  local obj="${*: -1}" args=("${@:1:$#-1}") kept
  kept="$(kubectl "${args[@]}" get "${obj}" --show-managed-fields -o json \
    | jq -c '[.metadata.managedFields[] | select(.manager | startswith("kubectl") | not)] | if length == 0 then [{}] else . end')"
  kubectl "${args[@]}" patch "${obj}" --type=json \
    -p "[{\"op\": \"replace\", \"path\": \"/metadata/managedFields\", \"value\": ${kept}}]" >/dev/null
}

adopt() {  # adopt <kubectl namespace args...> <object>
  local obj="${*: -1}" args=("${@:1:$#-1}") owner
  kubectl "${args[@]}" get "${obj}" >/dev/null 2>&1 || { echo "  ${obj}: not present (fresh install)"; return 0; }
  owner="$(kubectl "${args[@]}" get "${obj}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')"
  if [[ "${owner}" == "${release}" ]]; then
    echo -n "  ${obj}: already in release ${release}"
  else
    kubectl "${args[@]}" annotate "${obj}" --overwrite \
      "meta.helm.sh/release-name=${release}" "meta.helm.sh/release-namespace=${ns}" >/dev/null
    kubectl "${args[@]}" label "${obj}" --overwrite app.kubernetes.io/managed-by=Helm >/dev/null
    echo -n "  ${obj}: adopted"
  fi
  drop_kubectl_ownership "${args[@]}" "${obj}"
  echo ", field managers now: $(kubectl "${args[@]}" get "${obj}" --show-managed-fields \
    -o jsonpath='{.metadata.managedFields[*].manager}')"
}

echo "==> Adopting existing objects into Helm release '${release}' (namespace ${ns})"
for obj in "${namespaced[@]}"; do adopt -n "${ns}" "${obj}"; done
adopt persistentvolume/epiconnect-media        # cluster-scoped

echo "==> Removing the raw deployment's one-off Jobs (the chart creates its own)"
kubectl -n "${ns}" delete job epiconnect-migrate epiconnect-bootstrap-admin --ignore-not-found
