// cmd/main.go — CSV batch runner
//
// Reads an input CSV (columns: a, b, op), computes each row using mathlib,
// and writes a results CSV (columns: a, b, op, output, error).
//
// This binary is wrapped by the math_pipeline macro's _run genrule.
// The genrule passes --input and --output as $(location ...) paths so Bazel
// knows exactly which files are read/written — enabling correct caching and
// sandboxing.
//
// Usage:
//
//	runner --input data/inputs_s.csv --output /tmp/results.csv
package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"

	mathlib "github.com/exitthematrix26/remote_builder/examples/math-rbe/lib"
)

func main() {
	input := flag.String("input", "", "path to input CSV (a,b,op)")
	output := flag.String("output", "", "path to write results CSV")
	flag.Parse()

	if *input == "" || *output == "" {
		log.Fatal("--input and --output are required")
	}

	rows, err := readInput(*input)
	if err != nil {
		log.Fatalf("reading input: %v", err)
	}

	results := make([]mathlib.Result, 0, len(rows))
	for _, row := range rows {
		results = append(results, mathlib.Compute(row[0], row[1], mathlib.Op(row[2])))
	}

	if err := writeResults(*output, results); err != nil {
		log.Fatalf("writing results: %v", err)
	}

	fmt.Printf("processed %d rows → %s\n", len(results), *output)
}

// readInput parses the CSV into (a float64, b float64, op string) triples.
// Header row is skipped.  Malformed rows are logged and skipped.
func readInput(path string) ([][3]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	r := csv.NewReader(f)
	records, err := r.ReadAll()
	if err != nil {
		return nil, err
	}

	var rows [][3]string
	for i, rec := range records {
		if i == 0 {
			continue // skip header
		}
		if len(rec) < 3 {
			log.Printf("row %d: expected 3 columns, got %d — skipping", i+1, len(rec))
			continue
		}
		// Validate that a and b are parseable floats; op is validated in mathlib.
		if _, err := strconv.ParseFloat(rec[0], 64); err != nil {
			log.Printf("row %d: a=%q not a float — skipping", i+1, rec[0])
			continue
		}
		if _, err := strconv.ParseFloat(rec[1], 64); err != nil {
			log.Printf("row %d: b=%q not a float — skipping", i+1, rec[1])
			continue
		}
		rows = append(rows, [3]string{rec[0], rec[1], rec[2]})
	}
	return rows, nil
}

// writeResults writes results to a CSV with header: a,b,op,output,error.
func writeResults(path string, results []mathlib.Result) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	w := csv.NewWriter(f)
	if err := w.Write([]string{"a", "b", "op", "output", "error"}); err != nil {
		return err
	}
	for _, r := range results {
		output := ""
		if r.Err == "" {
			output = strconv.FormatFloat(r.Output, 'f', 10, 64)
		}
		if err := w.Write([]string{
			strconv.FormatFloat(r.A, 'f', 10, 64),
			strconv.FormatFloat(r.B, 'f', 10, 64),
			string(r.Op),
			output,
			r.Err,
		}); err != nil {
			return err
		}
	}
	w.Flush()
	return w.Error()
}
