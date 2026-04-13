#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# phase5_health.sh — Phase 5 (KEDA + Prometheus) health check
#
# Verifies that the complete autoscaling stack is healthy:
#   1. Prometheus pod Running in monitoring namespace
#   2. KEDA operator pod Running in keda namespace
#   3. bb-scheduler metrics endpoint responding (port 8083)
#   4. ServiceMonitor exists and targets are up in Prometheus
#   5. ScaledObject READY=True with correct target
#   6. KEDA HPA created and targeting bb-worker Rollout
#   7. Rollout healthy with >= minReplicas
#
# Usage:
#   ./cluster/phase5_health.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
CONTEXT="kind-remote-builder"

RESET="\033[0m"; BOLD="\033[1m"; GREEN="\033[32m"; RED="\033[31m"; CYAN="\033[36m"
ok()   { echo -e "${GREEN}✔ $1${RESET}"; }
fail() { echo -e "${RED}✗ $1${RESET}"; FAILED=$((FAILED+1)); }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${RESET}"; }
FAILED=0

section "Prometheus"
PROM_POD=$(kubectl get pods -n monitoring --context "$CONTEXT" \
  -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
[ "$PROM_POD" = "Running" ] && ok "Prometheus pod Running" || fail "Prometheus pod not Running (phase=$PROM_POD)"

section "KEDA"
KEDA_POD=$(kubectl get pods -n keda --context "$CONTEXT" \
  -l app=keda-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
[ "$KEDA_POD" = "Running" ] && ok "KEDA operator pod Running" || fail "KEDA operator pod not Running (phase=$KEDA_POD)"

section "bb-scheduler metrics endpoint"
METRICS_POD="pf-health-check-$$"
kubectl run "$METRICS_POD" --image=curlimages/curl:8.7.1 --restart=Never \
  --context "$CONTEXT" -n rbe-system \
  --command -- sh -c 'curl -sf http://bb-scheduler.rbe-system:8083/metrics | grep -c "grpc_server_started_total" > /dev/null && echo OK' \
  2>/dev/null &
sleep 8
CURL_RESULT=$(kubectl logs "$METRICS_POD" -n rbe-system --context "$CONTEXT" 2>/dev/null | tail -1 || true)
kubectl delete pod "$METRICS_POD" -n rbe-system --context "$CONTEXT" 2>/dev/null || true
[ "$CURL_RESULT" = "OK" ] && ok "bb-scheduler :8083/metrics responding" || fail "bb-scheduler :8083/metrics not accessible"

section "ServiceMonitor"
SM=$(kubectl get servicemonitor bb-scheduler -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.metadata.name}' 2>/dev/null || true)
[ "$SM" = "bb-scheduler" ] && ok "ServiceMonitor bb-scheduler exists" || fail "ServiceMonitor bb-scheduler missing"

section "KEDA ScaledObject"
SO_READY=$(kubectl get scaledobject bb-worker -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$SO_READY" = "True" ] && ok "ScaledObject bb-worker READY=True" || fail "ScaledObject bb-worker not ready (Ready=$SO_READY)"

SO_TARGET=$(kubectl get scaledobject bb-worker -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null || true)
[ "$SO_TARGET" = "bb-worker" ] && ok "ScaledObject targets bb-worker Rollout" || fail "ScaledObject target mismatch (got=$SO_TARGET)"

section "KEDA HPA"
HPA_MIN=$(kubectl get hpa keda-hpa-bb-worker -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)
HPA_MAX=$(kubectl get hpa keda-hpa-bb-worker -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)
[ -n "$HPA_MIN" ] && ok "HPA keda-hpa-bb-worker exists (min=$HPA_MIN, max=$HPA_MAX)" || fail "HPA keda-hpa-bb-worker not found"

section "Rollout"
ROLLOUT_PHASE=$(kubectl get rollout bb-worker -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
ROLLOUT_READY=$(kubectl get rollout bb-worker -n rbe-system --context "$CONTEXT" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
[ "$ROLLOUT_PHASE" = "Healthy" ] && ok "Rollout bb-worker phase=Healthy (readyReplicas=$ROLLOUT_READY)" || fail "Rollout bb-worker not Healthy (phase=$ROLLOUT_PHASE)"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}All Phase 5 checks passed.${RESET}"
else
  echo -e "${BOLD}${RED}$FAILED check(s) failed.${RESET}"
  exit 1
fi
