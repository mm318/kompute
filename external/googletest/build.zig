const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const googletest_dep = b.dependency("googletest", .{});

    const gtest = b.addLibrary(.{
        .name = "gtest",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gtest.addCSourceFile(.{ .file = googletest_dep.path("googletest/src/gtest-all.cc") });
    gtest.addIncludePath(googletest_dep.path("googletest")); // because "gtest-all.cc" includes "src/*.cc"...
    gtest.addIncludePath(googletest_dep.path("googletest/include"));
    gtest.linkLibCpp();
    gtest.installHeadersDirectory(googletest_dep.path("googletest/include"), ".", .{});
    b.installArtifact(gtest);

    const gtest_main = b.addLibrary(.{
        .name = "gtest_main",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gtest_main.addCSourceFile(.{ .file = googletest_dep.path("googletest/src/gtest_main.cc") });
    gtest_main.linkLibrary(gtest);
    gtest_main.installHeadersDirectory(googletest_dep.path("googletest/include"), ".", .{});
    b.installArtifact(gtest_main);

    const gmock = b.addLibrary(.{
        .name = "gmock",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gmock.addCSourceFile(.{ .file = googletest_dep.path("googlemock/src/gmock-all.cc") });
    gmock.addIncludePath(googletest_dep.path("googlemock")); // because "gmock-all.cc" includes "src/*.cc"...
    gmock.addIncludePath(googletest_dep.path("googlemock/include"));
    gmock.linkLibrary(gtest);
    gmock.installHeadersDirectory(googletest_dep.path("googlemock/include"), ".", .{});
    gmock.installHeadersDirectory(googletest_dep.path("googletest/include"), ".", .{}); // transitive dependency
    b.installArtifact(gmock);

    const gmock_main = b.addLibrary(.{
        .name = "gmock_main",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    gmock_main.addCSourceFile(.{ .file = googletest_dep.path("googlemock/src/gmock_main.cc") });
    gmock_main.linkLibrary(gmock);
    gmock_main.installHeadersDirectory(googletest_dep.path("googlemock/include"), ".", .{});
    gmock_main.installHeadersDirectory(googletest_dep.path("googletest/include"), ".", .{}); // transitive dependency
    b.installArtifact(gmock_main);
}
