// stats_main.cc — CLI wrapper around stats::FromResultsCSV.
//
// Reads a results CSV produced by the Go runner, computes statistics,
// and writes a JSON file consumed by validate_test.py.
//
// Usage (from genrule in macros.bzl):
//   stats_bin --input results.csv --output stats.json
#include "stats.h"

#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

int main(int argc, char* argv[]) {
    std::string input, output;

    for (int i = 1; i < argc - 1; ++i) {
        if (std::strcmp(argv[i], "--input") == 0)  input  = argv[i + 1];
        if (std::strcmp(argv[i], "--output") == 0) output = argv[i + 1];
    }

    if (input.empty() || output.empty()) {
        std::cerr << "usage: stats_bin --input <results.csv> --output <stats.json>\n";
        return 1;
    }

    try {
        stats::Summary s = stats::FromResultsCSV(input);
        std::string json = stats::ToJSON(s);

        std::ofstream f(output);
        if (!f.is_open()) {
            std::cerr << "cannot write: " << output << "\n";
            return 1;
        }
        f << json << "\n";
        std::cout << "stats written to " << output << "\n";
        std::cout << json << "\n";
    } catch (const std::exception& e) {
        std::cerr << "error: " << e.what() << "\n";
        return 1;
    }

    return 0;
}
