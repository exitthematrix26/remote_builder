# RBE Platform Lab — Full Architecture, Design & Phase Plan

> **Living document.** This is the single source of truth for the lab design. Every architectural decision recorded here with the rationale so future-you (or a teammate) understands *why*, not just *what*.

---

## 1. What We Are Building

A local Kubernetes lab that simulates **EngFlow** — a commercial Remote Bazel Execution (RBE) SaaS platform — using **Buildbarn**, the open-source implementation of the same REAPI protocol. When you point a real Bazel client at Buildbarn vs EngFlow, only the endpoint URL changes. This lab teaches the exact production concepts.

The lab is built in phases: each phase adds one production layer on top of the last. By the end you will have operated:

- A multi-node Kubernetes cluster managed entirely by GitOps (Argo CD)
- A full RBE stack (remote execution + content-addressable storage + action cache)
- Canary deployments with automatic rollback via Istio + Argo Rollouts
- Event-driven autoscaling to zero via KEDA + Prometheus custom metrics
- Multi-tenant isolation enforced by Kubernetes ResourceQuotas + Argo ApplicationSets
- A complete AWS EKS migration path requiring only variable swaps

**Target learner:** Senior developer with strong coding background. Has already built a prior lab with K8s remote cache, HPA on custom Prometheus gRPC metrics, and a simulated load tester. No prior Argo CD, Istio, or GitOps experience required.

---

## 2. Repository

| Field | Value |
|---|---|
| GitHub org/user | `exitthematrix26` |
| Repo name | `remote_builder` |
| Full URL | `https://github.com/exitthematrix26/remote_builder` |
| Argo CD watches | `gitops/` directory on `main` branch |
| Container registry | `ghcr.io/exitthematrix26/remote_builder/` |

---

## 3. Developer Machine Specs

| Resource | Spec |
|---|---|
| CPU | Intel Core i7-12800H — 14 cores / 20 threads @ up to 4.8GHz |
| RAM | 14.8 GB total, 4 GB swap |
| Storage | 953.9 GB NVMe |
| GPU | NVIDIA RTX 3070 (8GB VRAM) — not used in this lab |
| OS | Linux (x86_64) |
| Virtualization | VT-x enabled — kind (Kubernetes in Docker) works natively |

**Memory budget for the cluster (target after freeing other processes):**

| Component | Estimated RAM |
|---|---|
| kind control-plane node | ~400 MB |
| infra-node (Argo CD + Istio + Prometheus + KEDA + Sealed Secrets) | ~2.5 GB |
| services on infra-node (MinIO + Buildbarn scheduler) | ~800 MB |
| worker-node (KEDA target, tenant pods, Redis) | ~1.2 GB |
| Docker overhead + OS | ~1.5 GB |
| **Total cluster target** | **~6.4 GB** |

With 14.8 GB total (after freeing other processes: browser tabs, prior lab cluster, etc.) this is comfortable. **Kill your prior cluster before starting:**
```bash
kind delete cluster --name <your-old-cluster-name>
```

---

## 4. Technology Stack — All Decisions & Rationale

### 4.1 Local Cluster

| Decision | Choice | Rationale |
|---|---|---|
| Cluster tool | **kind** (Kubernetes in Docker) | Linux dev box, zero VM overhead, Docker-native, trivially reproducible |
| Node count | **3 nodes** | control-plane + infra-node + worker-node. Sufficient for isolation without over-provisioning |
| Node topology | Labeled + tainted | infra-node gets `pool=infra`; worker-node gets `pool=rbe-workers` + taint `dedicated=rbe-worker:NoSchedule` |
| Port mapping | kind extraPortMappings | Exposes :8981 (gRPC/Bazel), :8080 (Argo CD), :9090 (Prometheus) to localhost |

> **EKS equivalent:** 3 managed node groups — `system` (t3.large ×2), `services` (m5.large ×2), `rbe-workers` (c5.xlarge Spot, 0–20 auto-scaling).

### 4.2 RBE Backend

| Decision | Choice | Rationale |
|---|---|---|
| RBE implementation | **Buildbarn** | Open-source, implements identical REAPI protocol to EngFlow. Swapping to EngFlow = change endpoint URL only |
| Helm chart | **Custom `charts/buildbarn/`** | No official Buildbarn Helm chart exists. `bb-deployments` uses Jsonnet — adds a foreign DSL. We write a clean Helm chart wrapping official `ghcr.io/buildbarn/` images. This is what every real platform team does. |
| Phase 1 stub | **rbe-stub** (Go gRPC shim) | Proves GitOps + Prometheus + KEDA loop without standing up full Buildbarn. Swapped out at Phase 2. |
| Container images | Official `ghcr.io/buildbarn/bb-scheduler`, `bb-storage`, `bb-worker` | Same images used in bb-deployments reference configs |

### 4.3 Content Addressable Storage (CAS)

| Decision | Choice | Rationale |
|---|---|---|
| Local CAS | **MinIO** | S3-compatible object store. Drop-in replacement — Buildbarn uses the S3 backend API |
| Production CAS | **AWS S3** | Change endpoint URL + credentials in values.yaml. Zero chart changes. |
| Buildbarn CAS backend | S3 (not filesystem) | Ensures workers are truly stateless. Any pod can die mid-action without data loss. |

### 4.4 Action Cache

| Decision | Choice | Rationale |
|---|---|---|
| Action cache | **Redis per tenant** | Per-tenant isolation. Cache hits stay within tenant boundary. |
| Production | **AWS ElastiCache Redis** | Same Redis protocol. Change endpoint in values.yaml. |

