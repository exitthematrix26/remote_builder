// Package mathlib provides basic arithmetic operations used by the math-rbe
// load test pipeline.
//
// Keeping the logic in a library (separate from cmd/) lets both the Go binary
// and Go unit tests depend on it without duplicating code — standard Go layout
// that maps cleanly to Bazel's go_library + go_test model.
package mathlib

import (
	"errors"
	"fmt"
	"math"
)

// ErrDivisionByZero is returned when Divide is called with b == 0.
var ErrDivisionByZero = errors.New("division by zero")

// Op represents a supported arithmetic operation.
type Op string

const (
	OpMultiply Op = "mul"
	OpDivide   Op = "div"
)

// Result holds the output of a single computation row.
type Result struct {
	A      float64
	B      float64
	Op     Op
	Output float64
	Err    string // empty when no error
}

// Multiply returns a * b.
func Multiply(a, b float64) float64 {
	return a * b
}

// Divide returns a / b.
// Returns ErrDivisionByZero when b is zero (or within floating-point epsilon).
func Divide(a, b float64) (float64, error) {
	if math.Abs(b) < 1e-12 {
		return 0, ErrDivisionByZero
	}
	return a / b, nil
}

// Compute applies op to (a, b) and returns a Result.
// Invalid op values return an error string in Result.Err rather than
// panicking — the CSV runner logs and continues so one bad row doesn't
// abort the entire batch.
func Compute(a, b float64, op Op) Result {
	r := Result{A: a, B: b, Op: op}
	switch op {
	case OpMultiply:
		r.Output = Multiply(a, b)
	case OpDivide:
		out, err := Divide(a, b)
		if err != nil {
			r.Err = err.Error()
		} else {
			r.Output = out
		}
	default:
		r.Err = fmt.Sprintf("unknown op: %q", op)
	}
	return r
}
