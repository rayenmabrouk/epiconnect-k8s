#!/usr/bin/env bash
# Runs in WSL. Produces everything Hyper-V needs to create the lab VMs:
#
#   <labRoot>\base\ubuntu-24.04-base.vhdx   Ubuntu cloud image converted to VHDX
#   <labRoot>\seed\<node>.iso               per-node cloud-init seed (NoCloud)
#
# The Ubuntu image is verified before use: SHA256SUMS must carry a valid
# Canonical signature (gpgv) and the image must match its checksum.
# Idempotent: nothing is downloaded or converted twice.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB_JSON="${REPO_ROOT}/infra/lab.json"
TPL_DIR="${REPO_ROOT}/infra/hyperv/cloud-init"
CACHE="${HOME}/.cache/epiconnect-k8s"
CONF="${HOME}/.config/epiconnect-k8s"
SSH_PUB="${HOME}/.ssh/k3s_lab_ed25519.pub"
SEED_VERSION="v1"   # bump to make cloud-init treat the VMs as new instances

log() { printf '==> %s\n' "$*"; }
cfg() { jq -r "$1" "${LAB_JSON}"; }

[[ -f "${SSH_PUB}" ]] || { echo "Missing ${SSH_PUB}: run scripts/bootstrap-wsl.sh first" >&2; exit 1; }
for tool in jq qemu-img cloud-localds gpgv envsubst openssl; do
  command -v "${tool}" >/dev/null || { echo "Missing ${tool}: run scripts/bootstrap-wsl.sh" >&2; exit 1; }
done

LAB_ROOT="$(wslpath -u "$(cfg .labRoot)")"
[[ -d "${LAB_ROOT}" ]] || { echo "${LAB_ROOT} not found: run Initialize-LabHost.ps1 (as Administrator) first" >&2; exit 1; }
mkdir -p "${CACHE}" "${CONF}" "${LAB_ROOT}/base" "${LAB_ROOT}/seed"

# --- 1. Download and verify the Ubuntu cloud image ---------------------------
BASE_URL="$(cfg .ubuntu.baseUrl)"
IMAGE="$(cfg .ubuntu.image)"
log "Checking ${IMAGE}"
curl -fsSLo "${CACHE}/SHA256SUMS" "${BASE_URL}/SHA256SUMS"
curl -fsSLo "${CACHE}/SHA256SUMS.gpg" "${BASE_URL}/SHA256SUMS.gpg"
gpgv --keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg \
  "${CACHE}/SHA256SUMS.gpg" "${CACHE}/SHA256SUMS" 2>/dev/null \
  || { echo "SHA256SUMS signature is NOT valid - refusing to continue" >&2; exit 1; }

expected="$(awk -v f="*${IMAGE}" '$2 == f || $2 == substr(f, 2) {print $1}' "${CACHE}/SHA256SUMS")"
[[ -n "${expected}" ]] || { echo "${IMAGE} not listed in SHA256SUMS" >&2; exit 1; }
if [[ ! -f "${CACHE}/${IMAGE}" ]] || ! echo "${expected}  ${CACHE}/${IMAGE}" | sha256sum --check --quiet 2>/dev/null; then
  log "Downloading ${IMAGE} (~600 MB)"
  curl -fL --progress-bar -o "${CACHE}/${IMAGE}" "${BASE_URL}/${IMAGE}"
  echo "${expected}  ${CACHE}/${IMAGE}" | sha256sum --check --quiet
fi
log "Image signature and checksum OK (${expected:0:12}...)"

# --- 2. Convert qcow2 -> VHDX (Hyper-V's disk format) --------------------------
BASE_VHDX="${LAB_ROOT}/base/ubuntu-24.04-base.vhdx"
STAMP="${LAB_ROOT}/base/ubuntu-24.04-base.sha256"
if [[ ! -f "${BASE_VHDX}" || "$(cat "${STAMP}" 2>/dev/null)" != "${expected}" ]]; then
  log "Converting to VHDX"
  qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic "${CACHE}/${IMAGE}" "${CACHE}/base.vhdx"
  # Written on the Linux filesystem first, then copied with --sparse=never:
  # Hyper-V refuses to attach a VHDX stored as an NTFS sparse file.
  cp --sparse=never "${CACHE}/base.vhdx" "${BASE_VHDX}"
  rm -f "${CACHE}/base.vhdx"
  echo "${expected}" > "${STAMP}"
else
  log "Base VHDX up to date"
fi

# --- 3. Break-glass console password (Hyper-V console only, never SSH) ---------
if [[ ! -f "${CONF}/console-password" ]]; then
  (umask 077 && openssl rand -base64 18 > "${CONF}/console-password")
fi
CONSOLE_PASSWORD_HASH="$(openssl passwd -6 -salt "$(openssl rand -hex 8)" -stdin < "${CONF}/console-password")"

# --- 4. One cloud-init seed ISO per node ---------------------------------------
SSH_PUBLIC_KEY="$(cat "${SSH_PUB}")"
GATEWAY="$(cfg .gateway)"
PREFIX_LENGTH="$(cfg .prefixLength)"
DNS_SERVERS="$(jq -r '.dns | join(", ")' "${LAB_JSON}")"
export SSH_PUBLIC_KEY CONSOLE_PASSWORD_HASH GATEWAY PREFIX_LENGTH DNS_SERVERS SEED_VERSION

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
while read -r name ip mac; do
  NODE_NAME="${name}"
  NODE_IP="${ip}"
  # Hyper-V notation 00155D320A0A -> netplan notation 00:15:5d:32:0a:0a
  NODE_MAC="$(echo "${mac}" | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//')"
  export NODE_NAME NODE_IP NODE_MAC
  vars='${NODE_NAME} ${NODE_IP} ${NODE_MAC} ${SSH_PUBLIC_KEY} ${CONSOLE_PASSWORD_HASH} ${GATEWAY} ${PREFIX_LENGTH} ${DNS_SERVERS} ${SEED_VERSION}'
  envsubst "${vars}" < "${TPL_DIR}/user-data.yaml.tpl"      > "${work}/user-data"
  envsubst "${vars}" < "${TPL_DIR}/network-config.yaml.tpl" > "${work}/network-config"
  envsubst "${vars}" < "${TPL_DIR}/meta-data.yaml.tpl"      > "${work}/meta-data"
  cloud-localds --network-config="${work}/network-config" \
    "${work}/${name}.iso" "${work}/user-data" "${work}/meta-data"
  cp "${work}/${name}.iso" "${LAB_ROOT}/seed/${name}.iso"
  log "Seed ISO ${name} (${ip}, ${NODE_MAC})"
done < <(jq -r '.nodes[] | "\(.name) \(.ip) \(.mac)"' "${LAB_JSON}")

log "Done. Next (from WSL):  make vms"
log "Console password (Hyper-V console only): ${CONF}/console-password"
