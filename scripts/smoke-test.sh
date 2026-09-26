#!/usr/bin/env bash
# Smoke test of the Helm chart and the application image on a throwaway k3d
# cluster (k3s nodes running as Docker containers). Runs in CI on every push.
#
# What it proves: on a real Kubernetes API server of the lab's version, with
# Pod Security "restricted" and NetworkPolicy enforcement, the chart installs,
# migrations run, the app becomes Ready and serves HTTPS through Traefik, the
# database is isolated, and upgrade + rollback work.
# What it does not prove: anything about the lab cluster (never contacted),
# NFS/ReadWriteMany (no NFS server here), node failures (single agent).
#
#   scripts/smoke-test.sh [image tag]    default: the chart's appVersion
#   KEEP_CLUSTER=1 scripts/smoke-test.sh  leave the cluster up for inspection
#
# Needs docker, k3d, kubectl, helm, jq, openssl, curl. A local image with the
# same name is imported into the cluster (CI tests the image it just built);
# otherwise the nodes pull it from GHCR.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

cluster=epiconnect-smoke
k3s_image=rancher/k3s:v1.36.4-k3s1       # the lab's k3s version
ns=epiconnect
release=epiconnect
chart=helm/epiconnect
host=epiconnect.lab
http_port=8080
https_port=8443
tag="${1:-$(helm show chart "${chart}" | awk '/^appVersion:/ {gsub(/"/, "", $2); print $2}')}"
image="$(helm show values "${chart}" | awk '/^  repository:/ {print $2; exit}'):${tag}"

work="$(mktemp -d)"
# A private kubeconfig: this script can never reach the lab cluster, whatever
# KUBECONFIG says in the calling shell.
export KUBECONFIG="${work}/kubeconfig"
passed=()

