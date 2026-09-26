#!/usr/bin/env bash
# Installs pinned command-line tools, each verified against a SHA-256 recorded
# in THIS file. A checksum downloaded next to the binary only proves the
# download was not corrupted: an attacker who replaces a release asset can
# replace its checksum file too (what happened to Trivy's releases in March
# 2026). A checksum committed here must be changed in a reviewed commit.
#
#   scripts/install-tools.sh <bin dir> [tool...]
#   tools: helm kubectl kubeconform k3d (default: all)
#
# Used by CI (.github/workflows/ci.yml) and by scripts/bootstrap-wsl.sh.
set -euo pipefail

HELM_VERSION=v4.2.4          # same as the control machine
HELM_SHA256=c306b46f719b0a4da32d0f78ee21bf90ce8d602f15b22ab753f0674d1670a7f3
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
K3D_VERSION=v5.9.0
K3D_SHA256=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0
# kubectl: same version as the cluster. Verified against the checksum the
# Kubernetes release infrastructure publishes on dl.k8s.io (its own CDN, not a
# mutable release page).
KUBECTL_VERSION=v1.36.4

bin="${1:?usage: $0 <bin dir> [tool...]}"; shift
tools=("$@"); [[ ${#tools[@]} -gt 0 ]] || tools=(helm kubectl kubeconform k3d)
mkdir -p "${bin}"
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

# download <url> <file> <sha256>
download() {
  curl -fsSL --retry 3 -o "${tmp}/$2" "$1"
  echo "$3  ${tmp}/$2" | sha256sum --check --quiet \
    || { echo "checksum mismatch for $1" >&2; exit 1; }
}

for tool in "${tools[@]}"; do
  case "${tool}" in
    helm)
      download "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" helm.tgz "${HELM_SHA256}"
      tar -xzf "${tmp}/helm.tgz" -C "${tmp}" linux-amd64/helm
      install -m 0755 "${tmp}/linux-amd64/helm" "${bin}/helm" ;;
    kubeconform)
      download "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
        kubeconform.tgz "${KUBECONFORM_SHA256}"
      tar -xzf "${tmp}/kubeconform.tgz" -C "${tmp}" kubeconform
      install -m 0755 "${tmp}/kubeconform" "${bin}/kubeconform" ;;
    k3d)
      download "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" k3d "${K3D_SHA256}"
      install -m 0755 "${tmp}/k3d" "${bin}/k3d" ;;
    kubectl)
      url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
      download "${url}" kubectl "$(curl -fsSL --retry 3 "${url}.sha256")"
      install -m 0755 "${tmp}/kubectl" "${bin}/kubectl" ;;
    *) echo "unknown tool: ${tool}" >&2; exit 2 ;;
  esac
  echo "installed ${tool} -> ${bin}/${tool}"
done