### 4.5 GitOps

| Decision | Choice | Rationale |
|---|---|---|
| GitOps engine | **Argo CD** | Industry standard. Watches GitHub repo, reconciles cluster state continuously. |
| Install method | **Helm** (in bootstrap.sh) | Bootstrap chicken-and-egg: Argo CD must exist before it can manage itself |
| Canary controller | **Argo Rollouts** | Native Argo ecosystem. Integrates with Istio VirtualService weights. Required for Rollout CRD. |
| Multi-tenancy | **Argo CD ApplicationSets** | Git directory generator: one `values.yaml` directory = one tenant Application. Zero manual Argo config per tenant. |
| Source of truth | **GitHub** | If it's not in Git, it does not exist. `kubectl apply` is forbidden for anything Argo CD manages. |
| Sync waves | Yes — wave order enforced | CRDs must precede controllers which must precede workloads. See Section 7. |

### 4.6 Service Mesh & Canary

| Decision | Choice | Rationale |
|---|---|---|
| Service mesh | **Istio** | Industry standard. Required for weighted traffic splits between stable and canary pods. |
| Install method | **Helm charts in GitOps tree** | No `istioctl install` at runtime. Argo CD manages Istio the same way as any other workload. More complex to bootstrap but production-equivalent. |
| Chart order | istio/base (CRDs) → istiod → istio-ingressgateway | Sync waves enforce this. CRDs must be present before istiod starts. |
| Canary strategy | **Argo Rollout + Istio VirtualService weights** | Steps: 10% → 50% → 100% with pause gates. Rollback by reverting image tag in Git. |
| Worker resource | **Argo Rollout** (not Deployment) | Required for Istio subset routing. KEDA must target Rollout, not Deployment. |

### 4.7 Autoscaling

| Decision | Choice | Rationale |
|---|---|---|
| Autoscaler | **KEDA** (Kubernetes Event-Driven Autoscaling) | Scales to zero. CPU HPA cannot do this, and idle RBE workers have near-zero CPU anyway. |
| Scale signal | **Prometheus metric: gRPC RPM** | `sum(rate(grpc_server_handled_total{...}[2m])) * 60` on the REAPI Execution service |
| Threshold | 5 RPM per worker pod | One new worker pod per 5 gRPC requests/minute |
| Min replicas | **0** | Workers scale to zero when idle. This is the primary cost-saving mechanism in production. |
| Max replicas | Per-tenant values.yaml | Enforces tenant resource ceiling alongside ResourceQuota |
| KEDA target | `argoproj.io/v1alpha1/Rollout` | KEDA must point at the Rollout, not a Deployment. Critical: wrong target reference = KEDA scales nothing. |
| Cooldown | 60 seconds | Workers stay alive 60s after load drops before scaling down — prevents thrash on bursty workloads |

### 4.8 Secrets Management

| Decision | Choice | Rationale |
|---|---|---|
| Secrets tool | **Sealed Secrets** | Encrypts K8s Secrets client-side. Encrypted SealedSecret is safe to commit to Git. Only the in-cluster Sealed Secrets controller can decrypt. |
| Keypair | **Fresh generation** | New keypair created by Sealed Secrets controller on first install. Backup the private key after bootstrap. |
| What gets sealed | ghcr.io image pull token, MinIO credentials, Redis passwords | Any Secret that would otherwise be plaintext in Git |
| kubeseal CLI | Required locally | `kubeseal --fetch-cert` gets the public cert; `kubeseal` encrypts locally. Secret never leaves your machine unencrypted. |

### 4.9 Container Registry

| Decision | Choice | Rationale |
|---|---|---|
| Registry | **ghcr.io** (GitHub Container Registry) | Real-world GitOps loop. CI builds and pushes on merge. No local registry hack. |
| Auth | GitHub PAT (`read:packages` scope) → Sealed Secret imagePullSecret | PAT sealed before Sealed Secrets is fully bootstrapped; re-sealed properly at Phase 3 |
| Image naming | `ghcr.io/exitthematrix26/remote_builder/<image>:<tag>` | `<tag>` = git SHA (`sha-abc1234`) for traceability + `latest` for convenience |
| Package visibility | **Public** | Set in GitHub Settings → Packages after first push. Avoids pull secret complexity during early phases. |
| CI | **GitHub Actions** (`build-images.yml`) | Triggers on push to main when `load-gen/` or `rbe-stub/` changes. Multi-stage Docker build → push to ghcr.io |

### 4.10 Monitoring

| Decision | Choice | Rationale |
|---|---|---|
| Metrics | **kube-prometheus-stack** | Prometheus + Alertmanager + Grafana in one Helm chart |
| Phase 1 config | Slim: Grafana disabled, 1d retention, minimal scrape configs | Memory-conscious. Grafana added at Phase 4 when we need dashboards. |
| Key metric | `grpc_server_handled_total` on REAPI Execution service | Both rbe-stub and real Buildbarn expose this. KEDA reads it. |
| Scrape config | ServiceMonitor CRD (managed by kube-prometheus-stack) | Declarative scrape config, lives in Git, no Prometheus restarts needed |

---

## 5. Cluster Node Topology

