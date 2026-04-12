package mathlib_test

// Table-driven tests are idiomatic Go.  Bazel's go_test rule wraps `go test`
// under the hood — each test file in the package becomes one RBE action when
// --config=rbe is used.
//
// go_test in Bazel: the `embed` attribute compiles the library into the test
// binary, equivalent to listing the package as a test dependency.

import (
	"math"
	"testing"

	mathlib "github.com/exitthematrix26/remote_builder/examples/math-rbe/lib"
)

func TestMultiply(t *testing.T) {
	cases := []struct {
		a, b, want float64
	}{
		{2, 3, 6},
		{0, 100, 0},
		{-4, 5, -20},
		{1.5, 2.0, 3.0},
		{0.1, 0.2, 0.020000000000000004}, // floating-point precision case
	}
	for _, c := range cases {
		got := mathlib.Multiply(c.a, c.b)
		if math.Abs(got-c.want) > 1e-9 {
			t.Errorf("Multiply(%v, %v) = %v; want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestDivide(t *testing.T) {
	cases := []struct {
		a, b    float64
		want    float64
		wantErr bool
	}{
		{10, 2, 5, false},
		{7, 2, 3.5, false},
		{-9, 3, -3, false},
		{1, 0, 0, true},        // exact zero
		{1, 1e-13, 0, true},    // within epsilon — treated as zero
		{100, 0.5, 200, false},
	}
	for _, c := range cases {
		got, err := mathlib.Divide(c.a, c.b)
		if c.wantErr {
			if err == nil {
				t.Errorf("Divide(%v, %v): expected error, got %v", c.a, c.b, got)
			}
		} else {
			if err != nil {
				t.Errorf("Divide(%v, %v): unexpected error %v", c.a, c.b, err)
			} else if math.Abs(got-c.want) > 1e-9 {
				t.Errorf("Divide(%v, %v) = %v; want %v", c.a, c.b, got, c.want)
			}
		}
	}
}

func TestCompute(t *testing.T) {
	cases := []struct {
		a, b   float64
		op     mathlib.Op
		wantOk bool
	}{
		{6, 3, mathlib.OpMultiply, true},
		{6, 3, mathlib.OpDivide, true},
		{6, 0, mathlib.OpDivide, false}, // div-by-zero → Err populated
		{6, 3, "pow", false},            // unknown op
	}
	for _, c := range cases {
		r := mathlib.Compute(c.a, c.b, c.op)
		hasErr := r.Err != ""
		if c.wantOk && hasErr {
			t.Errorf("Compute(%v,%v,%v): unexpected error %q", c.a, c.b, c.op, r.Err)
		}
		if !c.wantOk && !hasErr {
			t.Errorf("Compute(%v,%v,%v): expected error, got output %v", c.a, c.b, c.op, r.Output)
		}
	}
}
