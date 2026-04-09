#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-tools.sh — Idempotent CLI tool installer for the RBE lab
# ─────────────────────────────────────────────────────────────────────────────
# Run this once before bootstrap.sh. Safe to re-run — skips already-installed tools.
#
# Installs:
#   kubectl   - Kubernetes CLI (talk to the cluster)
#   kind      - Kubernetes in Docker (create/manage local clusters)
#   helm      - Kubernetes package manager (install Argo CD + all charts)
#   argocd    - Argo CD CLI (inspect apps, sync, get admin password)
#   kubeseal  - Sealed Secrets CLI (encrypt secrets client-side for Git)
#   k9s       - Terminal UI for Kubernetes (optional but highly recommended)
#
# All versions are pinned explicitly — no 'latest' downloads.
# Reason: reproducibility. If something breaks, you know exactly which version
# to blame and can bisect. "latest" turns debugging into archaeology.
#
# Usage:
#   chmod +x cluster/install-tools.sh
#   ./cluster/install-tools.sh
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Pinned versions ────────────────────────────────────────────────────────────
# Update these deliberately, not automatically.
# Check release notes before bumping — especially kind (API changes) and argocd (CRD changes).
KUBECTL_VERSION="v1.31.2"       # Match the kind node image version (kindest/node:v1.31.2)
KIND_VERSION="v0.25.0"          # kind cluster manager
HELM_VERSION="v3.16.3"          # Helm chart manager
ARGOCD_VERSION="v2.13.3"        # Argo CD CLI (must match chart version deployed in bootstrap.sh)
KUBESEAL_VERSION="v0.27.3"      # Sealed Secrets CLI
K9S_VERSION="v0.32.7"           # Terminal UI (optional)

# ── Install target ─────────────────────────────────────────────────────────────
# /usr/local/bin is on PATH for all users. Requires sudo for write access.
INSTALL_DIR="/usr/local/bin"

# ── Helpers ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[install]${NC} $*"; }
skip()  { echo -e "${YELLOW}[skip]${NC}   $* already installed"; }
check() { command -v "$1" &>/dev/null; }

# ── kubectl ────────────────────────────────────────────────────────────────────
# The Kubernetes CLI. Every interaction with the cluster goes through this.
# Version should match (or be within 1 minor version of) the cluster's K8s version.
if check kubectl; then
  skip "kubectl ($(kubectl version --client --short 2>/dev/null | head -1))"
else
  info "Installing kubectl ${KUBECTL_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /tmp/kubectl
  # Verify checksum — never skip this for a privileged binary
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    -o /tmp/kubectl.sha256
  echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check --quiet
  sudo install -o root -g root -m 0755 /tmp/kubectl "${INSTALL_DIR}/kubectl"
  rm /tmp/kubectl /tmp/kubectl.sha256
  info "kubectl ${KUBECTL_VERSION} installed"
fi

# ── kind ───────────────────────────────────────────────────────────────────────
# Kubernetes in Docker — creates and manages local K8s clusters as Docker containers.
# Each cluster = a set of named Docker containers (remote-builder-control-plane, etc.)
# kind does NOT require a VM on Linux — it talks directly to the Docker socket.
if check kind; then
  skip "kind ($(kind version))"
else
  info "Installing kind ${KIND_VERSION}..."
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
    -o /tmp/kind
  sudo install -o root -g root -m 0755 /tmp/kind "${INSTALL_DIR}/kind"
  rm /tmp/kind
  info "kind ${KIND_VERSION} installed"
fi

# ── helm ───────────────────────────────────────────────────────────────────────
# Kubernetes package manager. Used in bootstrap.sh to install Argo CD.
# After bootstrap, Argo CD itself manages all subsequent Helm chart deployments
# via GitOps — you won't run 'helm install' again after the bootstrap.
if check helm; then
  skip "helm ($(helm version --short))"
else
  info "Installing helm ${HELM_VERSION}..."
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  sudo install -o root -g root -m 0755 /tmp/linux-amd64/helm "${INSTALL_DIR}/helm"
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  info "helm ${HELM_VERSION} installed"
fi

