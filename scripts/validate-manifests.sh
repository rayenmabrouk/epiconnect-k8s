#!/usr/bin/env bash
# Offline validation of everything that is applied to the cluster. Needs no
# cluster, so it runs in CI and on the control machine alike.
#
#   1. kubernetes/*.yaml             against the Kubernetes API schemas
#   2. helm lint --strict            chart structure, templates, values
#   3. helm template (lab values)    against the same schemas
#   4. helm template (CI values)     against the same schemas
#
# Schemas are those of the cluster's exact version, in strict mode: a typo in a
# field name ("replica: 3", "livenessprobe") is an error, not silently ignored.
# `make helm-check` goes further (server-side dry run with admission, e.g. Pod
# Security), but needs the live cluster.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

K8S_VERSION="${K8S_VERSION:-1.36.4}"   # = k3s v1.36.4+k3s1
chart=helm/epiconnect
kc=(kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}")

echo "== raw manifests (kubernetes/)"
find kubernetes -name '*.yaml' -print0 | sort -z | xargs -0 "${kc[@]}"

echo "== helm lint"
helm lint "${chart}" --strict
helm lint "${chart}" --strict --values "${chart}/ci/smoke-values.yaml"

echo "== chart rendered with the lab values"
helm template epiconnect "${chart}" --namespace epiconnect | "${kc[@]}" -

echo "== chart rendered with the CI smoke-test values"
helm template epiconnect "${chart}" --namespace epiconnect \
  --values "${chart}/ci/smoke-values.yaml" | "${kc[@]}" -
