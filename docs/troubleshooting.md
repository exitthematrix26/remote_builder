# Troubleshooting Log — RBE Platform Lab

> Real issues encountered during Phase 1 bootstrap, documented with root cause, debug steps, and fix. Each entry is a learning moment about how Kubernetes and kind actually work under the hood.

---

## Issue 1 — Bootstrap script silently exited after pre-flight checks

### Symptom
Running `./cluster/bootstrap.sh` printed the pre-flight success messages then exited with no error and no further output. No cluster was created.

```
[bootstrap] All required tools found
[bootstrap] Docker is running
[bootstrap] Cluster name 'remote-builder' is available
# ← script just stops here, no error message
```

### Root Cause
`set -euo pipefail` at the top of the script makes **any non-zero exit code in a pipeline kill the entire script silently**.

The offending line:
```bash
RUNNING_KIND=$(docker ps --filter name=kind --format '{{.Names}}' | grep -v "${CLUSTER_NAME}" | wc -l)
```

`grep` returns exit code `1` when it finds zero matches — a completely normal outcome. But inside `pipefail`, that exit code 1 is treated as a fatal error and the script dies silently.

The deeper issue: `docker ps --filter name=kind` returned nothing because the existing kind containers are named `bazel-sim-control-plane` and `bootik-local-control-plane` — neither contains the literal string `kind`.

### Fix
Replace the fragile docker filter + grep pipeline with `kind get clusters`, which reliably lists all kind clusters by name:

```bash
# Before (broken)
RUNNING_KIND=$(docker ps --filter name=kind --format '{{.Names}}' | grep -v "${CLUSTER_NAME}" | wc -l)

# After (fixed)
RUNNING_KIND=$(kind get clusters 2>/dev/null | grep -vc "^${CLUSTER_NAME}$" || true)
```

The `|| true` means "if grep returns non-zero (zero matches), treat it as success." This is the standard pattern for using grep inside `set -e` scripts when zero matches is a valid outcome.

### Lesson
`set -euo pipefail` is best practice for shell scripts — it catches real errors. But it bites you with tools like `grep`, `wc`, and `diff` that use non-zero exit codes to communicate normal results. Always append `|| true` when a non-zero result is acceptable.

---

## Issue 2 — Worker nodes fail to join: kubeadm v1beta3 label/taint breakage

### Symptom
Control plane starts successfully. Worker nodes fail during the join phase:

```
✗ Joining worker nodes 🚜
ERROR: failed to create cluster: failed to join node with kubeadm
nodes "remote-builder-worker" not found
error uploading crisocket
error execution phase kubelet-start
```

The kubelet starts briefly then dies. The node object never appears in the API server.

### Root Cause
The original `kind-config.yaml` used `kubeadmConfigPatches` to set node labels and taints:

```yaml
# BROKEN — do not use on K8s 1.31
kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "pool=rbe-workers"
      taints:
        - key: "dedicated"
          value: "rbe-worker"
          effect: "NoSchedule"
```

In Kubernetes 1.31, the `kubeadm.k8s.io/v1beta3` API changed `kubeletExtraArgs` from `map[string]string` to a typed `[]Arg` list. The old string-map format silently fails — kubeadm parses it but doesn't apply it, and the node registration process then fails because the node object can't be patched. The `taints[]` field has the same breakage.

### Debug Steps
```bash
# Use --retain so kind doesn't delete failed containers
kind create cluster --name remote-builder --config cluster/kind-config.yaml --retain

# After failure, inspect the dead worker's kubelet logs
docker exec remote-builder-worker journalctl -u kubelet --no-pager | tail -30
# Look for: "nodes remote-builder-worker not found" / "error uploading crisocket"
```

### Fix
**Labels:** Use kind's native `labels:` field — applies via the K8s API post-join, no kubeadm involvement:

```yaml
- role: worker
  image: kindest/node:v1.31.2
  labels:
    pool: rbe-workers   # kind applies this directly, not via kubeadm
```

**Taints:** Remove from `kind-config.yaml` entirely. Apply via `kubectl taint` in `bootstrap.sh` after nodes are Ready:

