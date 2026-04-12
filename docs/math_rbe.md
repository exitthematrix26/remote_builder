# Phase 4 — math-rbe: Multi-Language Load Test Pipeline

## What Was Built

`examples/math-rbe/` is a multi-language Bazel workspace that serves two purposes:

1. **RBE load generator** — runs enough parallel actions to saturate workers,
   produce measurable scheduler queue depth, and trigger KEDA autoscaling
   (wired up later in Phase 5).

2. **Bazel deep-dive** — every significant Bazel concept (macros, Bzlmod,
   pip.parse, cross-language deps, data files, genrules, cc_library, py_test)
   is demonstrated with a working, runnable example.

---

## Architecture

```
                         examples/math-rbe/
                         │
    ┌────────────────────┼────────────────────────────────────┐
    │                    │                                     │
    ▼                    ▼                                     ▼
  Go (rules_go)       C++ (rules_cc)                  Python (rules_python)
  lib/calc.go         cc/stats.cc                     validate/validate_test.py
  cmd/main.go         cc/stats_main.cc
  lib/calc_test.go    cc/stats_test.cc (googletest)
       │                    │                                     │
       │ go_library          │ cc_library                          │ py_test
       │ go_test             │ cc_binary (stats_bin)               │ (pytest)
       │ go_binary (runner)  │ cc_test                             │
       └────────────────────┴─────────────────────────────────────┘
                                     │
                               macros.bzl
                          math_pipeline(name, dataset)
                                     │
              ┌──────────────────────┼──────────────────────┐
              ▼                      ▼                       ▼
        {name}_run              {name}_stats           {name}_check
        (genrule)               (genrule)              (py_test)
     runner --input CSV      stats_bin --input     validate_test.py
         → results.csv       results.csv           asserts arithmetic
                             → stats.json          + stats correctness
```

### Data flow per dataset

```
data/inputs_s.csv
      │
      │  smoke_run (genrule — 1 RBE action)
      ▼
smoke_results.csv
      │
      │  smoke_stats (genrule — 1 RBE action)
      ▼
smoke_stats.json
      │
      │  smoke_check (py_test — 1 RBE action)
      ▼
     PASS / FAIL
```

Three datasets (smoke=10 rows, medium=50, large=200) × 3 actions = **9 parallel
RBE actions** on a cold build.  With `--config=nocache` and seed variation in
the load test loop, every iteration generates fresh action keys → scheduler
queue fills → KEDA sees the queue depth metric and scales workers.

---

## Files

| File | Purpose |
|------|---------|
| `MODULE.bazel` | Declares all deps: rules_go, rules_cc, googletest, rules_python, pip.parse |
| `.bazelrc` | `--config=rbe` and `--config=nocache` flag sets |
| `macros.bzl` | `math_pipeline()` Starlark macro — fan-out to 3 targets per dataset |
| `BUILD.bazel` | `rbe_platform()` + 3 `math_pipeline()` calls |
| `lib/calc.go` | `Multiply`, `Divide`, `Compute` — Go math library |
| `lib/calc_test.go` | Table-driven Go unit tests |
| `lib/BUILD.bazel` | `go_library` + `go_test` |
| `cmd/main.go` | CSV batch runner — reads inputs, writes results |
| `cmd/BUILD.bazel` | `go_binary` (runner) |
| `cc/stats.h` | C++ stats API: `Compute`, `FromResultsCSV`, `ToJSON` |
| `cc/stats.cc` | Implementation: mean, stddev, min, max |
| `cc/stats_main.cc` | CLI wrapper → writes stats.json |
| `cc/stats_test.cc` | GoogleTest unit tests |
| `cc/BUILD.bazel` | `cc_library` + `cc_binary` + `cc_test` |
| `data/inputs_s.csv` | 10-row smoke dataset (includes one div-by-zero row) |
| `data/inputs_m.csv` | 50-row medium dataset |
| `data/inputs_l.csv` | 200-row large dataset |
| `data/BUILD.bazel` | `filegroup` targets per CSV |
| `validate/validate_test.py` | pytest: shape checks, arithmetic correctness, stats cross-check |
| `validate/requirements.txt` | pandas 2.2.3, pytest 8.3.5 |
| `validate/BUILD.bazel` | `exports_files` |
| `scripts/gen_inputs.py` | Generates randomised CSVs with `--seed` for cache busting |
| `scripts/load_test.sh` | Orchestrates multi-pass load test with AC miss generation |

