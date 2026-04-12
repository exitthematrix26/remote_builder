// stats.h — descriptive statistics over a vector of doubles.
//
// Bazel C++ convention: public headers go in hdrs = ["stats.h"] in the
// cc_library rule.  Sources that #include this header list the library in
// their deps — Bazel propagates the include path automatically.
// No manual -I flags needed.
#pragma once

#include <string>
#include <vector>

namespace stats {

// Summary holds the computed statistics for one column.
struct Summary {
    double mean{0};
    double stddev{0};
    double min{0};
    double max{0};
    int count{0};
    int error_count{0}; // rows that had a computation error (div-by-zero etc.)
};

// Compute returns descriptive statistics for the given values.
// Empty input returns a zero-valued Summary.
Summary Compute(const std::vector<double>& values);

// ParseResultsCSV reads a results CSV written by the Go runner.
// Returns the "output" column values, skipping rows that have a non-empty
// "error" column.  error_count in the returned Summary reflects skipped rows.
//
// Expected CSV columns (produced by cmd/main.go):
//   a, b, op, output, error
Summary FromResultsCSV(const std::string& path);

// ToJSON serialises a Summary to a compact JSON string.
// Written to file by stats_main.cc — read by validate_test.py.
std::string ToJSON(const Summary& s);

} // namespace stats