```
kind cluster: remote-builder
│
├── remote-builder-control-plane
│   └── Standard K8s control plane components only (etcd, api-server, scheduler, controller-manager)
│
├── remote-builder-infra          (nodeSelector: pool=infra)
│   Hosts all cluster-wide operators and shared services:
│   ├── ns: kube-system           CoreDNS, kube-proxy
│   ├── ns: istio-system          istiod + ingress gateway
│   ├── ns: argocd                Argo CD server/repo-server/app-controller + Argo Rollouts
│   ├── ns: cluster-infra         KEDA operator, Prometheus stack, Sealed Secrets controller
│   ├── ns: minio                 MinIO object store (shared CAS for all tenants)
│   └── ns: rbe-system            Buildbarn scheduler (shared RBE frontend)
│
└── remote-builder-worker         (nodeSelector: pool=rbe-workers)
                                  (taint: dedicated=rbe-worker:NoSchedule)
    Hosts only tenant workloads — toleration required:
    ├── ns: tenant-acme           Worker Rollout, Redis, KEDA ScaledObject, ResourceQuota
    └── ns: tenant-initech        (Phase 6 — added by ApplicationSet)
```

> **Why separate the worker node?** In production, RBE workers run customer build actions inside sandboxed pods. Security, noisy-neighbour isolation, and independent scaling all require dedicated node pools. The taint ensures no non-worker pod can land on these nodes without an explicit toleration. The lab mirrors this exactly.

---

## 6. Namespace Topology

```
cluster/
├── kube-system
│   └── K8s internals — never modified directly
│
├── istio-system
│   ├── istiod (Istio control plane — manages sidecar injection + cert rotation)
│   └── istio-ingressgateway (edge proxy — terminates external gRPC + HTTP)
│   NOTE: Istio injects an Envoy sidecar proxy into every pod in labeled namespaces.
│         Sidecars add ~50MB RAM per pod but enable traffic splitting without app changes.
│
├── argocd
│   ├── argocd-server (UI + API — what you log into at :8080)
│   ├── argocd-repo-server (clones GitHub repo, renders Helm templates)
│   ├── argocd-application-controller (watches cluster state, reconciles toward Git)
│   └── argocd-rollouts-controller (watches Rollout objects, manages canary steps)
│
├── cluster-infra
│   ├── keda-operator (watches ScaledObjects, creates/destroys HPA under the hood)
│   ├── prometheus-server + alertmanager (scrapes all ServiceMonitors in cluster)
│   ├── grafana (Phase 4 — disabled initially to save RAM)
│   └── sealed-secrets-controller (decrypts SealedSecrets → creates K8s Secrets)
│
├── minio
│   └── minio pod (S3-compatible — Buildbarn CAS backend)
│       Bucket: rbe-cas  (Content Addressable Storage blobs)
│       Bucket: rbe-ac   (Action Cache results, if using S3 AC backend)
│
├── rbe-system
│   ├── bb-scheduler (accepts gRPC from Bazel clients, queues build actions)
│   └── bb-storage   (implements CAS + AC gRPC API, backed by MinIO)
│   NOTE: Shared across all tenants. Scheduler routes work to tenant worker pools.
│         In EngFlow production: this is the multi-tenant frontend service.
│
├── tenant-acme  ← First tenant (your own internal builds)
│   ├── Rollout: rbe-workers       (Argo Rollout — NOT Deployment)
│   │   ├── stable ReplicaSet      (current production version)
│   │   └── canary ReplicaSet      (new version during rollout — gets % of traffic)
│   ├── ScaledObject               (KEDA — watches Prometheus, scales the Rollout)
│   ├── ResourceQuota              (hard ceiling: CPU, memory, pods — cannot be exceeded)
│   ├── Redis                      (action cache — per-tenant, isolated)
│   ├── ServiceAccount             (plain in lab; IRSA role ARN annotation in prod)
│   ├── VirtualService             (Istio — weights traffic between stable + canary subsets)
│   ├── DestinationRule            (Istio — defines stable/canary subsets by pod label)
│   ├── PodDisruptionBudget        (minAvailable: 1 — protects active builds during drain)
│   └── Service                    (headless — Istio needs this for subset routing)
│
└── tenant-initech  ← Second tenant (Phase 6 — proves isolation)
    └── (identical structure to tenant-acme, different ResourceQuota values)
```

---

## 7. GitOps Architecture

### How the GitOps Loop Works

```
Developer pushes to GitHub main branch
         │
         ▼
Argo CD repo-server polls GitHub every 3 minutes (or webhook — instant)
         │
         ▼
Detects diff between Git state and cluster state
         │
         ▼
Renders Helm templates with values.yaml overrides
         │
         ▼
Applies diff to cluster via kubectl (server-side apply)
         │
         ▼
Cluster state converges to Git state
```

This means: **to deploy anything, you push to Git.** No `kubectl apply`. No `helm upgrade`. Git is the only control plane.

### Sync Wave Order (enforced by `argocd.argoproj.io/sync-wave` annotation)

Argo CD applies resources in wave order. Lower number = earlier. This solves the CRD-before-controller bootstrap problem.

```
Wave -3 │ sealed-secrets        Controller must exist before any SealedSecret is applied
Wave -2 │ istio-base            Installs Istio CRDs. istiod will fail to start without them.
Wave -1 │ istiod                Istio control plane. Must exist before gateway + injection.
Wave -1 │ argo-rollouts         Rollout CRD + controller. Tenants use Rollout objects.
Wave  0 │ istio-gateway         Needs istiod running. Independent of Prometheus/KEDA.
Wave  0 │ prometheus            Independent. Starts scraping immediately.
Wave  0 │ keda                  Independent. Starts watching ScaledObjects immediately.
Wave  1 │ minio                 Buildbarn needs MinIO ready before it tries to connect.
Wave  2 │ rbe-system            Buildbarn scheduler + storage. Needs MinIO at wave 1.
Wave  3 │ ApplicationSet        Generates tenant Applications. Needs Rollout CRD (wave -1)
        │                       and rbe-system (wave 2) to be healthy first.
```