---

## Bazel Concepts Demonstrated

### 1. Starlark Macros (`macros.bzl`)

A macro is a plain Python-like function called at **load time** (before any
build action runs).  It expands into native rules:

```python
# macros.bzl
def math_pipeline(name, dataset, timeout = "short"):
    native.genrule(
        name = name + "_run",
        srcs = [dataset],
        outs = [name + "_results.csv"],
        cmd = "$(location //cmd:runner) --input=$(location " + dataset + ") --output=$@",
        tools = ["//cmd:runner"],
    )
    # ... _stats and _check follow
```

```python
# BUILD.bazel — one call generates 3 targets
math_pipeline(name = "smoke",  dataset = "//data:inputs_s")
math_pipeline(name = "medium", dataset = "//data:inputs_m")
math_pipeline(name = "large",  dataset = "//data:inputs_l")
```

`bazel query //...` shows all 9 generated targets:
```
//:smoke_run   //:smoke_stats   //:smoke_check
//:medium_run  //:medium_stats  //:medium_check
//:large_run   //:large_stats   //:large_check
```

### 2. Bzlmod (`MODULE.bazel`)

Bzlmod replaces the old `WORKSPACE` + `http_archive` pattern.  All deps are
declared in `MODULE.bazel` and resolved from the Bazel Central Registry (BCR):

```python
bazel_dep(name = "rules_go",    version = "0.60.0")
bazel_dep(name = "googletest",  version = "1.15.2")
bazel_dep(name = "rules_python",version = "1.4.1")
```

No SHA256 pinning needed — BCR provides immutable versioned releases.

### 3. pip.parse in MODULE.bazel

Third-party Python packages are fetched by Bazel, not by system pip:

```python
pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")
pip.parse(
    hub_name    = "math_rbe_pip",
    python_version = "3.11",
    requirements_lock = "//validate:requirements.txt",
)
use_repo(pip, "math_rbe_pip")
```

Packages are then depended on as:
```python
deps = ["@math_rbe_pip//:pandas", "@math_rbe_pip//:pytest"]
```

This means workers receive wheels from the Bazel cache, not from the network
at test time.  No `pip install` is needed on workers.

### 4. $(location ...) in genrules

`$(location label)` resolves to the Bazel-sandboxed file path at execution
time.  This is how you wire file-producing rules together:

```python
native.genrule(
    name = name + "_stats",
    srcs  = [name + "_results.csv"],      # declares input dependency
    outs  = [name + "_stats.json"],       # declares output
    cmd   = "$(location //cc:stats_bin) "
            "--input=$(location " + name + "_results.csv) "
            "--output=$@",               # $@ = the single output file
    tools = ["//cc:stats_bin"],
)
```

### 5. Cross-language dependency graph

The action graph crosses three languages in order:

```
go_binary (runner) → genrule (_run) → genrule (_stats, uses cc_binary) → py_test (_check)
```

Bazel resolves this correctly: `_stats` will not start until `_run` has
written its CSV to the remote cache, and `_check` will not start until both
CSVs and the JSON are available.

### 6. C++ multi-file library (parallel compile actions)

```
cc_library(name="stats", hdrs=["stats.h"], srcs=["stats.cc"])
```

Bazel compiles each `.cc` file as a separate action.  A C++ library with 5
source files = 5 independent compile actions on RBE.  This is why C++ is a
better load generator than Go for the same logical component.

### 7. Data files with filegroup()

```python
filegroup(name = "inputs_s", srcs = ["inputs_s.csv"])
```

CSV files are not compiled — `filegroup` makes them addressable as Bazel
labels.  Rules that consume them list them in `data = [...]` or `srcs = [...]`
and use `$(location ...)` to get the runtime path.

