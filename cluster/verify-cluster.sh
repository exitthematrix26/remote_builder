#!/usr/bin/env bash
# =============================================================================
# verify-cluster.sh — End-to-end health check for the remote-builder RBE lab
#
# Runs through every layer of the stack in order, printing results and pausing
# so you can read each section before moving on.
#
# Usage:
#   ./cluster/verify-cluster.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed (script continues to the end, then exits 1)
# =============================================================================

set -uo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

FAILURES=0

# ── Helpers ───────────────────────────────────────────────────────────────────

header() {
  echo ""
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${RESET}"
  echo ""
}

subheader() {
  echo ""
  echo -e "${YELLOW}${BOLD}── $1 ──${RESET}"
  echo ""
}

pass() {
  echo -e "  ${GREEN}✓ $1${RESET}"
}

fail() {
  echo -e "  ${RED}✗ $1${RESET}"
  FAILURES=$((FAILURES + 1))
}

info() {
  echo -e "  ${CYAN}→ $1${RESET}"
}

pause() {
  echo ""
  echo -e "${YELLOW}  (pausing ${1}s — read the output above)${RESET}"
  sleep "$1"
}

run_cmd() {
  # run_cmd <label> <command...>
  local label="$1"; shift
  echo -e "  ${BOLD}\$ $*${RESET}"
  echo ""
  "$@"
  local rc=$?
  echo ""
  if [ $rc -eq 0 ]; then
    pass "$label"
  else
    fail "$label (exit code $rc)"
  fi
  return $rc
}

# Check a pod count — pass if at least N pods with a given label are Running
expect_running() {
  local namespace="$1"
  local label="$2"
  local min="$3"
  local description="$4"
  local count
  count=$(kubectl get pods -n "$namespace" -l "$label" \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l)
  if [ "$count" -ge "$min" ]; then
    pass "$description ($count/$min running)"
  else
    fail "$description — only $count/$min running in $namespace"
  fi
}

# =============================================================================
# SECTION 1 — Kubernetes cluster basics
# =============================================================================
header "SECTION 1 — Kubernetes cluster"

subheader "Nodes"
run_cmd "kubectl get nodes" kubectl get nodes -o wide
pause 5

subheader "Node taints and labels (worker placement)"
echo -e "  ${BOLD}\$ kubectl get nodes --show-labels${RESET}"
echo ""
kubectl get nodes --show-labels
echo ""
echo -e "  ${BOLD}\$ kubectl describe nodes | grep -A3 'Taints:'${RESET}"
echo ""
kubectl describe nodes | grep -A3 'Taints:'
pause 5

subheader "All pods — overall health snapshot"
run_cmd "kubectl get pods -A" kubectl get pods -A
pause 8

# =============================================================================
# SECTION 2 — Argo CD
# =============================================================================
header "SECTION 2 — Argo CD (GitOps engine)"

subheader "Argo CD pods"
run_cmd "Argo CD pods" kubectl get pods -n argocd

pause 4

subheader "Argo CD application sync status"
run_cmd "argocd app list" argocd app list 2>/dev/null || {
  info "argocd CLI not logged in — checking via kubectl instead"
  kubectl get applications -n argocd
}

pause 5

# =============================================================================
# SECTION 3 — Sealed Secrets
# =============================================================================
header "SECTION 3 — Sealed Secrets (secret encryption)"

subheader "Sealed Secrets controller"
run_cmd "Sealed Secrets pod" kubectl get pods -n cluster-infra

subheader "Sealed Secrets controller logs (last 10 lines)"
echo -e "  ${BOLD}\$ kubectl logs -n cluster-infra -l app.kubernetes.io/name=sealed-secrets --tail=10${RESET}"
echo ""
kubectl logs -n cluster-infra -l app.kubernetes.io/name=sealed-secrets --tail=10 2>&1
echo ""

pause 5

# =============================================================================
# SECTION 4 — MinIO
# =============================================================================
header "SECTION 4 — MinIO (object storage backend)"

subheader "MinIO pod"
run_cmd "MinIO pod" kubectl get pods -n minio -o wide

