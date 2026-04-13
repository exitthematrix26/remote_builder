# RBE Lab — End-to-End Walkthrough

A complete guide to starting the cluster, opening dashboards, running a load
test, watching KEDA autoscale workers, and triggering + observing a canary
rollout.

---

## Prerequisites

```bash
# Cluster context
kubectl config use-context kind-remote-builder

# Verify all nodes are Ready
kubectl get nodes
# NAME                           STATUS   ROLES           AGE
# remote-builder-control-plane   Ready    control-plane   ...
# remote-builder-worker          Ready    <none>   (pool=infra)
# remote-builder-worker2         Ready    <none>   (pool=rbe-workers)
```

---

## 1. Quick-Start Checklist

Run the health checks first. All should be green before proceeding.

```bash
# Phase 3 — ArgoCD + Argo Rollouts
./cluster/argo_health.sh

# Phase 5 — Prometheus + KEDA + Autoscaling stack
./cluster/phase5_health.sh

# Full RBE smoke test (CAS, AC, Execute)
./cluster/verify-cluster.sh
```

---

## 2. Start Resilient Port-Forwards

Plain `kubectl port-forward` dies on pod restart or idle timeout. Use the
managed wrapper instead:

```bash
./cluster/portforward.sh start

# Verify both are alive
./cluster/portforward.sh status
# NAME            PID      STATUS     PORTS
# scheduler       12345    running    8981:8981
# storage         12346    running    8980:8980
```

> **How it works:** each forward runs in a `while true; do ... sleep 2; done`
> loop, disowned from the shell. It reconnects automatically if the pod
> restarts or the connection drops.

To stop at end of session:
```bash
./cluster/portforward.sh stop
```

---

## 3. Open Dashboards (4 tabs)

Open four browser tabs — keep them visible while running the load test.

### Tab 1 — Grafana: RBE Load & Autoscaling
```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &
# open http://localhost:3000
# login: admin / admin
```

Navigate: **RBE → RBE Load & Autoscaling**

> This custom dashboard (auto-provisioned via ConfigMap) shows:
> - Execute RPC rate — the KEDA trigger
> - Worker replica count (current / min / max)
> - KEDA trigger value vs threshold
> - Action execution duration p50/p95
> - Canary vs stable replica split (live during rollouts)
> - Completed vs failed actions

### Tab 2 — Grafana: Compute Resources / Namespace (Pods)
Still in Grafana:
- Navigate: **Kubernetes → Compute Resources → Namespace (Pods)**
- Set namespace filter to `rbe-system`

> Shows CPU and memory per pod. During the load test you see bb-worker pods
> spike in CPU, then new pods appear as KEDA adds workers.

### Tab 3 — Argo Rollouts Dashboard
```bash
kubectl port-forward svc/argo-rollouts-dashboard 3100:3100 -n argo-rollouts &
# open http://localhost:3100
```

> Shows the live canary rollout state: which step the rollout is on, the
> current canary weight (25% / 50% / 100%), pause countdown, and analysis
> pass/fail. **This is the right tool for canary visualization — Grafana shows
> replica counts, the Rollouts Dashboard shows the actual intent.**

Select namespace `rbe-system` and click `bb-worker`.

### Tab 4 — ArgoCD
```bash
kubectl port-forward svc/argocd-server 8080:80 -n argocd &
# open http://localhost:8080
# login: admin / $(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)
```

> Shows the GitOps sync state of all applications. When you push a change to
> main, the rbe-system app turns yellow (OutOfSync) then syncs and goes green.

---

## 4. Run the Load Test

The load test drives RBE actions to trigger KEDA autoscaling.

```bash
cd examples/math-rbe

# Cache-busting mode, 5 loops — generates enough Execute RPCs to fire KEDA
./scripts/load_test.sh --nocache --loop 5
```

### What the load test does

```
Loop 1:  bazel test --config=rbe --config=nocache //...
         → 10+ remote execute RPCs to bb-scheduler
         → Go math runner, C++ stats binary, Python pytest validation

Loops 2-5:  gen_inputs.py --seed N generates a new CSV
            → runner binary executed against fresh input (no AC hit)
            → 10+ more execute RPCs per loop
            → each loop: additional bazel test //... --nocache pass
```

