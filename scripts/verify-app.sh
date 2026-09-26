#!/usr/bin/env bash
# Milestone 4 - does the application ACTUALLY work on the cluster?
# Not "are the pods Running", but: can a request travel Ingress -> Service ->
# pod -> PostgreSQL and back, on every node, with the security controls on?
#
# Each check prints PASS/FAIL with the evidence it relied on. Everything is
# written to evidence/04-app-verification/report.md.
#
#   scripts/verify-app.sh        (make verify)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ns=epiconnect
host=epiconnect.lab
ca="${HOME}/.config/epiconnect-k8s/tls/ca.crt"
out=evidence/04-app-verification
report="${out}/report.md"
nonce="$(date +%s)"
mapfile -t node_ips < <(jq -r '.nodes[].ip' infra/lab.json)
mkdir -p "${out}"
passed=0; failed=0

{
  echo "# Application verification"
  echo
  echo "- Date (UTC): $(date -u '+%Y-%m-%d %H:%M')"
  echo "- Commit: \`$(git rev-parse --short HEAD)\`"
  echo "- Image: \`$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.spec.template.spec.containers[0].image}')\`"
  echo
} > "${report}"

# check "<title>" <command producing evidence> ; the command's exit code decides
check() {
  local title="$1"; shift
  local evidence rc
  evidence="$("$@" 2>&1)"; rc=$?
  if [[ ${rc} -eq 0 ]]; then status=PASS; passed=$((passed + 1)); else status=FAIL; failed=$((failed + 1)); fi
  printf '[%s] %s\n' "${status}" "${title}"
  { echo "## ${status} - ${title}"; echo '```'; echo "${evidence}"; echo '```'; echo; } >> "${report}"
}

https_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "${ca}" --resolve "${host}:443:$1" "https://${host}$2"; }

web_pods() { kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}'; }

# ---------------------------------------------------------------------------
c_nodes() {
  kubectl get nodes -o wide -L epiconnect.io/pool
  [[ "$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)" -eq 3 ]]
}

c_postgres() {
  kubectl -n ${ns} get pod postgres-0 -o wide
  kubectl -n ${ns} get pvc data-postgres-0
  [[ "$(kubectl -n ${ns} get pod postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}')" == "true" ]] \
    && [[ "$(kubectl -n ${ns} get pod postgres-0 -o jsonpath='{.spec.nodeName}')" == "k3s-server" ]]
}

c_migrations() {
  local pending job_ok=true
  # The Job deletes itself 24 h after finishing (ttlSecondsAfterFinished); if it
  # still exists it must have succeeded. Either way no migration may be pending.
  if kubectl -n ${ns} get job epiconnect-migrate 2>/dev/null; then
    [[ "$(kubectl -n ${ns} get job epiconnect-migrate -o jsonpath='{.status.succeeded}')" == "1" ]] || job_ok=false
  else
    echo "job/epiconnect-migrate already cleaned up (TTL)"
  fi
  pending="$(kubectl -n ${ns} exec deploy/epiconnect -c web -- python manage.py showmigrations --plan | grep -c '\[ \]')"
  echo "unapplied migrations: ${pending}"
  [[ "${job_ok}" == true && "${pending}" -eq 0 ]]
}

c_replicas() {
  kubectl -n ${ns} get deploy epiconnect
  web_pods
  local ready nodes
  ready="$(kubectl -n ${ns} get deploy epiconnect -o jsonpath='{.status.readyReplicas}')"
  nodes="$(web_pods | awk '{print $2}' | sort -u | wc -l)"
  echo "ready replicas: ${ready}, spread over ${nodes} node(s)"
  [[ "${ready}" -eq 3 && "${nodes}" -ge 2 ]] && ! web_pods | grep -q k3s-server
}

c_probes() {
  kubectl -n ${ns} get pods -l app.kubernetes.io/component=web \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,LIVENESS:.spec.containers[0].livenessProbe.httpGet.path,READINESS:.spec.containers[0].readinessProbe.httpGet.path'
  echo "Unhealthy probe events in the last hour: $(kubectl -n ${ns} get events --field-selector reason=Unhealthy --no-headers 2>/dev/null | wc -l)"
  [[ "$(kubectl -n ${ns} get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[*].status.containerStatuses[0].ready}')" == "true true true" ]]
}

c_db_via_ingress() {
  local body
  body="$(curl -s --max-time 10 --cacert "${ca}" --resolve "${host}:443:${node_ips[0]}" "https://${host}/readyz/")"
  echo "GET https://${host}/readyz/ -> ${body}"
  grep -q '"database": "ok"' <<<"${body}"
}