step() { printf '\n== %s\n' "$*"; }
pass() { passed+=("$*"); echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

diagnostics() {
  echo "---- diagnostics"
  kubectl get nodes -o wide --show-labels || true
  kubectl -n "${ns}" get all,pvc,ingress,networkpolicy -o wide || true
  kubectl -n "${ns}" get events --sort-by=.lastTimestamp | tail -40 || true
  for pod in $(kubectl -n "${ns}" get pods -o name 2>/dev/null); do
    echo "---- logs ${pod}"
    kubectl -n "${ns}" logs "${pod}" --all-containers --tail=40 || true
  done
  helm -n "${ns}" history "${release}" || true
}

finish() {
  local rc=$?
  [[ ${rc} -eq 0 ]] || diagnostics
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Smoke test on k3d (${k3s_image##*:}), image \`${image}\`"
      echo
      for p in "${passed[@]}"; do echo "- ${p}"; done
      [[ ${rc} -eq 0 ]] || echo "- **FAILED** (diagnostics in the job log)"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  if [[ "${KEEP_CLUSTER:-0}" != 1 ]]; then
    k3d cluster delete "${cluster}" >/dev/null 2>&1 || true
  else
    echo "cluster kept: KUBECONFIG=${KUBECONFIG} kubectl get pods -A; k3d cluster delete ${cluster}"
  fi
  [[ "${KEEP_CLUSTER:-0}" == 1 ]] || rm -rf "${work}"
  exit "${rc}"
}
trap finish EXIT

# curl through Traefik: https://epiconnect.lab:8443 -> 127.0.0.1 (k3d load balancer)
https_code() {
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${host}:${https_port}:127.0.0.1" "https://${host}:${https_port}$1" || true
}

step "Cluster: 1 server (pool=data) + 1 agent (pool=app), k3s ${k3s_image##*:}"
k3d cluster delete "${cluster}" >/dev/null 2>&1 || true
k3d cluster create "${cluster}" --image "${k3s_image}" --agents 1 \
  --port "${http_port}:80@loadbalancer" --port "${https_port}:443@loadbalancer" \
  --kubeconfig-update-default=false --wait --timeout 180s
k3d kubeconfig get "${cluster}" > "${KUBECONFIG}"
kubectl label node "k3d-${cluster}-server-0" epiconnect.io/pool=data
kubectl label node "k3d-${cluster}-agent-0" epiconnect.io/pool=app
if docker image inspect "${image}" >/dev/null 2>&1; then
  k3d image import "${image}" --cluster "${cluster}"
  echo "imported local image ${image}"
fi

step "Namespace and Secrets (created outside the chart, as in the lab)"
kubectl apply -f kubernetes/namespace.yaml
kubectl -n "${ns}" create secret generic epiconnect-secrets \
  --from-literal=django-secret-key="$(openssl rand -hex 32)" \
  --from-literal=db-password="$(openssl rand -hex 24)" \
  --from-literal=admin-password="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=${host}" \
  -addext "subjectAltName=DNS:${host}" -keyout "${work}/tls.key" -out "${work}/tls.crt" 2>/dev/null
kubectl -n "${ns}" create secret tls epiconnect-tls --cert="${work}/tls.crt" --key="${work}/tls.key"

step "Install ${image}"
helm upgrade --install "${release}" "${chart}" --namespace "${ns}" \
  --values "${chart}/ci/smoke-values.yaml" --set image.tag="${tag}" \
  --wait --wait-for-jobs --timeout 10m
[[ "$(helm -n "${ns}" status "${release}" -o json | jq -r .info.status)" == deployed ]] || fail "release not deployed"
pass "helm install: migrations Job completed, PostgreSQL and all web pods Ready (restricted Pod Security)"

step "Scheduling"
web_nodes="$(kubectl -n "${ns}" get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[*].spec.nodeName}')"
db_node="$(kubectl -n "${ns}" get pod postgres-0 -o jsonpath='{.spec.nodeName}')"
echo "web pods on: ${web_nodes}; postgres-0 on: ${db_node}"
[[ "${db_node}" == "k3d-${cluster}-server-0" && "${web_nodes}" != *server* ]] || fail "nodeSelectors not honoured"
pass "nodeSelectors: web on the app pool, PostgreSQL on the data pool"

step "HTTPS through Traefik"
code=""
for _ in $(seq 1 30); do
  code="$(https_code /readyz/)"; [[ "${code}" == 200 ]] && break; sleep 2
done
[[ "${code}" == 200 ]] || fail "/readyz/ through the ingress returned ${code}"
home="$(https_code /)"
[[ "${home}" == 200 || "${home}" == 302 ]] || fail "home page returned ${home}"
redirect="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
  --resolve "${host}:${http_port}:127.0.0.1" "http://${host}:${http_port}/")"
[[ "${redirect}" == 301\ https://* ]] || fail "HTTP did not redirect to HTTPS: ${redirect}"
pass "ingress: /readyz/ 200 (database reachable), home page ${home}, HTTP -> HTTPS redirect"

step "NetworkPolicy"
# shellcheck source=scripts/lib/netpol-probe.sh
source scripts/lib/netpol-probe.sh
without="$(netpol_probe "${ns}" false)"
with="$(netpol_probe "${ns}" true)"
echo "without db-client label: ${without}"
echo "with db-client label:    ${with}"
[[ "${without}" == *dns=ok*BLOCKED* && "${with}" == *dns=ok*REACHABLE* ]] || fail "NetworkPolicy"
pass "NetworkPolicy: PostgreSQL reachable only from labelled clients (DNS works for both)"

step "Upgrade (configuration change)"
before="$(kubectl -n "${ns}" get deploy "${release}" -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')"
helm upgrade "${release}" "${chart}" --namespace "${ns}" \
  --values "${chart}/ci/smoke-values.yaml" --set image.tag="${tag}" --set config.LOG_LEVEL=DEBUG \
  --wait --wait-for-jobs --timeout 10m
after="$(kubectl -n "${ns}" get deploy "${release}" -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')"
[[ "${before}" != "${after}" ]] || fail "config checksum unchanged: pods would keep the old configuration"
kubectl -n "${ns}" get job "${release}-migrate-2" -o jsonpath='{.status.succeeded}' | grep -qx 1 || fail "migrate Job of revision 2"
[[ "$(https_code /readyz/)" == 200 ]] || fail "not ready after upgrade"
pass "upgrade: revision 2, new migration Job, config change rolled the web pods"

step "Rollback to revision 1"
helm rollback "${release}" 1 --namespace "${ns}" --wait --timeout 10m
[[ "$(kubectl -n "${ns}" get configmap "${release}-config" -o jsonpath='{.data.LOG_LEVEL}')" == INFO ]] || fail "config not rolled back"
kubectl -n "${ns}" rollout status deploy/"${release}" --timeout=5m
[[ "$(https_code /readyz/)" == 200 ]] || fail "not ready after rollback"
pass "rollback: revision 3 = revision 1's configuration, app Ready"

helm -n "${ns}" history "${release}"
printf '\nSMOKE TEST PASSED (%d checks)\n' "${#passed[@]}"
