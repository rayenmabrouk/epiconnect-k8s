#!/usr/bin/env bash
# HTTPS for https://epiconnect.lab without a public domain:
#   1. a private lab Certificate Authority (created once, key never leaves WSL)
#   2. a server certificate for epiconnect.lab signed by that CA
#   3. Kubernetes TLS Secret epiconnect/epiconnect-tls, used by the Ingress
# Browsers show a warning until the CA is trusted: make trust-ca (Windows,
# current user only) - optional; verify scripts pass --cacert explicitly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

host=epiconnect.lab
dir="${HOME}/.config/epiconnect-k8s/tls"
mkdir -p "${dir}" && chmod 700 "${dir}"

if [[ ! -f "${dir}/ca.key" ]]; then
  echo "==> Creating the lab CA"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${dir}/ca.key" -out "${dir}/ca.crt" -days 825 \
    -subj "/CN=EPIConnect Lab CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "${dir}/ca.key"
fi

if [[ ! -f "${dir}/${host}.crt" ]] || ! openssl x509 -checkend 2592000 -noout -in "${dir}/${host}.crt" >/dev/null; then
  echo "==> Issuing the certificate for ${host}"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${dir}/${host}.key" -out "${dir}/${host}.csr" -subj "/CN=${host}" 2>/dev/null
  openssl x509 -req -in "${dir}/${host}.csr" -CA "${dir}/ca.crt" -CAkey "${dir}/ca.key" \
    -CAcreateserial -out "${dir}/${host}.crt" -days 397 \
    -extfile <(printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' "${host}") 2>/dev/null
  chmod 600 "${dir}/${host}.key"
fi

kubectl apply -f kubernetes/namespace.yaml >/dev/null
kubectl -n epiconnect create secret tls epiconnect-tls \
  --cert="${dir}/${host}.crt" --key="${dir}/${host}.key" \
  --dry-run=client -o yaml | kubectl apply -f -
openssl x509 -noout -subject -issuer -enddate -in "${dir}/${host}.crt"