> **What happens if you get the order wrong?** Argo CD will show the app in a degraded/error state. The self-heal loop will keep retrying. Once the dependency appears, the dependent resource eventually converges. But during initial bootstrap this causes confusing error messages — the wave order prevents them.

### App-of-Apps Pattern

```
app-of-apps.yaml (applied manually ONCE in bootstrap.sh)
│
├── Application: sealed-secrets    → gitops/apps/sealed-secrets/
├── Application: istio-base        → gitops/apps/istio-base/
├── Application: istiod            → gitops/apps/istiod/
├── Application: argo-rollouts     → gitops/apps/argo-rollouts/
├── Application: istio-gateway     → gitops/apps/istio-gateway/
├── Application: prometheus        → gitops/apps/prometheus/
├── Application: keda              → gitops/apps/keda/
├── Application: minio             → gitops/apps/minio/
├── Application: rbe-system        → gitops/apps/rbe-system/
└── Application: rbe-tenants-appset → gitops/applicationsets/tenants.yaml
                                       │
                                       └── (generates per-tenant Applications)
                                           ├── Application: tenant-acme  → charts/rbe-tenant + gitops/tenants/tenant-acme/values.yaml
                                           └── Application: tenant-initech (Phase 6)
```

---

## 8. Repository File Structure (Annotated)

Every file and its purpose:

