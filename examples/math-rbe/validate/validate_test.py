"""validate_test.py — pytest suite that asserts correctness of the full pipeline.

This runs as a py_test target via the math_pipeline macro (_check step).
It is the final node in the Bazel action graph for each dataset:

    inputs.csv → (Go runner) → results.csv → (C++ stats) → stats.json
                                     └─────────────────────────┘
                                              (this test reads both)

File paths are passed via environment variables set by the math_pipeline
macro in macros.bzl.  This avoids argparse boilerplate and keeps the test
file reusable across all three pipeline instances (smoke/medium/large).

Run standalone (outside Bazel, for debugging):
    INPUTS_CSV=data/inputs_s.csv \\
    RESULTS_CSV=/tmp/smoke_results.csv \\
    STATS_JSON=/tmp/smoke_stats.json \\
    pytest validate/validate_test.py -v
"""

import json
import math
import os

import pandas as pd
import pytest


# ── Fixtures — load files once per session ───────────────────────────────────

@pytest.fixture(scope="session")
def inputs() -> pd.DataFrame:
    path = os.environ["INPUTS_CSV"]
    df = pd.read_csv(path)
    assert list(df.columns) == ["a", "b", "op"], f"unexpected columns in {path}: {df.columns.tolist()}"
    return df


@pytest.fixture(scope="session")
def results() -> pd.DataFrame:
    path = os.environ["RESULTS_CSV"]
    df = pd.read_csv(path)
    assert list(df.columns) == ["a", "b", "op", "output", "error"], \
        f"unexpected columns in {path}: {df.columns.tolist()}"
    return df


@pytest.fixture(scope="session")
def stats_summary() -> dict:
    path = os.environ["STATS_JSON"]
    with open(path) as f:
        return json.load(f)


# ── Basic shape tests ─────────────────────────────────────────────────────────

def test_results_row_count_matches_inputs(inputs, results):
    """Every input row must produce exactly one result row."""
    assert len(results) == len(inputs), \
        f"inputs has {len(inputs)} rows but results has {len(results)} rows"


def test_results_has_no_extra_errors(results):
    """Rows with b==0 and op==div are the only expected errors.
    All other rows must have an empty error column."""
    bad = results[
        (results["error"].notna()) &
        (results["error"] != "") &
        ~((results["b"].abs() < 1e-9) & (results["op"] == "div"))
    ]
    assert len(bad) == 0, f"unexpected error rows:\n{bad.to_string()}"


# ── Arithmetic correctness ────────────────────────────────────────────────────

def test_multiply_results_correct(results):
    """For every mul row, output must equal a * b within float tolerance."""
    mul = results[(results["op"] == "mul") & (results["error"].isna() | (results["error"] == ""))]
    for _, row in mul.iterrows():
        expected = row["a"] * row["b"]
        actual = float(row["output"])
        assert math.isclose(actual, expected, rel_tol=1e-6), \
            f"mul({row['a']}, {row['b']}): expected {expected}, got {actual}"


def test_divide_results_correct(results):
    """For every div row with non-zero b, output must equal a / b."""
    div = results[
        (results["op"] == "div") &
        (results["b"].abs() > 1e-9) &
        (results["error"].isna() | (results["error"] == ""))
    ]
    for _, row in div.iterrows():
        expected = row["a"] / row["b"]
        actual = float(row["output"])
        assert math.isclose(actual, expected, rel_tol=1e-6), \
            f"div({row['a']}, {row['b']}): expected {expected}, got {actual}"


# ── Stats JSON sanity ─────────────────────────────────────────────────────────

def test_stats_keys_present(stats_summary):
    """The C++ stats binary must emit all required keys."""
    required = {"count", "error_count", "mean", "stddev", "min", "max"}
    missing = required - stats_summary.keys()
    assert not missing, f"stats JSON missing keys: {missing}"


def test_stats_count_matches_valid_results(results, stats_summary):
    """stats.count must equal the number of rows without errors."""
    valid_count = len(results[results["error"].isna() | (results["error"] == "")])
    assert stats_summary["count"] == valid_count, \
        f"stats.count={stats_summary['count']} but {valid_count} valid result rows"


def test_stats_mean_in_range(results, stats_summary):
    """C++ mean must match pandas mean within tolerance."""
    valid_outputs = results[
        results["error"].isna() | (results["error"] == "")
    ]["output"].astype(float)
    if len(valid_outputs) == 0:
        pytest.skip("no valid output rows")
    expected_mean = valid_outputs.mean()
    assert math.isclose(stats_summary["mean"], expected_mean, rel_tol=1e-4), \
        f"C++ mean {stats_summary['mean']} != pandas mean {expected_mean}"


def test_stats_min_max_correct(results, stats_summary):
    """C++ min/max must match pandas min/max."""
    valid_outputs = results[
        results["error"].isna() | (results["error"] == "")
    ]["output"].astype(float)
    if len(valid_outputs) == 0:
        pytest.skip("no valid output rows")
    assert math.isclose(stats_summary["min"], valid_outputs.min(), rel_tol=1e-6)
    assert math.isclose(stats_summary["max"], valid_outputs.max(), rel_tol=1e-6)
