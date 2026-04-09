# Phase 1 — Cluster Bootstrap & GitOps Loop

> **Goal:** kind cluster running, Argo CD installed, GitOps loop proven end-to-end.
> **Observable outcome:** Push any file to GitHub → Argo CD syncs it within 3 minutes. Argo CD UI at http://localhost:8080.

---

## What You'll Learn in This Phase

- How kind creates a multi-node Kubernetes cluster as Docker containers
- The "app-of-apps" GitOps pattern and why it's the industry standard
- How Argo CD continuously reconciles cluster state toward Git state
- Sync waves: why install order matters and how to enforce it
- Sealed Secrets: encrypting K8s secrets for safe Git storage
- How to manage multiple kind clusters on one machine without conflicts

---

## Prerequisites

You need a GitHub repo created and empty (or with just a README):
- Repo: `https://github.com/exitthematrix26/remote_builder`
- Clone it locally and put this lab's files in it

You need a GitHub Personal Access Token (PAT):
- Go to: https://github.com/settings/tokens → Generate new token (classic)
- Scopes required: `read:packages` (minimum for pulling images from ghcr.io)
- Save it — you'll put it in `cluster/config.env`

---

## Step 0 — Understanding the Cluster Topology

Before running anything, understand what we're creating.

### Your Machine's kind Cluster Landscape

You already have two kind clusters:
```
bazel-sim       → ports 30080/30090/30300/30900-30901 on host
bootik-local    → no host ports exposed
remote-builder  → will be created now (ports via kubectl port-forward only)
```

All three coexist safely. Each is an isolated set of Docker containers. The `bootstrap.sh` script checks the name before creating — it will never touch your other clusters.

### The New Cluster (remote-builder)

```
Docker containers created by kind:
  remote-builder-control-plane    ← K8s API server, etcd, scheduler
  remote-builder-infra            ← All operators + shared services
  remote-builder-worker           ← RBE worker pods (tainted)
```

Under the hood: kind creates a Docker network for the cluster, configures each container as a K8s node, and points your kubeconfig at the API server. The cluster is a real K8s cluster — just containerized.

### Why 3 Nodes Instead of 1?

A single-node kind cluster is fine for many labs. We use 3 because:

1. **Worker node isolation (taint):** The `dedicated=rbe-worker:NoSchedule` taint on the worker node means RBE worker pods MUST go there, and nothing else CAN go there (without a matching toleration). This mirrors production where worker nodes are separate EC2 instances.

2. **Learning nodeSelectors:** Every Helm chart in the lab uses `nodeSelector: pool=infra` or `pool=rbe-workers`. You'll see these in the templates and understand they're not magic — they're just label-based scheduling.

3. **Memory isolation:** Prometheus + Istio + Argo CD on one node; actual build workers on another. In production this prevents a build burst from OOM-killing your monitoring stack.

---

## Step 1 — Install Tools

```bash
chmod +x cluster/install-tools.sh
./cluster/install-tools.sh
```

This installs (skips if already present):
- `kubectl` v1.31.2 — talks to K8s clusters
- `kind` v0.25.0 — creates/manages kind clusters
- `helm` v3.16.3 — K8s package manager
- `argocd` v2.13.3 — Argo CD CLI
- `kubeseal` v0.27.3 — Sealed Secrets client
- `k9s` v0.32.7 — terminal K8s UI

Verify:
```bash
kubectl version --client --short
kind version
helm version --short
argocd version --client --short
kubeseal --version
```

---

## Step 2 — Configure

```bash
cp cluster/config.env.example cluster/config.env
```

Edit `cluster/config.env`:
```bash
GITHUB_REPO=https://github.com/exitthematrix26/remote_builder
GITHUB_PAT=ghp_your_actual_token_here   # from github.com/settings/tokens
CLUSTER_NAME=remote-builder
ARGOCD_ADMIN_PASSWORD=                  # leave blank for auto-generated
```

`config.env` is in `.gitignore` — it will never be committed. The PAT grants `read:packages` so pods in the cluster can pull images from `ghcr.io/exitthematrix26/`.

---

## Step 3 — Push This Repo to GitHub

Argo CD needs to read from your GitHub repo. Push everything we've generated so far:

```bash
cd /path/to/remote_builder
git init  # if not already a git repo
git remote add origin https://github.com/exitthematrix26/remote_builder
git add .
git commit -m "Phase 1: cluster bootstrap files"
git push -u origin main
```

