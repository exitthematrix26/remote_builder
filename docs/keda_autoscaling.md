# Phase 5: KEDA Autoscaling for bb-worker

## What this is

KEDA (Kubernetes Event-Driven Autoscaling) watches a Prometheus metric from
bb-scheduler and automatically scales the `bb-worker` Argo Rollout between
`minReplicas=2` and `maxReplicas=6` based on incoming RBE load.

```
Bazel build
    │  Execute RPC
    ▼
bb-scheduler ──── /metrics ────► Prometheus ◄── scrape every 15s
    │                                   │
    │                             KEDA ScaledObject
    │                                   │ desiredReplicas = ceil(metric/threshold)
    ▼                                   ▼
bb-worker Rollout ◄──────────── HPA (keda-hpa-bb-worker)
  ┌────────────┐
  │ bb-runner  │  × replicas (2 → 6)
  │ bb-worker  │
  └────────────┘
```

## Components deployed

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| kube-prometheus-stack 70.4.2 | monitoring | Prometheus Operator + Prometheus + Grafana |
| KEDA 2.16.1 | keda | ScaledObject controller + HPA bridge |
| ServiceMonitor `bb-scheduler` | rbe-system | Auto-generates Prometheus scrape job for port 8083 |
| ScaledObject `bb-worker` | rbe-system | Watches Prometheus → manages HPA → scales Rollout |
| AnalysisTemplate `bb-worker-health` | rbe-system | Gates canary rollouts on error rate |

## Scaling trigger

**Primary: Execute RPC rate**

```promql
sum(increase(grpc_server_started_total{
  namespace="rbe-system",
  job="bb-scheduler",
  grpc_method="Execute"
}[2m]))
```

- `threshold=4`: add 1 worker per 4 Execute RPCs in the 2-minute window
- `desiredReplicas = ceil(metric_value / 4)`
- Example: 20 Execute RPCs in 2m → ceil(20/4) = 5 workers

**Why not `tasks_scheduled_total{assignment="Queue"}`?**
When workers are available, tasks go directly to `assignment="Worker"` — they
never enter the Queue state. The Queue metric only fires when workers are
already saturated, which is too late. The Execute RPC rate fires the moment
Bazel sends actions, giving workers time to start before the queue backs up.

**Scale-up behaviour:**
- `stabilizationWindowSeconds: 0` — scale up immediately, no delay
- `policies: [Pods: 2 per 30s]` — can add 2 pods per 30-second window

**Scale-down behaviour:**
- `stabilizationWindowSeconds: 300` — wait 5 minutes after load drops
- `policies: [Pods: 1 per 60s]` — remove at most 1 pod per minute
- Reason: in-flight build actions must finish before a worker pod is drained

## Key files

```
gitops/apps/prometheus/application.yaml     kube-prometheus-stack Argo CD app
gitops/apps/keda/application.yaml           KEDA Argo CD app

charts/buildbarn/templates/
  configmap-scheduler.yaml                  diagnosticsHttpServer enables /metrics
  service-scheduler.yaml                    exposes port 8083 (metrics)
  servicemonitor-scheduler.yaml             Prometheus scrape config
  scaledobject-worker.yaml                  KEDA scaling rules
  analysis-worker.yaml                      canary health check
```

## bb-scheduler metrics endpoint

bb-scheduler exposes Prometheus metrics at `:8083/metrics`.  Key metrics:

```
grpc_server_started_total{grpc_method="Execute"}   — incoming RBE actions
grpc_server_handled_total{grpc_method="Execute"}   — completed actions
buildbarn_builder_in_memory_build_queue_tasks_scheduled_total{assignment="Worker"}
                                                   — tasks dispatched to workers
buildbarn_builder_in_memory_build_queue_tasks_completed_duration_seconds
                                                   — action execution latency
```

The `diagnosticsHttpServer` config in `scheduler.json` must be nested under
`"global"` with `"httpServers"` (plural) and each entry must have
`"authenticationPolicy": {"allow": {}}` — see issues doc for the debugging
journey to discover this.

## How to verify autoscaling is working

```bash
# 1. Ensure port-forwards are running
kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system &
kubectl port-forward svc/bb-storage   8980:8980 -n rbe-system &

# 2. Watch pods and HPA in one terminal
watch -n5 "kubectl get pods -n rbe-system | grep bb-worker; echo; kubectl get hpa keda-hpa-bb-worker -n rbe-system"

# 3. Run load test in another terminal (from examples/math-rbe/)
./scripts/load_test.sh --nocache --loop 5

# 4. Expected: HPA metric climbs above threshold, replicas increase 2 → 3+
# 5. After load_test completes, wait 5 minutes — replicas scale back down to 2
```

## Observed scaling behaviour (confirmed working)

```
T+000s  HPA: 0/4 (avg)    replicas: 2  — idle
T+030s  HPA: 1143m/4      replicas: 2  — light load
T+060s  HPA: 5714m/4      replicas: 2  — metric > threshold → scale up triggered
T+075s  HPA: 3810m/4      replicas: 3  — new worker pod Running
T+165s  HPA: 0/4 (avg)    replicas: 3  — load done, 5-min cooldown starts
T+465s  (after 5 min)     replicas: 2  — scale-down executes
```

## Grafana (optional)

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &
# open http://localhost:3000  (admin / prom-operator)
```

Useful panels to add:
- `rate(grpc_server_handled_total{job="bb-scheduler",grpc_method="Execute"}[1m])` — action throughput
- `buildbarn_builder_in_memory_build_queue_tasks_completed_duration_seconds` — latency histogram
- HPA replica count via Kubernetes built-in dashboard

## Phase 6 preview

- Replace hand-rolled `generate + execute` loop with a proper Bazel load driver
- Add Grafana dashboard ConfigMap (auto-provision via kube-prometheus-stack)
- Add alerting rules: fire PagerDuty/Slack if `bb-scheduler` has no workers for
  more than `platformQueueWithNoWorkersTimeout=900s`
- Evaluate EKS migration path: swap `pool=rbe-workers` NodeSelector for
  Karpenter NodePool, replace kind cluster with actual autoscaling EC2 nodes
