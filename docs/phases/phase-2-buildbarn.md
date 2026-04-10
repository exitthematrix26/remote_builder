# Phase 2 — Buildbarn RBE + MinIO

## What this phase builds

Phase 2 deploys a complete Remote Build Execution (RBE) backend:

```
Bazel client
    │  --remote_executor=grpc://localhost:8981
    ▼
bb-scheduler  (namespace: rbe-system)
    │  routes work to available workers
    │  checks/writes action cache via bb-storage
    ▼
bb-storage  (namespace: rbe-system)
    │  CAS (Content Addressable Storage) — inputs + outputs
    │  AC  (Action Cache)               — result memos
    ▼
MinIO  (namespace: minio)
    │  S3-compatible object store
    │  buckets: rbe-cas, rbe-ac
    ▼
bb-worker  (namespace: rbe-system, node: pool=rbe-workers)
    │  downloads inputs from CAS
    │  runs build via Unix socket
    ▼
bb-runner  (sidecar container in worker pod)
       executes the actual build command as a subprocess
```

---

## Component responsibilities

| Component | What it does | Config file |
|-----------|-------------|-------------|
| **bb-storage** | Stores/retrieves blobs (CAS) and build results (AC). Delegates to MinIO via S3 protocol. | `configmap-storage.yaml` |
| **bb-scheduler** | Receives Execute RPCs from Bazel. Checks AC first; if miss, queues work and waits for a worker to pick it up. | `configmap-scheduler.yaml` |
| **bb-worker** | Connects to scheduler. Downloads inputs from CAS. Delegates execution to bb-runner over a Unix socket. Uploads outputs to CAS. | `configmap-worker.yaml` |
| **bb-runner** | Receives `RunRequest` from bb-worker. Runs the build command as a subprocess in `/worker/build`. Returns exit code, stdout, stderr. | `configmap-worker.yaml` (`runner.json`) |
| **MinIO** | S3-compatible object storage. Replaces AWS S3 for local dev. Same API — swap the endpoint URL when migrating to EKS. | `gitops/apps/minio/application.yaml` |

---

## Key design decisions

### Why bb-worker and bb-runner are separate containers

Buildbarn splits execution into two processes:

- **bb-worker** handles *orchestration*: talking to the scheduler, fetching from CAS, uploading outputs, reporting results.
- **bb-runner** handles *execution*: running the actual build command.

This lets you swap execution backends without touching the worker:
- `local` executor (this lab): runs commands directly as subprocesses — simple, trusted environment
- `docker` executor: runs each action in a fresh Docker container — isolation for untrusted builds
- `gVisor` executor: kernel-level sandboxing — maximum security

The two containers share two `emptyDir` volumes:
- `/worker` — Unix socket (`/worker/runner`) + build workspace (`/worker/build`)
- `/install` — holds the bb-runner binary, copied by the init container

### Why an init container for bb-runner?

The `bb-runner-installer` image is a purpose-built image that contains only the static bb-runner binary. The init container copies it to the `/install` emptyDir volume at pod startup, then exits.

The bb-runner container itself is based on `busybox:1.36` — a minimal base that provides just enough shell to exec the static Go binary. This keeps the attack surface small.

```
┌─────────────────────────────────────────────────────────┐
│  Pod: bb-worker                                          │
│                                                          │
│  initContainer: install-runner                           │
│    image: bb-runner-installer                            │
│    copies /bb-runner → /install/bb-runner                │
│    exits 0                                               │
│                                                          │
│  container: bb-runner                                    │
│    image: busybox:1.36                                   │
│    cmd: /install/bb-runner /config/runner.json           │
│    listens on: unix:///worker/runner                     │
│                                                          │
│  container: bb-worker                                    │
│    image: bb-worker                                      │
│    connects to: unix:///worker/runner                    │
│    connects to: bb-scheduler:8982                        │
└─────────────────────────────────────────────────────────┘
```

### Why workers run on a dedicated node

Workers need a `nodeSelector` (pool=rbe-workers) and a `toleration` (dedicated=rbe-worker:NoSchedule). The taint on the worker node acts as a gate:

- **Without taint**: any pod could land on the worker node, stealing CPU/memory from build jobs.
- **Without toleration**: the worker pods themselves would be refused even though they belong there.
- **With both**: only pods that explicitly opt in (via toleration) can run on the worker node.

### CAS and AC buckets

Buildbarn uses two separate buckets:

- **rbe-cas** — Content Addressable Storage. Every input file, output file, and action is a blob identified by its SHA256 hash. Immutable — never overwritten, only written once per hash.
- **rbe-ac** — Action Cache. Maps `(action hash)` → `(action result)`. If the same action runs twice with the same inputs, the second run hits AC and returns immediately without executing anything.

This is where remote build caching lives. The CAS stores the *data*, the AC stores the *result pointers*.

### MinIO → S3 migration

The only change needed when deploying to EKS is updating these values:

```yaml
# values.yaml (local)
minio:
  endpoint: "http://minio.minio:9000"
  accessKey: "minioadmin"
  secretKey: "minioadmin"
  disableSsl: true
  s3ForcePathStyle: true  # required for MinIO path-style URLs

# values.yaml (production)
minio:
  endpoint: "https://s3.us-east-1.amazonaws.com"
  accessKey: ""           # use IAM role annotation on ServiceAccount instead
  secretKey: ""
  disableSsl: false
  s3ForcePathStyle: false  # AWS uses virtual-hosted style
```

