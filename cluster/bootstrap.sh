#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — One-shot cluster bootstrap for the RBE lab
# ─────────────────────────────────────────────────────────────────────────────
#
# What this script does (in order):
#   1.  Pre-flight checks (tools, config, no conflicting cluster)
#   2.  Create kind cluster (remote-builder) — leaves other clusters untouched
#   3.  Wait for all nodes to be Ready
#   4.  Create required namespaces
#   5.  Create ghcr.io imagePullSecret in each namespace
#       (plain K8s Secret for bootstrap — will be sealed in Phase 3)
#   6.  Add Helm repos
#   7.  Install Argo CD via Helm
#   8.  Wait for Argo CD to be healthy
#   9.  Apply the app-of-apps root Application (the ONE manual kubectl apply)
#   10. Print access instructions + admin password
#
# After step 9, everything is GitOps-managed. You never run helm install or
# kubectl apply again for anything Argo CD owns.
#
# Usage:
#   ./cluster/bootstrap.sh
#
# Re-run safety:
#   The script is NOT fully idempotent — it will fail at step 2 if the cluster
#   already exists (by design — we don't want to clobber a running cluster).
#   To start fresh: kind delete cluster --name remote-builder && ./bootstrap.sh
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Resolve script directory so it works from any working directory ────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Load config ────────────────────────────────────────────────────────────────
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: ${CONFIG_FILE} not found."
  echo "Run: cp cluster/config.env.example cluster/config.env"
  echo "Then fill in GITHUB_PAT and other values."
  exit 1
fi
# shellcheck source=cluster/config.env
source "${CONFIG_FILE}"

# Validate required variables
: "${GITHUB_REPO:?GITHUB_REPO must be set in config.env}"
: "${GITHUB_PAT:?GITHUB_PAT must be set in config.env}"
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in config.env}"

# ── Pinned versions (must match install-tools.sh) ─────────────────────────────
ARGOCD_HELM_CHART_VERSION="7.7.16"   # Helm chart 7.7.x → Argo CD server v2.13.x
SEALED_SECRETS_CHART_VERSION="2.16.1" # bitnami-labs/sealed-secrets

