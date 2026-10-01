#!/usr/bin/env bash
# Demo 4 - Database data survives the loss of its pod.
#
# A row is written to PostgreSQL, then the pod postgres-0 is deleted. The
# StatefulSet recreates a pod with the same name, which claims the same
# PersistentVolumeClaim (data-postgres-0) and therefore the same volume on the
# same node. The row is read back from the new pod.
#
# Contrast: the web pods are disposable (any replica, any node, no local
# state); the database pod has a stable identity and its own volume.
#
#   demos/04-database-persistence.sh
#
# Evidence: evidence/04-database-persistence/
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=demos/lib.sh
source demos/lib.sh

out=evidence/04-database-persistence
mkdir -p "${out}"
trap stop_background EXIT

psql() {  # psql <sql>: runs inside the postgres container, with its own credentials
  # shellcheck disable=SC2016  # expanded by the container's shell, not this one
  kubectl -n ${ns} exec postgres-0 -c postgres -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$1"
}
pod_facts() {
  kubectl -n ${ns} get pod postgres-0 \
    -o jsonpath='pod uid {.metadata.uid}, node {.spec.nodeName}, started {.status.startTime}'
}
volume_facts() {
  local pv
  pv="$(kubectl -n ${ns} get pvc data-postgres-0 -o jsonpath='{.spec.volumeName}')"
  echo "claim data-postgres-0 -> volume ${pv}, $(kubectl get pv "${pv}" \
    -o jsonpath='path {.spec.local.path}{.spec.hostPath.path}, reclaim policy {.spec.persistentVolumeReclaimPolicy}')"
}

[[ "$(kubectl -n ${ns} get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}')" == true ]] \
  || { echo "postgres-0 is not Ready" >&2; exit 1; }

marker="written $(date -u '+%Y-%m-%dT%H:%M:%SZ') nonce $(openssl rand -hex 6)"
echo "==> Writing: ${marker}"
psql "CREATE TABLE IF NOT EXISTS k8s_persistence_demo (id serial PRIMARY KEY, note text NOT NULL)" >/dev/null
psql "INSERT INTO k8s_persistence_demo (note) VALUES ('${marker}')" >/dev/null
users_before="$(psql 'SELECT count(*) FROM auth_user' 2>/dev/null || echo n/a)"
pod_before="$(pod_facts)"; vol_before="$(volume_facts)"

start_client "${out}/requests.log"
start_observer "${out}/pods.log"
sleep 5
echo "==> Deleting pod postgres-0"
s_del=$(date +%s)
old_uid="$(kubectl -n ${ns} get pod postgres-0 -o jsonpath='{.metadata.uid}')"
kubectl -n ${ns} delete pod postgres-0 --wait=true
# the StatefulSet controller recreates it within seconds; wait for the NEW pod
for _ in $(seq 1 150); do
  [[ "$(kubectl -n ${ns} get pod postgres-0 -o jsonpath='{.metadata.uid} {.status.containerStatuses[0].ready}' 2>/dev/null)" == *" true" \
     && "$(kubectl -n ${ns} get pod postgres-0 -o jsonpath='{.metadata.uid}')" != "${old_uid}" ]] && break
  sleep 2
done
s_ready=$(date +%s)
for _ in $(seq 1 60); do [[ "$(web_ready)" == 3 ]] && break; sleep 2; done
s_app=$(date +%s)
sleep 5
stop_background

read_back="$(psql "SELECT note FROM k8s_persistence_demo WHERE note = '${marker}'")"
users_after="$(psql 'SELECT count(*) FROM auth_user' 2>/dev/null || echo n/a)"
pod_after="$(pod_facts)"; vol_after="$(volume_facts)"
psql "DROP TABLE k8s_persistence_demo" >/dev/null     # leave the application database as it was
ok_end=$(tail -10 "${out}/requests.log" | awk '$2 == "200"' | wc -l)

pass=false
[[ "${read_back}" == "${marker}" && "${pod_before}" != "${pod_after}" && "${vol_before}" == "${vol_after}" && ${ok_end} -ge 9 ]] && pass=true

{
  echo "# Demo 4 - Database persistence across pod loss"
  echo
  echo "- Date (UTC): $(date -u '+%Y-%m-%d %H:%M')"
  echo "- Row written before: \`${marker}\`"
  echo "- Row read back from the new pod: \`${read_back:-<missing>}\`"
  echo "- Application users (auth_user): ${users_before} before, ${users_after} after"
  echo
  echo "| | Before | After |"
  echo "|---|---|---|"
  echo "| Pod | ${pod_before} | ${pod_after} |"
  echo "| Storage | ${vol_before} | ${vol_after} |"
  echo
  echo "- New postgres-0 Ready after: **$(( s_ready - s_del )) s**; all web pods Ready again after: $(( s_app - s_del )) s"
  echo "- Requests during the test: $(count_codes "${out}/requests.log")"
  echo "  (one database instance, so requests fail while it restarts: the web pods report not ready and leave the Service, then return by themselves, as in demo 2. High availability would need a replicated database, e.g. a PostgreSQL operator or a managed service.)"
  echo
  echo '```'; cat "${out}/pods.log"; echo '```'
  echo
  if ${pass}; then
    echo "**Result: PASS** - new pod, same volume, data intact."
  else
    echo "**Result: FAIL** - see the logs in this folder."
  fi
} > "${out}/summary.md"

cat "${out}/summary.md"