```bash
WORKER_NODE=$(kubectl get nodes -l pool=rbe-workers -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "${WORKER_NODE}" dedicated=rbe-worker:NoSchedule --overwrite
```

### Lesson
Kind's native node fields (`labels:`, `extraPortMappings:`) are always more reliable than `kubeadmConfigPatches`. Only use patches for things that genuinely must be set at kubelet startup — and check kubeadm API version compatibility first.

---

## Issue 3 — Worker kubelet crashes: `inotify_init: too many open files`

### Symptom
Worker nodes still failed after fixing the kubeadm issue. Kubelet logs (via `--retain`) showed:

```
E kubelet: "Failed to watch CA file" err="error creating fsnotify watcher: too many open files"
E kubelet: "Unable to read config path" err="unable to create inotify: too many open files"
E kubelet: "Failed to start cAdvisor" err="inotify_init: too many open files"
systemd: kubelet.service: Main process exited, code=exited, status=1/FAILURE
```

### Root Cause
Linux limits the number of inotify file watchers per user. The kubelet, containerd, and cAdvisor each create dozens of inotify watches. With two existing kind clusters (`bazel-sim` and `bootik-local`) already running, the default inotify limits were exhausted.

Default limits (too low for 3 clusters):
```
fs.inotify.max_user_watches   = 65536
fs.inotify.max_user_instances = 128
```

### Debug Steps
```bash
# Check current limits
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances

# See which processes are consuming inotify instances
find /proc/*/fd -lname 'anon_inode:inotify' 2>/dev/null \
  | awk -F/ '{print $3}' \
  | xargs -I{} cat /proc/{}/comm 2>/dev/null \
  | sort | uniq -c | sort -rn
```

The `--retain` flag was essential here — without it, kind deletes failed containers and the logs are gone:
```bash
kind create cluster --name remote-builder --config cluster/kind-config.yaml --retain
# After failure:
docker exec remote-builder-worker journalctl -u kubelet --no-pager | grep -E "inotify|too many"
```

### Fix
Increase the inotify limits at the kernel level — applies immediately, no reboot:

```bash
# Apply immediately
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512

# Persist across reboots
echo "fs.inotify.max_user_watches = 524288" | sudo tee -a /etc/sysctl.d/99-kind.conf
echo "fs.inotify.max_user_instances = 512"  | sudo tee -a /etc/sysctl.d/99-kind.conf

# Verify
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
```

### Lesson
This is the #1 cause of multi-cluster kind failures on developer machines. The default Linux inotify limits were designed for a single workstation. Running 3 kind clusters simultaneously exhausts them. The symptom looks like a Docker or K8s config problem — it's actually a host kernel parameter.

---

## Issue 4 — Worker kubelet fails: cgroup v2 + systemd driver mismatch

### Symptom
After fixing inotify, worker nodes still failed. The 4-minute healthz timeout:

```
[kubelet-check] Waiting for a healthy kubelet at http://127.0.0.1:10248/healthz.
[kubelet-check] The kubelet is not healthy after 4m0.000475618s

context deadline exceeded

This error is likely caused by:
  - The kubelet is not running
  - The kubelet is unhealthy due to a misconfiguration of the node
    (required cgroups disabled)
```

**Key diagnostic clue:** Control plane always succeeded. Only worker nodes failed.

### Root Cause
Linux kernel 6.x uses **cgroup v2** with **systemd** as the cgroup manager. The containerd runtime inside kind worker node containers was defaulting to the `cgroupfs` cgroup driver. The kubelet expected `systemd` (correct for cgroup v2), but containerd was using `cgroupfs` — a mismatch that causes the kubelet to fail to initialize.

The control plane succeeded because `kubeadm init` uses a slightly different cgroup initialization path than `kubeadm join`.

```bash
# Confirm you're on cgroup v2
stat -fc %T /sys/fs/cgroup/
# Returns: cgroup2fs  ← you're on v2

docker info | grep -i cgroup
# Cgroup Driver: systemd
# Cgroup Version: 2
```