c_https_every_node() {
  local ok=0 code ip
  for ip in "${node_ips[@]}"; do
    code="$(https_code "${ip}" /)"
    echo "https://${host}/ via node ${ip}: HTTP ${code}"
    [[ "${code}" == "200" ]] && ok=$((ok + 1))
  done
  [[ ${ok} -eq ${#node_ips[@]} ]]
}

c_http_redirect() {
  local headers
  headers="$(curl -s -o /dev/null -D - --max-time 10 --resolve "${host}:80:${node_ips[0]}" "http://${host}/")"
  echo "${headers}" | grep -iE '^(HTTP|location)'
  grep -qiE '^location: https://' <<<"${headers}"
}

c_load_balancing() {
  local name node count spread=0
  for _ in $(seq 1 30); do https_code "${node_ips[0]}" "/lb-check-${nonce}/" >/dev/null; done
  sleep 2
  while read -r name node; do
    count="$(kubectl -n ${ns} logs "${name}" -c web --since=5m | grep -c "lb-check-${nonce}")"
    echo "${name} (${node}): ${count} of 30 requests"
    [[ "${count}" -gt 0 ]] && spread=$((spread + 1))
  done < <(web_pods)
  [[ ${spread} -ge 2 ]]
}

c_shared_uploads() {
  local a b file="/app/media/rwx-check-${nonce}"
  read -r a _ < <(web_pods | sort -k2 | head -1)
  read -r b _ < <(web_pods | sort -k2 | tail -1)
  echo "write on ${a} ($(kubectl -n ${ns} get pod "${a}" -o jsonpath='{.spec.nodeName}')), read on ${b} ($(kubectl -n ${ns} get pod "${b}" -o jsonpath='{.spec.nodeName}'))"
  kubectl -n ${ns} exec "${a}" -c web -- sh -c "echo ${nonce} > ${file}"
  local seen
  seen="$(kubectl -n ${ns} exec "${b}" -c web -- cat "${file}")"
  kubectl -n ${ns} exec "${b}" -c web -- ls -ln "${file}"
  kubectl -n ${ns} exec "${a}" -c web -- rm -f "${file}"
  echo "content read back: ${seen}"
  [[ "${seen}" == "${nonce}" ]]
}

# A throw-away pod tries to open a TCP connection to PostgreSQL. Without the
# db-client label the NetworkPolicy must drop it; with the label it must work.
# The pod is created, waited for, and its log read afterwards: attaching to a
# pod this short-lived ("kubectl run -i") can miss its output entirely.
# Policy enforcement is eventually consistent: kube-router adds a new pod's IP
# to the allowed-client set a few seconds after the pod starts. The probe
# therefore retries for ~20 s: the labelled pod must get through within that
# window, the unlabelled one must stay blocked for all of it.
# The full service name is used because busybox's resolver does not apply the
# pod's DNS search domains reliably: the short name "postgres" fails to resolve
# in busybox even though it resolves in the application pods.
netpol_probe() {
  local label="$1" pod="netpol-probe-${nonce}-$1"
  # shellcheck disable=SC2016  # the JSON is literal; the shell inside the pod expands nothing here
  kubectl -n ${ns} run "${pod}" --restart=Never \
    --image=busybox:1.37 --labels="epiconnect.io/db-client=${label}" --overrides='{
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{
          "name": "probe", "image": "busybox:1.37",
          "command": ["sh", "-c", "host=postgres.epiconnect.svc.cluster.local; if nslookup $host >/dev/null 2>&1; then echo dns=ok; else echo dns=FAILED; fi; i=0; while [ $i -lt 8 ]; do i=$((i+1)); if nc -w 2 $host 5432 </dev/null >/dev/null 2>&1; then echo REACHABLE attempt=$i; exit 0; fi; sleep 1; done; echo BLOCKED attempts=$i"],
          "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
        }]}}' >/dev/null
  # The first run pulls busybox, so allow time for the image download
  kubectl -n ${ns} wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=120s >/dev/null 2>&1 \
    || echo "probe pod did not complete: phase=$(kubectl -n ${ns} get pod "${pod}" -o jsonpath='{.status.phase}')" >&2
  kubectl -n ${ns} logs "${pod}" 2>&1 | tr '\n' ' '
  kubectl -n ${ns} delete pod "${pod}" --wait=false >/dev/null 2>&1
}

c_network_policy() {
  local without with
  without="$(netpol_probe false)"
  with="$(netpol_probe true)"
  echo "pod WITHOUT db-client label -> postgres:5432: ${without}"
  echo "pod WITH    db-client label -> postgres:5432: ${with}"
  # DNS must work in both cases, otherwise "BLOCKED" would prove nothing
  [[ "${without}" == *dns=ok*BLOCKED* && "${with}" == *dns=ok*REACHABLE* ]]
}

c_security() {
  local uid ro psa
  uid="$(kubectl -n ${ns} exec deploy/epiconnect -c web -- id -u)"
  ro="$(kubectl -n ${ns} exec deploy/epiconnect -c web -- sh -c 'touch /app/probe 2>&1 || true')"
  psa="$(kubectl get ns ${ns} -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  echo "web container UID: ${uid}"
  echo "write to the image filesystem: ${ro}"
  echo "namespace Pod Security enforce level: ${psa}"
  [[ "${uid}" == "10001" && "${ro}" == *"Read-only file system"* && "${psa}" == "restricted" ]]
}

# ---------------------------------------------------------------------------
[[ -f "${ca}" ]] || { echo "Missing ${ca}: run make tls" >&2; exit 1; }

check "3 nodes Ready" c_nodes
check "PostgreSQL ready on k3s-server with its own volume" c_postgres
check "Migrations applied (Job succeeded, none pending)" c_migrations
check "3 web replicas ready, spread over both workers, none on the control plane" c_replicas
check "Probes: every web pod Ready, no restarts" c_probes
check "Database reachable from the app (/readyz/ through the Ingress)" c_db_via_ingress
check "HTTPS 200 through the Ingress on every node IP" c_https_every_node
check "HTTP redirects to HTTPS" c_http_redirect
check "Requests are load-balanced across replicas" c_load_balancing
check "Uploads volume shared across nodes (ReadWriteMany)" c_shared_uploads
check "NetworkPolicy: only labelled database clients reach PostgreSQL" c_network_policy
check "Security: non-root, read-only root filesystem, restricted Pod Security" c_security

{ echo "---"; echo "**${passed} passed, ${failed} failed**"; } >> "${report}"
echo
echo "${passed} passed, ${failed} failed - report: ${report}"
# Optional copy for review outside WSL (export OUTBOX=/mnt/c/...)
if [[ -n "${OUTBOX:-}" && -d "${OUTBOX}" ]]; then cp "${report}" "${OUTBOX}/app-verification-report.md"; fi
[[ ${failed} -eq 0 ]]
