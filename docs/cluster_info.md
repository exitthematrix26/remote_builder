# Cluster Info — What's Running and Why

Current state: **Phase 2 complete.** Buildbarn RBE stack is live.

---

## Force Argo CD to sync immediately (don't wait 3 minutes)

```bash
# Start port-forward if not already running (runs in background)
kubectl port-forward svc/argocd-server -n argocd 8080:80 &

# Force sync a specific app
argocd app sync rbe-system --force

# Force sync all apps
argocd app sync --all --force

# Watch sync status
argocd app list
```

Use `--force` after every `git push` to get instant deployment instead of waiting
for Argo CD's default 3-minute polling interval.

---

## Cluster topology

```
┌─────────────────────────────────────────────────────────────────────┐
│  kind cluster: remote-builder                                        │
│                                                                      │
│  ┌──────────────────────────┐                                        │
│  │  remote-builder-control-plane                                     │
│  │  role: control-plane                                              │
│  │  runs: kube-apiserver, etcd, kube-scheduler,                      │
│  │        kube-controller-manager, coredns                           │
│  └──────────────────────────┘                                        │
│                                                                      │
│  ┌──────────────────────────┐  ┌──────────────────────────┐         │
│  │  remote-builder-worker   │  │  remote-builder-worker2  │         │
│  │  label: pool=infra       │  │  label: pool=rbe-workers │         │
│  │  taint: (none)           │  │  taint: dedicated=        │         │
│  │                          │  │         rbe-worker:       │         │
│  │  runs:                   │  │         NoSchedule        │         │
│  │  - argocd (all pods)     │  │                          │         │
│  │  - sealed-secrets        │  │  runs:                   │         │
│  │  - minio (phase 2)       │  │  - bb-worker (phase 2)   │         │
│  │  - bb-storage (phase 2)  │  │    (must tolerate taint) │         │
│  │  - bb-scheduler (phase 2)│  │                          │         │
│  └──────────────────────────┘  └──────────────────────────┘         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Namespace: `kube-system`

Core Kubernetes control plane. Installed automatically by kind. You never touch these directly.

```
kube-system
├── kube-apiserver          ← the Kubernetes API — every kubectl command hits this
├── etcd                    ← the database; stores all cluster state (pods, secrets, etc.)
├── kube-controller-manager ← reconciliation loops (deployments, replicasets, endpoints)
├── kube-scheduler          ← decides which node a new pod lands on
├── coredns (x2)            ← in-cluster DNS; how pods resolve "bb-storage.rbe-system.svc.cluster.local"
├── kindnet (x3)            ← CNI plugin (one per node); sets up pod networking + routes
└── kube-proxy (x3)         ← programs iptables rules (one per node); makes Services work
```

### How they relate

```
You (kubectl / Argo CD)
        │
        ▼
  kube-apiserver  ──────────── etcd  (persists all state)
        │
        ├──▶ kube-controller-manager  (watches for desired vs actual state; creates pods)
        │
        └──▶ kube-scheduler  (assigns pods to nodes based on resources + nodeSelector + taints)

Pod networking (between pods across nodes):
  kindnet (node 1) ◄──────────► kindnet (node 2) ◄──────────► kindnet (node 3)

Service routing (ClusterIP → pod IP):
  kube-proxy (node 1/2/3)  — programs iptables so svc:port → pod:port works
```

---

## Namespace: `argocd`

GitOps engine. Watches the GitHub repo and reconciles the cluster to match what's in Git.

```
argocd
├── argocd-server                   ← UI + API; what you hit on localhost:8080
├── argocd-application-controller   ← the core reconciler; compares Git state vs cluster state
├── argocd-repo-server              ← clones the Git repo, renders Helm/Kustomize templates
├── argocd-applicationset-controller← manages ApplicationSet resources (phase 6: multi-tenancy)
├── argocd-dex-server               ← SSO/OIDC provider; handles login federation
├── argocd-notifications-controller ← sends Slack/email/webhook on sync events
└── argocd-redis                    ← in-memory cache for rendered manifests and app state
```

### GitOps reconciliation loop

```
GitHub repo (remote_builder)
        │
        │  argocd-repo-server polls / webhook
        ▼
  argocd-repo-server  ──── renders Helm chart → raw YAML manifests
        │
        ▼
  argocd-application-controller
        │  compares rendered YAML vs live cluster resources
        │  if diff detected → applies changes (kubectl apply server-side)
        ▼
  kube-apiserver  ──── updates cluster state
        │
        ▼
  cluster reaches desired state  ──── app shows Synced + Healthy
```

**App-of-apps pattern** — one root `Application` watches `gitops/apps/`. Every subdirectory
is a child `Application`. Adding a folder to Git = deploying a new app with no manual steps.

---

## Namespace: `cluster-infra`

Infrastructure utilities that the rest of the cluster depends on.

```
cluster-infra
└── sealed-secrets-controller  ← decrypts SealedSecret resources into real Secrets
```

### Why Sealed Secrets?

Kubernetes `Secret` objects are only base64-encoded — not encrypted. Committing them to Git
exposes credentials to anyone with repo access.

```
Developer machine                    cluster-infra namespace
      │                                       │
      │  kubeseal --cert <pub.crt>            │
      │  encrypts Secret → SealedSecret       │
      │                                       │
      │  git push SealedSecret.yaml ──────────┤
      │                                       │
      │                              sealed-secrets-controller
      │                              decrypts with private key
      │                              creates real Secret in namespace
      │                                       │
      │                              Pod mounts Secret as env/volume
```

Only the in-cluster controller holds the private key. The encrypted `SealedSecret` is safe to
store in a public or private Git repo.

---

## Namespace: `local-path-storage`

```
local-path-storage
└── local-path-provisioner  ← dynamic PersistentVolume provisioner for kind
```

When a pod requests a `PersistentVolumeClaim` (e.g. MinIO needs 5Gi of disk), this provisioner
automatically creates a `PersistentVolume` backed by a directory on the node's local disk.
In production this is replaced by EBS (AWS) or a proper storage class.

---

## Phase 2 namespaces (not yet live — pending push)

```
minio
└── minio  ← S3-compatible object store; stores Buildbarn CAS + AC blobs

rbe-system
├── bb-storage    ← CAS (inputs/outputs) + AC (action cache); backed by MinIO
├── bb-scheduler  ← RBE frontend; receives Bazel Execute RPCs, routes to workers
└── bb-worker     ← pulls actions from scheduler, runs builds via bb-runner sidecar
```

---

## Full namespace map (all phases)

```
Namespace         Phase  Purpose
──────────────    ─────  ───────────────────────────────────────────────────
kube-system         0    Kubernetes control plane (auto-installed by kind)
local-path-storage  0    Dynamic PV provisioner for kind
argocd              1    GitOps engine (app-of-apps)
cluster-infra       1    Sealed Secrets controller
minio               2    Object storage backend for Buildbarn
rbe-system          2    Buildbarn RBE: storage + scheduler + workers
monitoring          4    Prometheus + Grafana (metrics + dashboards)
(tenants)           6    Per-tenant namespaces via ApplicationSet
```
