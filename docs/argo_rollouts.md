# Phase 3 — Argo Rollouts: Canary Deployment for bb-worker

## What Was Built

bb-worker (the RBE execution engine) now uses **Argo Rollouts** instead of a plain Kubernetes
Deployment. Every time the worker image is updated — new toolchain, new Buildbarn version, config
tuning — the change rolls out as a **canary**: a small fraction of workers gets the new version
first, real build traffic exercises it, and only then does the rollout proceed to full capacity.

This is how EngFlow, Google's RBE team, and every mature platform team deploys worker updates.

---

## Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │           bb-worker Rollout                  │
                 │                                              │
  Bazel actions  │  revision:1 (stable)   revision:2 (canary)  │
  ──────────────▶│  ┌────────────────┐    ┌──────────────────┐ │
  via scheduler  │  │ bb-worker pod  │    │  bb-worker pod   │ │
                 │  │ bb-runner pod  │    │  bb-runner pod   │ │
                 │  └────────────────┘    └──────────────────┘ │
                 │     75% of workers          25% of workers   │
                 │        (stable)              (canary)        │
                 │                                              │
                 │  Argo Rollouts controller manages the split  │
                 └─────────────────────────────────────────────┘

Canary steps (defined in rollout-worker.yaml):
  1. setWeight: 25   → 1 of 4 worker slots gets new version
  2. pause: 60s      → Scheduler routes ~25% of queued actions to canary
  3. setWeight: 50   → 2 of 4 worker slots get new version
  4. pause: 60s      → Verify no regressions at half capacity
  5. (full rollout)  → Canary promoted to stable, old revision ScaledDown
```

---

## Files Added

| File | Purpose |
|------|---------|
| `gitops/apps/argo-rollouts/application.yaml` | Argo CD app — installs Rollouts controller + CRDs (sync wave -1) |
| `charts/buildbarn/templates/rollout-worker.yaml` | bb-worker Rollout with canary strategy |
| `charts/buildbarn/templates/analysis-worker.yaml` | AnalysisTemplate for Phase 4 Prometheus integration |

`charts/buildbarn/templates/deployment-worker.yaml` was **deleted** — replaced by the Rollout.

---

## Canary Strategy

```yaml
strategy:
  canary:
    maxSurge: 1        # At most 1 extra pod above desired (memory-conscious)
    maxUnavailable: 0  # Never reduce below desired capacity
    steps:
      - setWeight: 25
      - pause:
          duration: 60s
      - setWeight: 50
      - pause:
          duration: 60s
      # 100% promotion happens automatically after the last pause
```

`maxSurge: 1` means at peak the cluster runs 3 worker pods (2 desired + 1 surge). On this lab's
14GB RAM node, that's intentional — we never sacrifice build capacity for the rollout.

---

## AnalysisTemplate (Phase 4)

`analysis-worker.yaml` defines a `bb-worker-health` AnalysisTemplate that queries Prometheus for
the Execute RPC error rate during canary steps. When Prometheus is deployed in Phase 4:

```yaml
# In rollout-worker.yaml canary steps, add:
- analysis:
    templates:
      - templateName: bb-worker-health
```

If `(error RPCs / total RPCs) > 5%` during the 90s measurement window, Argo Rollouts
**automatically aborts the rollout** and restores 100% stable workers — no manual intervention.

---

## Day-to-Day Usage

### Trigger a rollout

Update the worker image in `charts/buildbarn/values.yaml`:
```yaml
image:
  worker:
    tag: "20260501T120000Z-newcommit"
  runnerInstaller:
    tag: "20260501T120000Z-newcommit"
```
Push to `main`. Argo CD syncs → Rollout detects image change → canary starts automatically.

### Monitor a rollout

```bash
# Live view (updates in terminal)
kubectl argo rollouts get rollout bb-worker -n rbe-system -w

# Quick status
kubectl argo rollouts status bb-worker -n rbe-system
```

### Manual operations

```bash
# Promote past a pause step immediately (skip the wait)
kubectl argo rollouts promote bb-worker -n rbe-system

# Abort and roll back to stable immediately
kubectl argo rollouts abort bb-worker -n rbe-system

# Undo an aborted rollout (resets to stable revision)
kubectl argo rollouts undo bb-worker -n rbe-system
```

### Argo Rollouts dashboard

```bash
kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100 &
# Open: http://localhost:3100
```

Visual timeline of all rollouts, revision history, and analysis results.

---

## How This Differs from a Plain Deployment

| | Deployment | Rollout (canary) |
|--|--|--|
| Update method | Rolling replace (all pods) | Staged: 25% → 50% → 100% |
| Bad deploy impact | 100% of workers affected | At most 25% on step 1 |
| Rollback | `kubectl rollout undo` | `kubectl argo rollouts abort` (instant) |
| Promotion gate | None | AnalysisTemplate (Phase 4: Prometheus) |
| Visibility | `kubectl rollout status` | Dashboard + `get rollout -w` |

The key difference: with a Deployment, if a bad worker image is deployed, every build action
queued during the rollout has a chance of hitting a broken worker. With canary, the blast radius is
capped at the canary weight (25% on step 1) and automated analysis can roll back before most users
notice.

---

## What's Next: Phase 4 — Prometheus + KEDA

Phase 4 wires up the AnalysisTemplate by deploying `kube-prometheus-stack`. Once bb-scheduler
exposes Prometheus metrics via its `diagnosticsHttpServer`:

1. Canary promotions are gated by real error-rate analysis
2. KEDA scales bb-worker replicas based on scheduler queue depth
3. Grafana dashboard shows RBE build throughput, cache hit rate, and worker utilization
