// stats.cc — implementation of stats::Compute and stats::FromResultsCSV.
//
// This is intentionally split across multiple files (stats.h / stats.cc /
// stats_main.cc / stats_test.cc) so Bazel compiles them as separate actions.
// Even a small C++ library produces multiple compile actions on RBE:
//   stats.cc   → stats.o        (1 action)
//   stats_main.cc → main.o      (1 action)
//   stats_test.cc → test binary (1 action, links stats.o + googletest)
//
// That's 3 independent actions the scheduler can dispatch in parallel —
// unlike Go where one package = one action.
#include "stats.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace stats {

Summary Compute(const std::vector<double>& values) {
    Summary s;
    if (values.empty()) return s;

    s.count = static_cast<int>(values.size());
    s.min = *std::min_element(values.begin(), values.end());
    s.max = *std::max_element(values.begin(), values.end());

    double sum = 0.0;
    for (double v : values) sum += v;
    s.mean = sum / s.count;

    double sq_sum = 0.0;
    for (double v : values) {
        double d = v - s.mean;
        sq_sum += d * d;
    }
    // Population stddev (not sample) — consistent with numpy default used in pytest.
    s.stddev = std::sqrt(sq_sum / s.count);

    return s;
}

// Minimal CSV parser — avoids pulling in a third-party library.
// Handles the simple comma-separated format written by cmd/main.go.
static std::vector<std::string> SplitCSV(const std::string& line) {
    std::vector<std::string> fields;
    std::stringstream ss(line);
    std::string field;
    while (std::getline(ss, field, ',')) {
        fields.push_back(field);
    }
    return fields;
}

Summary FromResultsCSV(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        throw std::runtime_error("cannot open: " + path);
    }

    std::vector<double> outputs;
    int error_count = 0;
    std::string line;
    bool header = true;

    while (std::getline(f, line)) {
        if (header) { header = false; continue; }
        if (line.empty()) continue;

        auto fields = SplitCSV(line);
        // Expected columns: a, b, op, output, error
        if (fields.size() < 5) continue;

        const std::string& error_field = fields[4];
        if (!error_field.empty()) {
            ++error_count;
            continue;
        }

        const std::string& output_field = fields[3];
        if (output_field.empty()) {
            ++error_count;
            continue;
        }

        try {
            outputs.push_back(std::stod(output_field));
        } catch (...) {
            ++error_count;
        }
    }

    Summary s = Compute(outputs);
    s.error_count = error_count;
    return s;
}

std::string ToJSON(const Summary& s) {
    std::ostringstream out;
    out << std::fixed;
    out << "{"
        << "\"count\":" << s.count << ","
        << "\"error_count\":" << s.error_count << ","
        << "\"mean\":" << s.mean << ","
        << "\"stddev\":" << s.stddev << ","
        << "\"min\":" << s.min << ","
        << "\"max\":" << s.max
        << "}";
    return out.str();
}

} // namespace stats
