// stats_test.cc — unit tests for the stats library using GoogleTest.
//
// GoogleTest in Bazel:
//   bazel_dep(name = "googletest", version = "1.15.2")  in MODULE.bazel
//   deps = ["@googletest//:gtest_main"]                 in cc_test
//
// @googletest//:gtest_main provides main() so we just write TEST() macros.
// Each cc_test is a separate compile+link action on RBE.
#include "cc/stats.h"

#include <cmath>
#include <gtest/gtest.h>
#include <vector>

namespace stats {

TEST(ComputeTest, EmptyInput) {
    Summary s = Compute({});
    EXPECT_EQ(s.count, 0);
    EXPECT_DOUBLE_EQ(s.mean, 0.0);
    EXPECT_DOUBLE_EQ(s.stddev, 0.0);
}

TEST(ComputeTest, SingleValue) {
    Summary s = Compute({42.0});
    EXPECT_EQ(s.count, 1);
    EXPECT_DOUBLE_EQ(s.mean, 42.0);
    EXPECT_DOUBLE_EQ(s.stddev, 0.0);
    EXPECT_DOUBLE_EQ(s.min, 42.0);
    EXPECT_DOUBLE_EQ(s.max, 42.0);
}

TEST(ComputeTest, BasicStats) {
    // values: 2, 4, 4, 4, 5, 5, 7, 9
    // mean = 5, stddev(pop) = sqrt(4) = 2
    std::vector<double> v = {2, 4, 4, 4, 5, 5, 7, 9};
    Summary s = Compute(v);
    EXPECT_EQ(s.count, 8);
    EXPECT_DOUBLE_EQ(s.mean, 5.0);
    EXPECT_NEAR(s.stddev, 2.0, 1e-9);
    EXPECT_DOUBLE_EQ(s.min, 2.0);
    EXPECT_DOUBLE_EQ(s.max, 9.0);
}

TEST(ComputeTest, NegativeValues) {
    std::vector<double> v = {-3.0, -1.0, 1.0, 3.0};
    Summary s = Compute(v);
    EXPECT_DOUBLE_EQ(s.mean, 0.0);
    EXPECT_DOUBLE_EQ(s.min, -3.0);
    EXPECT_DOUBLE_EQ(s.max, 3.0);
}

TEST(ToJSONTest, ContainsExpectedKeys) {
    Summary s;
    s.count = 10;
    s.error_count = 1;
    s.mean = 3.14;
    s.stddev = 0.5;
    s.min = 1.0;
    s.max = 9.0;
    std::string json = ToJSON(s);
    EXPECT_NE(json.find("\"count\":10"), std::string::npos);
    EXPECT_NE(json.find("\"error_count\":1"), std::string::npos);
    EXPECT_NE(json.find("\"mean\":"), std::string::npos);
    EXPECT_NE(json.find("\"stddev\":"), std::string::npos);
    EXPECT_NE(json.find("\"min\":"), std::string::npos);
    EXPECT_NE(json.find("\"max\":"), std::string::npos);
}

} // namespace stats
