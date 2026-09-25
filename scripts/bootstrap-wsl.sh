#!/usr/bin/env bash
# Prepares WSL2 Ubuntu 24.04 as the control machine for the lab.
#
#   Ansible (pinned, in a virtualenv)  -> configures the VMs
#   kubectl / helm (pinned, checksummed) -> talk to the cluster
#   qemu-utils / cloud-image-utils      -> turn the Ubuntu cloud image into
#                                          Hyper-V disks + cloud-init seed ISOs
#   ~/.ssh/k3s_lab_ed25519               -> dedicated lab SSH key
#
# Idempotent: re-running only installs what is missing or outdated.
set -euo pipefail

KUBECTL_VERSION="v1.36.4"   # same minor as the cluster (k3s v1.36.4+k3s1)
HELM_VERSION="v4.2.4"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${HOME}/.venvs/epiconnect-k8s"
BIN="${HOME}/.local/bin"
SSH_KEY="${HOME}/.ssh/k3s_lab_ed25519"

log() { printf '\n==> %s\n' "$*"; }

if ! grep -qi microsoft /proc/version; then
  echo "This script is meant for WSL2 (Ubuntu 24.04)." >&2
fi

log "APT packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3-venv python3-pip git make jq curl openssl gettext-base \
  qemu-utils cloud-image-utils ubuntu-cloudimage-keyring gpgv \
  netcat-openbsd dnsutils shellcheck >/dev/null

log "Ansible toolchain in ${VENV}"
[[ -d "${VENV}" ]] || python3 -m venv "${VENV}"
"${VENV}/bin/pip" install -q --upgrade pip
"${VENV}/bin/pip" install -q -r "${REPO_ROOT}/requirements-tools.txt"
if [[ -f "${REPO_ROOT}/ansible/requirements.yml" ]]; then
  "${VENV}/bin/ansible-galaxy" collection install -r "${REPO_ROOT}/ansible/requirements.yml"
fi

mkdir -p "${BIN}"
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

log "kubectl ${KUBECTL_VERSION}"
if [[ "$("${BIN}/kubectl" version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" != "${KUBECTL_VERSION}" ]]; then
  curl -fsSLo "${tmp}/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  curl -fsSLo "${tmp}/kubectl.sha256" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
  echo "$(cat "${tmp}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum --check --quiet
  install -m 0755 "${tmp}/kubectl" "${BIN}/kubectl"
fi

log "helm ${HELM_VERSION}"
if [[ "$("${BIN}/helm" version --template '{{.Version}}' 2>/dev/null)" != "${HELM_VERSION}" ]]; then
  archive="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSLo "${tmp}/${archive}" "https://get.helm.sh/${archive}"
  curl -fsSLo "${tmp}/${archive}.sha256sum" "https://get.helm.sh/${archive}.sha256sum"
  (cd "${tmp}" && sha256sum --check --quiet "${archive}.sha256sum")
  tar -xzf "${tmp}/${archive}" -C "${tmp}"
  install -m 0755 "${tmp}/linux-amd64/helm" "${BIN}/helm"
fi

log "Lab SSH key ${SSH_KEY}"
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
if [[ ! -f "${SSH_KEY}" ]]; then
  # Dedicated to this lab: never reused elsewhere, private half never leaves WSL
  ssh-keygen -q -t ed25519 -N "" -C "k3s-lab-ansible@$(hostname)" -f "${SSH_KEY}"
fi

# "ssh k3s-server" instead of "ssh -i ... ansible@192.168.50.10"
if ! grep -q "# BEGIN k3s-lab" "${HOME}/.ssh/config" 2>/dev/null; then
  {
    echo "# BEGIN k3s-lab (managed by epiconnect-k8s/scripts/bootstrap-wsl.sh)"
    jq -r '.nodes[] | "Host \(.name)\n  HostName \(.ip)"' "${REPO_ROOT}/infra/lab.json"
    echo "Host k3s-server k3s-worker1 k3s-worker2"
    echo "  User ansible"
    echo "  IdentityFile ${SSH_KEY}"
    echo "  IdentitiesOnly yes"
    echo "  StrictHostKeyChecking accept-new"
    echo "# END k3s-lab"
  } >> "${HOME}/.ssh/config"
  chmod 600 "${HOME}/.ssh/config"
fi

if ! grep -q "epiconnect-k8s toolchain" "${HOME}/.bashrc"; then
  cat >> "${HOME}/.bashrc" <<RC

# epiconnect-k8s toolchain
export PATH="${BIN}:${VENV}/bin:\${PATH}"
RC
fi
export PATH="${BIN}:${VENV}/bin:${PATH}"

log "Versions"
ansible --version | head -1
kubectl version --client | head -1
helm version --short
qemu-img --version | head -1

cat <<MSG

Done. Open a new shell (or: source ~/.bashrc) so PATH includes the tools.
Networking: WSL must run in mirrored mode to reach 192.168.50.0/24.
  Check:  wslinfo --networking-mode   (expected: mirrored)
MSG