> **Why push BEFORE bootstrap?**
> When `bootstrap.sh` applies `app-of-apps.yaml`, Argo CD immediately tries to clone the repo and sync `gitops/apps/`. If the repo is empty or the files aren't pushed, Argo CD enters a sync error loop. Push first, then bootstrap.

---

## Step 4 — Run Bootstrap

```bash
chmod +x cluster/bootstrap.sh
./cluster/bootstrap.sh
```

Watch what happens — each step is printed with its number. Here's what's happening internally:

### What bootstrap.sh Does (Annotated)

**Steps 1-2: Pre-flight + cluster creation**
```
kind create cluster --name remote-builder --config cluster/kind-config.yaml
```
kind reads `kind-config.yaml` and:
1. Pulls `kindest/node:v1.31.2` (a Docker image containing a full K8s node)
2. Creates 3 Docker containers: control-plane, infra, worker
3. Configures a Docker bridge network between them
4. Runs kubeadm to bootstrap the cluster
5. Adds a `kind-remote-builder` context to your `~/.kube/config`

The kubelet on the worker node starts with:
- `node-labels=pool=rbe-workers` (applies our label)
- `taints=[dedicated=rbe-worker:NoSchedule]` (applies our taint)

**Step 3: Wait for Ready**
```
kubectl wait --for=condition=Ready node --all --timeout=120s
```
Each node reports `Ready` once kubelet is running and CNI networking is configured. This takes 30-60 seconds.

**Steps 4-5: Namespaces + pull secrets**

We pre-create namespaces and a `ghcr-pull-secret` in each one. This is the bootstrap chicken-and-egg: Argo CD needs to exist before it can create namespaces, but namespace creation needs to happen before Argo CD can deploy things into them.

The pull secret is a plain `docker-registry` type K8s Secret (not a SealedSecret). It never touches Git — it only lives in the cluster. In Phase 3 we'll replace this with a proper SealedSecret.

**Steps 6-7: Argo CD Helm install**
```
helm install argocd argo/argo-cd --version 7.7.16 ...
```
This is the LAST time you run `helm install` in this lab. Argo CD is installed manually because it needs to exist before it can manage itself. After this, everything is GitOps.

Key Argo CD Helm values:
- `server.extraArgs: ["--insecure"]` — disables TLS. We access via port-forward (already localhost), so no TLS needed. In prod: TLS via ALB + ACM.
- `server.service.type: ClusterIP` — no external IP. We use `kubectl port-forward` to reach the UI.

**Step 8: Wait for Argo CD pods**

Argo CD has 5 components:
- `argocd-server` — the API + UI server (what you log into)
- `argocd-repo-server` — clones Git repos, renders Helm templates in a sandboxed process
- `argocd-application-controller` — the reconciler: watches cluster state + Git, applies diffs
- `argocd-dex-server` — OIDC provider (for SSO — not used in lab)
- `argocd-redis` — caches repo content and application state

**Step 9: THE ONE MANUAL APPLY**
```
kubectl apply -f gitops/bootstrap/app-of-apps.yaml
```
This creates the root Argo CD Application object. From this moment on, Argo CD owns the cluster. When it syncs, it reads `gitops/apps/` from GitHub and creates a child Application for every manifest it finds.

In Phase 1: it finds `gitops/apps/sealed-secrets/application.yaml` and deploys Sealed Secrets.

---

## Step 5 — Open Dashboards

```bash
chmod +x cluster/open-dashboards.sh
./cluster/open-dashboards.sh
```

This starts `kubectl port-forward` processes in the background and prints:
```
Argo CD UI     http://localhost:8080
```