```
remote_builder/
│
├── .github/
│   └── workflows/
│       └── build-images.yml
│           # GitHub Actions CI pipeline.
│           # Triggers: push to main when load-gen/** or rbe-stub/** changes.
│           # Steps: docker buildx build (multi-arch) → push to ghcr.io
│           # Tags: ghcr.io/exitthematrix26/remote_builder/<name>:latest
│           #       ghcr.io/exitthematrix26/remote_builder/<name>:sha-${{ github.sha }}
│           # The SHA tag is what values.yaml pins. 'latest' is for convenience.
│
├── cluster/                          # LOCAL SCRIPTS — not watched by Argo CD
│   │
│   ├── kind-config.yaml
│   │   # Defines the 3-node kind cluster.
│   │   # Nodes: control-plane, infra (pool=infra), worker (pool=rbe-workers, tainted)
│   │   # extraPortMappings: host:8981→container:8981 (Bazel gRPC)
│   │   #                    host:8080→container:80   (Argo CD UI via NodePort)
│   │   # containerdConfigPatches: configures kind to trust ghcr.io pull auth
│   │
│   ├── install-tools.sh
│   │   # Idempotent installer for all CLI tools needed in the lab:
│   │   #   kubectl, kind, helm, argocd (CLI), kubeseal, k9s
│   │   # Checks if already installed before downloading.
│   │   # Sets versions explicitly — no 'latest' downloads (reproducibility).
│   │
│   ├── bootstrap.sh
│   │   # THE MAIN SCRIPT. Run once to stand up the entire cluster.
│   │   # Steps (in order):
│   │   #   1. Validate: config.env exists, tools installed, no existing cluster
│   │   #   2. kind create cluster --config kind-config.yaml
│   │   #   3. Wait for cluster to be Ready
│   │   #   4. Create namespaces (argocd, cluster-infra, etc.)
│   │   #   5. Create ghcr.io imagePullSecret in each namespace (plain Secret, pre-seal)
│   │   #   6. helm install argocd (argo/argo-cd chart) in argocd namespace
│   │   #   7. Wait for Argo CD to be Ready
│   │   #   8. kubectl apply -f gitops/bootstrap/app-of-apps.yaml
│   │   #   9. argocd app wait app-of-apps --health --timeout 600
│   │   #   10. Print access URLs
│   │   # NOTE: Step 8 is the ONLY manual kubectl apply in the entire lab.
│   │   #       Everything after is GitOps-managed.
│   │
│   ├── open-dashboards.sh
│   │   # Port-forwards all UIs to localhost in background processes.
│   │   # Argo CD UI:        http://localhost:8080   (admin / auto-retrieved password)
│   │   # Prometheus:        http://localhost:9090
│   │   # Grafana:           http://localhost:3000   (Phase 4+)
│   │   # MinIO browser:     http://localhost:9001
│   │   # Buildbarn browser: http://localhost:7984   (Phase 2+)
│   │   # Prints PID of each process for easy cleanup.
│   │
│   └── config.env.example
│       # Copy to config.env (listed in .gitignore).
│       # Variables:
│       #   GITHUB_REPO=https://github.com/exitthematrix26/remote_builder
│       #   GITHUB_PAT=ghp_xxxx  (needs read:packages scope for ghcr.io pulls)
│       #   CLUSTER_NAME=remote-builder
│
├── gitops/                           # ← ARGO CD WATCHES THIS DIRECTORY
│   │
│   ├── bootstrap/
│   │   └── app-of-apps.yaml
│   │       # Root Argo Application. The "parent" of all other applications.
│   │       # Source: gitops/apps/ (directory of Application manifests)
│   │       # Applied ONCE manually in bootstrap.sh step 8.
│   │       # After apply: Argo CD self-manages everything.
│   │       # Sync policy: automated + selfHeal + prune
│   │
│   ├── apps/
│   │   # Each subdirectory contains one Argo Application manifest.
│   │   # The Application tells Argo CD: where to find the Helm chart,
│   │   # which values file to use, and which namespace to deploy to.
│   │   │
│   │   ├── sealed-secrets/
│   │   │   └── application.yaml    # Chart: sealed-secrets/sealed-secrets. Wave: -3
│   │   ├── istio-base/
│   │   │   └── application.yaml    # Chart: istio/base (CRDs only). Wave: -2
│   │   ├── istiod/
│   │   │   └── application.yaml    # Chart: istio/istiod. Wave: -1
│   │   ├── argo-rollouts/
│   │   │   └── application.yaml    # Chart: argo/argo-rollouts. Wave: -1
│   │   ├── istio-gateway/
│   │   │   └── application.yaml    # Chart: istio/gateway. Wave: 0
│   │   ├── prometheus/
│   │   │   ├── application.yaml    # Chart: prometheus-community/kube-prometheus-stack. Wave: 0
│   │   │   └── values.yaml         # Slim config: Grafana disabled, 1d retention, tight memory
│   │   ├── keda/
│   │   │   └── application.yaml    # Chart: kedacore/keda. Wave: 0
│   │   ├── minio/
│   │   │   ├── application.yaml    # Chart: minio/minio. Wave: 1
│   │   │   └── values.yaml         # Bucket names, credentials ref (SealedSecret)
│   │   └── rbe-system/
│   │       ├── application.yaml    # Chart: charts/buildbarn/ (local). Wave: 2
│   │       └── values.yaml         # MinIO endpoint, scheduler replicas, image tags
│   │
│   ├── tenants/
│   │   # One directory per tenant. The ApplicationSet generator scans for tenant-* dirs.
│   │   # To add a tenant: create gitops/tenants/tenant-<name>/values.yaml, push, done.
│   │   │
│   │   ├── tenant-acme/
│   │   │   └── values.yaml
│   │   │       # Example overrides:
│   │   │       #   tenant.name: acme
│   │   │       #   worker.maxReplicas: 5
│   │   │       #   worker.image.tag: sha-abc1234
│   │   │       #   quota.cpu: "4"
│   │   │       #   quota.memory: "8Gi"
│   │   │       #   redis.memory: "256Mi"
│   │   │
│   │   └── tenant-initech/
│   │       └── values.yaml         # Phase 6: adding this file = entire tenant appears
│   │
│   └── applicationsets/
│       └── tenants.yaml
│           # ApplicationSet with git directory generator.
│           # Scans: gitops/tenants/tenant-*
│           # For each match: creates Argo Application using charts/rbe-tenant
│           # with /gitops/tenants/<dirname>/values.yaml as Helm values override.
│           # syncPolicy: automated + selfHeal + prune + CreateNamespace=true
│
├── charts/
│   │
│   ├── buildbarn/
│   │   # Custom Helm chart wrapping official Buildbarn container images.
│   │   # Models the architecture from bb-deployments reference configs
│   │   # but expressed in Helm (not Jsonnet) for lab clarity.
│   │   │
│   │   ├── Chart.yaml              # apiVersion: v2, name: buildbarn
│   │   ├── values.yaml
│   │   │   # Key values:
│   │   │   #   scheduler.image: ghcr.io/buildbarn/bb-scheduler:<tag>
│   │   │   #   storage.image: ghcr.io/buildbarn/bb-storage:<tag>
│   │   │   #   storage.s3.endpoint: http://minio.minio:9000
│   │   │   #   storage.s3.bucket: rbe-cas
│   │   │   #   storage.s3.region: us-east-1 (MinIO accepts any region)
│   │   │
│   │   └── templates/
│   │       ├── configmap-scheduler.yaml
│   │       │   # Buildbarn scheduler config in protobuf text format.
│   │       │   # Defines: gRPC listener, worker routing, platform properties.
│   │       ├── configmap-storage.yaml
│   │       │   # Buildbarn storage config.
│   │       │   # Defines: S3 backend (MinIO), CAS + AC gRPC listeners.
│   │       ├── deployment-scheduler.yaml   # bb-scheduler pod on infra-node
│   │       ├── deployment-storage.yaml     # bb-storage pod on infra-node
│   │       ├── service-grpc.yaml
│   │       │   # NodePort service: port 8981 → Bazel clients use this
│   │       │   # grpc://localhost:8981 in .bazelrc
│   │       └── service-storage.yaml        # Internal ClusterIP for scheduler→storage
│   │
│   └── rbe-tenant/
│       # Shared Helm chart deployed once per tenant by the ApplicationSet.
│       # Tenants only override what differs from defaults (image tag, quotas).
│       │
│       ├── Chart.yaml
│       ├── values.yaml
│       │   # Full documented defaults:
│       │   #   tenant.name: ""          (required override)
│       │   #   worker.image.repo: ghcr.io/exitthematrix26/remote_builder/rbe-stub
│       │   #   worker.image.tag: latest (pin to SHA in prod)
│       │   #   worker.minReplicas: 0    (scale to zero)
│       │   #   worker.maxReplicas: 3
│       │   #   worker.tolerations: [{key: dedicated, value: rbe-worker, effect: NoSchedule}]
│       │   #   keda.threshold: "5"      (RPM per worker pod)
│       │   #   keda.cooldown: 60
│       │   #   quota.cpu: "2"
│       │   #   quota.memory: "4Gi"
│       │   #   quota.pods: "10"
│       │   #   redis.memory: "128Mi"
│       │   #   canary.steps: [{setWeight: 10}, {pause: {}}, {setWeight: 50}, {pause: {duration: 60}}, {setWeight: 100}]
│       │
│       └── templates/
│           ├── namespace.yaml
│           │   # Creates namespace: tenant-{{ .Values.tenant.name }}
│           │   # Labels: istio-injection=enabled (Envoy sidecar auto-injection)
│           │   #         app.kubernetes.io/managed-by=argocd
│           ├── resourcequota.yaml
│           │   # Hard limits — cannot be exceeded by pods in this namespace.
│           │   # requests.cpu, limits.cpu, requests.memory, limits.memory, count/pods
│           │   # Without this, one tenant's burst can starve all others.
│           ├── rollout.yaml
│           │   # apiVersion: argoproj.io/v1alpha1, kind: Rollout
│           │   # spec.strategy.canary.steps from values.yaml
│           │   # spec.strategy.canary.trafficRouting.istio (VirtualService + DestinationRule)
│           │   # Toleration: dedicated=rbe-worker:NoSchedule (lands on worker-node)
│           │   # NOTE: This is NOT a Deployment. KEDA targets this directly.
│           ├── scaledobject.yaml
│           │   # apiVersion: keda.sh/v1alpha1, kind: ScaledObject
│           │   # scaleTargetRef: argoproj.io/v1alpha1 Rollout (NOT apps/v1 Deployment)
│           │   # trigger: prometheus → grpc_server_handled_total rate query
│           │   # minReplicaCount: 0, maxReplicaCount: {{ .Values.worker.maxReplicas }}
│           ├── redis.yaml          # Per-tenant Redis Deployment + Service
│           ├── service.yaml        # Headless Service — required for Istio subset routing
│           ├── serviceaccount.yaml # Plain SA in lab; add IRSA annotation for prod
│           ├── virtualservice.yaml
│           │   # Istio VirtualService: routes % of traffic to stable vs canary pods
│           │   # Argo Rollouts controller updates the weights during rollout steps
│           ├── destinationrule.yaml
│           │   # Defines stable and canary subsets by pod label (rollouts-pod-template-hash)
│           └── pdb.yaml
│               # PodDisruptionBudget: minAvailable: 1
│               # Protects in-flight builds during kubectl drain or node upgrades
│
├── rbe-stub/
│   # Lightweight gRPC stub implementing bare minimum REAPI for Phase 1.
│   # Purpose: prove GitOps + Prometheus + KEDA loop before adding Buildbarn weight.
│   # Exposes: /metrics (Prometheus) + REAPI Execution.Execute (returns fake response)
│   │
│   ├── main.go                     # Go gRPC server. ~150 lines. No external deps beyond grpc.
│   ├── Dockerfile                  # Multi-stage: golang:1.22-alpine build → scratch runtime
│   └── README.md                   # How to build locally, how to test with grpcurl
│
├── load-gen/
│   # gRPC load generator simulating concurrent Bazel clients.
│   # Used in Phase 5 to drive KEDA scaling and validate the full system under load.
│   │
│   ├── main.go
│   │   # Flags:
│   │   #   --endpoint  gRPC target (default: localhost:8981)
│   │   #   --rps       requests/second per client (default: 10)
│   │   #   --clients   concurrent gRPC clients (default: 5)
│   │   #   --tenant    tenant label for metric attribution
│   │   #   --duration  how long to run (default: 60s)
│   │   # Implements: ExecuteRequest spam to REAPI Execution.Execute
│   │   # Reports: requests sent, responses received, errors, p99 latency
│   ├── Dockerfile                  # Multi-stage: golang:1.22-alpine → scratch
│   └── README.md
│
└── docs/
    ├── concept.txt                 # Original design brief (source of this plan)
    ├── fullplan.md                 # THIS FILE — master architecture reference
    ├── phases/
    │   ├── phase-1-cluster.md      # Step-by-step: cluster bootstrap + GitOps proof
    │   ├── phase-2-buildbarn.md    # Step-by-step: RBE stack + real Bazel build
    │   ├── phase-3-istio-rollouts.md # Step-by-step: canary deploy walkthrough
    │   ├── phase-4-keda.md         # Step-by-step: autoscaling to zero
    │   ├── phase-5-loadgen.md      # Step-by-step: load test + stress
    │   └── phase-6-multitenant.md  # Step-by-step: add tenant-initech, prove isolation
    └── aws-migration.md            # Variable-by-variable swap guide: kind → EKS
```

