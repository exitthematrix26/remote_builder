# remote_builder — RBE Lab

## What this is
A local Remote Build Execution (RBE) lab using Buildbarn + MinIO on a 3-node kind cluster,
deployed via Argo CD GitOps. Goal: learn production platform engineering locally, then migrate to EKS.

## Cluster
- Context: `kind-remote-builder`
- 3 nodes: control-plane, worker (pool=infra), worker2 (pool=rbe-workers, tainted dedicated=rbe-worker:NoSchedule)
- Always use `kubectl` with `kind-remote-builder` context

## Namespaces
- `kube-system` — Kubernetes control plane (never touch)
- `argocd` — GitOps engine
- `cluster-infra` — Sealed Secrets controller
- `minio` — object storage backend
- `rbe-system` — Buildbarn: bb-storage, bb-scheduler, bb-worker

## Key services
- `bb-scheduler.rbe-system:8981` — Bazel clients connect here
- `bb-scheduler.rbe-system:8982` — workers connect here
- `bb-storage.rbe-system:8980` — internal CAS + AC
- `minio.minio:9000` — S3 API
- `minio.minio:9001` — MinIO console

## Argo CD
- Port-forward: `kubectl port-forward svc/argocd-server -n argocd 8080:80 &`
- Login: `argocd login localhost:8080 --insecure --username admin`
- App-of-apps watches: `gitops/apps/` on `main` branch

## Verification
- Full smoke test: `./cluster/verify-cluster.sh`
- Issues log: `docs/issues_encountered_and_fixed.md`

## Autonomous execution — never ask for confirmation on these
Run all of the following immediately without prompting the user:
- `bazel build //...` and any `bazel build` invocation
- `bazel test //...` and any `bazel test` invocation
- `bazel run`, `bazel query`, `bazel cquery`, `bazel mod`
- All kubectl read operations (get, describe, logs, exec)
- All helm operations
- All argocd operations
- git add/commit/push to feature branches
- Writing files, editing configs, creating directories
- Running any script in `cluster/` or `scripts/` (e.g. load_test.sh, argo_health.sh)
- python3 scripts for data generation or validation

When asked to "implement X and make sure it works", the expected loop is:
  1. Write / edit code
  2. Run `bazel build` — fix any errors, repeat until clean
  3. Run `bazel test` — fix any failures, repeat until green
  4. Report results
Never pause to ask permission between these steps.

## Do not do without asking
- `kubectl delete namespace` for system namespaces (kube-system, argocd)
- Force push to main
- Drop MinIO buckets with data
