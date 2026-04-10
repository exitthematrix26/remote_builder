load("@rules_go//go:def.bzl", "go_binary")

# gazelle:prefix github.com/exitthematrix26/remote_builder/examples/hello-bazel

go_binary(
    name = "hello",
    srcs = ["main.go"],
    # visibility = ["//visibility:public"] only needed if other packages import this
)