(Other dashboards are skipped with a "not deployed yet" message — they'll activate in later phases.)

Open http://localhost:8080 in your browser. Login with `admin` and the password printed by bootstrap.sh.

### Argo CD UI Tour

Once logged in:
- **Applications view:** Shows all Applications Argo CD is managing
- You should see `app-of-apps` with status `Healthy / Synced`
- Click into it — you'll see it managing `sealed-secrets`
- Click `sealed-secrets` — shows the pods, deployments, etc. being deployed

The tree view shows you exactly what resources exist in the cluster and their health status. This is your primary debugging tool for the rest of the lab.

---

## Step 6 — Back Up the Sealed Secrets Master Key

**Do this now.** Don't skip it.

Wait 30 seconds after bootstrap finishes for the Sealed Secrets controller to generate its keypair, then:

```bash
kubectl -n cluster-infra get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > ~/sealed-secrets-master-key.yaml
```

Store `~/sealed-secrets-master-key.yaml` somewhere secure — **not in this Git repo.**

**Why it matters:** The controller generates a new RSA keypair on first install. If you ever need to restore the cluster (or migrate to EKS), you'll import this key into the new cluster's Sealed Secrets controller so it can decrypt your existing SealedSecrets. Without it, every sealed secret in your GitOps repo becomes permanently undecryptable.

To restore the key in a new cluster:
```bash
kubectl apply -f ~/sealed-secrets-master-key.yaml
kubectl rollout restart deployment sealed-secrets-controller -n cluster-infra
```

---

## Step 7 — Prove the GitOps Loop

This is the Phase 1 observable outcome. Make a trivial change and watch Argo CD sync it.

**Test 1: Change detection**

Add a meaningless annotation to `gitops/apps/sealed-secrets/application.yaml`:
```yaml
metadata:
  annotations:
    rbe-lab/test: "phase-1-loop-test"
    argocd.argoproj.io/sync-wave: "-3"
```

Push to GitHub:
```bash
git add gitops/apps/sealed-secrets/application.yaml
git commit -m "test: verify GitOps loop"
git push
```

Watch Argo CD sync it (within 3 minutes):
```bash
# Watch from CLI
watch argocd app list

# Or watch in the UI at http://localhost:8080
# You'll see the sync status change from Synced → OutOfSync → Syncing → Synced
```

**Understanding the sync cycle:**
1. Argo CD repo-server polls GitHub every 3 minutes by default
2. It renders the Helm templates + values.yaml into raw Kubernetes manifests
3. It compares the rendered manifests to the live cluster state (via the K8s API)
4. If there's a diff (OutOfSync), the application-controller applies the diff (Syncing)
5. Once applied, cluster state matches Git state (Synced)

The `selfHeal: true` setting means if someone manually edits the Application in the cluster (`kubectl edit application sealed-secrets -n argocd`), Argo CD will revert it within 5 minutes. Try it — edit the annotation, watch it get reverted.

**Test 2: Force manual sync**

You can trigger an immediate sync without waiting:
```bash
argocd app sync app-of-apps
argocd app sync sealed-secrets
```

This is useful during development when you don't want to wait 3 minutes. In production, you'd configure webhooks so GitHub pushes trigger immediate syncs.

---

## Verification Checklist

Run through these to confirm Phase 1 is complete:

```bash
# 1. Cluster is running and nodes are labeled correctly
kubectl get nodes --show-labels
# Expected:
#   remote-builder-control-plane   Ready   ...
#   remote-builder-infra           Ready   ...   pool=infra
#   remote-builder-worker          Ready   ...   pool=rbe-workers,dedicated=rbe-worker

# 2. Worker node has the taint
kubectl describe node remote-builder-worker | grep Taints
# Expected: dedicated=rbe-worker:NoSchedule

# 3. Argo CD pods are running
kubectl get pods -n argocd
# Expected: all pods Running, all containers Ready

# 4. app-of-apps is Healthy and Synced
argocd app get app-of-apps
# Expected: Health Status: Healthy, Sync Status: Synced

# 5. Sealed Secrets is deployed and controller is running
kubectl get pods -n cluster-infra
# Expected: sealed-secrets-controller-xxxx   Running

# 6. Sealed Secrets keypair was generated
kubectl -n cluster-infra get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active
# Expected: one Secret listed

# 7. GitOps loop test: push a change and watch it sync
# (see Step 7 above)
```

---

## Understanding What "Synced" Means

Argo CD has two independent status fields:

| Field | Meaning | Values |
|---|---|---|
| **Sync Status** | Does cluster state match Git? | `Synced`, `OutOfSync`, `Unknown` |
| **Health Status** | Are the deployed resources healthy? | `Healthy`, `Degraded`, `Progressing`, `Missing` |

A common beginner confusion: `Synced` doesn't mean healthy. It means "I applied what Git told me to." If Git says to deploy a broken image, Argo CD will sync it (apply it), and then report Health: Degraded because the pod is crash-looping.

Watch for `OutOfSync + Healthy` — this means something changed in the cluster that isn't in Git yet (e.g., a KEDA-managed HPA was created — this is normal and expected).

---

## How Sync Waves Work (Reference)

You'll see `argocd.argoproj.io/sync-wave` annotations throughout the lab. Here's the full explanation:

Argo CD processes resources in sync waves. Within a single sync operation, it:
1. Applies all resources with the lowest wave number first
2. Waits for them to become healthy
3. Moves to the next wave

This is critical because some resources depend on others:
- Istio CRDs (wave -2) must exist before istiod (wave -1) can start
- istiod must be running before pods with sidecar injection can start
- Sealed Secrets controller (wave -3) must exist before SealedSecrets can be created

Without sync waves, Argo CD tries to apply everything simultaneously. The dependent resources fail (CRDs not found, controllers not ready), Argo CD marks them as degraded, and you spend 30 minutes debugging what was actually a timing issue.

Full wave order for this lab (for reference):
```
-3  sealed-secrets       (controller must exist before any SealedSecret)
-2  istio-base           (CRDs only — must precede istiod)
-1  istiod               (control plane)
-1  argo-rollouts        (CRD + controller — must precede Rollout objects)
 0  istio-gateway        (needs istiod running)
 0  prometheus           (independent)
 0  keda                 (independent)
 1  minio                (Buildbarn needs MinIO before it starts)
 2  rbe-system           (Buildbarn scheduler + storage)
 3  ApplicationSet       (generates tenant apps — needs Rollout CRD + rbe-system)
```

In Phase 1, only wave -3 (sealed-secrets) is deployed. Each subsequent phase adds apps at their appropriate wave.

---

## Troubleshooting

### Cluster create fails: "node not found" or timeout

```bash
# Check Docker has enough resources
docker system df
docker stats --no-stream

# If Docker is out of disk space:
docker system prune  # removes stopped containers, unused images
# WARNING: this affects ALL Docker containers, not just kind
```

### Argo CD pods not starting

```bash
kubectl describe pods -n argocd
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

Common cause: the infra node isn't Ready yet. Check:
```bash
kubectl get nodes
kubectl describe node remote-builder-infra
```

### app-of-apps shows "ComparisonError: repository not found"

Argo CD can't clone the GitHub repo. Check:
```bash
argocd repo list
```

If the repo isn't listed or shows an error:
```bash
# Re-register the repo
argocd repo add https://github.com/exitthematrix26/remote_builder
```

For a private repo, add credentials:
```bash
argocd repo add https://github.com/exitthematrix26/remote_builder \
  --username git \
  --password "${GITHUB_PAT}"
```

### sealed-secrets Application is OutOfSync but won't sync

```bash
argocd app sync sealed-secrets --force
argocd app get sealed-secrets --refresh
```

If it shows a CRD validation error: the Sealed Secrets Helm chart version may have changed. Check:
```bash
helm repo update sealed-secrets
helm search repo sealed-secrets/sealed-secrets
```

### kubeseal: "error: cannot fetch certificate"

The Sealed Secrets controller isn't running yet, or you're pointing at the wrong cluster:
```bash
kubectl config current-context  # must be kind-remote-builder
kubectl get pods -n cluster-infra  # sealed-secrets-controller must be Running
```

### Switching between your three kind clusters

```bash
# List all contexts
kubectl config get-contexts

# Switch to a different cluster
kubectl config use-context kind-bazel-sim
kubectl config use-context kind-bootik-local
kubectl config use-context kind-remote-builder

# Stop a cluster without deleting it (preserves all state)
docker stop $(docker ps -q --filter name=kind-remote-builder)

# Resume it
docker start $(docker ps -aq --filter name=kind-remote-builder)
kubectl config use-context kind-remote-builder
# Wait ~15 seconds for the API server to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=60s
```

---

## What We Built

```
remote-builder cluster
├── remote-builder-control-plane    Running ✓
├── remote-builder-infra            Running ✓
│   ├── argocd (5 pods)            Running ✓
│   └── cluster-infra
│       └── sealed-secrets-controller   Running ✓
└── remote-builder-worker           Running ✓ (empty — tainted, waiting for Phase 2+)

GitOps loop
└── GitHub push → Argo CD detects → syncs → cluster converges   Working ✓
```

---

## Next: Phase 2 — Buildbarn via Argo CD

In Phase 2 we add to `gitops/apps/` (via Git push — no more manual steps):
- MinIO object store (CAS backend)
- Buildbarn scheduler + storage
- A real Bazel workspace

Observable outcome: `bazel build //... --remote_executor=grpc://localhost:8981` succeeds.

See [phase-2-buildbarn.md](phase-2-buildbarn.md).
