# Grafana Dashboard Guide — RBE Load & Autoscaling

How to read the custom RBE dashboard while running a load test or watching a
canary rollout.  Each panel is explained: what the metric is, what "normal"
looks like, and what to watch for.

---

## Access

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &
# http://localhost:3000   login: admin / admin
# Navigate: General → "RBE Load & Autoscaling"
# Time range: top-right → "Last 15 minutes"  (set refresh to 15s)
```

---

## Panel Map

```
┌─────────────────────────┬─────────────────────────┐
│  1. Execute RPC Rate    │  2. Worker Replicas      │
├─────────────────────────┼─────────────────────────┤
│  3. KEDA Trigger Value  │  4. Action Duration      │
├─────────────────────────┼─────────────────────────┤
│  5. Canary/Stable Split │  6. Success vs Errors    │
└─────────────────────────┴─────────────────────────┘
```

---

## Panel 1 — Execute RPC Rate

**What it shows:** Incoming RBE Execute RPCs per second hitting bb-scheduler.

**Metric:**
```promql
rate(grpc_server_started_total{
  namespace="rbe-system", job="bb-scheduler", grpc_method="Execute"
}[1m])
```

**Reading it:**

| What you see | What it means |
|---|---|
| Flat at 0 | No active Bazel build using RBE |
| Spike to 0.2–1.0/s | Load test running — Bazel dispatching actions |
| Multiple spikes | Each `bazel test --config=rbe //...` loop |
| Sustained > 0.5/s | Enough load to hold workers above minReplicas |

**This is the KEDA trigger source.** KEDA polls `increase(this_metric[2m])` every 15s.  When the area under this curve exceeds `threshold × current_replicas`, a new worker pod is added.

---

## Panel 2 — Worker Replicas

**What it shows:** Current, minimum, and maximum replica count for the
`bb-worker` Rollout as seen by the KEDA-managed HPA.

**Metrics:**
```promql
kube_horizontalpodautoscaler_status_current_replicas{...hpa="keda-hpa-bb-worker"}  ← Current
kube_horizontalpodautoscaler_spec_min_replicas{...}                                 ← Min (2)
kube_horizontalpodautoscaler_spec_max_replicas{...}                                 ← Max (6)
```

**Reading it:**

| What you see | What it means |
|---|---|
| Current flat at 2 | Idle — at minReplicas, no load |
| Current steps up 2→3 | KEDA fired a scale-up event |
| Current steps down after ~5 min | Scale-down stabilization (300s) expired |
| Current hits 6 | Saturated at maxReplicas — consider raising the limit |

**The step up is the money shot** — this is your visual confirmation that
KEDA detected load and added capacity.  It typically lags Panel 1 by 30–75
seconds (KEDA polls every 15s, pod takes ~20s to become Ready).

---

## Panel 3 — KEDA Trigger Value vs Threshold

**What it shows:** The raw value KEDA feeds into its scale formula, plotted
against the threshold line.

**Metrics:**
```promql
# Trigger value (what KEDA sees)
sum(increase(grpc_server_started_total{...,grpc_method="Execute"}[2m]))

# Threshold reference line (constant 4)
0 * grpc_server_started_total{...} + 4
```

**The KEDA scale formula:**
```
desiredReplicas = ceil(trigger_value / threshold)
                = ceil(trigger_value / 4)
```

**Reading it:**

| Trigger value | desiredReplicas | Scale action |
|---|---|---|
| 0–3 | 0 → clamped to minReplicas (2) | No change |
| 4–7 | 1–2 → clamped to minReplicas (2) | No change |
| 8–11 | 2–3 | Scale up to 3 if currently at 2 |
| 12–23 | 3–6 | Scale up proportionally |
| ≥ 24 | ≥ 6 → clamped to maxReplicas (6) | No change |

**What to watch:** During a `--loop 5` load test you should see this value
climb to 8–20.  When it crosses the threshold × current_replicas boundary,
Panel 2 steps up within the next KEDA poll (15s).

---

## Panel 4 — Action Execution Duration

**What it shows:** How long each RBE action takes from start to finish,
at the 50th and 95th percentiles.

**Metrics:**
```promql
histogram_quantile(0.50, rate(buildbarn_builder_in_memory_build_queue_tasks_completed_duration_seconds_bucket{...}[2m]))
histogram_quantile(0.95, rate(...bucket{...}[2m]))
```

**Reading it:**

| p50 | p95 | What it means |
|---|---|---|
| No data / NaN | No data | No completed actions recently |
| 1–5s | 5–15s | Normal: Go compile / Python test on RBE workers |
| 10–30s | 30–120s | Large actions (C++ compile chains, slow network) |
| > 120s | > 300s | Worker overloaded — check Panel 2, raise maxReplicas |
| p95 >> p50 | | Outliers: one slow action type (often cold cache) |

