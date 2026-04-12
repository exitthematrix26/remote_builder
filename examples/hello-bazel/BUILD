load("@rules_go//go:def.bzl", "go_binary")

# gazelle:prefix github.com/exitthematrix26/remote_builder/examples/hello-bazel

# RBE execution platform — exec_properties become REAPI platform properties in Execute requests.
# Workers register ISA=amd64, OSFamily=linux; actions must match exactly for dispatch.
# constraint_values are needed for toolchain resolution (e.g. rules_go selects linux_amd64 Go SDK).
platform(
    name = "rbe_platform",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    exec_properties = {
        "OSFamily": "Linux",   # capital L — matches EngFlow convention and worker registration
        "ISA": "x86_64",
    },
)

go_binary(
    name = "hello",
    srcs = ["main.go"],
    pure = "on",    # CGO_ENABLED=0 — no C compiler needed in the worker image
)

genrule(
    name = "echo_test",
    outs = ["echo_output.txt"],
    cmd = "echo 'hello from rbe' > $@",
)