### What to watch while it runs

**In Grafana "RBE Load" dashboard:**
- "Execute RPC Rate" panel climbs from 0 to ~0.5–1.0/s during each loop
- "KEDA Trigger Value" panel should cross the threshold line (4) → triggers scale-up

**In Grafana "Namespace (Pods)":**
- bb-worker pods: CPU spikes during execution
- Pod count row shows new pods appearing (typically within 30–60s of load)

**In terminal (open a second window):**
```bash
# Watch pods appear in real time
watch -n5 "kubectl get pods -n rbe-system | grep bb-worker"

# Watch KEDA HPA
watch -n5 "kubectl get hpa keda-hpa-bb-worker -n rbe-system"
# TARGETS column changes from "0/4 (avg)" to e.g. "5714m/4" during load
```

### Expected scaling timeline

```
T+000s  2 workers  — idle baseline
T+030s  metric rises  — Execute RPCs arriving
T+060s  KEDA fires  — trigger value > threshold × replicas
T+075s  3 workers  — new bb-worker pod becomes Ready
T+165s  load ends
T+465s  2 workers  — 5-min scale-down stabilization expires
```

---

## 5. Watching KEDA Autoscaling Live

Three views, pick what you have screen space for:

### View A — Terminal (most reliable)
```bash
# One-liner that shows metric + replicas + pod count every 10s
while true; do
  echo "=== $(date +%T) ==="
  kubectl get hpa keda-hpa-bb-worker -n rbe-system --no-headers
  kubectl get pods -n rbe-system --no-headers | grep -c bb-worker
  sleep 10
done
```

### View B — Grafana "RBE Load" dashboard
- Panel "Worker Replicas": Current (solid line) steps up when KEDA fires
- Panel "KEDA Trigger Value": crosses the threshold annotation

### View C — Grafana Explore (custom query)
Navigate to Grafana → **Explore**, paste:
```promql
kube_horizontalpodautoscaler_status_current_replicas{
  namespace="rbe-system",
  horizontalpodautoscaler="keda-hpa-bb-worker"
}
```

---

## 6. Triggering a Canary Rollout

A canary rollout is triggered whenever a **tracked Rollout field changes** —
most commonly the worker or runner-installer image tag. Argo CD detects the
diff from git and applies the updated Rollout spec, which Argo Rollouts then
executes through the canary steps.

### Step-by-step

**Step 1: Create a branch**
```bash
git checkout main && git pull
git checkout -b demo-canary-$(date +%Y%m%d)
```

**Step 2: Change a value that affects the Rollout**

The easiest safe change: bump the `image.runnerInstaller.tag` in
`charts/buildbarn/values.yaml`. Use any valid tag from the Buildbarn registry:
```bash
# Check available tags:
# https://github.com/buildbarn/bb-runner-installer/pkgs/container/bb-runner-installer
```

Edit `charts/buildbarn/values.yaml`:
```yaml
# before
  runnerInstaller:
    tag: "20260408T084910Z-570a4d4"

# after (example — use any newer available tag)
  runnerInstaller:
    tag: "20260409T120000Z-XXXXXXX"
```

> For a no-op demo (no real image change, just tests the rollout mechanics):
> bump `worker.concurrency` from 2 to 3 or add a label annotation. Any field
> that changes the pod template checksum triggers the Rollout.

**Step 3: Commit, push, open PR, merge**
```bash
git add charts/buildbarn/values.yaml
git commit -m "demo: bump runner tag to trigger canary rollout"
git push -u origin HEAD
gh pr create --title "demo: canary rollout test" --body "Triggers bb-worker canary to test rollout mechanics."
# merge via GitHub UI or: gh pr merge --merge
```

**Step 4: ArgoCD detects and syncs (< 3 minutes)**

Watch the ArgoCD UI (tab 4): `rbe-system` app turns yellow (OutOfSync), then
Argo CD applies the Rollout update. Alternatively force-sync:
```bash
argocd app sync rbe-system
```

### Watching the canary steps

**In the Argo Rollouts Dashboard (tab 3, the best view):**