# ── Colours ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warning]${NC}   $*"; }
error() { echo -e "${RED}[error]${NC}     $*"; exit 1; }
step()  { echo -e "\n${BLUE}══ $* ${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────
step "1/10 Pre-flight checks"

# Check required tools
for tool in kubectl kind helm argocd kubeseal docker; do
  if ! command -v "$tool" &>/dev/null; then
    error "$tool not found. Run: ./cluster/install-tools.sh"
  fi
done
info "All required tools found"

# Check Docker is running
if ! docker info &>/dev/null; then
  error "Docker is not running. Start Docker and retry."
fi
info "Docker is running"

# CRITICAL: Protect existing clusters
# We check by name to ensure we never accidentally clobber bazel-sim or bootik-local.
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  error "Cluster '${CLUSTER_NAME}' already exists."$'\n'"       To start fresh: kind delete cluster --name ${CLUSTER_NAME}"$'\n'"       Your other clusters (bazel-sim, bootik-local) are not affected."
fi
info "Cluster name '${CLUSTER_NAME}' is available — no conflict with existing clusters"

# Warn about RAM if both other clusters are running
RUNNING_KIND=$(docker ps --filter name=kind --format '{{.Names}}' | grep -v "${CLUSTER_NAME}" | wc -l)
if [[ "${RUNNING_KIND}" -gt 0 ]]; then
  warn "You have ${RUNNING_KIND} other kind cluster(s) running."
  warn "This is fine for Phase 1, but for later phases (Istio + Buildbarn) consider:"
  warn "  docker stop \$(docker ps -q --filter name=kind-bazel-sim)"
  warn "  to free ~350MB RAM before heavy workloads."
fi

# Validate GitHub PAT is not the placeholder
if [[ "${GITHUB_PAT}" == "ghp_REPLACE_WITH_YOUR_TOKEN" ]]; then
  error "GITHUB_PAT is still the placeholder value. Set a real PAT in config.env."
fi

info "Pre-flight checks passed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Create kind cluster
# ─────────────────────────────────────────────────────────────────────────────
step "2/10 Creating kind cluster: ${CLUSTER_NAME}"

# kind uses cluster/kind-config.yaml which defines:
#   - 3 nodes (control-plane, infra, worker)
#   - Node labels (pool=infra, pool=rbe-workers)
#   - Worker node taint (dedicated=rbe-worker:NoSchedule)
kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config "${SCRIPT_DIR}/kind-config.yaml"

# Set kubectl context to the new cluster
# kind automatically adds a context named kind-<cluster-name>
kubectl config use-context "kind-${CLUSTER_NAME}"
info "kubectl context set to kind-${CLUSTER_NAME}"
info "Your other clusters' contexts are preserved and unchanged"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Wait for nodes
# ─────────────────────────────────────────────────────────────────────────────
step "3/10 Waiting for all nodes to be Ready"

kubectl wait \
  --for=condition=Ready \
  node --all \
  --timeout=120s

info "All nodes Ready:"
kubectl get nodes -o wide

# Verify our labels and taints were applied correctly
info "Verifying node topology..."
INFRA_NODES=$(kubectl get nodes -l pool=infra --no-headers | wc -l)
WORKER_NODES=$(kubectl get nodes -l pool=rbe-workers --no-headers | wc -l)
if [[ "${INFRA_NODES}" -ne 1 ]]; then
  error "Expected 1 infra node (pool=infra), found ${INFRA_NODES}. Check kind-config.yaml."
fi
if [[ "${WORKER_NODES}" -ne 1 ]]; then
  error "Expected 1 worker node (pool=rbe-workers), found ${WORKER_NODES}. Check kind-config.yaml."
fi
info "Node topology verified: 1 infra node, 1 worker node"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Create namespaces
# ─────────────────────────────────────────────────────────────────────────────
step "4/10 Creating namespaces"

# We create these manually here because Argo CD itself needs to exist in argocd
# before it can create namespaces. This is the bootstrap chicken-and-egg.
# After Argo CD is running, it creates all subsequent namespaces via GitOps
# (via syncOptions: CreateNamespace=true in Application specs).
NAMESPACES=(
  argocd          # Argo CD server + Argo Rollouts controller
  cluster-infra   # KEDA, Prometheus, Sealed Secrets controller
  istio-system    # Istio control plane (Phase 3)
  minio           # MinIO CAS object store (Phase 2)
  rbe-system      # Buildbarn scheduler (Phase 2)
)

for ns in "${NAMESPACES[@]}"; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  info "Namespace: ${ns}"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Create ghcr.io imagePullSecret in each namespace
# ─────────────────────────────────────────────────────────────────────────────
step "5/10 Creating ghcr.io image pull secrets"

# Why we need this:
# ghcr.io packages are authenticated. Pods pulling from ghcr.io/exitthematrix26/
# need credentials. We create a Secret with the GitHub PAT in each namespace
# that will run pods with our custom images.
#
# This is a PLAIN K8s Secret (not SealedSecret) created directly — it never
# touches Git, so it's safe for now. In Phase 3 we'll encrypt it properly
# with kubeseal so it CAN be stored in Git.
#
# Secret name: ghcr-pull-secret
# This name is referenced in the imagePullSecrets field of our Helm chart templates.

for ns in "${NAMESPACES[@]}"; do
  kubectl create secret docker-registry ghcr-pull-secret \
    --docker-server="ghcr.io" \
    --docker-username="exitthematrix26" \
    --docker-password="${GITHUB_PAT}" \
    --namespace="${ns}" \
    --dry-run=client -o yaml | kubectl apply -f -
  info "Pull secret created in namespace: ${ns}"
done

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Add Helm repositories
# ─────────────────────────────────────────────────────────────────────────────
step "6/10 Adding Helm repositories"

helm repo add argo             https://argoproj.github.io/argo-helm
helm repo add sealed-secrets   https://bitnami-labs.github.io/sealed-secrets
helm repo update

info "Helm repos updated"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Install Argo CD via Helm
# ─────────────────────────────────────────────────────────────────────────────
step "7/10 Installing Argo CD (Helm chart ${ARGOCD_HELM_CHART_VERSION})"

# Why Helm for Argo CD bootstrap?
# Argo CD is the GitOps engine — it manages everything ELSE via Git. But Argo CD
# itself can't manage its own installation (chicken-and-egg). We use Helm here
# as a one-time bootstrap. After this, Argo CD can optionally manage its own
# upgrades via an Application pointing at the argo/argo-cd chart (app-of-apps
# pattern applied to the manager itself — advanced, skipped for this lab).
#
# Key Helm values we set:
#   server.extraArgs: ["--insecure"]
#     Disables TLS on the Argo CD server API. In the lab we access it via
#     kubectl port-forward (already on localhost), so TLS adds no security value
#     but complicates browser access. In production: use a proper ingress with TLS.
#
#   server.service.type: ClusterIP
#     We'll port-forward to reach the UI. No LoadBalancer needed in kind.
#     In EKS: use service.type=LoadBalancer or an Ingress + ACM cert.

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_HELM_CHART_VERSION}" \
  --set server.extraArgs[0]="--insecure" \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --wait \
  --timeout=300s

