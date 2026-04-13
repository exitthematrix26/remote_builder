#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# portforward.sh — resilient port-forwards for the RBE lab
#
# WHY PLAIN kubectl port-forward IS FRAGILE
# ──────────────────────────────────────────
# kubectl port-forward opens a single long-lived HTTP/2 stream to the apiserver.
# It dies when:
#   - The target pod restarts (new pod → new stream needed)
#   - The apiserver connection times out (typically 30–60 min idle)
#   - The parent shell exits (SIGHUP kills the process)
#   - Network blips (TCP RST not immediately visible to the process)
#
# This script wraps each port-forward in a retry loop + disowns the process
# so it outlives the shell.  A PID file lets you stop it cleanly.
#
# Usage:
#   ./cluster/portforward.sh start    # start all forwards in background
#   ./cluster/portforward.sh stop     # kill all managed forwards
#   ./cluster/portforward.sh status   # show which forwards are running
#
# Forwards managed:
#   bb-scheduler:8981   Bazel --remote_executor
#   bb-storage:8980     Bazel --remote_cache
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTEXT="kind-remote-builder"
PID_DIR="/tmp/rbe-portforward-pids"
mkdir -p "$PID_DIR"

RESET="\033[0m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"
ok()   { echo -e "${GREEN}✔ $1${RESET}"; }
info() { echo -e "${CYAN}ℹ $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $1${RESET}"; }

# forward_loop <name> <namespace> <svc> <local-port>:<remote-port>
forward_loop() {
  local name="$1" ns="$2" svc="$3" ports="$4"
  local pidfile="$PID_DIR/${name}.pid"

  # Already running?
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    warn "$name already running (PID $(cat "$pidfile"))"
    return
  fi

  (
    while true; do
      kubectl port-forward "svc/$svc" "$ports" -n "$ns" --context "$CONTEXT" \
        >/tmp/pf-${name}.log 2>&1 || true
      # Connection dropped — wait 2s then retry
      sleep 2
    done
  ) &
  echo $! > "$pidfile"
  disown $!
  ok "$name started (PID $!, $ports)"
}

cmd="${1:-help}"

case "$cmd" in
  start)
    info "Starting RBE port-forwards (auto-restart on drop)..."
    forward_loop "scheduler" "rbe-system" "bb-scheduler" "8981:8981"
    forward_loop "storage"   "rbe-system" "bb-storage"   "8980:8980"
    echo ""
    info "Port-forwards are running in background."
    info "Run './cluster/portforward.sh status' to check."
    info "Run './cluster/portforward.sh stop'   to stop."
    ;;

  stop)
    for pidfile in "$PID_DIR"/*.pid; do
      [ -f "$pidfile" ] || continue
      name="$(basename "$pidfile" .pid)"
      pid="$(cat "$pidfile")"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && ok "Stopped $name (PID $pid)"
      else
        warn "$name was not running"
      fi
      rm -f "$pidfile"
    done
    # Also kill any orphaned kubectl port-forward processes
    pkill -f "kubectl port-forward.*rbe-system" 2>/dev/null || true
    ok "All RBE port-forwards stopped"
    ;;

  status)
    echo ""
    printf "%-15s %-8s %-10s %s\n" "NAME" "PID" "STATUS" "PORTS"
    printf "%-15s %-8s %-10s %s\n" "────" "───" "──────" "─────"
    for pidfile in "$PID_DIR"/*.pid; do
      [ -f "$pidfile" ] || { echo "(none running)"; break; }
      name="$(basename "$pidfile" .pid)"
      pid="$(cat "$pidfile")"
      if kill -0 "$pid" 2>/dev/null; then
        ports="$(pgrep -af "kubectl port-forward.*$name" 2>/dev/null | grep -oP '\d+:\d+' | head -1 || true)"
        printf "%-15s %-8s ${GREEN}%-10s${RESET} %s\n" "$name" "$pid" "running" "${ports:-?}"
      else
        printf "%-15s %-8s ${RED}%-10s${RESET}\n" "$name" "$pid" "dead"
        rm -f "$pidfile"
      fi
    done
    echo ""
    ;;

  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
