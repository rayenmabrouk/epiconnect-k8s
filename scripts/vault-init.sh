#!/usr/bin/env bash
# Creates the encrypted Ansible vault (ansible/inventory/group_vars/all/vault.yml) once.
#
#   vault password  -> ~/.config/epiconnect-k8s/vault-pass   (random, never in Git;
#                      BACK IT UP: without it the vault cannot be decrypted)
#   vault_k3s_token -> random 256-bit join token for the cluster
#   vault_admin_password_hash -> SHA-512 crypt hash of the password you choose
#                      for your admin account on the nodes (sudo asks for it)
#
# The encrypted vault.yml IS committed: AES-256 ciphertext, safe in a public repo,
# and it makes the secrets versioned alongside the code that uses them.
# Non-interactive use (tests): ADMIN_PASSWORD=... scripts/vault-init.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_FILE="${REPO_ROOT}/ansible/inventory/group_vars/all/vault.yml"
PASS_FILE="${HOME}/.config/epiconnect-k8s/vault-pass"

mkdir -p "$(dirname "${PASS_FILE}")"
if [[ ! -f "${PASS_FILE}" ]]; then
  (umask 077 && openssl rand -base64 32 > "${PASS_FILE}")
  echo "Created vault password file ${PASS_FILE} - back it up (e.g. in your password manager)."
fi

if [[ -f "${VAULT_FILE}" ]]; then
  echo "${VAULT_FILE} already exists. View: ansible-vault view ${VAULT_FILE#"${REPO_ROOT}/"}"
  exit 0
fi

if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  read -rsp "Password for your admin account on the nodes (used by sudo): " ADMIN_PASSWORD; echo
  read -rsp "Repeat: " again; echo
  [[ "${ADMIN_PASSWORD}" == "${again}" ]] || { echo "Passwords differ." >&2; exit 1; }
  [[ ${#ADMIN_PASSWORD} -ge 12 ]] || { echo "Use at least 12 characters." >&2; exit 1; }
fi

hash="$(printf '%s' "${ADMIN_PASSWORD}" | openssl passwd -6 -stdin)"
token="$(openssl rand -hex 32)"

plain="$(mktemp)"; trap 'shred -u "${plain}" 2>/dev/null || rm -f "${plain}"' EXIT
chmod 600 "${plain}"
cat > "${plain}" <<YAML
---
vault_k3s_token: "${token}"
vault_admin_password_hash: "${hash}"
YAML
ansible-vault encrypt --vault-password-file "${PASS_FILE}" --output "${VAULT_FILE}" "${plain}"
echo "Encrypted vault written: ${VAULT_FILE#"${REPO_ROOT}/"} (commit it; never commit ${PASS_FILE})"
