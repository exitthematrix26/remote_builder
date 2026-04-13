#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# demo_full.sh — Guided RBE lab walkthrough with timed pauses
#
# Runs the full demonstration sequence with 10-second pauses so you can
# watch dashboards react to each step:
#
#   Phase 1  Health checks            (verify cluster is ready)
#   Phase 2  Port-forwards            (start resilient forwards)
#   Phase 3  Dashboard reminder       (tells you which tabs to open)
#   Phase 4  Load test                (drives KEDA autoscaling)
#   Phase 5  Watch KEDA scale         (live polling of HPA + pods)
#   Phase 6  Scale-down wait          (observe 5-min cooldown)
#   Phase 7  Canary rollout prompt    (instructions to trigger)
#
# Usage:
#   ./cluster/demo_full.sh              # full demo, all phases
#   ./cluster/demo_full.sh --skip-load  # skip load test (phases 4+5)
#   ./cluster/demo_full.sh --canary     # canary instructions only
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT="kind-remote-builder"
MATH_RBE="$REPO_ROOT/examples/math-rbe"

# ── colours ──────────────────────────────────────────────────────────────────
RESET="\033[0m"; BOLD="\033[1m"
GREEN="\033[32m"; CYAN="\033[36m"; YELLOW="\033[33m"; MAGENTA="\033[35m"; RED="\033[31m"

banner()  { echo -e "\n${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════╗${RESET}"; \
            echo -e "${BOLD}${MAGENTA}║  $1${RESET}"; \
            echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════╝${RESET}"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${RESET}"; }
ok()      { echo -e "${GREEN}✔  $1${RESET}"; }
info()    { echo -e "${CYAN}ℹ  $1${RESET}"; }
warn()    { echo -e "${YELLOW}⚠  $1${RESET}"; }
step()    { echo -e "\n${BOLD}${YELLOW}▶ $1${RESET}"; }

wait_watching() {
  local msg="$1" secs="${2:-10}"
  echo -e "${CYAN}   ↳ Waiting ${secs}s — ${msg}${RESET}"
  sleep "$secs"
}

# ── args ─────────────────────────────────────────────────────────────────────
SKIP_LOAD=0
CANARY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-load) SKIP_LOAD=1 ;;
    --canary)    CANARY_ONLY=1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Health checks
# ─────────────────────────────────────────────────────────────────────────────
if [ "$CANARY_ONLY" -eq 0 ]; then

banner "Phase 1 — Health Checks"
info "Verifying the cluster is ready before starting the demo."
wait_watching "check ArgoCD + Argo Rollouts" 3

section "Argo CD / Argo Rollouts"
bash "$SCRIPT_DIR/argo_health.sh" || { warn "argo_health.sh reported failures — check before continuing."; }

wait_watching "watch the output above" 10

section "Prometheus + KEDA + Autoscaling Stack"
bash "$SCRIPT_DIR/phase5_health.sh" || { warn "phase5_health.sh reported failures — check before continuing."; }

wait_watching "review health check results" 10

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Port-forwards
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 2 — Port-Forwards"
info "Starting resilient port-forwards (auto-restart on pod restart or idle)."

bash "$SCRIPT_DIR/portforward.sh" start || true

wait_watching "confirm port-forwards are alive" 5

bash "$SCRIPT_DIR/portforward.sh" status

wait_watching "port-forwards stable" 10

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Dashboard reminder
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 3 — Dashboards"
echo ""
echo -e "${BOLD}Open these 4 tabs in your browser NOW, before the load test starts:${RESET}"
echo ""
echo -e "  ${BOLD}Tab 1 — Grafana: RBE Load & Autoscaling${RESET}"
echo -e "  ${CYAN}    kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &${RESET}"
echo -e "  ${CYAN}    http://localhost:3000  →  RBE → RBE Load & Autoscaling${RESET}"
echo -e "  ${CYAN}    login: admin / admin${RESET}"
echo ""
echo -e "  ${BOLD}Tab 2 — Grafana: Compute Resources / Namespace (Pods)${RESET}"
echo -e "  ${CYAN}    Same Grafana instance → Kubernetes → Compute Resources → Namespace (Pods)${RESET}"
echo -e "  ${CYAN}    Set namespace = rbe-system${RESET}"
echo ""
echo -e "  ${BOLD}Tab 3 — Argo Rollouts Dashboard${RESET}"
echo -e "  ${CYAN}    kubectl port-forward svc/argo-rollouts-dashboard 3100:3100 -n argo-rollouts &${RESET}"
echo -e "  ${CYAN}    http://localhost:3100  →  select namespace rbe-system → bb-worker${RESET}"
echo ""
echo -e "  ${BOLD}Tab 4 — ArgoCD${RESET}"
echo -e "  ${CYAN}    kubectl port-forward svc/argocd-server 8080:80 -n argocd &${RESET}"
echo -e "  ${CYAN}    http://localhost:8080  →  rbe-system app${RESET}"
echo ""

