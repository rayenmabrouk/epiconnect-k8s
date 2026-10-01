#!/usr/bin/env bash
# Demo 3 - A worker node crashes; its pods are rescheduled on the other worker.
#
# The app worker that hosts web pods (and, if possible, none of the
# single-replica platform pods: Traefik, CoreDNS) is powered off hard, like a
# power cut. Then, under continuous traffic:
#   ~40 s  the node controller stops receiving the kubelet's heartbeat and
#          marks the node NotReady; its pods become NotReady too, so they leave
#          the Service endpoints
#   +30 s  the pods' toleration of the "unreachable" taint expires (the chart
#          sets 30 s instead of the default 300 s): they are evicted and the
#          Deployment creates replacements on the surviving worker, which can
#          mount the same uploads volume because it is NFS (ReadWriteMany)
# The old pods stay "Terminating" until the node comes back: the API server
# cannot confirm they stopped on a machine it cannot reach.
#
#   demos/03-worker-failure.sh [node]     default: chosen automatically
#
# Evidence: evidence/03-worker-failure/
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=demos/lib.sh
source demos/lib.sh

out=evidence/03-worker-failure
mkdir -p "${out}"
trap 'stop_background; kill "${nodes_pid:-}" 2>/dev/null || true' EXIT

[[ "$(web_ready)" == 3 ]] || { echo "expected 3 Ready web pods before starting" >&2; exit 1; }
[[ "$(kubectl get nodes --no-headers | grep -c ' Ready ')" == 3 ]] || { echo "expected 3 Ready nodes" >&2; exit 1; }

pods_on() {  # number of pods matching <selector> in <namespace> on <node>
  kubectl -n "$2" get pods -l "$1" --field-selector "spec.nodeName=$3" --no-headers 2>/dev/null | wc -l
}
victim="${1:-}"
if [[ -z "${victim}" ]]; then
  for n in $(kubectl get nodes -l epiconnect.io/pool=app -o jsonpath='{.items[*].metadata.name}'); do
    if [[ $(pods_on app.kubernetes.io/component=web epiconnect "${n}") -gt 0 \
       && $(pods_on app.kubernetes.io/name=traefik kube-system "${n}") -eq 0 \
       && $(pods_on k8s-app=kube-dns kube-system "${n}") -eq 0 ]]; then victim="${n}"; break; fi
  done
fi
[[ -n "${victim}" ]] || { echo "no app worker hosts web pods without also hosting Traefik or CoreDNS; pass a node name to force one" >&2; exit 1; }
platform="$(kubectl -n kube-system get pods -l 'app.kubernetes.io/name in (traefik)' -o wide --no-headers; kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide --no-headers)"
before="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o wide)"
echo "==> Powering off ${victim} ($(pods_on app.kubernetes.io/component=web epiconnect "${victim}") web pod(s) on it)"

start_client "${out}/requests.log"
start_observer "${out}/pods.log"
(
  last=""
  while :; do
    s="$(kubectl get nodes --no-headers --request-timeout=5s 2>/dev/null | awk '{printf "%s=%s  ", $1, $2}')"
    [[ "${s}" == "${last}" ]] || { echo "$(ts) ${s}"; last="${s}"; }
    sleep 1
  done
) > "${out}/nodes.log" &
nodes_pid=$!
sleep 5

t_off="$(ts)"; s_off=$(date +%s)
make --no-print-directory poweroff NODE="${victim}"

# Node NotReady
s_notready=""
for _ in $(seq 1 120); do
  [[ "$(kubectl get node "${victim}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ]] \
    && { s_notready=$(date +%s); break; }
  sleep 2
done
# 3 Ready web pods, none on the victim
s_recovered=""
for _ in $(seq 1 120); do
  live="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.containerStatuses[0].ready}{" "}{.metadata.deletionTimestamp}{"\n"}{end}')"
  ready_elsewhere=$(awk -v v="${victim}" '$1 != v && $2 == "true" && $3 == ""' <<<"${live}" | wc -l)
  [[ ${ready_elsewhere} -ge 3 ]] && { s_recovered=$(date +%s); break; }
  sleep 2
done
t_recovered="$(ts)"
sleep 10
during="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o wide)"
stop_background
kill "${nodes_pid}" 2>/dev/null || true

echo "==> Starting ${victim} again"
make --no-print-directory start NODE="${victim}"
kubectl wait --for=condition=Ready "node/${victim}" --timeout=300s
sleep 15
after="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o wide)"

total=$(wc -l < "${out}/requests.log")
failed=$(awk '$2 != "200"' "${out}/requests.log" | wc -l)
first_fail="$(awk '$2 != "200" {print $1; exit}' "${out}/requests.log")"
last_fail="$(awk '$2 != "200" {t = $1} END {print t}' "${out}/requests.log")"
ok_end=$(tail -10 "${out}/requests.log" | awk '$2 == "200"' | wc -l)
pass=false
[[ -n "${s_recovered}" && ${ok_end} -ge 9 ]] && pass=true

{
  echo "# Demo 3 - Worker node failure and rescheduling"
  echo
  echo "- Date (UTC): $(date -u '+%Y-%m-%d %H:%M')"
  echo "- Node powered off (hard, Hyper-V TurnOff): **${victim}** at ${t_off}"
  echo "- Node marked NotReady after: **$(( ${s_notready:-0} - s_off )) s**"
  echo "- 3 web pods Ready again on the surviving nodes after: **$(( ${s_recovered:-0} - s_off )) s** (${t_recovered})"
  echo
  echo "## Client view"
  echo
  echo "One HTTPS request every 0.2 s through Traefik on k3s-server:"
  echo
  echo "- Requests: ${total}; not 200: **${failed}** ($(count_codes "${out}/requests.log"))"
  [[ ${failed} -eq 0 ]] || echo "- Failures between ${first_fail} and ${last_fail}: requests routed to pods on the dead node until it was declared NotReady (\`000\` = no answer within 3 s)"
  echo "- Last 10 requests: ${ok_end} x 200"
  echo
  echo "## Timeline"
  echo
  echo '```'; sort "${out}/nodes.log" "${out}/pods.log"; echo '```'
  echo
  echo "## Pods"
  echo
  echo "Before:"; echo; echo '```'; echo "${before}"; echo '```'
  echo "After rescheduling, ${victim} still down (its pods cannot be confirmed stopped, so they stay Terminating):"
  echo; echo '```'; echo "${during}"; echo '```'
  echo "After ${victim} came back (Kubernetes does not move running pods back: no automatic rebalancing):"
  echo; echo '```'; echo "${after}"; echo '```'
  echo
  echo "Single-replica platform pods at the start (k3s defaults; a node hosting them was not chosen):"
  echo; echo '```'; echo "${platform}"; echo '```'
  echo
  if ${pass}; then
    echo "**Result: PASS** - the web tier recovered on the surviving worker without intervention."
  else
    echo "**Result: FAIL** - see the logs in this folder."
  fi
} > "${out}/summary.md"

cat "${out}/summary.md"