**Use this to tune the load test.** If p95 is consistently > 60s, workers
are likely saturated and KEDA should be scaling.  If it's low (< 5s) even
under load, workers have headroom and you may not need autoscaling yet.

---

## Panel 5 — Canary / Stable Worker Split

**What it shows:** Replica count per ReplicaSet owned by the `bb-worker`
Rollout.  At rest there is one RS (stable).  During a canary rollout, two
RS appear.

**Metric:**
```promql
kube_replicaset_spec_replicas{namespace="rbe-system"}
  * on(replicaset) group_left()
  (kube_replicaset_labels{namespace="rbe-system",
    label_app_kubernetes_io_name="bb-worker"} > 0)
```

**Reading it — idle state:**
```
bb-worker-5cc494f76d   ──── 2 ────────────────────────   (stable, all traffic)
```

**Reading it — during canary rollout (4 total workers):**
```
Step 1  setWeight 25%:   stable=3  canary=1
Step 4  setWeight 50%:   stable=2  canary=2
Step 7  promoted:        stable=0  canary=4  (canary is now the new stable RS)
```

**Watch this panel while triggering a canary** (see
`docs/overall_readme.md §6`).  The two lines splitting apart is the visual
confirmation that Argo Rollouts is routing partial traffic to the new image.

> For a richer canary view — step names, pause countdown, analysis
> pass/fail — use the Argo Rollouts Dashboard at `http://localhost:3100`
> alongside this panel.

---

## Panel 6 — Completed vs Failed Actions

**What it shows:** Rate of Execute RPCs that completed successfully vs those
that failed (any non-OK gRPC status code).

**Metrics:**
```promql
# Success
sum(rate(grpc_server_handled_total{...,grpc_code="OK"}[1m]))

# Errors  (total − success)
sum(rate(grpc_server_handled_total{...}[1m]))
  - sum(rate(grpc_server_handled_total{...,grpc_code="OK"}[1m]))
```

**Reading it:**

| What you see | What it means |
|---|---|
| Success only, Errors at 0 | Healthy — all actions completing |
| Errors spike during canary step | AnalysisTemplate will catch this (5% threshold) |
| Errors sustained after rollout | Roll back: `kubectl argo rollouts abort bb-worker -n rbe-system` |
| Both lines flat near 0 | No active load |

**This is the same signal the AnalysisTemplate queries** during canary
promotion gates.  If you see the error line rise above ~5% of the success
line during a rollout, Argo Rollouts will auto-abort within 90 seconds.

---

## Load Test Walkthrough — What to Watch Panel by Panel

Run this in one terminal:
```bash
cd examples/math-rbe
./scripts/load_test.sh --nocache --loop 5
```

**T+0s — before first Bazel invocation:**
- All panels flat or no-data — baseline
- Panel 2: Current=2 (minReplicas)

**T+15–30s — Bazel dispatches first batch of actions:**
- Panel 1: first spike appears (0.2–0.8/s)
- Panel 3: trigger value starts climbing

**T+60s — enough load accumulated:**
- Panel 3: trigger value crosses `threshold × replicas` line
- Panel 2: desired replica count increases (watch for the step)

**T+75s — new pod Ready:**
- Panel 2: Current steps from 2 → 3
- Panel 4: p50 may briefly drop (new worker absorbs queue)

**T+120–180s — load test completing final loops:**
- Panel 1: rate drops back toward 0
- Panel 3: trigger value falls below threshold

**T+480s (8 min) — scale-down:**
- Panel 2: Current steps from 3 → 2 (300s stabilization + pod drain)

---

## Canary Rollout Walkthrough — What to Watch

Trigger: change a value in `charts/buildbarn/values.yaml`, commit, merge to
main, let ArgoCD sync.

**Before rollout:**
- Panel 5: one RS line at 2

**Step 1 — setWeight 25%:**
- Panel 5: second RS line appears at 1; stable RS drops to 3
  (if KEDA has scaled to 4 total)

**Step 3 / Step 6 — AnalysisRun:**
- Panel 6: watch for any Errors line appearing
- If error rate > 5%, Argo Rollouts aborts; Panel 5 drops the canary line

**Full promotion:**
- Panel 5: canary RS climbs to full count; stable RS drops to 0 and disappears

---

## Useful Explore Queries

Grafana → **Explore** tab (compass icon, top left)

```promql
# All RBE gRPC method call counts since scheduler start
sum by (grpc_method) (grpc_server_started_total{job="bb-scheduler", namespace="rbe-system"})

# Action completion rate over last 5 min
rate(buildbarn_builder_in_memory_build_queue_tasks_completed_duration_seconds_count{namespace="rbe-system"}[5m])

# Which workers are currently executing actions (non-zero = busy)
buildbarn_worker_build_executor_current_state{namespace="rbe-system"}

# KEDA HPA desired vs current over last 30 min (set time range to 30m)
kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="keda-hpa-bb-worker"}
kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="keda-hpa-bb-worker"}
```