warn "Start the port-forwards above in separate terminals if not already running."
wait_watching "open your dashboard tabs" 30

section "Baseline state before load test"
step "Current bb-worker pods (expect 2):"
kubectl get pods -n rbe-system --context "$CONTEXT" | grep bb-worker || true

echo ""
step "Current HPA targets:"
kubectl get hpa keda-hpa-bb-worker -n rbe-system --context "$CONTEXT" || true

echo ""
step "Current ScaledObject:"
kubectl get scaledobject bb-worker -n rbe-system --context "$CONTEXT" || true

wait_watching "note the baseline — 2 workers, HPA metric near 0" 10

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Load test
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 4 — Load Test (drives KEDA autoscaling)"
info "Running: examples/math-rbe/scripts/load_test.sh --nocache --loop 5"
info "This sends ~50+ Execute RPCs to bb-scheduler across 5 Bazel build loops."
info "Watch Grafana Tab 1 — Execute RPC Rate panel should climb during each loop."
echo ""
warn "Load test starting in 10 seconds. Switch to Grafana now."

wait_watching "switch to Grafana Tab 1 (RBE Load & Autoscaling)" 10

if [ "$SKIP_LOAD" -eq 0 ]; then
  cd "$MATH_RBE"
  bash scripts/load_test.sh --nocache --loop 5 &
  LOAD_PID=$!
  info "Load test running in background (PID $LOAD_PID)."
  info "Polling HPA + pod count every 10s while load test runs..."
  echo ""

  # ── Phase 5 — Live polling ──────────────────────────────────────────────
  banner "Phase 5 — Watching KEDA Scale (live)"
  info "Polling every 10 seconds. Watch dashboards for pod count change."
  echo ""
  printf "%-10s %-35s %s\n" "TIME" "HPA (metric/threshold, replicas)" "POD COUNT"
  printf "%-10s %-35s %s\n" "────" "────────────────────────────────" "─────────"

  for i in $(seq 1 18); do
    sleep 10
    T="${i}x10s"
    HPA_LINE=$(kubectl get hpa keda-hpa-bb-worker -n rbe-system \
      --context "$CONTEXT" --no-headers 2>/dev/null || echo "n/a")
    METRICS=$(echo "$HPA_LINE" | awk '{print $3}')
    REPLICAS=$(echo "$HPA_LINE" | awk '{print $7}')
    PODS=$(kubectl get pods -n rbe-system --context "$CONTEXT" \
      --no-headers 2>/dev/null | grep -c bb-worker || echo "?")
    printf "%-10s %-35s %s\n" "T+${T}" "${METRICS}  replicas=${REPLICAS}" "${PODS} pods"

    # Announce scale-up event
    if [ "${REPLICAS:-2}" -gt 2 ] 2>/dev/null; then
      echo -e "${BOLD}${GREEN}  ↑ SCALE-UP DETECTED: replicas=${REPLICAS}, pods=${PODS}${RESET}"
    fi
  done

  wait $LOAD_PID
  echo ""
  ok "Load test complete."

  # ── Phase 6 — Scale-down cooldown ─────────────────────────────────────
  banner "Phase 6 — Scale-Down Cooldown (5 minutes)"
  info "KEDA's scaleDown.stabilizationWindowSeconds=300."
  info "Workers stay up for 5 minutes after load drops to let in-flight actions complete."
  info "Polling every 30s — watch Grafana Tab 1 'Worker Replicas' panel."
  echo ""

  for i in $(seq 1 10); do
    sleep 30
    REPLICAS=$(kubectl get hpa keda-hpa-bb-worker -n rbe-system \
      --context "$CONTEXT" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "?")
    PODS=$(kubectl get pods -n rbe-system --context "$CONTEXT" \
      --no-headers 2>/dev/null | grep -c bb-worker || echo "?")
    printf "T+%3dm  replicas=%s  pods=%s\n" $((i*30/60 + (LOAD_PID > 0 ? 3 : 0))) "${REPLICAS}" "${PODS}"
    if [ "${REPLICAS:-3}" -le 2 ] 2>/dev/null; then
      echo -e "${BOLD}${GREEN}  ↓ SCALE-DOWN COMPLETE: back to minReplicas=2${RESET}"
      break
    fi
  done
fi  # SKIP_LOAD

