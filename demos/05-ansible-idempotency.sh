#!/usr/bin/env bash
# Demo 5 - Ansible idempotency.
#
# Runs the complete playbook twice. Run 1 converges the nodes to the desired
# state; run 2 must find nothing to do: changed=0 on every host. That proves
# the automation describes a STATE, not a sequence of commands: re-running it
# is safe, and any non-zero "changed" on a later run means drift.
#
#   demos/05-ansible-idempotency.sh            two runs on the current lab
#   demos/05-ansible-idempotency.sh --fresh    first roll every VM back to the
#                                              "fresh" checkpoint (straight out of
#                                              cloud-init), so run 1 builds everything
#
# Evidence: evidence/05-ansible-idempotency/ (full logs + summary.md)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

out="evidence/05-ansible-idempotency"
mkdir -p "${out}"
export ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1

wait_for_ssh() {
  for ip in $(jq -r '.nodes[].ip' infra/lab.json); do
    until nc -z -w 2 "${ip}" 22; do sleep 3; done
  done
  sleep 5
}

if [[ "${1:-}" == "--fresh" ]]; then
  echo "==> Rolling every VM back to the 'fresh' checkpoint"
  make --no-print-directory restore SNAPSHOT=fresh
  wait_for_ssh
fi

for run in 1 2; do
  echo "==> Run ${run}"
  start=$(date +%s)
  (cd ansible && ansible-playbook playbooks/site.yml) | tee "${out}/run-${run}.log"
  echo "$(( $(date +%s) - start ))" > "${out}/.run-${run}.seconds"
done

recap() { sed -n '/^PLAY RECAP/,$p' "${out}/run-$1.log" | grep -E 'changed='; }
changed_total=$(recap 2 | sed -E 's/.*changed=([0-9]+).*/\1/' | awk '{s+=$1} END {print s+0}')

{
  echo "# Demo 5 - Ansible idempotency"
  echo
  echo "- Date (UTC): $(date -u '+%Y-%m-%d %H:%M')"
  echo "- Commit: \`$(git rev-parse --short HEAD)\`"
  echo "- Started from the fresh checkpoint: $([[ "${1:-}" == "--fresh" ]] && echo yes || echo no)"
  echo
  echo "## Run 1 ($(cat "${out}/.run-1.seconds") s)"
  echo '```'; recap 1; echo '```'
  echo "## Run 2 ($(cat "${out}/.run-2.seconds") s)"
  echo '```'; recap 2; echo '```'
  echo
  if [[ "${changed_total}" -eq 0 ]]; then
    echo "**Result: PASS** - the second run changed nothing on any node."
  else
    echo "**Result: FAIL** - the second run changed ${changed_total} item(s):"
    echo '```'
    grep -E '^changed:' -B2 "${out}/run-2.log" | grep -E '^TASK' || true
    echo '```'
  fi
} > "${out}/summary.md"
rm -f "${out}"/.run-*.seconds

echo
cat "${out}/summary.md"
[[ "${changed_total}" -eq 0 ]]