Sealed Secrets handles the access key/secret in production — see Phase 5.

---

## Helm chart structure

```
charts/buildbarn/
├── Chart.yaml                        # name: buildbarn, version: 0.1.0
├── values.yaml                       # all defaults with comments
└── templates/
    ├── _helpers.tpl                  # buildbarn.labels + selector labels
    ├── configmap-storage.yaml        # bb-storage JSON config
    ├── configmap-scheduler.yaml      # bb-scheduler JSON config
    ├── configmap-worker.yaml         # bb-worker.json + runner.json
    ├── deployment-storage.yaml       # bb-storage Deployment
    ├── deployment-scheduler.yaml     # bb-scheduler Deployment
    ├── deployment-worker.yaml        # bb-worker Deployment (init + 2 containers)
    ├── service-storage.yaml          # ClusterIP :8980
    └── service-scheduler.yaml        # ClusterIP :8981 (client) + :8982 (worker)
```

The config checksum annotation in each Deployment forces a pod restart whenever the ConfigMap changes:

```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap-storage.yaml") . | sha256sum }}
```

Without this, `helm upgrade` updates the ConfigMap but the running pods never see the new config.

---

## Sync wave ordering

```
Wave -3  sealed-secrets   ← must exist before any SealedSecret resources
Wave -2  istio-base
Wave -1  istiod
Wave  0  prometheus, keda
Wave  1  minio            ← must exist before buildbarn (storage backend)
Wave  2  rbe-system       ← buildbarn chart deployed here
Wave  3  ApplicationSet
```

MinIO must be Healthy before bb-storage starts, because bb-storage connects to MinIO on startup to validate the S3 credentials and bucket access. If MinIO isn't ready, bb-storage crashes and the readiness probe fails, which blocks the scheduler (which depends on bb-storage for AC lookups).

---

## Verifying the deployment

### 1. Check all pods are Running

```bash
kubectl get pods -n rbe-system
# Expected:
# bb-storage-<hash>    1/1  Running
# bb-scheduler-<hash>  1/1  Running
# bb-worker-<hash>     2/2  Running   ← 2 containers: bb-runner + bb-worker
```

### 2. Check MinIO buckets exist

```bash
kubectl port-forward svc/minio 9001:9001 -n minio &
# Open http://localhost:9001 (minioadmin/minioadmin)
# Buckets: rbe-cas, rbe-ac
```

### 3. Run a remote build

```bash
# Start the port-forward (keep this running in a separate terminal)
kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system

# In the examples/hello-bazel directory:
cd examples/hello-bazel
bazel build --config=rbe //...

# Expected output:
# INFO: 2 processes: 1 remote, 1 internal.
# Target //:hello up-to-date:
#   bazel-bin/hello_/hello
```

The key line is `1 remote` — that confirms the action was sent to the scheduler, executed on a worker, and the result was fetched from CAS.

### 4. Verify the action cache is working

```bash
# Build again — should be instant
bazel build --config=rbe //...

# Expected output:
# INFO: 2 processes: 2 remote cache hit.
```

`remote cache hit` means bb-scheduler found the action in the AC and returned the cached result without running any workers.

### 5. Check worker logs

```bash
kubectl logs -n rbe-system deploy/bb-worker -c bb-worker
# Look for: "Received action" and "Finished action"

kubectl logs -n rbe-system deploy/bb-worker -c bb-runner
# Look for: RunRequest received, command executed
```

---

## What "remote execution" actually means step by step

When you run `bazel build --config=rbe //...`:

1. **Bazel hashes all inputs** — source files, compiler flags, environment. This produces an action digest (SHA256).

2. **Bazel calls GetActionResult** on the scheduler. If the action digest is in the AC, Bazel downloads the outputs from CAS and is done. No compilation happens.

3. **If AC miss**: Bazel calls Execute on the scheduler. The scheduler queues the action.

4. **A worker picks up the action**. It calls GetBlob on bb-storage to download all input files from CAS to `/worker/build`.

5. **bb-worker sends a RunRequest** to bb-runner via Unix socket. bb-runner runs the command (e.g., `go tool compile ...`) as a subprocess in `/worker/build`.

6. **bb-runner returns** exit code, stdout, stderr to bb-worker.

7. **bb-worker uploads outputs** (compiled `.a` files, etc.) to CAS via bb-storage.

8. **bb-worker writes the ActionResult** to AC — mapping action digest → output digests.

9. **Scheduler returns the result to Bazel**. Bazel downloads the output files from CAS.

---

## Troubleshooting

| Symptom | Likely cause | Debug command |
|---------|-------------|---------------|
| `bb-storage` crashlooping | MinIO not ready or wrong credentials | `kubectl logs deploy/bb-storage -n rbe-system` |
| `bb-worker` stays Pending | Node taint/toleration mismatch | `kubectl describe pod -l app=bb-worker -n rbe-system` |
| `UNAVAILABLE: connection refused` from Bazel | Port-forward not running | `kubectl port-forward svc/bb-scheduler 8981:8981 -n rbe-system` |
| `0 remote` in Bazel output | Platform properties mismatch | Check `.bazelrc` platforms match worker `platformProperties` in `values.yaml` |
| Action cache never hits | AC bucket not connected | Check bb-storage logs for S3 write errors |
| `bb-runner` init fails | Image pull error for installer | `kubectl describe pod ... -n rbe-system`, check imagePullSecrets |
