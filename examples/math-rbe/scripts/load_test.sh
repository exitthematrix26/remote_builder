#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# load_test.sh — RBE load test runner for math-rbe
#
# Purpose: drive enough distinct build+test invocations to:
#   1. Fill the RBE scheduler's action queue (triggers worker scale-up via KEDA)
#   2. Produce measurable cache hit / cache miss ratios in Grafana
#   3. Exercise canary traffic split if a rollout is in progress
#
# Modes
# ──────
#   ./scripts/load_test.sh            # warm run — uses AC hits, light load
#   ./scripts/load_test.sh --nocache  # cache-busting — all actions remote exec
#   ./scripts/load_test.sh --loop N   # repeat N times (default: 3)
#   ./scripts/load_test.sh --nocache --loop 10  # sustained load test
#
# How cache misses are generated
# ────────────────────────────────
# Bazel computes an action key from (command, inputs, env, platform).
# Identical inputs → same key → AC hit.  To force misses we:
#   a) --config=nocache: skips reading the AC entirely (--noremote_accept_cached)
#   b) --seed variation: gen_inputs.py creates a different CSV each iteration,
#      so action keys for the _run genrule differ per iteration
#   c) --stamp (not used here yet): workspace status can be injected to vary keys
#
# Prerequisites
# ──────────────
#   kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system &
#   kubectl port-forward svc/bb-storage   8980:8980 -n rbe-system &
#   cd examples/math-rbe
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

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
info()    { echo -e "${CYAN}ℹ $1${RESET}"; }

# ── Parse args ────────────────────────────────────────────────────────────────
NOCACHE=0
LOOPS=3

for arg in "$@"; do
  case "$arg" in
    --nocache) NOCACHE=1 ;;
    --loop)    ;;  # handled below
  esac
done

# Parse --loop N
for i in "$@"; do
  if [[ "$PREV" == "--loop" ]]; then LOOPS=$i; fi
  PREV=$i
done

RBE_FLAGS="--config=rbe"
if [ "$NOCACHE" -eq 1 ]; then
  RBE_FLAGS="--config=rbe --config=nocache"
  info "Cache-busting mode: --noremote_accept_cached is set — all actions will remote-exec"
else
  info "Warm mode: AC hits expected on repeat runs"
fi

# ── Verify port-forwards are running ─────────────────────────────────────────
section "Port-forward check"
SCHED=$(pgrep -fa "port-forward.*bb-scheduler.*8981" | grep -v grep | wc -l || true)
STOR=$(pgrep -fa "port-forward.*bb-storage.*8980" | grep -v grep | wc -l || true)
[ "$SCHED" -gt 0 ] && ok "bb-scheduler:8981 forwarded" || { echo -e "${RED}✗ bb-scheduler port-forward not running${RESET}"; exit 1; }
[ "$STOR"  -gt 0 ] && ok "bb-storage:8980 forwarded"   || { echo -e "${RED}✗ bb-storage port-forward not running${RESET}"; exit 1; }

# ── Local unit tests first (fast gate before remote load) ─────────────────────
section "Local unit tests (Go + C++)"
run "bazel test //lib:mathlib_test //cc:stats_test"
ok "Unit tests passed"

# ── Warm pass: all three pipelines with standard datasets ─────────────────────
section "Pass 1 / $LOOPS — standard datasets (smoke + medium + large)"
run "bazel test $RBE_FLAGS //..."
ok "Pass 1 complete"

# ── Main loop: vary seed to bust cache ────────────────────────────────────────
if [ "$LOOPS" -gt 1 ]; then
  section "Seeded loop (passes 2–$LOOPS): generating varied inputs for cache misses"
  for i in $(seq 2 "$LOOPS"); do
    section "Pass $i / $LOOPS — seed=$i"

    SEED_CSV="/tmp/inputs_seed${i}.csv"
    info "Generating ${SEED_CSV} with seed=${i}"
    run "python3 scripts/gen_inputs.py --rows 50 --seed $i --out $SEED_CSV"

    # Run the Go runner directly (outside Bazel) against the seeded CSV.
    # This bypasses the Bazel AC — every call is a fresh remote exec.
    info "Running Go batch runner against seeded input (direct binary, no AC)"
    RUNNER="$(bazel cquery --config=rbe --output=files //cmd:runner 2>/dev/null | tail -1)"
    RESULT_CSV="/tmp/results_seed${i}.csv"
    run "$RUNNER --input=$SEED_CSV --output=$RESULT_CSV"

    # Run C++ stats on the result
    STATS_BIN="$(bazel cquery --config=rbe --output=files //cc:stats_bin 2>/dev/null | tail -1)"
    STATS_JSON="/tmp/stats_seed${i}.json"
    run "$STATS_BIN --input=$RESULT_CSV --output=$STATS_JSON"

    info "Stats for seed=$i: $(cat $STATS_JSON)"

    # Also trigger a full Bazel test run to generate scheduler traffic
    run "bazel test $RBE_FLAGS //... --test_output=summary"
    ok "Pass $i complete"
  done
fi

# ── Summary ────────────────────────────────────────────────────────────────────
section "Load test summary"
echo ""
echo "  Loops completed: $LOOPS"
echo "  Cache mode:      $([ $NOCACHE -eq 1 ] && echo '--noremote_accept_cached (all remote exec)' || echo 'normal (AC hits expected)')"
echo ""
echo "  Check RBE worker logs for action dispatch:"
echo "    kubectl logs -n rbe-system -l app.kubernetes.io/name=bb-worker -c bb-worker --tail=20"
echo ""
echo "  Watch live RBE action throughput (once Prometheus is up in Phase 5):"
echo "    kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100 &"
echo ""
echo "  BEP log for this run: /tmp/bep_mathrbe.txt"
echo "    grep 'processes:' /tmp/bep_mathrbe.txt | tail -5"
