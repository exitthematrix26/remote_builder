# remote_builder — RBE Platform Lab

A local Kubernetes lab simulating **EngFlow**, a commercial Remote Bazel Execution (RBE) SaaS platform, using open-source components. Built to teach production platform engineering by doing — locally first, then migrating to AWS EKS with minimal changes.

> **Status:** Phase 1 complete — cluster running, GitOps loop proven.

---

## What This Builds

```
Bazel Client
    │  gRPC (REAPI protocol)
    ▼
┌─────────────────────────────────────────────────────┐
│  Buildbarn Scheduler  (rbe-system namespace)        │  ← Phase 2
│  Routes build actions to available worker pools     │
└──────────────┬──────────────────────────────────────┘
               │
     ┌─────────┴──────────┐
     ▼                    ▼
┌─────────┐        ┌────────────┐
│ Workers │        │  Buildbarn │  ← Phase 2
│ tenant- │        │  Storage   │
│  acme   │        │  (CAS+AC)  │
│  KEDA ↕ │        │  MinIO/S3  │
└─────────┘        └────────────┘
     ↑
Argo Rollouts (canary)    ← Phase 3
KEDA → Prometheus RPM     ← Phase 4
ApplicationSet (tenants)  ← Phase 6
```

**The full stack:**

| Layer | Tool | Purpose |
|---|---|---|
| Cluster | kind (local) → EKS (prod) | Kubernetes infrastructure |
| GitOps | Argo CD | Everything deployed from Git |
| Canary deploys | Argo Rollouts + Istio | 10%→50%→100% traffic splits |
| Autoscaling | KEDA | Scale workers to zero on idle |
| Scale signal | Prometheus gRPC RPM | Workers scale on build traffic, not CPU |
| RBE backend | Buildbarn | Open-source EngFlow equivalent |
| Object store | MinIO (local) → S3 (prod) | Content-addressable storage for builds |
| Secrets | Sealed Secrets | Encrypted secrets safe to commit to Git |
| Multi-tenancy | Argo CD ApplicationSets | One `values.yaml` = one tenant |

---

## Architecture

### Cluster Topology

```
Docker host (your machine)
│
├── remote-builder-control-plane
│   └── etcd, kube-apiserver, kube-scheduler, kube-controller-manager
│       (no workloads — tainted automatically by Kubernetes)
│
├── remote-builder-infra          [label: pool=infra]
│   ├── ns: argocd
│   │   ├── argocd-server              ← UI + API (port-forward → localhost:8080)
│   │   ├── argocd-repo-server         ← clones GitHub, renders Helm templates
│   │   ├── argocd-application-controller ← reconciles Git → cluster
│   │   └── argocd-rollouts-controller ← manages canary steps (Phase 3)
│   ├── ns: cluster-infra
│   │   ├── sealed-secrets-controller  ← decrypts SealedSecrets → K8s Secrets
│   │   ├── keda-operator              ← watches ScaledObjects (Phase 4)
│   │   └── prometheus-stack           ← scrapes metrics (Phase 4)
│   ├── ns: istio-system               ← Istio control plane (Phase 3)
│   ├── ns: minio                      ← CAS object store (Phase 2)
│   └── ns: rbe-system                 ← Buildbarn scheduler (Phase 2)
│
└── remote-builder-worker         [label: pool=rbe-workers]
                                  [taint: dedicated=rbe-worker:NoSchedule]
    ├── ns: tenant-acme            ← RBE workers + Redis + KEDA target
    └── ns: tenant-initech         ← Phase 6
```

**Why three nodes?**
- **Isolation:** Build workers run arbitrary user code — they must be separated from cluster operators
- **Taint enforcement:** The `dedicated=rbe-worker:NoSchedule` taint means no pod lands on the worker node unless it explicitly tolerates it
- **Production parity:** In EKS this maps to 3 separate managed node groups with independent scaling

### GitOps Flow

```
You push a file to GitHub
         │
         ▼  (polls every 3 min, or instant via webhook)
Argo CD repo-server clones the repo
         │
         ▼
Renders Helm templates + values.yaml into Kubernetes manifests
         │
         ▼
Compares rendered manifests to live cluster state
         │
    ┌────┴────┐
    │ diff?   │
    └────┬────┘
    YES  │  NO → nothing to do
         ▼
Applies the diff (kubectl server-side apply)
         │
         ▼
Cluster state matches Git state ✓
```

**The rule:** If it's not in Git, it doesn't exist. The only exception is the initial Argo CD bootstrap.

### Namespace Strategy

```
kube-system       K8s internals — never touched
istio-system      Istio control plane — Phase 3
argocd            Argo CD + Argo Rollouts — installed by bootstrap.sh
cluster-infra     Cluster-wide operators: KEDA, Prometheus, Sealed Secrets
minio             Shared CAS object store — Phase 2
rbe-system        Buildbarn scheduler (shared RBE frontend) — Phase 2
tenant-acme       First tenant: workers + Redis + quota — Phase 2
tenant-initech    Second tenant (Phase 6) — created automatically by ApplicationSet
```