info "Argo CD installed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Wait for Argo CD to be healthy
# ─────────────────────────────────────────────────────────────────────────────
step "8/10 Waiting for Argo CD pods to be Ready"

kubectl wait \
  --for=condition=Ready \
  pods \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd \
  --timeout=180s

kubectl wait \
  --for=condition=Ready \
  pods \
  -l app.kubernetes.io/name=argocd-application-controller \
  -n argocd \
  --timeout=180s

kubectl wait \
  --for=condition=Ready \
  pods \
  -l app.kubernetes.io/name=argocd-repo-server \
  -n argocd \
  --timeout=180s

info "Argo CD is healthy"
kubectl get pods -n argocd

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Connect Argo CD to GitHub and apply app-of-apps
# ─────────────────────────────────────────────────────────────────────────────
step "9/10 Applying app-of-apps (the ONE manual kubectl apply)"

# Get Argo CD admin password (auto-generated by Helm install)
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

# Port-forward Argo CD temporarily for the CLI login
# We run it in background, kill it after we're done
kubectl port-forward svc/argocd-server -n argocd 18080:80 &
PF_PID=$!
sleep 3  # Wait for port-forward to establish

# Login to Argo CD CLI
argocd login localhost:18080 \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --insecure

# Add the GitHub repo to Argo CD
# This tells Argo CD where to find the GitOps manifests.
# For a public repo (which we recommend — packages set to Public), no token needed.
# If your repo is private, add: --username git --password "${GITHUB_PAT}"
argocd repo add "${GITHUB_REPO}" \
  --insecure-skip-server-verification || true
info "GitHub repo registered with Argo CD: ${GITHUB_REPO}"

# Kill the temporary port-forward
kill "${PF_PID}" 2>/dev/null || true
wait "${PF_PID}" 2>/dev/null || true

# THE ONE MANUAL APPLY.
# This is the bootstrap moment: we tell Argo CD "here is the root Application
# that describes all other Applications." After this single apply, Argo CD
# takes over — it will sync all child apps from Git automatically.
#
# gitops/bootstrap/app-of-apps.yaml points to gitops/apps/ directory.
# Argo CD will find every Application manifest in that directory and deploy them.
# In Phase 1: only sealed-secrets is in gitops/apps/, so only that gets deployed.
# In Phase 2+: we add more apps to gitops/apps/ via Git push — no more manual steps.
kubectl apply -f "${REPO_ROOT}/gitops/bootstrap/app-of-apps.yaml"
info "app-of-apps applied — GitOps loop is now active"
info "Argo CD will sync gitops/apps/ from ${GITHUB_REPO} every 3 minutes"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Print access instructions
# ─────────────────────────────────────────────────────────────────────────────
step "10/10 Bootstrap complete!"

echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo ""
echo "  Cluster '${CLUSTER_NAME}' is running."
echo "  kubectl context: kind-${CLUSTER_NAME}"
echo ""
echo "  Argo CD admin password:"
echo "    ${ARGOCD_PASSWORD}"
echo "  (Also in: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "  To open all dashboards:"
echo "    ./cluster/open-dashboards.sh"
echo ""
echo "  To switch back to another cluster:"
echo "    kubectl config use-context kind-bazel-sim"
echo "    kubectl config use-context kind-bootik-local"
echo "    kubectl config use-context kind-${CLUSTER_NAME}  # back to this one"
echo ""
echo "  To verify the GitOps loop (Phase 1 test):"
echo "    1. Push any file change to ${GITHUB_REPO}"
echo "    2. Watch: argocd app list"
echo "    3. Argo CD should sync within 3 minutes"
echo ""
echo "  To stop this cluster without deleting it:"
echo "    docker stop \$(docker ps -q --filter name=kind-${CLUSTER_NAME})"
echo "  To resume:"
echo "    docker start \$(docker ps -aq --filter name=kind-${CLUSTER_NAME})"
echo "    kubectl config use-context kind-${CLUSTER_NAME}"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo ""
echo "  IMPORTANT — Back up your Sealed Secrets private key NOW:"
echo "  (Wait 30 seconds for the sealed-secrets controller to start first)"
echo ""
echo "    kubectl -n cluster-infra get secret \\"
echo "      -l sealedsecrets.bitnami.com/sealed-secrets-key=active \\"
echo "      -o yaml > ~/sealed-secrets-master-key.yaml"
echo ""
echo "  Store ~/sealed-secrets-master-key.yaml SECURELY (not in Git)."
echo "  If you lose this, you cannot decrypt existing SealedSecrets."
echo ""
echo "─────────────────────────────────────────────────────────────────────"
