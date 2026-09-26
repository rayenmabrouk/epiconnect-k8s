#!/usr/bin/env bash
# Demo 2 - Readiness: what happens when something is not ready, and recovery.
#
# Part A - dependency outage. PostgreSQL is stopped while a client sends
#   requests. The readiness probe (/readyz/, which queries the database) fails,
#   so every web pod leaves the Service and Traefik answers 503 at once instead
#   of letting requests hang. The liveness probe (/healthz/, no database) keeps
#   passing, so no pod is restarted: when PostgreSQL returns, the same pods
#   become Ready again by themselves. (Design decision D15.)
#
# Part B - bad release. An upgrade with a wrong setting (a typo in DB_HOST)
#   starts new pods that can never become Ready (they wait for the database in
#   their init container). maxUnavailable 0 keeps every old pod serving, the
#   upgrade fails after its timeout, and `helm rollback` restores the previous
#   revision. Users see nothing.
#
#   demos/02-readiness-and-rollback.sh
#
# Evidence: evidence/02-readiness-and-rollback/
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=demos/lib.sh
source demos/lib.sh

out=evidence/02-readiness-and-rollback
mkdir -p "${out}"
trap stop_background EXIT

[[ "$(web_ready)" == 3 ]] || { echo "expected 3 Ready web pods before starting" >&2; exit 1; }
image="$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.spec.template.spec.containers[0].image}')"

# ---------------------------------------------------------------- Part A
echo "==> Part A: PostgreSQL outage"
restarts_before="$(web_restarts)"
start_client "${out}/a-requests.log"
start_observer "${out}/a-pods.log"
sleep 5
a_stop="$(ts)"
kubectl -n ${ns} scale statefulset postgres --replicas=0
kubectl -n ${ns} wait --for=delete pod/postgres-0 --timeout=120s
for _ in $(seq 1 30); do [[ "$(web_ready)" == 0 ]] && break; sleep 2; done
a_all_out="$(ts)"; a_ready_during="$(web_ready)"
echo "web pods Ready during the outage: ${a_ready_during}; holding the outage 30 s"
sleep 30
a_start="$(ts)"
kubectl -n ${ns} scale statefulset postgres --replicas=1
kubectl -n ${ns} wait --for=condition=Ready pod/postgres-0 --timeout=180s
for _ in $(seq 1 60); do [[ "$(web_ready)" == 3 ]] && break; sleep 2; done
a_back="$(ts)"
sleep 5
stop_background
restarts_after="$(web_restarts)"
a_ok_end="$(tail -5 "${out}/a-requests.log" | awk '$2 == "200"' | wc -l)"

# `kubectl scale` recorded kubectl as owner of spec.replicas; hand it back to
# Helm so later upgrades do not conflict (see scripts/adopt-into-helm.sh)
scripts/adopt-into-helm.sh >/dev/null

# ---------------------------------------------------------------- Part B
echo "==> Part B: bad release, then rollback"
start_client "${out}/b-requests.log"
start_observer "${out}/b-pods.log"
sleep 5
b_upgrade_rc=0
scripts/deploy-helm.sh --set image.tag="${image##*:}" --set config.DB_HOST=postgres-typo --timeout 2m \
  > "${out}/b-upgrade.log" 2>&1 || b_upgrade_rc=$?
b_ready_during="$(web_ready)"
echo "upgrade exit code: ${b_upgrade_rc}; Ready web pods: ${b_ready_during}"
kubectl -n ${ns} get pods -o wide > "${out}/b-pods-after-failed-upgrade.txt"
helm -n ${ns} rollback epiconnect --wait --timeout 5m > "${out}/b-rollback.log" 2>&1
kubectl -n ${ns} rollout status deploy/epiconnect --timeout=5m
sleep 5
stop_background
db_host="$(kubectl -n ${ns} get configmap epiconnect-config -o jsonpath='{.data.DB_HOST}')"
image_after="$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.spec.template.spec.containers[0].image}')"
b_total=$(wc -l < "${out}/b-requests.log")
b_failed=$(awk '$2 != "200"' "${out}/b-requests.log" | wc -l)

# ---------------------------------------------------------------- Summary
a_pass=false; b_pass=false
[[ "${a_ready_during}" == 0 && "${restarts_after}" == "${restarts_before}" && "${a_ok_end}" -ge 4 ]] && a_pass=true
[[ "${b_upgrade_rc}" -ne 0 && "${b_failed}" -eq 0 && "${db_host}" == postgres && "${image_after}" == "${image}" ]] && b_pass=true

{
  echo "# Demo 2 - Readiness failure and recovery, bad release and rollback"
  echo
  echo "- Date (UTC): $(date -u '+%Y-%m-%d %H:%M')"
  echo "- Image: \`${image}\`"
  echo "- Probes: readiness \`/readyz/\` (runs \`SELECT 1\`) every 5 s, 2 failures; liveness \`/healthz/\` (no database)"
  echo
  echo "## A. PostgreSQL outage"
  echo
  echo "| Phase | Requests (HTTP code x count) |"
  echo "|---|---|"
  echo "| before (database up) | $(count_codes "${out}/a-requests.log" "" "${a_stop}") |"
  echo "| database stopping, pods leaving the Service | $(count_codes "${out}/a-requests.log" "${a_stop}" "${a_all_out}") |"
  echo "| outage (no Ready pod) | $(count_codes "${out}/a-requests.log" "${a_all_out}" "${a_start}") |"
  echo "| database restarting, pods rejoining | $(count_codes "${out}/a-requests.log" "${a_start}" "${a_back}") |"
  echo "| after | $(count_codes "${out}/a-requests.log" "${a_back}") |"
  echo
  echo "- Ready web pods during the outage: **${a_ready_during}** (all removed from the Service: Traefik answers 503 immediately)"
  echo "- Web container restarts: ${restarts_before} before, **${restarts_after} after** (liveness does not depend on the database)"
  echo "- Recovered without intervention on the web tier: $([[ "${a_ok_end}" -ge 4 ]] && echo yes || echo no)"
  echo
  echo '```'; cat "${out}/a-pods.log"; echo '```'
  echo
  echo "**Part A: $(${a_pass} && echo PASS || echo FAIL)**"
  echo
  echo "## B. Bad release (DB_HOST=postgres-typo), then rollback"
  echo
  echo "- \`helm upgrade\` exit code: ${b_upgrade_rc} (failed after its 2 min timeout: new pods never became Ready)"
  echo "- Ready web pods while the bad release was stuck: ${b_ready_during} (the old pods, maxUnavailable 0)"
  echo "- Requests during the whole part: ${b_total}, not 200: **${b_failed}**"
  echo "- After \`helm rollback\`: DB_HOST=\`${db_host}\`, image \`${image_after##*/}\`"
  echo
  echo '```'; cat "${out}/b-pods.log"; echo '```'
  echo
  echo "Pods while the bad release was stuck:"
  echo
  echo '```'; cat "${out}/b-pods-after-failed-upgrade.txt"; echo '```'
  echo
  echo '```'; helm -n ${ns} history epiconnect --max 3; echo '```'
  echo
  echo "**Part B: $(${b_pass} && echo PASS || echo FAIL)**"
  echo
  if ${a_pass} && ${b_pass}; then echo "**Result: PASS**"; else echo "**Result: FAIL** - see the logs in this folder."; fi
} > "${out}/summary.md"

cat "${out}/summary.md"
