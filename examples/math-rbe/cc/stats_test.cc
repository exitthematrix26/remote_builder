// stats_test.cc — unit tests for the stats library.
//
// Uses a minimal hand-rolled test harness (EXPECT_EQ / EXPECT_NEAR macros)
// rather than GoogleTest.  GoogleTest's BCR package (1.17.0) carries
// cc_library calls without the load() statements required by Bazel 9, making
// it incompatible.  A simple harness keeps the build portable and teaches
// that cc_test is just a cc_binary with a failing exit code — no framework
// required.
#include "stats.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

// ── Minimal test harness ─────────────────────────────────────────────────────

static int failures = 0;
static int checks   = 0;

#define EXPECT_EQ(a, b) do { \
    ++checks; \
    if ((a) != (b)) { \
        std::fprintf(stderr, "FAIL %s:%d  expected %s == %s  (%g != %g)\n", \
                     __FILE__, __LINE__, #a, #b, (double)(a), (double)(b)); \
        ++failures; \
    } \
} while(0)

#define EXPECT_NEAR(a, b, tol) do { \
    ++checks; \
    if (std::fabs((double)(a) - (double)(b)) > (tol)) { \
        std::fprintf(stderr, "FAIL %s:%d  |%s - %s| > %g  (%g vs %g)\n", \
                     __FILE__, __LINE__, #a, #b, (double)(tol), (double)(a), (double)(b)); \
        ++failures; \
    } \
} while(0)

#define EXPECT_TRUE(expr) do { \
    ++checks; \
    if (!(expr)) { \
        std::fprintf(stderr, "FAIL %s:%d  expected true: %s\n", \
                     __FILE__, __LINE__, #expr); \
        ++failures; \
    } \
} while(0)

static const char* current_test = "";
#define TEST(name) \
    static void test_##name(); \
    struct _reg_##name { _reg_##name() { current_test = #name; test_##name(); } } _inst_##name; \
    static void test_##name()

// ── Tests ─────────────────────────────────────────────────────────────────────

TEST(EmptyInput) {
    stats::Summary s = stats::Compute({});
    EXPECT_EQ(s.count, 0);
    EXPECT_NEAR(s.mean,   0.0, 1e-12);
    EXPECT_NEAR(s.stddev, 0.0, 1e-12);
}

TEST(SingleValue) {
    stats::Summary s = stats::Compute({42.0});
    EXPECT_EQ(s.count, 1);
    EXPECT_NEAR(s.mean,   42.0, 1e-9);
    EXPECT_NEAR(s.stddev,  0.0, 1e-9);
    EXPECT_NEAR(s.min,    42.0, 1e-9);
    EXPECT_NEAR(s.max,    42.0, 1e-9);
}

TEST(BasicStats) {
    // values: 2, 4, 4, 4, 5, 5, 7, 9  →  mean=5, stddev(pop)=2
    std::vector<double> v = {2, 4, 4, 4, 5, 5, 7, 9};
    stats::Summary s = stats::Compute(v);
    EXPECT_EQ(s.count, 8);
    EXPECT_NEAR(s.mean,   5.0, 1e-9);
    EXPECT_NEAR(s.stddev, 2.0, 1e-9);
    EXPECT_NEAR(s.min,    2.0, 1e-9);
    EXPECT_NEAR(s.max,    9.0, 1e-9);
}

TEST(NegativeValues) {
    std::vector<double> v = {-3.0, -1.0, 1.0, 3.0};
    stats::Summary s = stats::Compute(v);
    EXPECT_NEAR(s.mean, 0.0,  1e-9);
    EXPECT_NEAR(s.min,  -3.0, 1e-9);
    EXPECT_NEAR(s.max,   3.0, 1e-9);
}

TEST(ToJSONContainsKeys) {
    stats::Summary s;
    s.count = 10; s.error_count = 1;
    s.mean = 3.14; s.stddev = 0.5; s.min = 1.0; s.max = 9.0;
    std::string json = stats::ToJSON(s);
    EXPECT_TRUE(json.find("\"count\":10")       != std::string::npos);
    EXPECT_TRUE(json.find("\"error_count\":1")  != std::string::npos);
    EXPECT_TRUE(json.find("\"mean\":")          != std::string::npos);
    EXPECT_TRUE(json.find("\"stddev\":")        != std::string::npos);
    EXPECT_TRUE(json.find("\"min\":")           != std::string::npos);
    EXPECT_TRUE(json.find("\"max\":")           != std::string::npos);
}

// ── main ──────────────────────────────────────────────────────────────────────

int main() {
    // Tests auto-register via static constructors above.
    if (failures == 0) {
        std::printf("PASSED  (%d checks)\n", checks);
        return 0;
    }
    std::fprintf(stderr, "FAILED  %d / %d checks failed\n", failures, checks);
    return 1;
}