---

## 9. Phase Plan

### Phase 1 — Cluster Bootstrap & GitOps Loop

**Goal:** kind cluster running, Argo CD installed, GitOps loop proven end-to-end.

**What gets deployed:**
- kind 3-node cluster (control-plane + infra + worker)
- Argo CD (Helm, manual bootstrap)
- Sealed Secrets (Wave -3 — first thing Argo deploys)
- App-of-apps root Application

**Files generated:**
- `cluster/kind-config.yaml`
- `cluster/install-tools.sh`
- `cluster/bootstrap.sh`
- `cluster/open-dashboards.sh`
- `cluster/config.env.example`
- `gitops/bootstrap/app-of-apps.yaml`
- `docs/phases/phase-1-cluster.md`

**Observable outcome:**
1. Argo CD UI accessible at `http://localhost:8080`
2. Push any file change to GitHub → Argo CD syncs it within 3 minutes (or immediately via webhook)
3. `argocd app list` shows app-of-apps as `Healthy/Synced`

**Memory checkpoint:** After Phase 1, the cluster uses ~1.5GB RAM. Well within budget.

---

### Phase 2 — Buildbarn via Argo CD

**Goal:** Full RBE stack deployed by Argo CD. Bazel client can execute a real remote build.

**What gets deployed (all via Argo CD — no manual kubectl):**
- MinIO (CAS object store)
- Buildbarn: bb-storage (CAS + AC gRPC) + bb-scheduler (frontend/scheduler)
- rbe-stub replaced by real Buildbarn in `rbe-system`
- Sample Bazel workspace with a real Go binary target