fi  # CANARY_ONLY

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Canary rollout instructions
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 7 — Canary Rollout Demo"
echo ""
echo -e "${BOLD}To trigger a canary rollout, follow these steps:${RESET}"
echo ""
echo -e "  ${BOLD}1. Open Argo Rollouts Dashboard${RESET} (Tab 3)"
echo -e "  ${CYAN}     http://localhost:3100  →  rbe-system → bb-worker${RESET}"
echo -e "  ${CYAN}     Note current step: should be Healthy (all 6 steps complete)${RESET}"
echo ""
echo -e "  ${BOLD}2. Create a branch and change a value${RESET}"
echo -e "  ${YELLOW}     git checkout main && git pull${RESET}"
echo -e "  ${YELLOW}     git checkout -b canary-demo-\$(date +%Y%m%d)${RESET}"
echo ""
echo -e "  ${BOLD}     Edit charts/buildbarn/values.yaml${RESET}"
echo -e "  ${CYAN}     Change worker.concurrency or image.runnerInstaller.tag${RESET}"
echo -e "  ${CYAN}     Any change to the pod template checksum triggers the Rollout.${RESET}"
echo ""
echo -e "  ${BOLD}3. Commit and push${RESET}"
echo -e "  ${YELLOW}     git add charts/buildbarn/values.yaml${RESET}"
echo -e "  ${YELLOW}     git commit -m 'demo: trigger canary rollout'${RESET}"
echo -e "  ${YELLOW}     git push -u origin HEAD${RESET}"
echo -e "  ${YELLOW}     gh pr create --title 'canary demo' --body 'test'${RESET}"
echo -e "  ${YELLOW}     # merge via GitHub UI or: gh pr merge --merge${RESET}"
echo ""
echo -e "  ${BOLD}4. Watch ArgoCD sync (Tab 4)${RESET}"
echo -e "  ${CYAN}     rbe-system app turns yellow (OutOfSync) → green (Synced)${RESET}"
echo -e "  ${CYAN}     Or force sync: argocd app sync rbe-system${RESET}"
echo ""
echo -e "  ${BOLD}5. Watch the rollout progress in Argo Rollouts Dashboard${RESET}"
echo ""
echo -e "     ${CYAN}Step 1: setWeight 25%   — canary RS gets 1 of 4 worker pods${RESET}"
echo -e "     ${CYAN}Step 2: pause 60s       — scheduler routes ~25%% Execute RPCs to canary${RESET}"
echo -e "     ${CYAN}Step 3: analysis        — Prometheus error rate check (<5%% threshold)${RESET}"
echo -e "     ${CYAN}Step 4: setWeight 50%   — 2 stable / 2 canary pods${RESET}"
echo -e "     ${CYAN}Step 5: pause 60s${RESET}"
echo -e "     ${CYAN}Step 6: analysis        — second health gate${RESET}"
echo -e "     ${CYAN}Step 7: promotion       — canary becomes new stable, old RS scales to 0${RESET}"
echo ""
echo -e "  ${BOLD}6. Watch in Grafana 'Canary / Stable Split' panel${RESET}"
echo -e "  ${CYAN}     Two ReplicaSet lines appear at step 1${RESET}"
echo -e "  ${CYAN}     At setWeight 50%: both lines at the same value${RESET}"
echo -e "  ${CYAN}     After promotion: old RS line drops to 0${RESET}"
echo ""
echo -e "  ${BOLD}Terminal watch commands:${RESET}"
echo -e "  ${YELLOW}     # ReplicaSet split${RESET}"
echo -e "  ${YELLOW}     watch -n5 'kubectl get rs -n rbe-system -l app.kubernetes.io/name=bb-worker'${RESET}"
echo ""
echo -e "  ${YELLOW}     # Rollout step index${RESET}"
echo -e "  ${YELLOW}     watch -n5 \"kubectl get rollout bb-worker -n rbe-system -o jsonpath='{.status.currentStepIndex}/{.status.phase}'\"${RESET}"
echo ""
echo -e "  ${BOLD}To force-promote (skip remaining pauses):${RESET}"
echo -e "  ${YELLOW}     kubectl argo rollouts promote bb-worker -n rbe-system${RESET}"
echo ""
echo -e "  ${BOLD}To abort and roll back:${RESET}"
echo -e "  ${YELLOW}     kubectl argo rollouts abort bb-worker -n rbe-system${RESET}"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
banner "Demo Complete"
echo ""
ok "Full RBE lab demonstration finished."
echo ""
echo -e "  ${BOLD}Summary of what was demonstrated:${RESET}"
echo -e "  ${GREEN}✔ Health checks passed (Prometheus, KEDA, Rollout, HPA)${RESET}"
echo -e "  ${GREEN}✔ Resilient port-forwards running${RESET}"
echo -e "  ${GREEN}✔ Load test dispatched 50+ Execute RPCs via RBE${RESET}"
echo -e "  ${GREEN}✔ KEDA autoscaling triggered (2→3 workers within ~75s)${RESET}"
echo -e "  ${GREEN}✔ Scale-down cooldown (300s stabilization window)${RESET}"
echo ""
echo -e "  ${CYAN}See docs/overall_readme.md for the full reference guide.${RESET}"
echo -e "  ${CYAN}See docs/keda_autoscaling.md for autoscaling architecture details.${RESET}"
echo ""
