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

## Phase 2 continued

### 8. Buildbarn config schema breaking changes (2025 API overhaul)
**Symptom:** All three Buildbarn pods (`bb-storage`, `bb-scheduler`, `bb-worker`) crash immediately after pulling images with errors like:
```
Fatal error: Failed to unmarshal configuration: proto: (line 2:4): unknown field "blobstore"
Fatal error: Failed to unmarshal configuration: proto: (line 16:4): unknown field "scheduler"
```
**Root cause:** Buildbarn overhauled its protobuf config schema in 2025. Three separate breaking changes:

1. **bb-storage**: The `blobstore.cas` / `blobstore.ac` structure was replaced by top-level `contentAddressableStorage` and `actionCache` fields. The S3/MinIO backend was **removed entirely** — only local file-based storage is supported now.

2. **bb-scheduler**: The `scheduler.invocationStagedByIdAndTimeout` routing algorithm was replaced by `actionRouter.simple` with explicit `platformKeyExtractor`, `invocationKeyExtractors`, and `initialSizeClassAnalyzer` sub-fields.

3. **bb-worker**: The `schedulers` map was replaced by a single `scheduler.address` string field.

**Fix:** Rewrite all three configmaps to match the new schema:
```json
// bb-storage storage.json (new)
{
  "grpcServers": [{ "listenAddresses": [":8980"], "authenticationPolicy": { "allow": {} } }],
  "contentAddressableStorage": {
    "backend": {
      "local": {
        "keyLocationMapOnBlockDevice": { "file": { "path": "/storage/cas/key_location_map", "sizeBytes": 16777216 } },
        "oldBlocks": 2, "currentBlocks": 8, "newBlocks": 1,
        "blocksOnBlockDevice": {
          "source": { "file": { "path": "/storage/cas/blocks", "sizeBytes": 1073741824 } },
          "spareBlocks": 1
        },
        "persistent": { "stateDirectoryPath": "/storage/cas/persistent_state", "minimumEpochInterval": "300s" }
      }
    },
    "getAuthorizer": { "allow": {} }, "putAuthorizer": { "allow": {} }, "findMissingAuthorizer": { "allow": {} }
  },
  "actionCache": { ... same local structure, smaller sizes ... }
}

// bb-scheduler scheduler.json (new)
{
  "actionRouter": {
    "simple": {
      "platformKeyExtractor": { "action": {} },
      "invocationKeyExtractors": [{ "correlatedInvocationsId": {} }, { "toolInvocationId": {} }],
      "initialSizeClassAnalyzer": { "defaultExecutionTimeout": "1800s", "maximumExecutionTimeout": "7200s" }
    }
  }
}

// bb-worker worker.json (new)
{
  "blobstore": { "grpc": { "address": "bb-storage:8980" } },
  "scheduler": { "address": "bb-scheduler:8982" }
}
```

Also added an init container to `deployment-storage.yaml` to pre-create the `/storage/cas` and `/storage/ac` directory trees that `bb-storage` requires but does not create itself:
```yaml
initContainers:
  - name: init-storage-dirs
    image: busybox:1.36
    command: ["sh", "-c", "mkdir -p /storage/cas/persistent_state && mkdir -p /storage/ac/persistent_state"]
    volumeMounts:
      - name: storage
        mountPath: /storage
```
**Lesson:** Always check the current proto definitions at `github.com/buildbarn/bb-storage` and `github.com/buildbarn/bb-remote-execution` when upgrading image tags. The config schema version is tied to the image tag — mixing old configs with new images will always crash.

---

### 9. bb-scheduler grpc storage field requires nested `client` object
**Symptom:** `bb-scheduler` crashloops: `proto: (line 33:10): unknown field "address"`
**Root cause:** `contentAddressableStorage.grpc` is type `GrpcBlobAccessConfiguration` which wraps a `ClientConfiguration`. The address is not directly inside `grpc{}` — it's inside `grpc.client{}`.
**Fix:**
```json
// Wrong:
"contentAddressableStorage": { "grpc": { "address": "bb-storage:8980" } }
// Correct:
"contentAddressableStorage": { "grpc": { "client": { "address": "bb-storage:8980" } } }
```

---

### 10. bb-runner-installer arg is a destination DIRECTORY not a file path
**Symptom:** Worker init container fails: `open /install/bb-runner/bb_runner: no such file or directory`
**Root cause:** The installer takes its arg as a directory path and places the binary named `bb_runner` inside it. Passing `/install/bb-runner` tries to write to a non-existent subdirectory.
**Fix:** Pass `/install` so binary lands at `/install/bb_runner`. Update runner container command:
```yaml
initContainers:
  - args: ["/install"]             # was ["/install/bb-runner"]
containers:
  - name: bb-runner
    command: ["/install/bb_runner"] # was /install/bb-runner (wrong path + wrong name)
```

---

### 11. bb-runner config: `buildExecutor` removed, Unix socket uses `listenPaths`
**Symptom:** bb-runner crashloops: `proto: unknown field "buildExecutor"`
**Root cause:** The runner IS the executor — no `buildExecutor` sub-config exists. Unix socket paths use `listenPaths` not `listenAddresses` (which is TCP only).
**Fix:**
```json
// Correct runner.json:
{
  "grpcServers": [{ "listenPaths": ["/worker/runner"], "authenticationPolicy": { "allow": {} } }],
  "buildDirectoryPath": "/worker/build"
}
```

---

