#!/usr/bin/env bash
# Demo 1 - Rolling update from version A to version B without downtime.
#
# While a client sends a request every 0.2 s through the Ingress, the Helm
# release is upgraded to another image tag. The Deployment replaces the web
# pods one at a time (maxSurge 1, maxUnavailable 0): a new pod only receives
# traffic once its readiness probe passes, and an old pod leaves the Service
# endpoints before it stops (preStop sleep), so no request should fail.
#
#   demos/01-rolling-update.sh [tag]     default: b38f31a (built by CI with app_ref)
#
# Evidence: evidence/01-rolling-update/ (summary.md, requests.log, pods.log, upgrade.log)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ns=epiconnect
host=epiconnect.lab
node_ip=192.168.50.10          # ServiceLB answers on every node; any one will do
repo=rayenmabrouk/epiconnect
new_tag="${1:-b38f31a}"
out=evidence/01-rolling-update
mkdir -p "${out}"
ts() { date '+%H:%M:%S.%3N'; }

old_image="$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.spec.template.spec.containers[0].image}')"
old_tag="${old_image##*:}"
[[ "${old_tag}" != "${new_tag}" ]] || { echo "already running ${new_tag}; pass another tag" >&2; exit 1; }

# Fail before touching anything if the new image was never published
token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token)"
curl -fsS -o /dev/null -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "https://ghcr.io/v2/${repo}/manifests/${new_tag}" \
  || { echo "ghcr.io/${repo}:${new_tag} not found: run the CI workflow with app_ref=${new_tag} first" >&2; exit 1; }

echo "==> ${old_tag} -> ${new_tag}"

# Client: one request every 0.2 s, one line per request: time, HTTP code
# (-k: this measures availability, not certificate trust)
(
  while :; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
      --resolve "${host}:443:${node_ip}" "https://${host}/" || true)"
    echo "$(ts) ${code}"
    sleep 0.2
  done
) > "${out}/requests.log" &
client=$!

# Observer: how many web pods run each version and how many of them are Ready,
# one line per change
(
  last=""
  while :; do
    state="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o jsonpath='{range .items[*]}{.spec.containers[0].image}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
      | awk '{split($1, a, ":"); total[a[2]]++; if ($2 == "true") ready[a[2]]++}
             END {for (t in total) printf "%s: %d pods, %d ready   ", t, total[t], ready[t] + 0}')"
    [[ "${state}" == "${last}" ]] || { echo "$(ts) ${state}"; last="${state}"; }
    sleep 1
  done
) > "${out}/pods.log" &
observer=$!
trap 'kill ${client} ${observer} 2>/dev/null || true' EXIT

sleep 5                                    # baseline: traffic before the change
start=$(date +%s)
scripts/deploy-helm.sh --set image.tag="${new_tag}" 2>&1 | tee "${out}/upgrade.log"
duration=$(( $(date +%s) - start ))
# helm --wait returns when the new pods are Ready; the old ones are still
# draining (preStop sleep, then graceful shutdown). Their termination is the
# riskiest moment for in-flight requests, so keep measuring until they are gone.
web_images() {
  kubectl -n ${ns} get pods -l app.kubernetes.io/component=web \
    -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
}
for _ in $(seq 1 60); do
  [[ "$(web_images)" == *":${old_tag}"* ]] || break
  sleep 2
done
sleep 5                                    # traffic after the last old pod is gone
kill "${client}" "${observer}" 2>/dev/null || true
wait 2>/dev/null || true

total=$(wc -l < "${out}/requests.log")
ok=$(awk '$2 == "200"' "${out}/requests.log" | wc -l)
failed=$(( total - ok ))
images="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort | uniq -c)"
ready="$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
on_new=$(web_images | grep -c ":${new_tag}$" || true)

{
  echo "# Demo 1 - Rolling update without downtime"
  echo
  echo "- Date (UTC): $(date -u '+%Y-%m-%d %H:%M')"
  echo "- Version A: \`${old_image}\`"
  echo "- Version B: \`ghcr.io/${repo}:${new_tag}\` (built, scanned and smoke-tested by CI)"
  echo "- Strategy: RollingUpdate, maxSurge 1, maxUnavailable 0; readiness on \`/readyz/\`; preStop sleep 5 s"
  echo "- Upgrade (\`make deploy-helm ARGS=\"--set image.tag=${new_tag}\"\`, incl. migration Job): ${duration} s"
  echo
  echo "## Client view"
  echo
  echo "One HTTPS request every 0.2 s through Traefik, from 5 s before the upgrade until 5 s after the last old pod had terminated:"
  echo
  echo "- Requests: ${total}"
  echo "- HTTP 200: ${ok}"
  echo "- Failed or non-200: ${failed}"
  if [[ ${failed} -gt 0 ]]; then
    echo; echo '```'; awk '$2 != "200"' "${out}/requests.log"; echo '```'
  fi
  echo
  echo "## Pods, as they changed"
  echo
  echo '```'; cat "${out}/pods.log"; echo '```'
  echo
  echo "## After"
  echo
  echo '```'
  echo "${images}"
  echo "Ready: ${ready}"
  helm -n ${ns} history epiconnect --max 3
  echo '```'
  echo
  echo "(APP VERSION in the history is the chart's default appVersion; the image actually deployed is the image.tag value: helm -n ${ns} get values epiconnect)"
  echo
  if [[ ${failed} -eq 0 && "${on_new}" -ge 1 && "${ready%/*}" == "${ready#*/}" && "${images}" != *":${old_tag}"* ]]; then
    echo "**Result: PASS** - every web pod runs ${new_tag}, and none of the ${total} requests failed during the update."
  else
    echo "**Result: FAIL** - see the logs in this folder."
  fi
} > "${out}/summary.md"

cat "${out}/summary.md"
