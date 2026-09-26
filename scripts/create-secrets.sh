#!/usr/bin/env bash
# Creates Secret epiconnect/epiconnect-secrets with random values, ONCE.
#
# Never rotated automatically: PostgreSQL stores the password when its volume
# is first initialised, so a new random db-password would lock the application
# out of an existing database. To rotate on purpose: change the password in
# PostgreSQL first, then update the Secret, then restart the pods.
#
# The admin password is also written to ~/.config/epiconnect-k8s/admin-password
# (mode 600) so you can log in at https://epiconnect.lab/admin/ as "admin".
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ns=epiconnect
conf="${HOME}/.config/epiconnect-k8s"
kubectl apply -f kubernetes/namespace.yaml >/dev/null

if kubectl -n "${ns}" get secret epiconnect-secrets >/dev/null 2>&1; then
  echo "Secret ${ns}/epiconnect-secrets already exists - left unchanged."
  exit 0
fi

mkdir -p "${conf}"
work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
chmod 700 "${work}"
# Values go through files, not command-line arguments (visible in `ps`)
openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 64 > "${work}/django-secret-key"
openssl rand -hex 24 | tr -d '\n' > "${work}/db-password"   # no trailing newline inside the password
if [[ ! -s "${conf}/admin-password" ]]; then
  (umask 077 && openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20 > "${conf}/admin-password")
fi
cp "${conf}/admin-password" "${work}/admin-password"

kubectl -n "${ns}" create secret generic epiconnect-secrets \
  --from-file=django-secret-key="${work}/django-secret-key" \
  --from-file=db-password="${work}/db-password" \
  --from-file=admin-password="${work}/admin-password"
echo "Admin login: admin / $(cat "${conf}/admin-password")   (saved in ${conf}/admin-password)"
