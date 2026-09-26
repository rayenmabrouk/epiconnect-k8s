# shellcheck shell=bash
# Sourced by scripts/verify-app.sh (lab) and scripts/smoke-test.sh (CI).
#
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
  local ns="$1" label="$2" pod
  pod="netpol-probe-$(date +%s)-${label}"
  # shellcheck disable=SC2016  # the JSON is literal; the shell inside the pod expands nothing here
  kubectl -n "${ns}" run "${pod}" --restart=Never \
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
  kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=120s >/dev/null 2>&1 \
    || echo "probe pod did not complete: phase=$(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.status.phase}')" >&2
  kubectl -n "${ns}" logs "${pod}" 2>&1 | tr '\n' ' '
  kubectl -n "${ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1
}