---

## Repository Layout

```
remote_builder/
├── cluster/                    Local scripts — NOT watched by Argo CD
│   ├── kind-config.yaml        3-node cluster definition (labels, cgroup patch)
│   ├── bootstrap.sh            One-shot bootstrap: kind → Argo CD → app-of-apps
│   ├── install-tools.sh        Installs kubectl, kind, helm, argocd, kubeseal, k9s
│   ├── open-dashboards.sh      Port-forwards all UIs to localhost
│   └── config.env.example      Copy to config.env, fill in GITHUB_PAT
│
├── gitops/                     ← Argo CD watches this directory on GitHub
│   ├── bootstrap/
│   │   └── app-of-apps.yaml    Root Application — the ONE manual kubectl apply
│   ├── apps/                   One Application per subdirectory
│   │   └── sealed-secrets/     Wave -3: deployed first by Argo CD
│   ├── tenants/                One directory per tenant (Phase 6)
│   │   └── tenant-acme/
│   │       └── values.yaml
│   └── applicationsets/
│       └── tenants.yaml        Git directory generator → one app per tenant dir
│
├── charts/
│   ├── buildbarn/              Custom Helm chart wrapping Buildbarn images (Phase 2)
│   └── rbe-tenant/             Shared chart for all tenants: Rollout, KEDA, Redis, quota
│
├── rbe-stub/                   Lightweight REAPI stub for Phase 1 testing
├── load-gen/                   gRPC load generator for Phase 5
└── docs/
    ├── concept.txt             Original design brief
    ├── fullplan.md             Complete architecture + phase plan
    ├── troubleshooting.md      Documented issues + fixes from Phase 1
    └── phases/
        └── phase-1-cluster.md  Phase 1 annotated walkthrough
```

---

## Current State — Phase 1 Complete

### What's running

```bash
kubectl get nodes
# NAME                           STATUS   ROLES           AGE
# remote-builder-control-plane   Ready    control-plane   ...
# remote-builder-infra           Ready    <none>          ...  pool=infra
# remote-builder-worker          Ready    <none>          ...  pool=rbe-workers

kubectl get pods -n argocd
# argocd-application-controller   Running
# argocd-repo-server              Running
# argocd-server                   Running
# argocd-redis                    Running
# argocd-dex-server               Running

kubectl get pods -n cluster-infra
# sealed-secrets-controller       Running

argocd app list
# NAME            STATUS  HEALTH   SYNCPOLICY
# app-of-apps     Synced  Healthy  Auto-Prune
# sealed-secrets  Synced  Healthy  Auto-Prune
```

### What the GitOps loop looks like

```
GitHub: gitops/apps/
  └── sealed-secrets/application.yaml
          │
          │  Argo CD syncs this
          ▼
cluster-infra namespace:
  └── sealed-secrets-controller pod    ← Running, watching for SealedSecrets
```

When you push a new Application manifest to `gitops/apps/`, Argo CD picks it up and deploys it — no manual steps.

---

## Getting Started

### Prerequisites
- Docker running
- Git + GitHub account
- `cluster/config.env` filled in (copy from `config.env.example`)

### Initial Setup

```bash
# 1. Install tools (idempotent — safe to re-run)
./cluster/install-tools.sh

# 2. Required for running 3 kind clusters simultaneously
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
# Make persistent:
echo "fs.inotify.max_user_watches = 524288" | sudo tee -a /etc/sysctl.d/99-kind.conf
echo "fs.inotify.max_user_instances = 512"  | sudo tee -a /etc/sysctl.d/99-kind.conf

# 3. Configure
cp cluster/config.env.example cluster/config.env
# Edit: set GITHUB_PAT (needs read:packages scope)

# 4. Push code to GitHub FIRST (Argo CD clones on bootstrap)
git add . && git commit -m "Phase 1" && git push -u origin main

# 5. Bootstrap
./cluster/bootstrap.sh
```

### Daily Use

```bash
# Switch to this cluster
kubectl config use-context kind-remote-builder

# Open all dashboards (port-forwards to localhost)
./cluster/open-dashboards.sh
# → Argo CD:  http://localhost:8080
# → (Phase 2+: MinIO :9001, Buildbarn :7984, Prometheus :9090)

# Check sync status
argocd app list

# Force immediate sync (don't wait 3 minutes)
argocd app sync app-of-apps

# Watch all pods
kubectl get pods -A -w

# Use k9s for a live terminal UI
k9s
```

### Managing Multiple Clusters

You have three kind clusters. They coexist safely — only switch context when needed:

```bash
# List all clusters and active context
kubectl config get-contexts

# Switch contexts
kubectl config use-context kind-remote-builder   # this lab
kubectl config use-context kind-bazel-sim        # prior lab
kubectl config use-context kind-bootik-local     # bootik

# Pause a cluster to free ~350MB RAM (state fully preserved)
docker stop $(docker ps -q --filter name=bazel-sim)

# Resume it
docker start $(docker ps -aq --filter name=bazel-sim)
kubectl config use-context kind-bazel-sim
```