### Fix
Add `containerdConfigPatches` at the cluster level in `kind-config.yaml`. This patches containerd's TOML config on every node *before* any kubelet starts:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: remote-builder

# Fix for cgroup v2 + systemd on Linux kernel 6.x
# Tells containerd to use the systemd cgroup driver on all nodes.
# Without this: kubelet healthz times out on worker nodes → cluster never forms.
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        SystemdCgroup = true

nodes:
  - role: control-plane
    image: kindest/node:v1.31.2
  - role: worker
    image: kindest/node:v1.31.2
    labels:
      pool: infra
  - role: worker
    image: kindest/node:v1.31.2
    labels:
      pool: rbe-workers
```

### Lesson
cgroup v2 is the default on all modern Linux distros (Ubuntu 22.04+, Fedora 31+, kernel 5.15+). Kind v0.20 and earlier auto-detected this and applied the fix transparently. Kind v0.25 with K8s 1.31 requires it explicit.

**Always include `containerdConfigPatches` with `SystemdCgroup = true` when using kind on any modern Linux system.** It is harmless on systems that don't need it, and silently fixes this failure on systems that do.

The control-plane-works / workers-fail asymmetry is a reliable signal: if you ever see this pattern again, suspect cgroup driver mismatch first.

---

## Issue 5 — Argo CD `ComparisonError: authentication required`

### Symptom
After bootstrap, `argocd app list` showed:

```
NAME           STATUS   CONDITIONS
app-of-apps    Unknown  ComparisonError
```

Argo CD couldn't sync because it couldn't clone the repo.

### Root Cause
Two causes combined:
1. The GitHub repo had not been pushed yet (existed locally, not on GitHub)
2. The `argocd repo add` command in `bootstrap.sh` uses `|| true` — so when it fails (repo not yet accessible), the script continues silently

### Fix

```bash
# Step 1: Push code to GitHub
git add .
git commit -m "Phase 1: cluster bootstrap"
git branch -M main
git push -u origin main

# Step 2: Register repo with credentials
source cluster/config.env
argocd repo add https://github.com/exitthematrix26/remote_builder \
  --username exitthematrix26 \
  --password "${GITHUB_PAT}"

# Step 3: Force refresh
argocd app get app-of-apps --refresh
argocd app list
# Expected: Synced / Healthy
```

### Lesson
Always push code to GitHub *before* running `bootstrap.sh`. Argo CD needs to be able to clone the repo at the moment the app-of-apps Application is applied, or it enters a `ComparisonError` loop.

---

## Quick Reference — Essential Commands

```bash
# ── Cluster context switching ──────────────────────────────────────────────
kubectl config get-contexts                          # list all clusters
kubectl config use-context kind-remote-builder       # switch to this lab
kubectl config use-context kind-bazel-sim            # switch to bazel-sim
kubectl config use-context kind-bootik-local         # switch to bootik

# ── Stop/resume clusters without losing state ──────────────────────────────
docker stop $(docker ps -q --filter name=bazel-sim)  # pause bazel-sim
docker start $(docker ps -aq --filter name=bazel-sim) # resume bazel-sim

# ── Health checks ──────────────────────────────────────────────────────────
kubectl get nodes --show-labels                      # verify labels + status
kubectl describe nodes | grep -A3 Taints             # verify taints
kubectl get pods -A                                  # all pods all namespaces
argocd app list                                      # GitOps sync status

# ── Argo CD ────────────────────────────────────────────────────────────────
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d         # get admin password
argocd app sync app-of-apps                          # force immediate sync
argocd app get app-of-apps --refresh                 # refresh + show status

# ── Sealed Secrets ─────────────────────────────────────────────────────────
# Back up master key (do this after every fresh bootstrap)
kubectl -n cluster-infra get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > ~/sealed-secrets-master-key.yaml

# ── Debug inside a failed kind container ──────────────────────────────────
kind create cluster --name remote-builder \
  --config cluster/kind-config.yaml --retain         # keep containers on failure
docker exec remote-builder-worker \
  journalctl -u kubelet --no-pager | tail -50        # kubelet logs

# ── inotify limits (required for 3+ kind clusters) ────────────────────────
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```