subheader "MinIO service"
run_cmd "MinIO service" kubectl get svc -n minio

subheader "MinIO PersistentVolumeClaim"
run_cmd "MinIO PVC" kubectl get pvc -n minio

subheader "MinIO pod logs (last 15 lines)"
echo -e "  ${BOLD}\$ kubectl logs -n minio -l app=minio --tail=15${RESET}"
echo ""
kubectl logs -n minio -l app=minio --tail=15 2>&1
echo ""

expect_running "minio" "app=minio" 1 "MinIO running"

pause 6

# =============================================================================
# SECTION 5 — Buildbarn (rbe-system)
# =============================================================================
header "SECTION 5 — Buildbarn RBE stack (rbe-system)"

subheader "All rbe-system pods"
run_cmd "rbe-system pods" kubectl get pods -n rbe-system -o wide

pause 5

subheader "rbe-system services (ClusterIP)"
run_cmd "rbe-system services" kubectl get svc -n rbe-system

pause 4

subheader "rbe-system ConfigMaps"
run_cmd "rbe-system configmaps" kubectl get configmap -n rbe-system

pause 3

# ── bb-storage ────────────────────────────────────────────────────────────────
subheader "bb-storage — CAS + Action Cache"
echo -e "  ${BOLD}\$ kubectl get pods -n rbe-system -l app=bb-storage${RESET}"
echo ""
kubectl get pods -n rbe-system -l app=bb-storage
echo ""

