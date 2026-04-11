#!/usr/bin/env bash
# =============================================================================
# verify-cluster.sh — End-to-end health check for the remote-builder RBE lab
#
# Checks every layer in order with 10s pauses so you can read each section.
#
# Usage:  ./cluster/verify-cluster.sh
# Exit:   0 = all checks passed / 1 = failures detected
# =============================================================================

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
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

pass() { echo -e "  ${GREEN}✓ $1${RESET}"; }
fail() { echo -e "  ${RED}✗ $1${RESET}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${CYAN}→ $1${RESET}"; }

pause() {
  echo ""
  echo -e "${YELLOW}  (pausing ${1}s)${RESET}"
  sleep "$1"
}

run_cmd() {
  local label="$1"; shift
  echo -e "  ${BOLD}\$ $*${RESET}"
  echo ""
  "$@"
  local rc=$?
  echo ""
  [ $rc -eq 0 ] && pass "$label" || fail "$label (exit $rc)"
  return $rc
}

# Pass if ≥N pods with given label are Running
expect_running() {
  local ns="$1" label="$2" min="$3" desc="$4"
  local count
  count=$(kubectl get pods -n "$ns" -l "$label" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$count" -ge "$min" ]; then
    pass "$desc ($count/$min running)"
  else
    fail "$desc — only $count/$min running in $ns"
  fi
}

# =============================================================================
# SECTION 1 — Kubernetes cluster
# =============================================================================
header "SECTION 1 — Kubernetes cluster"

subheader "Nodes"
run_cmd "kubectl get nodes" kubectl get nodes -o wide
pause 10

subheader "Node labels and taints"
echo -e "  ${BOLD}\$ kubectl get nodes --show-labels${RESET}"
echo ""
kubectl get nodes --show-labels
echo ""
echo -e "  ${BOLD}\$ kubectl describe nodes | grep -A3 'Taints:'${RESET}"
echo ""
kubectl describe nodes | grep -A3 'Taints:'
pause 10

subheader "All pods — overall health snapshot"
run_cmd "All pods" kubectl get pods -A
pause 10

# =============================================================================
# SECTION 2 — Argo CD
# =============================================================================
header "SECTION 2 — Argo CD (GitOps engine)"

subheader "Argo CD pods"
run_cmd "Argo CD pods" kubectl get pods -n argocd

subheader "Argo CD application sync status"
argocd app list 2>/dev/null && pass "argocd app list" || {
  info "argocd CLI session expired or port-forward not running — checking via kubectl"
  kubectl get applications -n argocd
}
pause 10

# =============================================================================
# SECTION 3 — Sealed Secrets
# =============================================================================
header "SECTION 3 — Sealed Secrets"

subheader "Sealed Secrets controller"
run_cmd "Sealed Secrets pod" kubectl get pods -n cluster-infra

subheader "Sealed Secrets logs (last 10 lines)"
echo -e "  ${BOLD}\$ kubectl logs -n cluster-infra -l app.kubernetes.io/name=sealed-secrets --tail=10${RESET}"
echo ""
kubectl logs -n cluster-infra -l app.kubernetes.io/name=sealed-secrets --tail=10 2>&1
echo ""
pause 10

# =============================================================================
# SECTION 4 — Buildbarn: bb-storage
# =============================================================================
header "SECTION 4 — bb-storage (CAS + Action Cache)"

# Pods use app.kubernetes.io/name labels (set by Helm _helpers.tpl), not app=
subheader "bb-storage pod"
echo -e "  ${BOLD}\$ kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-storage${RESET}"
echo ""
kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-storage -o wide
echo ""
expect_running "rbe-system" "app.kubernetes.io/name=bb-storage" 1 "bb-storage running"

subheader "bb-storage service"
run_cmd "bb-storage service" kubectl get svc bb-storage -n rbe-system

BB_STORAGE_POD=$(kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-storage \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BB_STORAGE_POD" ]; then
  subheader "bb-storage logs (last 20 lines)"
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_STORAGE_POD --tail=20${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_STORAGE_POD" --tail=20 2>&1
  echo ""
fi
pause 10

# =============================================================================
# SECTION 5 — Buildbarn: bb-scheduler
# =============================================================================
header "SECTION 5 — bb-scheduler (RBE frontend)"

subheader "bb-scheduler pod"
echo -e "  ${BOLD}\$ kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-scheduler${RESET}"
echo ""
kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-scheduler -o wide
echo ""
expect_running "rbe-system" "app.kubernetes.io/name=bb-scheduler" 1 "bb-scheduler running"

subheader "bb-scheduler service (ports 8981=client, 8982=worker)"
run_cmd "bb-scheduler service" kubectl get svc bb-scheduler -n rbe-system

BB_SCHED_POD=$(kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-scheduler \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BB_SCHED_POD" ]; then
  subheader "bb-scheduler logs (last 20 lines)"
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_SCHED_POD --tail=20${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_SCHED_POD" --tail=20 2>&1
  echo ""
fi
pause 10

# =============================================================================
# SECTION 6 — Buildbarn: bb-worker
# =============================================================================
header "SECTION 6 — bb-worker (build executor, node: pool=rbe-workers)"

subheader "bb-worker pods"
echo -e "  ${BOLD}\$ kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-worker -o wide${RESET}"
echo ""
kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-worker -o wide
echo ""
expect_running "rbe-system" "app.kubernetes.io/name=bb-worker" 1 "bb-worker running"

BB_WORKER_POD=$(kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-worker \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$BB_WORKER_POD" ]; then
  subheader "bb-worker logs — bb-worker container (last 15 lines)"
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_WORKER_POD -c bb-worker --tail=15${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_WORKER_POD" -c bb-worker --tail=15 2>&1
  echo ""
  subheader "bb-worker logs — bb-runner container (last 15 lines)"
  echo -e "  ${BOLD}\$ kubectl logs -n rbe-system $BB_WORKER_POD -c bb-runner --tail=15${RESET}"
  echo ""
  kubectl logs -n rbe-system "$BB_WORKER_POD" -c bb-runner --tail=15 2>&1
  echo ""
fi
pause 10

# =============================================================================
# SECTION 7 — ConfigMaps
# =============================================================================
header "SECTION 7 — ConfigMaps"

run_cmd "rbe-system configmaps" kubectl get configmap -n rbe-system

subheader "bb-storage config"
echo -e "  ${BOLD}\$ kubectl get configmap bb-storage-config -n rbe-system -o jsonpath='{.data.storage\\.json}' | python3 -m json.tool${RESET}"
echo ""
kubectl get configmap bb-storage-config -n rbe-system \
  -o jsonpath='{.data.storage\.json}' 2>/dev/null | python3 -m json.tool 2>/dev/null || \
  kubectl get configmap bb-storage-config -n rbe-system -o jsonpath='{.data.storage\.json}'
echo ""

subheader "bb-scheduler config"
kubectl get configmap bb-scheduler-config -n rbe-system \
  -o jsonpath='{.data.scheduler\.json}' 2>/dev/null | python3 -m json.tool 2>/dev/null || \
  kubectl get configmap bb-scheduler-config -n rbe-system -o jsonpath='{.data.scheduler\.json}'
echo ""

subheader "bb-worker config"
kubectl get configmap bb-worker-config -n rbe-system \
  -o jsonpath='{.data.worker\.json}' 2>/dev/null | python3 -m json.tool 2>/dev/null || \
  kubectl get configmap bb-worker-config -n rbe-system -o jsonpath='{.data.worker\.json}'
echo ""
pause 10

# =============================================================================
# SECTION 8 — Internal connectivity (DNS)
# =============================================================================
header "SECTION 8 — Internal connectivity"

subheader "DNS: bb-storage from rbe-system namespace"
info "Testing FQDN resolution (short names fail in busybox — that is expected)"
echo -e "  ${BOLD}\$ kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i -n rbe-system -- nslookup bb-storage.rbe-system.svc.cluster.local${RESET}"
echo ""
# Use FQDN — busybox nslookup fails on short names due to ndots search order, which is expected
kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i \
  -n rbe-system -- nslookup bb-storage.rbe-system.svc.cluster.local 2>&1 | grep -v "^$" || true

# Check DNS passed by looking for an Address line rather than error
DNS_RESULT=$(kubectl run dns-test2 --image=busybox:1.36 --restart=Never --rm -i \
  -n rbe-system -- nslookup bb-storage.rbe-system.svc.cluster.local 2>&1)
if echo "$DNS_RESULT" | grep -q "Address:.*10\."; then
  pass "bb-storage DNS resolves to ClusterIP"
else
  fail "bb-storage DNS resolution failed"
fi
echo ""

subheader "DNS: bb-scheduler from rbe-system namespace"
DNS_SCHED=$(kubectl run dns-test3 --image=busybox:1.36 --restart=Never --rm -i \
  -n rbe-system -- nslookup bb-scheduler.rbe-system.svc.cluster.local 2>&1)
echo "$DNS_SCHED"
if echo "$DNS_SCHED" | grep -q "Address:.*10\."; then
  pass "bb-scheduler DNS resolves to ClusterIP"
else
  fail "bb-scheduler DNS resolution failed"
fi
pause 10

# =============================================================================
# SECTION 9 — Remote build smoke test
# =============================================================================
header "SECTION 9 — Remote build smoke test"

HELLO_BAZEL_DIR="$(cd "$(dirname "$0")/.." && pwd)/examples/hello-bazel"

if [ ! -f "$HELLO_BAZEL_DIR/MODULE.bazel" ]; then
  fail "examples/hello-bazel not found at $HELLO_BAZEL_DIR — skipping"
else
  SCHED_READY=$(kubectl get pods -n rbe-system -l app.kubernetes.io/name=bb-scheduler \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

  if [ "$SCHED_READY" -lt 1 ]; then
    fail "bb-scheduler not running — skipping smoke test"
  else
    subheader "Starting port-forward: bb-scheduler → localhost:8981"
    pkill -f "port-forward.*8981" 2>/dev/null || true
    sleep 2
    kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system &
    PF_PID=$!
    info "Port-forward PID: $PF_PID"
    sleep 4

    if ! kill -0 $PF_PID 2>/dev/null; then
      fail "Port-forward failed to start"
    else
      pass "Port-forward running on localhost:8981"

      # Build 1: cache miss → remote execution
      subheader "Build 1 — expect REMOTE EXECUTION (cache miss)"
      info "Clearing local Bazel cache to force a genuine cache miss on the RBE side"
      echo ""
      cd "$HELLO_BAZEL_DIR"
      bazel clean --expunge 2>&1
      echo ""
      echo -e "  ${BOLD}\$ bazel build --config=rbe //...${RESET}"
      echo ""
      BUILD1=$(bazel build --config=rbe //... 2>&1)
      echo "$BUILD1"
      echo ""
      if echo "$BUILD1" | grep -qE "[0-9]+ remote[^_]"; then
        pass "Build 1: remote execution confirmed"
      else
        fail "Build 1: no 'remote' in output — check scheduler/worker logs"
      fi

      pause 10

      # Build 2: cache hit
      subheader "Build 2 — expect REMOTE CACHE HIT"
      info "Same action digest — scheduler should return cached result instantly"
      echo ""
      echo -e "  ${BOLD}\$ bazel build --config=rbe //...${RESET}"
      echo ""
      BUILD2=$(bazel build --config=rbe //... 2>&1)
      echo "$BUILD2"
      echo ""
      if echo "$BUILD2" | grep -q "cache hit"; then
        pass "Build 2: remote cache hit confirmed"
      else
        fail "Build 2: no 'cache hit' — action cache may not be persisting"
      fi

      kill $PF_PID 2>/dev/null || true
      info "Port-forward stopped"
    fi
  fi
fi

pause 10

# =============================================================================
# SUMMARY
# =============================================================================
header "SUMMARY"

echo ""
echo -e "${BOLD}All pods:${RESET}"
kubectl get pods -A
echo ""

if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   ALL CHECKS PASSED — cluster is ready   ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo "  Next: Phase 3 — Argo Rollouts (canary deployment for bb-worker)"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║   $FAILURES CHECK(S) FAILED — see above         ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo "  Debug tips:"
  echo "    kubectl describe pod <name> -n rbe-system"
  echo "    kubectl logs <name> -n rbe-system --previous"
  echo "    argocd app sync rbe-system --force"
  echo ""
  exit 1
fi