### 12. bb-worker blobstore structure: `contentAddressableStorage` + `actionCache` sub-fields
**Symptom:** bb-worker crashloops: `proto: unknown field "grpc"`
**Root cause:** The worker's `blobstore` field is `BlobstoreConfiguration` (not `BlobAccessConfiguration`). It has two sub-fields; each uses `grpc.client.address`.
**Fix:**
```json
"blobstore": {
  "contentAddressableStorage": { "grpc": { "client": { "address": "bb-storage:8980" } } },
  "actionCache":                { "grpc": { "client": { "address": "bb-storage:8980" } } }
}
```

---

### 13. bb-worker requires `inputDownloadConcurrency` and `outputUploadConcurrency` > 0
**Symptom:** bb-worker crashes: `Nonpositive input download concurrency: 0`
**Root cause:** These fields default to 0 which is explicitly rejected. Must be positive.
**Fix:** Add to `worker.json`: `"inputDownloadConcurrency": 4, "outputUploadConcurrency": 4`

---

### 14. bb-worker native build dir requires cache policy and size limits
**Symptom:** bb-worker crashes: `Failed to create eviction set for cache directory: Unknown cache replacement policy`
**Root cause:** `cacheDirectoryPath` requires `cacheReplacementPolicy`, `maximumCacheFileCount`, and `maximumCacheSizeBytes` to be explicitly set.
**Fix:**
```json
"native": {
  "buildDirectoryPath": "/worker/build",
  "cacheDirectoryPath": "/worker/cache",
  "maximumCacheFileCount": 10000,
  "maximumCacheSizeBytes": 536870912,
  "cacheReplacementPolicy": "LEAST_RECENTLY_USED"
}
```

---

### 15. Storage and worker directories must be pre-created via init containers
**Symptom:** bb-storage and bb-worker crash on startup — can't open files/directories that don't exist yet.
**Root cause:** Both require directory trees to exist before they start. `emptyDir` volumes are blank.
**Fix:** Init containers in both deployments:
```yaml
initContainers:
  - name: init-dirs
    image: busybox:1.36
    command: ["sh", "-c", "mkdir -p /storage/cas/persistent_state /storage/ac/persistent_state"]
```

---

### 16. bb-storage local backend: missing keyLocationMap attempt counts
**Symptom:** `FAILED_PRECONDITION: Failed to obtain action: Object not found` from bb-scheduler. ByteStream/Write to bb-storage returned `committed_size` success but all subsequent reads returned `NOT_FOUND`.
**Root cause:** The `local` storage backend proto has `keyLocationMapMaximumGetAttempts` and `keyLocationMapMaximumPutAttempts` fields that default to **0** in proto3. With 0 attempts, the open-addressing hash table never probes any slots — writes store blob data in the blocks file but never write the key→location entry, so all lookups fail immediately.
**Fix:** Add to both CAS and AC local backends in `configmap-storage.yaml`:
```json
"keyLocationMapMaximumGetAttempts": 16,
"keyLocationMapMaximumPutAttempts": 64
```
These match the reference config in `bb-deployments/docker-compose/config/storage.jsonnet`.

**Also fixed:** Helm renders large YAML integers as Go float64, producing scientific notation in JSON (`1.6777216e+07` instead of `16777216`). Use `| int64` in templates:
```yaml
"sizeBytes": {{ .Values.storage.cas.keyLocationMapSize | int64 }}
```

---

### 17. bb-runner container uses busybox — no /bin/bash for genrules
**Symptom:** Remote action fails: `Invalid Argument: Failed to run command: Failed to start process: fork/exec /bin/bash: no such file or directory`
**Root cause:** The bb-runner container was set to `busybox:1.36` which has `/bin/sh` (ash) but not `/bin/bash`. Bazel genrule wrapper scripts use bash.
**Fix:** Change bb-runner container image to `ubuntu:22.04`:
```yaml
- name: bb-runner
  image: ubuntu:22.04
```
Bazel uploads all toolchain inputs (Go SDK, etc.) via CAS, so only `bash` + basic coreutils are needed in the worker image.

---

### 18. RBE platform: workers vs. action platform mismatch (empty platform {})
**Symptom:** `FAILED_PRECONDITION: No workers exist for instance name prefix "" platform {}` — even though workers were running.
**Root cause (two parts):**
1. The old `.bazelrc` used `--extra_execution_platforms=@rules_go//go/toolchain:linux_amd64` which has no `exec_properties`. Bazel sent `platform {}` (empty) in Execute requests. Workers registered with `{ISA=amd64, OSFamily=linux}`. The scheduler uses exact matching — empty platform didn't match.
2. Host-tool actions (`GoToolchainBinaryBuild [for tool]`) use a separate exec platform. Setting only `--extra_execution_platforms` isn't enough; `--host_platform` must also be set.
**Fix:** Define a custom Bazel platform with both constraint_values (for toolchain resolution) and exec_properties (for REAPI platform matching):
```python
# BUILD
platform(
    name = "rbe_platform",
    constraint_values = ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    exec_properties = {"ISA": "amd64", "OSFamily": "linux"},
)
```
```
# .bazelrc
build:rbe --extra_execution_platforms=//:rbe_platform
build:rbe --host_platform=//:rbe_platform
build:rbe --platforms=//:rbe_platform
```

---

### 19. Go stdlib remote build fails: cc not found (CGO)
**Symptom:** `GoStdlib` remote action fails: `cc: no such file or directory`. stdlib: error running subcommand go: exit status 1`
**Root cause:** By default, rules_go compiles the Go stdlib with CGO enabled, which requires a C compiler (`cc`/`gcc`). ubuntu:22.04 worker image doesn't have gcc installed.
**Fix:** Add `pure = "on"` to the `go_binary` rule to disable CGO entirely:
```python
go_binary(name = "hello", srcs = ["main.go"], pure = "on")
```
This is standard practice for containerized RBE builds — pure Go binaries have no system dependencies.

---

