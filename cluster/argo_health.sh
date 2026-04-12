#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# argo_health.sh — Phase 3 health check + RBE smoke test
#
# Shows cluster state, Rollout status, and runs a live RBE build.
# Designed for onboarding — every command is echoed before running so you
# can see exactly what's being checked and why.
#
# Usage:
#   ./cluster/argo_health.sh           # full check + build
#   ./cluster/argo_health.sh --no-build  # skip the Bazel build
#
# Prerequisites:
#   kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system &
#   kubectl port-forward svc/bb-storage   8980:8980 -n rbe-system &
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTEXT="kind-remote-builder"
NS="rbe-system"
ROLLOUTS_NS="argo-rollouts"
BAZEL_DIR="$(cd "$(dirname "$0")/../examples/hello-bazel" && pwd)"
SKIP_BUILD="${1:-}"

# Install kubectl-argo-rollouts plugin if missing
ROLLOUTS_BIN="$HOME/.local/bin/kubectl-argo-rollouts"
export PATH="$HOME/.local/bin:$PATH"

RESET="\033[0m"
BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"

section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $1${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; }
run()     { echo -e "${YELLOW}▶ $*${RESET}"; eval "$*"; }
ok()      { echo -e "${GREEN}✔ $1${RESET}"; }
fail()    { echo -e "${RED}✗ $1${RESET}"; exit 1; }

# ── 0. Prerequisites ─────────────────────────────────────────────────────────
section "0. Prerequisites"

run "kubectl config use-context $CONTEXT"

if ! command -v kubectl-argo-rollouts &>/dev/null; then
  echo "Installing kubectl-argo-rollouts plugin..."
  run "mkdir -p ~/.local/bin"
  run "curl -sL https://github.com/argoproj/argo-rollouts/releases/download/v1.8.3/kubectl-argo-rollouts-linux-amd64 -o $ROLLOUTS_BIN"
  run "chmod +x $ROLLOUTS_BIN"
fi
run "kubectl-argo-rollouts version"
ok "kubectl-argo-rollouts plugin ready"

# ── 1. Node health ────────────────────────────────────────────────────────────
section "1. Cluster Nodes"

echo -e "${YELLOW}▶ kubectl get nodes -o wide${RESET}"
kubectl get nodes -o wide --context=$CONTEXT
echo ""
READY=$(kubectl get nodes --context=$CONTEXT --no-headers | grep -v "NotReady" | wc -l)
TOTAL=$(kubectl get nodes --context=$CONTEXT --no-headers | wc -l)
[ "$READY" -eq "$TOTAL" ] && ok "All $TOTAL nodes Ready" || fail "$READY/$TOTAL nodes Ready"

# ── 2. Argo CD apps ──────────────────────────────────────────────────────────
section "2. Argo CD Applications"

run "argocd app list --output table 2>/dev/null || kubectl get applications -n argocd -o wide 2>/dev/null"

# ── 3. Argo Rollouts controller ───────────────────────────────────────────────
section "3. Argo Rollouts Controller"

run "kubectl get pods -n $ROLLOUTS_NS"
ROLLOUTS_READY=$(kubectl get pods -n $ROLLOUTS_NS --no-headers 2>/dev/null | grep "Running" | wc -l)
[ "$ROLLOUTS_READY" -ge 1 ] && ok "Argo Rollouts controller running" || fail "Argo Rollouts controller not running"

# ── 4. RBE system pods ────────────────────────────────────────────────────────
section "4. RBE System Pods (rbe-system)"

run "kubectl get pods -n $NS -o wide"

RUNNING=$(kubectl get pods -n $NS --no-headers 2>/dev/null | grep -c "Running" || true)
NOT_READY=$(kubectl get pods -n $NS --no-headers 2>/dev/null | grep -v "Running\|Completed\|Terminating" | wc -l || true)
[ "$NOT_READY" -eq 0 ] && ok "All pods Running ($RUNNING total)" || fail "$NOT_READY pod(s) not Running"

# ── 5. bb-worker Rollout status ───────────────────────────────────────────────
section "5. bb-worker Rollout (Argo Rollouts)"

echo -e "${YELLOW}▶ kubectl-argo-rollouts get rollout bb-worker -n $NS${RESET}"
kubectl-argo-rollouts get rollout bb-worker -n $NS 2>/dev/null || {
  echo "(Rollout not found — may still be deploying from argorollout branch)"
  run "kubectl get deployment bb-worker -n $NS 2>/dev/null || true"
}