BB_STORAGE_POD=$(kubectl get pods -n rbe-system -l app=bb-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BB_STORAGE_POD" ]; then
  info "Pod: $BB_STORAGE_POD"
  echo ""
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_STORAGE_POD --tail=20${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_STORAGE_POD" --tail=20 2>&1
  echo ""
  expect_running "rbe-system" "app=bb-storage" 1 "bb-storage running"
else
  fail "bb-storage pod not found"
fi

pause 6

# ── bb-scheduler ──────────────────────────────────────────────────────────────
subheader "bb-scheduler — RBE frontend (Bazel entry point)"
echo -e "  ${BOLD}\$ kubectl get pods -n rbe-system -l app=bb-scheduler${RESET}"
echo ""
kubectl get pods -n rbe-system -l app=bb-scheduler
echo ""

BB_SCHED_POD=$(kubectl get pods -n rbe-system -l app=bb-scheduler -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BB_SCHED_POD" ]; then
  info "Pod: $BB_SCHED_POD"
  echo ""
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_SCHED_POD --tail=20${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_SCHED_POD" --tail=20 2>&1
  echo ""
  expect_running "rbe-system" "app=bb-scheduler" 1 "bb-scheduler running"
else
  fail "bb-scheduler pod not found"
fi

pause 6

# ── bb-worker ─────────────────────────────────────────────────────────────────
subheader "bb-worker — build executor (runs on pool=rbe-workers node)"
echo -e "  ${BOLD}\$ kubectl get pods -n rbe-system -l app=bb-worker -o wide${RESET}"
echo ""
kubectl get pods -n rbe-system -l app=bb-worker -o wide
echo ""

BB_WORKER_POD=$(kubectl get pods -n rbe-system -l app=bb-worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BB_WORKER_POD" ]; then
  info "Pod: $BB_WORKER_POD"
  echo ""
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_WORKER_POD -c bb-worker --tail=15${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_WORKER_POD" -c bb-worker --tail=15 2>&1
  echo ""
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_WORKER_POD -c bb-runner --tail=15${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_WORKER_POD" -c bb-runner --tail=15 2>&1
  echo ""
  expect_running "rbe-system" "app=bb-worker" 1 "bb-worker running"
else
  fail "bb-worker pod not found"
fi

pause 6

# =============================================================================
# SECTION 6 — Connectivity checks
# =============================================================================
header "SECTION 6 — Internal connectivity"

subheader "DNS resolution: bb-storage from within rbe-system"
echo -e "  ${BOLD}\$ kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i -n rbe-system -- nslookup bb-storage${RESET}"
echo ""
kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i \
  -n rbe-system -- nslookup bb-storage 2>&1 || true
echo ""

pause 4

subheader "DNS resolution: minio from rbe-system (storage backend)"
echo -e "  ${BOLD}\$ kubectl run dns-test2 --image=busybox:1.36 --restart=Never --rm -i -n rbe-system -- nslookup minio.minio${RESET}"
echo ""
kubectl run dns-test2 --image=busybox:1.36 --restart=Never --rm -i \
  -n rbe-system -- nslookup minio.minio 2>&1 || true
echo ""

pause 4

# =============================================================================
# SECTION 7 — Remote build smoke test
# =============================================================================
header "SECTION 7 — Remote build smoke test"

HELLO_BAZEL_DIR="$(cd "$(dirname "$0")/.." && pwd)/examples/hello-bazel"

if [ ! -f "$HELLO_BAZEL_DIR/MODULE.bazel" ]; then
  fail "examples/hello-bazel not found at $HELLO_BAZEL_DIR — skipping smoke test"
else
  # Check if bb-scheduler is ready before trying
  SCHED_READY=$(kubectl get pods -n rbe-system -l app=bb-scheduler \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

  if [ "$SCHED_READY" -lt 1 ]; then
    fail "bb-scheduler not running — skipping smoke test"
  else
    subheader "Starting port-forward: bb-scheduler → localhost:8981"
    info "Killing any existing port-forward on 8981..."
    pkill -f "port-forward.*8981" 2>/dev/null || true
    sleep 1

    kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system &
    PF_PID=$!
    info "Port-forward PID: $PF_PID"
    sleep 3

    if ! kill -0 $PF_PID 2>/dev/null; then
      fail "Port-forward failed to start"
    else
      pass "Port-forward running on localhost:8981"

      # ── First build: expect cache miss → remote execution
      subheader "Build 1 of 2 — expect REMOTE EXECUTION (cache miss)"
      info "This action has never been built — it must run on the worker"
      echo ""
      echo -e "  ${BOLD}\$ cd $HELLO_BAZEL_DIR && bazel clean && bazel build --config=rbe //...${RESET}"
      echo ""

      cd "$HELLO_BAZEL_DIR"
      bazel clean --expunge 2>&1
      echo ""

      BUILD1_OUTPUT=$(bazel build --config=rbe //... 2>&1)
      BUILD1_EXIT=$?
      echo "$BUILD1_OUTPUT"
      echo ""

      if echo "$BUILD1_OUTPUT" | grep -q "remote"; then
        pass "Build 1: remote execution confirmed"
      else
        fail "Build 1: no 'remote' in output — check scheduler/worker logs"
      fi

      pause 5

      # ── Second build: expect cache hit
      subheader "Build 2 of 2 — expect REMOTE CACHE HIT"
      info "Same action digest — bb-scheduler should return cached result instantly"
      echo ""
      echo -e "  ${BOLD}\$ bazel build --config=rbe //...${RESET}"
      echo ""

      BUILD2_OUTPUT=$(bazel build --config=rbe //... 2>&1)
      BUILD2_EXIT=$?
      echo "$BUILD2_OUTPUT"
      echo ""

      if echo "$BUILD2_OUTPUT" | grep -q "cache hit"; then
        pass "Build 2: remote cache hit confirmed"
      else
        fail "Build 2: no 'cache hit' in output — action cache may not be persisting"
      fi

      # Clean up port-forward
      kill $PF_PID 2>/dev/null || true
      info "Port-forward stopped"
    fi
  fi
fi

pause 5

# =============================================================================
# SUMMARY
# =============================================================================
header "VERIFICATION SUMMARY"

echo ""
kubectl get pods -A
echo ""

if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   ALL CHECKS PASSED — cluster is ready   ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo ""
  echo "  Next step: Phase 3 — Argo Rollouts (canary deployment for bb-worker)"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   $FAILURES CHECK(S) FAILED — see above     ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo ""
  echo "  Tips:"
  echo "    kubectl describe pod <pod-name> -n rbe-system"
  echo "    kubectl logs <pod-name> -n rbe-system --previous"
  echo "    argocd app get rbe-system"
  echo ""
  exit 1
fi
