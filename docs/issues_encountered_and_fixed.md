# Issues Encountered and Fixed

Running log of problems hit during the lab and how they were resolved.
Kept here so future sessions can diagnose the same problems faster.

---

## Phase 1 — Cluster bootstrap

### 1. Silent bootstrap exit after pre-flight check
**Symptom:** `bootstrap.sh` exits immediately after the "cluster already exists" check with no error message.
**Root cause:** `grep -v` returns exit code 1 when it finds no lines to pass through. Combined with `set -euo pipefail`, this silently kills the script.
**Fix:**
```bash
# Before (breaks with set -e):
docker ps --filter name=kind | grep -v "$CLUSTER_NAME"

# After (safe):
kind get clusters 2>/dev/null | grep -vc "^${CLUSTER_NAME}$" || true
```

---

### 2. Worker nodes fail to join — kubeadm v1beta3
**Symptom:** `kubectl get nodes` shows only control-plane; workers never appear.
**Root cause:** Kubernetes 1.31 changed `kubeletExtraArgs` from a string map to a structured type. Setting `node-labels` and `taints` via `JoinConfiguration.kubeletExtraArgs` silently fails.
**Fix:** Use kind's native `labels:` field in `kind-config.yaml` and apply taints via `kubectl taint` after cluster creation:
```yaml
# kind-config.yaml
nodes:
  - role: worker
    labels:
      pool: rbe-workers   # ← native kind field, always works
```
```bash
# bootstrap.sh — post-creation taint
kubectl taint nodes "${WORKER_NODE}" dedicated=rbe-worker:NoSchedule --overwrite
```

---

### 3. inotify exhaustion (`too many open files`)
**Symptom:** kind cluster creation hangs or pods fail with `too many open files`.
**Root cause:** Running 2+ kind clusters exhausts the default inotify limits (65536 watches, 128 instances). Each kind node container consumes significant inotify resources.
**Fix:**
```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
# Persist across reboots:
echo "fs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/99-kind.conf
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.d/99-kind.conf
```

---

### 4. cgroup v2 / systemd driver mismatch
**Symptom:** Control plane comes up but worker nodes fail with a 4-minute healthz timeout in kubelet logs.
**Root cause:** Linux kernel 6.x uses cgroup v2. containerd defaults to the `cgroupfs` driver. kubelet expects `systemd`. The mismatch causes kubelet on worker nodes to crash-loop silently.
**Fix:** Add `containerdConfigPatches` to `kind-config.yaml`:
```yaml
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        SystemdCgroup = true
```

---

### 5. Argo CD ComparisonError — authentication required
**Symptom:** `argocd app list` shows `ComparisonError: authentication required` for app-of-apps.
**Root cause:** The GitHub repo wasn't pushed before `argocd repo add` ran, or the PAT was missing. Argo CD couldn't clone the repo.
**Fix:** Push the repo first, then re-register:
```bash
argocd repo add https://github.com/exitthematrix26/remote_builder \
  --username exitthematrix26 \
  --password "$GITHUB_PAT"
```

---

## Phase 2 — Buildbarn + MinIO

### 6. Buildbarn pods stuck on ImagePullBackOff
**Symptom:** `bb-storage`, `bb-scheduler`, `bb-worker` all show `ImagePullBackOff` immediately after Argo CD deploys them.
**Root cause:** Buildbarn does not publish a `latest` tag on ghcr.io. Tags follow the pattern `YYYYMMDDTHHMMSSz-<commithash>`. Using `tag: latest` in `values.yaml` results in a 404 from ghcr.io.
**Fix:** Pin explicit tags in `charts/buildbarn/values.yaml`:
```yaml
image:
  storage:
    tag: "20260326T151518Z-d0c6f26"
  scheduler:
    tag: "20260408T084910Z-570a4d4"
  worker:
    tag: "20260408T084910Z-570a4d4"
  runnerInstaller:
    tag: "20260408T084910Z-570a4d4"
  pullPolicy: IfNotPresent
```
Check current tags at:
- https://github.com/buildbarn/bb-storage/pkgs/container/bb-storage
- https://github.com/buildbarn/bb-remote-execution/pkgs/container/bb-worker

---

### 7. Bazel WORKSPACE deprecated / MODULE.bazel required
**Symptom:** VS Code Bazel extension errors: `not within a workspace (below a directory having a MODULE.bazel file)`. `bazel build` fails with CcInfo symbol removed error using `rules_go 0.51.0`.
**Root cause:** Bazel 9 removed legacy APIs used by older `rules_go` versions. The `WORKSPACE` format is deprecated. `rules_go 0.51.0` predates Bazel 9.
**Fix:** Replace `WORKSPACE` with `MODULE.bazel` using Bzlmod, and upgrade to `rules_go 0.60.0`:
```python
# MODULE.bazel
module(name = "hello_bazel", version = "0.1.0")
bazel_dep(name = "rules_go", version = "0.60.0")
bazel_dep(name = "gazelle", version = "0.50.0")
go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
go_sdk.download(version = "1.23.4")
```
Also update label prefix in BUILD and .bazelrc from `@io_bazel_rules_go//` to `@rules_go//`.

---
