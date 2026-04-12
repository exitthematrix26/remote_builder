# macros.bzl — custom Starlark macros for math-rbe
#
# WHY MACROS?
# A Bazel macro is a function that expands into one or more rules at load time.
# They live in .bzl files and are loaded with load() in BUILD files.
#
# The math_pipeline() macro is the core learning vehicle here:
# given a dataset label, it generates THREE targets automatically:
#
#   {name}_run    genrule  — runs the Go CSV runner → produces results CSV
#   {name}_stats  genrule  — runs the C++ stats binary over the results CSV
#   {name}_check  py_test  — pytest validates results + stats output
#
# With a single call per dataset in BUILD, this fan-out gives the RBE
# scheduler multiple independent actions to dispatch in parallel.
# 50 datasets × 3 actions = 150 parallel RBE dispatches on --config=nocache.

def math_pipeline(name, dataset, timeout = "short"):
    """Generate a run → stats → check pipeline for one CSV dataset.

    Args:
        name:    Unique prefix. Produces {name}_run, {name}_stats, {name}_check.
        dataset: Label for the input CSV file, e.g. "//data:inputs_s".
        timeout: Bazel test timeout. "short" (60s), "moderate" (300s), "long" (900s).
    """

    # ── Step 1: Go CSV runner ─────────────────────────────────────────────────
    # genrule wraps the pre-built Go binary (//cmd:runner) and feeds it one
    # input CSV.  $(location ...) resolves to the Bazel-sandboxed path at
    # execution time — this is how you pass file paths across rule boundaries.
    #
    # Output: {name}_results.csv in the genrule's output directory.
    native.genrule(
        name = name + "_run",
        srcs = [dataset],
        outs = [name + "_results.csv"],
        cmd = "$(location //cmd:runner) --input=$(location " + dataset + ") --output=$@",
        tools = ["//cmd:runner"],
        # Each genrule is a standalone action — the scheduler sees these as
        # independent and can dispatch all of them to different workers in parallel.
    )

    # ── Step 2: C++ stats binary ──────────────────────────────────────────────
    # Reads the results CSV, computes mean/stddev/min/max, writes a JSON summary.
    # This creates a data-dependency: {name}_stats CANNOT start until {name}_run
    # completes and its output CSV is available in the remote cache.
    native.genrule(
        name = name + "_stats",
        srcs = [name + "_results.csv"],
        outs = [name + "_stats.json"],
        cmd = "$(location //cc:stats_bin) --input=$(location " + name + "_results.csv) --output=$@",
        tools = ["//cc:stats_bin"],
    )

    # ── Step 3: Python pytest validation ─────────────────────────────────────
    # py_test (not genrule) so `bazel test //...` picks it up and reports
    # pass/fail in the test summary. The validate_test.py script reads both
    # the results CSV and the stats JSON and asserts correctness.
    native.py_test(
        name = name + "_check",
        srcs = ["//validate:validate_test.py"],
        main = "//validate:validate_test.py",
        data = [
            name + "_results.csv",
            name + "_stats.json",
            dataset,
        ],
        deps = [
            "@math_rbe_pip//:pandas",
            "@math_rbe_pip//:pytest",
        ],
        env = {
            # Pass file paths via env so pytest doesn't need argparse.
            # $(location ...) in env is expanded by Bazel before the test runs.
            "INPUTS_CSV": "$(location " + dataset + ")",
            "RESULTS_CSV": "$(location " + name + "_results.csv)",
            "STATS_JSON": "$(location " + name + "_stats.json)",
        },
        timeout = timeout,
        # Tags make it easy to filter: `bazel test --test_tag_filters=math`
        tags = ["math", "rbe-load"],
    )