**Files generated:**
- `gitops/apps/minio/application.yaml` + `values.yaml`
- `gitops/apps/rbe-system/application.yaml` + `values.yaml`
- `charts/buildbarn/` (full chart)
- Sample `WORKSPACE` + `BUILD` + `main.go` under `examples/hello-bazel/`
- `docs/phases/phase-2-buildbarn.md`

**Observable outcome:**
```bash
bazel build //examples/hello-bazel:hello \
  --remote_executor=grpc://localhost:8981 \
  --remote_cache=grpc://localhost:8981
# Succeeds. MinIO browser shows CAS blobs in rbe-cas bucket.
```

---

### Phase 3 — Istio + Argo Rollouts (Canary Deployments)

**Goal:** Worker deployment uses Argo Rollout with Istio canary traffic steps (10% → 50% → 100%).

**What gets deployed:**
- Istio (istio-base CRDs, istiod, istio-gateway) — all via Argo CD
- Argo Rollouts controller — via Argo CD
- tenant-acme workers migrated from rbe-stub Deployment → Argo Rollout

**Files generated:**
- `gitops/apps/istio-base/application.yaml`
- `gitops/apps/istiod/application.yaml` + `values.yaml`
- `gitops/apps/istio-gateway/application.yaml`
- `gitops/apps/argo-rollouts/application.yaml`
- `charts/rbe-tenant/templates/rollout.yaml`
- `charts/rbe-tenant/templates/virtualservice.yaml`
- `charts/rbe-tenant/templates/destinationrule.yaml`
- `docs/phases/phase-3-istio-rollouts.md`

**Observable outcome:**
```bash
# Bump worker.image.tag in gitops/tenants/tenant-acme/values.yaml
# Push to GitHub
kubectl argo rollouts get rollout rbe-workers -n tenant-acme -w
# Watch: canary at 10% → paused → promoted to 50% → paused → promoted to 100%
# Rollback: revert the image tag in Git → Argo reverts the VirtualService weights automatically
```

---

### Phase 4 — KEDA Autoscaling on Prometheus Metric

**Goal:** Worker pods scale to zero at idle. Scale up is driven entirely by gRPC RPM from Prometheus.

**What gets deployed:**
- Prometheus (kube-prometheus-stack, with Grafana now enabled)
- KEDA operator
- ScaledObject in tenant-acme pointing at the Rollout

**Key ScaledObject config:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: rbe-workers-{{ .Values.tenant.name }}
  namespace: tenant-{{ .Values.tenant.name }}
spec:
  scaleTargetRef:
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout                   # ← NOT Deployment
    name: rbe-workers
  minReplicaCount: 0                # ← Scale to zero when idle
  maxReplicaCount: {{ .Values.worker.maxReplicas }}
  cooldownPeriod: 60
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-operated.cluster-infra:9090
        metricName: grpc_requests_per_minute
        query: |
          sum(rate(grpc_server_handled_total{
            namespace="tenant-{{ .Values.tenant.name }}",
            grpc_service="build.bazel.remote.execution.v2.Execution"
          }[2m])) * 60
        threshold: "5"              # One worker pod per 5 RPM
```

**Files generated:**
- `gitops/apps/prometheus/application.yaml` + `values.yaml` (Grafana enabled)
- `gitops/apps/keda/application.yaml`
- `charts/rbe-tenant/templates/scaledobject.yaml`
- `docs/phases/phase-4-keda.md`

**Observable outcome:**
```bash
kubectl get pods -n tenant-acme -w
# 0 pods at idle
# Run load-gen → watch pods appear
# Stop load-gen → pods terminate within ~90 seconds (cooldown)
```

---

### Phase 5 — Load Generator + System Stress Test

**Goal:** Simulate realistic concurrent build load. Validate the full system under stress.

**What gets built:**
- `load-gen` Go binary built and pushed to ghcr.io via GitHub Actions
- Load generator deployed as a K8s Job (or run locally)

**Files generated:**
- `load-gen/main.go`
- `load-gen/Dockerfile`
- `load-gen/README.md`
- `examples/hello-bazel/` (Bazel workspace with enough targets for interesting cache behavior)
- `docs/phases/phase-5-loadgen.md`

**Observable outcome:**
```bash
go run load-gen/main.go --rps 20 --clients 10 --duration 120s
# Grafana: gRPC RPM climbs to 200+
# KEDA: workers scale from 0 → N (based on RPM / 5 threshold)
# Prometheus: cache hit rate visible (second run much faster than first)
# Stop: workers drain back to 0 within cooldown period
```

---

### Phase 6 — Multi-Tenant via ApplicationSet

**Goal:** Add a second tenant by creating one directory + one values.yaml. Nothing else.

**What gets deployed:**
- ApplicationSet with git directory generator
- tenant-initech namespace, workers, quota, Redis — all created automatically

**Files generated:**
- `gitops/applicationsets/tenants.yaml`
- `gitops/tenants/tenant-initech/values.yaml`
- `charts/rbe-tenant/templates/resourcequota.yaml` (reviewed for isolation proof)
- `docs/phases/phase-6-multitenant.md`

**Observable outcome:**
```bash
# Create gitops/tenants/tenant-initech/values.yaml (5 lines), push to GitHub
kubectl get namespace tenant-initech
# Appears automatically — Argo CD created it
kubectl get rollout -n tenant-initech
kubectl get scaledobject -n tenant-initech