**Never run kubectl apply against a cluster you didn't intend to target.** Always check `kubectl config current-context` first.

---

## Key Concepts Explained

### App-of-Apps Pattern

```
app-of-apps  (gitops/bootstrap/app-of-apps.yaml)
│  points at gitops/apps/ directory
│
├── Application: sealed-secrets   (gitops/apps/sealed-secrets/application.yaml)
├── Application: istio-base       (gitops/apps/istio-base/)        ← Phase 3
├── Application: prometheus       (gitops/apps/prometheus/)        ← Phase 4
├── Application: keda             (gitops/apps/keda/)              ← Phase 4
├── Application: minio            (gitops/apps/minio/)             ← Phase 2
├── Application: rbe-system       (gitops/apps/rbe-system/)        ← Phase 2
└── ApplicationSet: rbe-tenants   (gitops/applicationsets/)        ← Phase 6
```

**How to add a new component:** Create a file in `gitops/apps/<name>/application.yaml` and push to GitHub. Argo CD detects it and deploys automatically. No manual steps.

### Sync Waves — Why Order Matters

Argo CD deploys resources in wave order. Lower number = deployed first:

```
Wave -3  sealed-secrets     Must exist before any SealedSecret can be decrypted
Wave -2  istio-base         CRDs only — istiod will fail without them
Wave -1  istiod             Control plane — pods need this for sidecar injection
Wave -1  argo-rollouts      Rollout CRD must exist before tenant Rollout objects
Wave  0  prometheus, keda   Independent — can start any time
Wave  1  minio              Buildbarn needs MinIO ready before connecting
Wave  2  rbe-system         Buildbarn scheduler — needs MinIO at wave 1
Wave  3  ApplicationSet     Generates tenant apps — needs everything above
```

Wave annotation in any manifest:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
```

### Sealed Secrets — How Secrets Get Into Git Safely

```
Your machine                    Cluster
─────────────────               ─────────────────────────────
kubectl create secret ...       sealed-secrets-controller
  --dry-run=client -o yaml        holds private RSA key
    │                               │
    │  pipe to kubeseal             │  only one that can decrypt
    ▼                               │
kubeseal --cert pub-cert.pem        │
    │                               │
    ▼                               │
SealedSecret YAML  ────git push──▶  Argo CD applies it
(safe to commit)                    │
                                    ▼
                               K8s Secret (plaintext, in-cluster only)
                                    │
                                    ▼
                               Your pod reads it normally
```

The private key never leaves the cluster. If someone gets your Git repo, they get encrypted blobs — useless.

### KEDA Autoscaling (Phase 4 Preview)

```
Prometheus scrapes gRPC metrics from Buildbarn workers
         │
         ▼
KEDA ScaledObject watches: sum(rate(grpc_server_handled_total[2m])) * 60
         │
    ┌────┴─────────────────┐
    │  RPM < threshold?    │
    └────┬─────────────────┘
         │ YES                        NO
         ▼                            ▼
  Scale workers DOWN          Scale workers UP
  (min: 0 — scale to zero)    (1 pod per 5 RPM)
```

This is why CPU-based HPA doesn't work for RBE workers: idle workers have near-zero CPU but Prometheus knows they're receiving zero build requests.

---

## Phase Roadmap

| Phase | Goal | Status |
|---|---|---|
| **1 — Cluster Bootstrap** | kind + Argo CD + GitOps loop | **Complete ✓** |
| 2 — Buildbarn | Full RBE stack, real Bazel build | Next |
| 3 — Istio + Rollouts | Canary deployments 10→50→100% | Pending |
| 4 — KEDA | Workers scale to zero on idle | Pending |
| 5 — Load Generator | Full stress test, Grafana dashboards | Pending |
| 6 — Multi-Tenant | Add tenant by creating one file | Pending |

---

## AWS Migration Path

Every local configuration maps directly to an EKS equivalent:

| Lab | Production (EKS) |
|---|---|
| `kind create cluster` | `terraform apply` (modules/eks-cluster) |
| `pool=infra` node label | EKS managed node group label (Terraform) |
| MinIO `http://minio.minio:9000` | S3 `https://s3.us-east-1.amazonaws.com` |
| Plain ServiceAccount | IRSA: `eks.amazonaws.com/role-arn: arn:aws:...` |
| ghcr.io pull secret | ECR via IRSA (no secret needed) |
| `grpc://localhost:8981` | `grpc://rbe.internal.yourco.com:443` |
| kubectl port-forward | Route53 + ACM + NLB |

The Helm charts and GitOps manifests require **zero structural changes** for EKS — only values change.

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for documented issues including:
- Bootstrap script silent exit (`set -e` + grep)
- Worker node join failures (kubeadm v1beta3 breakage)
- inotify limits exhausted by multiple clusters
- cgroup v2 / systemd driver mismatch on Linux kernel 6.x
- Argo CD `ComparisonError` (repo not pushed / no credentials)