---

## Running Locally (one-off)

```bash
cd examples/math-rbe

# 1. Unit tests only (no RBE, fast)
bazel test //lib:mathlib_test //cc:stats_test

# 2. Full pipeline, local execution
bazel test //...

# 3. Full pipeline, remote execution (port-forwards must be running)
bazel test --config=rbe //...

# 4. Inspect what ran remotely
grep "processes:" /tmp/bep_mathrbe.txt | tail -5
#   INFO: 9 processes: 3 remote, 6 action cache hit.

# 5. Force all actions to remote-execute (no AC hits)
bazel test --config=rbe --config=nocache //...
#   INFO: 9 processes: 9 remote.
```

Expected output when healthy:
```
//cc:stats_test            PASSED in 2.1s
//lib:mathlib_test         PASSED in 0.8s
//:smoke_check             PASSED in 1.4s
//:medium_check            PASSED in 1.9s
//:large_check             PASSED in 3.2s
```

---

## Running as a Load Test

### Quick load test (warm, AC hits)

```bash
cd examples/math-rbe
./scripts/load_test.sh --loop 5
```

Actions repeat with identical inputs → AC hits → light scheduler load.
Use this to verify the pipeline is healthy and caching works.

### Sustained load test (cache-busting, forces remote exec)

```bash
./scripts/load_test.sh --nocache --loop 10
```

`--nocache` sets `--noremote_accept_cached`.  Each iteration also generates a
seeded CSV with `gen_inputs.py --seed N`, so action keys differ per iteration.
Every loop = 9 fresh remote actions + N runner invocations.

### Manual cache-busting by seed

```bash
# Generate a varied dataset
python3 scripts/gen_inputs.py --rows 200 --seed 99 --out /tmp/inputs_99.csv

# Run the Go batch binary directly (no Bazel AC involved)
$(bazel cquery --config=rbe --output=files //cmd:runner) \
  --input=/tmp/inputs_99.csv --output=/tmp/results_99.csv

# Run C++ stats
$(bazel cquery --config=rbe --output=files //cc:stats_bin) \
  --input=/tmp/results_99.csv --output=/tmp/stats_99.json

cat /tmp/stats_99.json
```

### Watching worker activity during load

```bash
# Live pod logs (see action dispatch messages)
kubectl logs -n rbe-system -l app.kubernetes.io/name=bb-worker \
  -c bb-worker --tail=30 -f

# BEP summary after each Bazel run
grep "processes:" /tmp/bep_mathrbe.txt | tail -3
# X processes: Y remote.              ← actions executed on workers
# X processes: Y action cache hit.    ← results from AC (no worker used)

# Rollout status (checks canary traffic split if a rollout is in progress)
kubectl-argo-rollouts get rollout bb-worker -n rbe-system
```

---

## Connecting to Phase 5: KEDA Autoscaling

Once `kube-prometheus-stack` is deployed and bb-scheduler exposes Prometheus
metrics, KEDA will watch the scheduler's pending-action queue depth and scale
`bb-worker` replicas up/down automatically.

The load test loop (`--nocache --loop 20`) is designed to:

1. Saturate the current 2 workers → queue depth rises
2. KEDA ScaledObject triggers HPA → new `bb-worker` pods spin up
3. Scheduler dispatches backlog to new workers → queue drains
4. Idle timeout → KEDA scales back to 2

This closes the loop: **load test → KEDA scale-up → Argo Rollout canary for
the scaled image → AnalysisTemplate gates → Prometheus confirms health**.

---

## What's Next: Phase 5 — kube-prometheus-stack + KEDA

- Deploy `kube-prometheus-stack` via Argo CD
- Configure bb-scheduler `diagnosticsHttpServer.enablePrometheus: true`
- Deploy KEDA `ScaledObject` targeting `bb_scheduler_operations_enqueued_total`
- Wire `bb-worker-health` AnalysisTemplate into Rollout canary steps
- Grafana dashboard: build throughput, cache hit rate, worker utilization