```
Step 1: setWeight 25%  ← rollout starts here
        25% of pods run new image (canary RS)
        75% run old image (stable RS)

Step 2: pause 60s      ← countdown visible in dashboard
        scheduler routes ~25% of new Execute RPCs to canary workers

Step 3: analysis       ← AnalysisRun queries Prometheus
        checks: (errors / total Execute RPCs) < 5% in 90s window
        PASS → continue  |  FAIL → auto-rollback

Step 4: setWeight 50%  ← 50/50 split
        both RS have equal replicas

Step 5: pause 60s

Step 6: analysis       ← second health check

Step 7: full promotion ← canary RS becomes new stable RS
        old stable RS scaled to 0
```

**In Grafana "RBE Load" — Canary / Stable Split panel:**
- Two lines appear: `bb-worker-XXXXXXXX` (stable) and `bb-worker-YYYYYYYY` (canary)
- At step 1: stable=3, canary=1 (of 4 total)
- At step 4: stable=2, canary=2
- At promotion: only one RS remains

**In terminal:**
```bash
# Watch the rollout step by step
watch -n5 "kubectl get rollout bb-worker -n rbe-system -o jsonpath='{.status.currentStepIndex}/{.status.phase}'"

# See both ReplicaSets
kubectl get rs -n rbe-system -l app.kubernetes.io/name=bb-worker
```

### To force-promote or abort
```bash
# Skip pause and proceed to next step
kubectl argo rollouts promote bb-worker -n rbe-system

# Roll back to previous image immediately
kubectl argo rollouts abort bb-worker -n rbe-system
```

---

## 7. Grafana Dashboard Quick-Reference

| Dashboard | Where | What to watch |
|-----------|-------|---------------|
| RBE Load & Autoscaling | RBE folder | Execute rate, replica count, KEDA trigger, canary split |
| Kubernetes / Compute Resources / Namespace (Pods) | Kubernetes folder | Per-pod CPU/memory, pod count |
| Prometheus / Overview | Prometheus folder | Scrape health, bb-scheduler target up |
| Grafana Explore | top nav | Ad-hoc PromQL for any bb-scheduler metric |

**Key PromQL queries for Explore:**

```promql
# Incoming RBE load
rate(grpc_server_started_total{job="bb-scheduler",grpc_method="Execute"}[1m])

# Current worker count (HPA)
kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="keda-hpa-bb-worker"}

# KEDA trigger value
sum(increase(grpc_server_started_total{namespace="rbe-system",job="bb-scheduler",grpc_method="Execute"}[2m]))

# Action duration p95
histogram_quantile(0.95, rate(buildbarn_builder_in_memory_build_queue_tasks_completed_duration_seconds_bucket{namespace="rbe-system"}[5m]))
```

---

## 8. After Merge: Re-enable ArgoCD Automated Sync

When PR#6 (phase-5-keda) is merged, rbe-system is still pointed at that branch
with automated sync disabled. Re-enable:

```bash
kubectl patch application rbe-system -n argocd --type=merge \
  -p '{"spec":{"source":{"targetRevision":"main"},"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

kubectl patch application app-of-apps -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

argocd app sync rbe-system
```

---

## Architecture Summary

```
                    ┌─────────────────────────────────────────────────────┐
                    │                  kind-remote-builder                │
                    │                                                     │
  git push main     │  argocd (argocd ns)                                │
  ────────────────► │    app-of-apps → rbe-system, monitoring, keda      │
                    │                                                     │
                    │  monitoring ns        keda ns                      │
                    │  Prometheus ◄──────── KEDA operator                │
                    │  Grafana              ScaledObject                  │
                    │      │                    │                         │
                    │      │ scrape /metrics     │ poll every 15s         │
                    │      ▼                    ▼                         │
                    │  rbe-system ns                                      │
                    │  bb-scheduler:8083/metrics                          │
                    │  bb-scheduler:8981 ◄── Bazel --remote_executor     │
                    │  bb-storage:8980   ◄── Bazel --remote_cache        │
                    │                                                     │
                    │  bb-worker Rollout (2→6 pods via KEDA HPA)         │
                    │    ├── stable RS (75%→50%→0% during canary)        │
                    │    └── canary RS (25%→50%→100% during rollout)     │
                    │         ├── bb-runner container                     │
                    │         └── bb-worker container                     │
                    └─────────────────────────────────────────────────────┘
```