# ── argocd CLI ─────────────────────────────────────────────────────────────────
# The Argo CD command-line interface.
# Used for:
#   - Retrieving the initial admin password (argocd admin initial-password)
#   - Watching sync status (argocd app list, argocd app get)
#   - Manually triggering syncs during development (argocd app sync)
#   - Logging into the Argo CD API server
#
# The CLI version must match the Argo CD server version deployed by bootstrap.sh.
# Argo CD Helm chart 7.7.x deploys Argo CD server v2.13.x — CLI must match.
if check argocd; then
  skip "argocd ($(argocd version --client --short 2>/dev/null | head -1))"
else
  info "Installing argocd CLI ${ARGOCD_VERSION}..."
  curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" \
    -o /tmp/argocd
  sudo install -o root -g root -m 0755 /tmp/argocd "${INSTALL_DIR}/argocd"
  rm /tmp/argocd
  info "argocd ${ARGOCD_VERSION} installed"
fi

# ── kubeseal ───────────────────────────────────────────────────────────────────
# The Sealed Secrets client-side CLI.
# Workflow:
#   1. kubeseal --fetch-cert --controller-namespace cluster-infra > pub-cert.pem
#      (downloads the public key from the in-cluster Sealed Secrets controller)
#   2. kubectl create secret generic my-secret --dry-run=client -o yaml \
#        | kubeseal --cert pub-cert.pem -o yaml > my-sealed-secret.yaml
#      (encrypts the Secret — the SealedSecret is safe to commit to Git)
#   3. kubectl apply -f my-sealed-secret.yaml
#      (Argo CD picks it up; the in-cluster controller decrypts it into a real Secret)
#
# Only the in-cluster controller holds the private key — kubeseal never touches it.
# If you lose the controller private key, you cannot decrypt existing SealedSecrets.
# BACK IT UP after bootstrap: see phase-1-cluster.md "Sealing the Keypair" section.
if check kubeseal; then
  skip "kubeseal ($(kubeseal --version 2>/dev/null))"
else
  info "Installing kubeseal ${KUBESEAL_VERSION}..."
  curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION#v}-linux-amd64.tar.gz" \
    -o /tmp/kubeseal.tar.gz
  tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
  sudo install -o root -g root -m 0755 /tmp/kubeseal "${INSTALL_DIR}/kubeseal"
  rm /tmp/kubeseal.tar.gz /tmp/kubeseal
  info "kubeseal ${KUBESEAL_VERSION} installed"
fi

# ── k9s ────────────────────────────────────────────────────────────────────────
# Terminal-based Kubernetes UI. Not strictly required but makes the lab
# much more enjoyable — you can watch pods, logs, and resource events in real time
# without memorizing kubectl commands.
#
# Key shortcuts once inside k9s:
#   :pods          → list all pods
#   :ns            → switch namespace
#   l              → view logs for selected pod
#   d              → describe selected resource
#   ctrl+d         → delete resource
#   /              → filter by name
#   ?              → help
if check k9s; then
  skip "k9s ($(k9s version --short 2>/dev/null | head -1))"
else
  info "Installing k9s ${K9S_VERSION}..."
  curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    -o /tmp/k9s.tar.gz
  tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
  sudo install -o root -g root -m 0755 /tmp/k9s "${INSTALL_DIR}/k9s"
  rm /tmp/k9s.tar.gz /tmp/k9s
  info "k9s ${K9S_VERSION} installed"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────"
echo "All tools ready. Versions installed:"
echo "─────────────────────────────────────────────────────"
kubectl version --client --short 2>/dev/null | head -1  || true
kind version                                             || true
helm version --short                                     || true
argocd version --client --short 2>/dev/null | head -1   || true
kubeseal --version 2>/dev/null                          || true
k9s version --short 2>/dev/null | head -1               || true
echo "─────────────────────────────────────────────────────"
echo ""
echo "Next step:"
echo "  cp cluster/config.env.example cluster/config.env"
echo "  # Edit cluster/config.env — fill in GITHUB_PAT"
echo "  ./cluster/bootstrap.sh"
