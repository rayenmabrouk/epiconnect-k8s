# shellcheck shell=bash
# Shared by the failure demos (02-04): a client that measures availability
# and an observer that records the state of the pods, both in the background.
ns=epiconnect
host=epiconnect.lab
node_ip=192.168.50.10          # the server node: stays up in every demo
ts() { date '+%H:%M:%S.%3N'; }

# One HTTPS request every 0.2 s through the Ingress; one line per request:
# time, HTTP code (000 = no response within 3 s). -k: this measures
# availability, not certificate trust.
start_client() {  # start_client <log file>
  (
    while :; do
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 \
        --resolve "${host}:443:${node_ip}" "https://${host}/" || true)"
      echo "$(ts) ${code}"
      sleep 0.2
    done
  ) > "$1" &
  client_pid=$!
}

# Web pods: how many Ready, total restarts, which nodes; PostgreSQL: Ready or
# not. One line each time something changes.
cluster_state() {
  local web pg
  web="$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web --request-timeout=5s \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{.status.containerStatuses[0].restartCount}{" "}{.spec.nodeName}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {total++; if ($1 == "true") ready++; restarts += $2; if ($4 == "") node[$3]++}
           END {printf "web %d/%d ready, restarts %d, on", ready, total, restarts;
                for (n in node) printf " %s:%d", n, node[n]}')"
  pg="$(kubectl -n ${ns} get pod postgres-0 --request-timeout=5s \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  echo "${web} | postgres-0 $([[ "${pg}" == true ]] && echo ready || echo "not ready/absent")"
}

start_observer() {  # start_observer <log file>
  (
    last=""
    while :; do
      state="$(cluster_state)"
      [[ "${state}" == "${last}" ]] || { echo "$(ts) ${state}"; last="${state}"; }
      sleep 1
    done
  ) > "$1" &
  observer_pid=$!
}

stop_background() {
  kill "${client_pid:-}" "${observer_pid:-}" 2>/dev/null || true
  wait 2>/dev/null || true
}

# "200 x120  503 x14" for a request log, optionally between two times
count_codes() {  # count_codes <log> [from HH:MM:SS.mmm] [to HH:MM:SS.mmm]
  awk -v from="${2:-}" -v to="${3:-99}" '$1 >= from && $1 <= to {c[$2]++}
    END {for (k in c) printf "%s x%d  ", k, c[k]}' "$1"
}

web_ready() {  # number of Ready web pods (the field is absent, not 0, when none is Ready)
  local n
  n="$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  echo "${n:-0}"
}

# Wait until a pod exists AND is Ready. `kubectl wait` fails at once with
# NotFound if the pod has not been created yet, which is exactly the situation
# right after scaling a StatefulSet up.
wait_pod_ready() {  # wait_pod_ready <pod> [timeout seconds]
  local i
  for ((i = 0; i < ${2:-180} / 2; i++)); do
    [[ "$(kubectl -n ${ns} get pod "$1" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)" == true ]] && return 0
    sleep 2
  done
  echo "$1 not Ready after ${2:-180} s" >&2
  return 1
}

web_restarts() {
  kubectl -n ${ns} get pods -l app.kubernetes.io/component=web \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    | awk '{s += $1} END {print s + 0}'
}