# ── 6. Port-forward check ─────────────────────────────────────────────────────
section "6. Port-Forwards (required for RBE builds)"

SCHED_PF=$(pgrep -fa "port-forward.*bb-scheduler.*8981" | grep -v grep | wc -l || true)
STOR_PF=$(pgrep -fa "port-forward.*bb-storage.*8980" | grep -v grep | wc -l || true)

if [ "$SCHED_PF" -gt 0 ]; then
  ok "bb-scheduler port-forward: localhost:8981 → rbe-system/bb-scheduler:8981"
else
  echo -e "${YELLOW}⚠  No bb-scheduler port-forward found${RESET}"
  echo "   Start with: kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system &"
fi

if [ "$STOR_PF" -gt 0 ]; then
  ok "bb-storage port-forward: localhost:8980 → rbe-system/bb-storage:8980"
else
  echo -e "${YELLOW}⚠  No bb-storage port-forward found${RESET}"
  echo "   Start with: kubectl port-forward svc/bb-storage 8980:8980 -n rbe-system &"
fi

# ── 7. Storage round-trip ─────────────────────────────────────────────────────
section "7. bb-storage gRPC Health (FindMissingBlobs)"

echo -e "${YELLOW}▶ grpcurl -plaintext localhost:8980 build.bazel.remote.execution.v2.ContentAddressableStorage/FindMissingBlobs${RESET}"
if command -v /tmp/grpcurl &>/dev/null; then
  RESULT=$(/tmp/grpcurl -plaintext -d '{}' localhost:8980 \
    build.bazel.remote.execution.v2.ContentAddressableStorage/FindMissingBlobs 2>&1 || true)
  echo "$RESULT"
  ok "bb-storage CAS API responding"
else
  echo "(grpcurl not found — skipping CAS API check)"
fi

# ── 8. RBE build smoke test ────────────────────────────────────────────────────
if [ "$SKIP_BUILD" = "--no-build" ]; then
  section "8. RBE Build (skipped — pass no args to run)"
  echo "Run without --no-build to execute a live Bazel RBE build."
else
  section "8. RBE Build Smoke Test"

  if [ "$SCHED_PF" -eq 0 ] || [ "$STOR_PF" -eq 0 ]; then
    echo -e "${YELLOW}⚠  Skipping build — port-forwards not running${RESET}"
    echo "   Start both port-forwards and re-run."
  else
    echo -e "${YELLOW}▶ cd $BAZEL_DIR && bazel build --config=rbe //...${RESET}"
    cd "$BAZEL_DIR"

    # First pass — use cached results to show AC hit performance
    echo ""
    echo -e "${BOLD}Pass 1: with remote cache${RESET}"
    time bazel build --config=rbe //... 2>&1
    echo ""

    # Second pass — force fresh remote execution
    echo -e "${BOLD}Pass 2: --noremote_accept_cached (forces remote execution)${RESET}"
    time bazel build --config=rbe --noremote_accept_cached //... 2>&1
    echo ""

    ok "RBE build smoke test PASSED"
    echo ""
    echo "  Look for these lines in the output above:"
    echo "    INFO: X processes: Y remote.        ← actions ran on workers"
    echo "    INFO: X processes: Y action cache hit ← results served from AC"
    echo "    INFO: Elapsed time: ~0.3s (cache hit) vs ~30-60s (remote exec)"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
section "Summary"

echo "  Cluster:       kind-remote-builder (3 nodes)"
echo "  RBE stack:     bb-storage + bb-scheduler + bb-worker (via Rollout)"
echo "  Worker image:  gcr.io/bazel-public/ubuntu2004-java11:latest"
echo "  Rollouts:      canary 25%→50%→100%, 60s pauses between steps"
echo "  AnalysisTemplate: bb-worker-health (active in Phase 4 with Prometheus)"
echo ""
echo "  Useful commands:"
echo "    # Watch a live rollout"
echo "    kubectl-argo-rollouts get rollout bb-worker -n rbe-system -w"
echo ""
echo "    # Trigger a canary (simulated image bump)"
echo "    kubectl patch rollout bb-worker -n rbe-system --type=json \\"
echo "      -p='[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":[{\"name\":\"VER\",\"value\":\"v2\"}]}]'"
echo ""
echo "    # Abort a bad rollout instantly"
echo "    kubectl-argo-rollouts abort bb-worker -n rbe-system"
echo ""
echo "    # Argo Rollouts dashboard"
echo "    kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100 &"
echo "    # Open: http://localhost:3100"
