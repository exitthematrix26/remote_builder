# Argo Rollouts — Issues Encountered and Fixed

Running log of problems hit during Phase 3 (Argo Rollouts canary for bb-worker).

---

## Issue 1: App-of-apps resets targetRevision, preventing branch testing

**Symptom:** After running `argocd app set rbe-system --revision argorollout`, within seconds the
app resets back to `targetRevision: HEAD` (main branch). The Rollout resource is created then
immediately pruned and replaced by the old Deployment.

**Root cause:** The app-of-apps Application watches `gitops/apps/rbe-system/application.yaml` on
the `main` branch, which has `targetRevision: HEAD`. Argo CD's `selfHeal: true` reconciles this
back within one polling cycle, overwriting any manual `argocd app set` changes.

**Fix:** For branch testing without merging to main, apply the rbe-system Application directly
with `kubectl apply --server-side`, pointing `targetRevision` to the feature branch. Then disable
auto-sync on rbe-system while testing:
```bash
argocd app set rbe-system --sync-policy none
kubectl apply --server-side -f - <<EOF
# ... Application manifest with targetRevision: argorollout
EOF
argocd app sync rbe-system --force
```
After testing, reset sync policy:
```bash
argocd app set rbe-system --sync-policy automated
```

**Production note:** In a real multi-cluster setup, you'd have a staging cluster that tracks
feature branches. The production cluster always tracks `main`/`HEAD` only.

---

## Issue 2: Old Deployment and new Rollout fight over same selector

**Symptom:** After applying the Rollout, both Rollout pods (`bb-worker-5d5bc8bfc-*`) and old
Deployment pods (`bb-worker-7ddb8c7db-*`) are running simultaneously. The pod count doubles.

**Root cause:** The old Deployment's ReplicaSet has the same `matchLabels` selector as the new
Rollout. When both exist simultaneously, both controllers try to manage pods with
`app.kubernetes.io/name=bb-worker`. The old Deployment's ReplicaSet keeps spawning pods even after
the Deployment is deleted.

**Fix:**
1. Delete the Deployment: `kubectl delete deployment bb-worker -n rbe-system`
2. Delete all orphaned ReplicaSets with the worker label:
   `kubectl delete replicaset -n rbe-system -l app.kubernetes.io/name=bb-worker`
3. The Rollout controller recreates its own ReplicaSet immediately.

**Prevention:** When migrating Deployment → Rollout, always ensure the old Deployment is fully
removed before the Rollout is created. In GitOps, this means the Deployment template file must be
deleted in the same commit that adds the Rollout template — which is what we did by running
`git rm charts/buildbarn/templates/deployment-worker.yaml` in the same commit that added
`rollout-worker.yaml`. The conflict only occurs during live branch testing before merge.

---

## Issue 3: `kubectl argo rollouts` plugin not installed

**Symptom:** `kubectl argo rollouts get rollout bb-worker -n rbe-system` returns exit code 1 with no output.

**Root cause:** The Argo Rollouts kubectl plugin is a separate binary from the controller — it is
not installed by the Helm chart.

**Fix:**
```bash
mkdir -p ~/.local/bin
curl -sL https://github.com/argoproj/argo-rollouts/releases/download/v1.8.3/kubectl-argo-rollouts-linux-amd64 \
  -o ~/.local/bin/kubectl-argo-rollouts
chmod +x ~/.local/bin/kubectl-argo-rollouts
export PATH="$HOME/.local/bin:$PATH"
kubectl-argo-rollouts version
```

---

## Issue 4: Same image tag does not trigger a new canary revision

**Symptom:** After running `kubectl argo rollouts set image bb-worker bb-runner=gcr.io/...:latest`,
the Rollout stays at revision:1 with no canary step initiated. `Status: ✔ Healthy`.

**Root cause:** Argo Rollouts (like Deployments) only creates a new revision when the pod template
spec actually changes. Setting the same image tag is a no-op.

**Fix:** To test canary progression without a real image change, either:
- Use `kubectl argo rollouts restart bb-worker` for a rolling restart (same revision, no canary steps)
- Use `kubectl patch rollout` to add/change an env var, annotation, or label in the pod template:
  ```bash
  kubectl patch rollout bb-worker -n rbe-system --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/env","value":[
      {"name":"RBE_REVISION","value":"v2-canary-test"}
    ]}
  ]'
  ```
  This creates a genuine revision:2 and initiates the canary steps.

---

## Verified Working State

After all fixes applied:

```
Name:            bb-worker
Status:          ✔ Healthy
Strategy:        Canary
  Step:          4/4
  SetWeight:     100
  ActualWeight:  100

revision:2  bb-worker-6f68597dd9  ✔ Healthy  stable
  bb-worker-6f68597dd9-j62h6  ✔ Running  ready:2/2
  bb-worker-6f68597dd9-jmp8z  ✔ Running  ready:2/2
revision:1  bb-worker-5d5bc8bfc   ScaledDown
```

Canary progression observed:
- Step 1/4: SetWeight 25 → 1 canary pod, 2 stable pods, 60s pause
- Step 3/4: SetWeight 50 → 1 canary pod, 1 stable pod, 60s pause
- Step 4/4: SetWeight 100 → 2 canary pods promoted to stable, old revision ScaledDown

RBE build during canary: `bazel build --config=rbe //:echo_test` succeeded with `1 remote` action.