# Isolation proof:
# Max out tenant-acme quota → tenant-initech builds unaffected
# Kill all tenant-acme workers → tenant-initech still serves builds
```

---

## 10. AWS Migration Reference

Every lab configuration decision has a production equivalent. Migrating = changing values, not architecture.

| Lab Component | Lab Value | Production (EKS) Value |
|---|---|---|
| Cluster tool | `kind create cluster` | `terraform apply` (modules/eks-cluster) |
| Control plane | kind control-plane node | EKS managed control plane (no node) |
| infra-node | 1 Docker container | `system` node group: t3.large ×2 (Multi-AZ) |
| worker-node | 1 Docker container | `rbe-workers` node group: c5.xlarge Spot ×0-20 |
| CAS backend | MinIO in-cluster | AWS S3 bucket (modules/s3-cache) |
| MinIO endpoint | `http://minio.minio:9000` | `https://s3.us-east-1.amazonaws.com` |
| Action cache | Redis pod per tenant | AWS ElastiCache Redis (modules/elasticache) |
| ServiceAccount | Plain K8s SA | IRSA: `eks.amazonaws.com/role-arn: arn:aws:iam::...` |
| Image pull auth | ghcr.io PAT (SealedSecret) | ECR via IRSA (no pull secret needed) |
| Image registry | `ghcr.io/exitthematrix26/...` | `123456789.dkr.ecr.us-east-1.amazonaws.com/...` |
| Bazel endpoint | `grpc://localhost:8981` | `grpc://rbe.internal.yourco.com:443` (NLB + Route53) |
| TLS termination | None (plaintext gRPC) | ACM cert on NLB + gRPC over TLS |
| Argo CD source | GitHub → localhost port-forward | GitHub → EKS Argo CD (LoadBalancer or internal NLB) |
| Node taints | kind-config.yaml | EKS managed node group taint config |
| Topology spread | Single AZ (kind) | Multi-AZ: `topologyKey: topology.kubernetes.io/zone` |
| Secrets | Sealed Secrets (same) | Sealed Secrets OR AWS Secrets Manager + CSI driver |

**Terraform modules to write (separate repo or `terraform/` directory):**
- `modules/eks-cluster` — VPC, EKS, 3 node groups (system, services, rbe-workers)
- `modules/s3-cache` — CAS bucket, lifecycle rules (expire blobs > 30 days), bucket policy
- `modules/irsa` — IAM role + OIDC trust policy per tenant ServiceAccount
- `modules/ecr` — Container registries for rbe-stub, load-gen, worker images
- `modules/elasticache` — Redis for action cache (replaces per-tenant Redis pods)

---

## 11. Key Gotchas & Things That Will Bite You

These are documented now so you recognize them when they happen, not after 2 hours of debugging.

| Gotcha | What Happens | Fix |
|---|---|---|
| Wrong KEDA target kind | KEDA creates an HPA pointing at a Deployment that doesn't exist | Set `scaleTargetRef.apiVersion: argoproj.io/v1alpha1` and `kind: Rollout` |
| Istio CRDs before istiod | Argo CD tries to apply istiod before CRDs exist → CRD validation error | Sync wave -2 for istio-base, -1 for istiod |
| No `istio-injection=enabled` label | Pods start without Envoy sidecar → VirtualService routing silently ignored | Label every tenant namespace in `namespace.yaml` |
| Rollout vs Deployment naming | Argo CD shows the wrong health status | Rollout health check requires the `argoproj` Argo CD extension |
| ghcr.io packages default private | Image pull fails with 401 even with correct PAT | Set package visibility to Public in GitHub Settings after first push |
| Buildbarn S3 bucket doesn't exist | bb-storage crashes on startup | MinIO bucket must be created before bb-storage starts (wave order: minio wave 1, rbe-system wave 2) |
| KEDA scale-to-zero + canary | KEDA scaling a Rollout that's mid-canary can cause unexpected replica counts | Pause KEDA ScaledObject during rollouts: `kubectl annotate scaledobject ... autoscaling.keda.sh/paused=true` |
| Prometheus metric not scraped | KEDA trigger sees 0 RPM always → workers never scale up | Check ServiceMonitor selector matches pod labels; `kubectl port-forward prometheus-pod 9090` and query manually |
| kind extraPortMapping conflict | Port 8981 already in use on host | `lsof -i :8981` and kill the prior lab's process |

---

## 12. Pre-Flight Checklist Before Starting Phase 1

```bash
# 1. Delete prior lab cluster
kind get clusters
kind delete cluster --name <old-cluster-name>

# 2. Free RAM — target: ~8GB free
# Close Chrome, VS Code unused windows, Docker containers from old labs
docker ps   # identify and stop any running containers you don't need
free -h     # confirm available > 8GB

# 3. Verify Docker is running
docker info

# 4. Copy and fill config
cp cluster/config.env.example cluster/config.env
# Edit cluster/config.env:
#   GITHUB_REPO=https://github.com/exitthematrix26/remote_builder
#   GITHUB_PAT=ghp_xxxx   (create at github.com/settings/tokens → read:packages)
#   CLUSTER_NAME=remote-builder

# 5. Confirm tools (install-tools.sh will handle missing ones)
kubectl version --client
kind version
helm version
argocd version --client

# 6. Set ghcr.io package visibility to Public
# GitHub → Your Profile → Packages → remote_builder packages → Package Settings → Change visibility
# Do this BEFORE bootstrap.sh, or pull will 401
```

---

*Document version: 1.0 — Generated 2026-03-30*
*Next step: Confirm design, then generate all Phase 1 files.*
