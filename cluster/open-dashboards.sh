#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# open-dashboards.sh — Port-forward all lab UIs to localhost
# ─────────────────────────────────────────────────────────────────────────────
#
# Starts kubectl port-forward processes in the background for every service
# that has a UI or needs to be reachable from your host machine.
#
# Why port-forward instead of NodePort/LoadBalancer?
#   In a kind cluster there's no external load balancer and no MetalLB.
#   kubectl port-forward tunnels traffic from your localhost directly into the
#   cluster's pod network. It's the standard pattern for local cluster access.
#   In production (EKS), these services get proper DNS + TLS via Route53/ACM.
#
# All port-forwards are killed when you press Ctrl+C or close the terminal.
# Re-run this script any time you need dashboards after a terminal restart.
#
# Ports used (verify no conflicts with your other clusters):
#   8080  → Argo CD UI         (bazel-sim uses 30080 → safe)
#   8981  → Buildbarn gRPC     (bazel-sim uses 30090 → safe) [Phase 2+]
#   9090  → Prometheus         (bazel-sim uses 30900 → safe) [Phase 4+]
#   9001  → MinIO browser      (bazel-sim uses 30901 → safe) [Phase 2+]
#   3000  → Grafana            [Phase 4+]
#   7984  → Buildbarn browser  [Phase 2+]
#
# Usage:
#   ./cluster/open-dashboards.sh
#   # Opens dashboards and prints URLs. Press Ctrl+C to stop all tunnels.
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=cluster/config.env
  source "${CONFIG_FILE}"
fi

CLUSTER_NAME="${CLUSTER_NAME:-remote-builder}"

# ── Verify we're pointing at the right cluster ────────────────────────────────
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
if [[ "${CURRENT_CONTEXT}" != "kind-${CLUSTER_NAME}" ]]; then
  echo "WARNING: Current kubectl context is '${CURRENT_CONTEXT}'"
  echo "         Expected 'kind-${CLUSTER_NAME}'"
  echo ""
  echo "Switch with: kubectl config use-context kind-${CLUSTER_NAME}"
  read -rp "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

# ── Colours ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

info() { echo -e "${GREEN}[dashboards]${NC} $*"; }
dim()  { echo -e "${DIM}$*${NC}"; }

# ── Track child PIDs for clean shutdown ───────────────────────────────────────
PIDS=()

cleanup() {
  echo ""
  echo "Stopping all port-forwards..."
  for pid in "${PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "Done."
}
trap cleanup EXIT INT TERM

# ── Helper: start a port-forward if the service exists ───────────────────────
# Usage: forward <namespace> <svc/name> <local-port>:<remote-port> <label> <phase>
forward() {
  local ns="$1"
  local target="$2"
  local ports="$3"
  local label="$4"
  local phase="${5:-current}"
  local local_port="${ports%%:*}"

  # Check if service exists
  if ! kubectl get "${target}" -n "${ns}" &>/dev/null; then
    echo -e "${YELLOW}[skip]${NC}       ${label} — not deployed yet (${phase})"
    return
  fi

  # Check if port is already in use
  if lsof -i ":${local_port}" &>/dev/null; then
    echo -e "${YELLOW}[skip]${NC}       ${label} — port ${local_port} already in use"
    return
  fi

  kubectl port-forward "${target}" "${ports}" -n "${ns}" \
    --address 127.0.0.1 \
    >/dev/null 2>&1 &
  PIDS+=($!)
  info "${label} → http://localhost:${local_port}"
}

echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo "  Starting port-forwards for cluster: ${CLUSTER_NAME}"
echo "─────────────────────────────────────────────────────────────────────"
echo ""

# ── Phase 1: Argo CD ──────────────────────────────────────────────────────────
# Argo CD UI — the primary interface for watching GitOps sync status.
# Login: admin / (password printed by bootstrap.sh, or run the command below)
forward argocd svc/argocd-server 8080:80 \
  "Argo CD UI     http://localhost:8080  (admin / see bootstrap output)" \
  "Phase 1 ✓"

# ── Phase 2: MinIO + Buildbarn ────────────────────────────────────────────────
# MinIO browser — inspect CAS blobs being written by Bazel builds
forward minio svc/minio 9001:9001 \
  "MinIO browser  http://localhost:9001  (minioadmin / minioadmin)" \
  "Phase 2"

# Buildbarn browser — inspect scheduler queue, worker pool status
forward rbe-system svc/buildbarn-browser 7984:7984 \
  "Buildbarn UI   http://localhost:7984" \
  "Phase 2"

# Buildbarn gRPC endpoint — this is what Bazel clients connect to
# Used in .bazelrc: --remote_executor=grpc://localhost:8981
forward rbe-system svc/bb-scheduler 8981:8981 \
  "Bazel gRPC     grpc://localhost:8981  (--remote_executor target)" \
  "Phase 2"

# ── Phase 4: Prometheus + Grafana ─────────────────────────────────────────────
# Prometheus — query the raw metrics KEDA is using for autoscaling decisions
forward cluster-infra svc/prometheus-operated 9090:9090 \
  "Prometheus     http://localhost:9090" \
  "Phase 4"

# Grafana — dashboards showing gRPC RPM, KEDA scaling events, cache hit rate
forward cluster-infra svc/kube-prometheus-stack-grafana 3000:80 \
  "Grafana        http://localhost:3000  (admin / prom-operator)" \
  "Phase 4"

echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo ""

# ── Print Argo CD password ─────────────────────────────────────────────────────
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "(secret not found)")
echo "  Argo CD credentials:"
echo "    Username: admin"
echo "    Password: ${ARGOCD_PASS}"
echo ""
dim "  Port-forwards are running in the background."
dim "  Press Ctrl+C to stop all tunnels."
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo ""

# ── Tail — keep script alive so trap fires on Ctrl+C ─────────────────────────
# If we exit immediately, the background port-forwards die with the script.
echo "Watching for errors (Ctrl+C to stop all)..."
while true; do
  # Check if any port-forward processes have died unexpectedly
  for pid in "${PIDS[@]}"; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo -e "${YELLOW}WARNING: A port-forward process (PID ${pid}) died unexpectedly.${NC}"
      echo "  This can happen if the target service was restarted. Re-run this script."
    fi
  done
  sleep 10
done
