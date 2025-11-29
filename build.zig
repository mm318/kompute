const std = @import("std");
const builtin = @import("builtin");

const cpp_flags = &.{
    "-std=c++14",
    "-Wall",
    "-Wextra",
    "-Wpedantic",
};

const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
    critical,
    off,

    fn parseLogLevel(log_level_str: []const u8, optimize: std.builtin.OptimizeMode) LogLevel {
        if (std.ascii.eqlIgnoreCase(log_level_str, "trace")) {
            return .trace;
        } else if (std.ascii.eqlIgnoreCase(log_level_str, "debug")) {
            return .debug;
        } else if (std.ascii.eqlIgnoreCase(log_level_str, "info")) {
            return .info;
        } else if (std.ascii.eqlIgnoreCase(log_level_str, "warn")) {
            return .warn;
        } else if (std.ascii.eqlIgnoreCase(log_level_str, "error")) {
            return .err;
        } else if (std.ascii.eqlIgnoreCase(log_level_str, "critical")) {
            return .critical;
        } else if (std.ascii.eqlIgnoreCase(log_level_str, "off")) {
            return .off;
        } else {
            if (!std.ascii.eqlIgnoreCase(log_level_str, "default")) {
                std.log.err("Unknown log level '{s}', falling back to Default", .{log_level_str});
            }
            return switch (optimize) {
                .Debug => .debug,
                else => .info,
            };
        }
    }
};

fn makeCxxModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    srcs: []const []const u8,
    log_level: LogLevel,
    flags: []const []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    mod.addCSourceFiles(.{ .files = srcs, .flags = flags });

    const log_macro = switch (log_level) {
        .trace => "KOMPUTE_LOG_LEVEL_TRACE",
        .debug => "KOMPUTE_LOG_LEVEL_DEBUG",
        .info => "KOMPUTE_LOG_LEVEL_INFO",
        .warn => "KOMPUTE_LOG_LEVEL_WARN",
        .err => "KOMPUTE_LOG_LEVEL_ERROR",
        .critical => "KOMPUTE_LOG_LEVEL_CRITICAL",
        .off => "KOMPUTE_LOG_LEVEL_OFF",
    };
    mod.addCMacro("KOMPUTE_OPT_ACTIVE_LOG_LEVEL", log_macro);
    mod.addCMacro("KOMPUTE_OPT_LOG_LEVEL_DISABLED", if (log_level == .off) "1" else "0");
    // mod.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");   // unnecessary

    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tests = b.option(bool, "enable-tests", "Build the kompute_tests executable") orelse false;
    const enable_benchmark = b.option(bool, "enable-benchmark", "Build the kompute_benchmark executable") orelse false;
    const log_level_str = b.option([]const u8, "log-level", "Trace|Debug|Info|Warn|Error|Critical|Off|Default") orelse "Default";
    const log_level = LogLevel.parseLogLevel(log_level_str, optimize);

    const fmt_dep = b.dependency("fmt", .{});
    const fmt_artifact = fmt_dep.artifact("fmt");

    const logger_module = makeCxxModule(b, target, optimize, &.{"src/logger/Logger.cpp"}, log_level, cpp_flags);
    logger_module.addIncludePath(b.path("src/include"));
    logger_module.addIncludePath(fmt_artifact.getEmittedIncludeTree());
    const kp_logger = b.addLibrary(.{
        .name = "kp_logger",
        .root_module = logger_module,
        .linkage = .static,
    });
    kp_logger.installHeadersDirectory(fmt_artifact.getEmittedIncludeTree(), "", .{ .include_extensions = null });
    b.installArtifact(kp_logger);

    const kompute_module = makeCxxModule(
        b,
        target,
        optimize,
        &.{
            "src/Algorithm.cpp",
            "src/Core.cpp",
            "src/Image.cpp",
            "src/Manager.cpp",
            "src/Memory.cpp",
            "src/OpAlgoDispatch.cpp",
            "src/OpCopy.cpp",
            "src/OpMemoryBarrier.cpp",
            "src/OpSyncDevice.cpp",
            "src/OpSyncLocal.cpp",
            "src/Sequence.cpp",
            "src/Tensor.cpp",
        },
        log_level,
        cpp_flags,
    );
    kompute_module.addIncludePath(b.path("src/include"));
    kompute_module.addIncludePath(b.path("src/shaders/glsl"));
    kompute_module.linkLibrary(kp_logger);
    kompute_module.linkSystemLibrary("vulkan", .{});
    kompute_module.linkSystemLibrary("pthread", .{});
    const kompute = b.addLibrary(.{
        .name = "kompute",
        .root_module = kompute_module,
        .linkage = .static,
    });
    kompute.installHeadersDirectory(kp_logger.getEmittedIncludeTree(), "", .{ .include_extensions = null });
    kompute.installHeadersDirectory(b.path("src/include"), "", .{ .include_extensions = null });
    kompute.installHeadersDirectory(b.path("src/shaders/glsl"), "", .{ .include_extensions = &.{".hpp"} });
    b.installArtifact(kompute);

    add_tests(b, target, optimize, kompute, log_level);

    if (enable_tests or enable_benchmark) {
        // const gtest_paths = buildGTest(b, target, optimize, cpp_flags) catch {
        //     std.log.err("GoogleTest sources not found; install libgtest-dev", .{});
        //     @panic("missing gtest sources");
        // };

        // if (enable_tests) {
        //     const test_shader_dir = blk: {
        //         const generated = b.addWriteFiles();
        //         const endian_big = builtin.target.cpu.arch.endian() == .big;
        //         const shaders = [_]struct { src: []const u8, out: []const u8 }{
        //             .{ .src = "test/shaders/glsl/test_logistic_regression_shader.comp", .out = "test_logistic_regression_shader.hpp" },
        //             .{ .src = "test/shaders/glsl/test_op_custom_shader.comp", .out = "test_op_custom_shader.hpp" },
        //             .{ .src = "test/shaders/glsl/test_workgroup_shader.comp", .out = "test_workgroup_shader.hpp" },
        //             .{ .src = "test/shaders/glsl/test_shader.comp", .out = "test_shader.hpp" },
        //         };
        //         for (shaders) |shader| {
        //             const header = shaderHeader(
        //                 b,
        //                 glslang.?,
        //                 cmake_exe.?,
        //                 shader.src,
        //                 shader.out,
        //                 endian_big,
        //             );
        //             _ = generated.addCopyFile(header, shader.out);
        //         }
        //         break :blk generated.getDirectory();
        //     };

        //     const tests_module = makeCxxModule(b, target, optimize);
        //     tests_module.addCSourceFiles(.{
        //         .files = &.{
        //             "test/TestAsyncOperations.cpp",
        //             "test/TestDestroy.cpp",
        //             "test/TestImage.cpp",
        //             "test/TestLogisticRegression.cpp",
        //             "test/TestManager.cpp",
        //             "test/TestMultipleAlgoExecutions.cpp",
        //             "test/TestOpCopyImage.cpp",
        //             "test/TestOpCopyImageToTensor.cpp",
        //             "test/TestOpCopyTensor.cpp",
        //             "test/TestOpCopyTensorToImage.cpp",
        //             "test/TestOpImageCreate.cpp",
        //             "test/TestOpShadersFromStringAndFile.cpp",
        //             "test/TestOpSync.cpp",
        //             "test/TestOpTensorCreate.cpp",
        //             "test/TestPushConstant.cpp",
        //             "test/TestSequence.cpp",
        //             "test/TestSpecializationConstant.cpp",
        //             "test/TestTensor.cpp",
        //             "test/TestWorkgroup.cpp",
        //             "test/shaders/Utils.cpp",
        //         },
        //         .flags = cpp_flags,
        //     });
        //     tests_module.addIncludePath(b.path("src/include"));
        //     tests_module.addIncludePath(shader_include_dir);
        //     tests_module.addIncludePath(fmt_include);
        //     tests_module.addIncludePath(b.path("test"));
        //     tests_module.addIncludePath(test_shader_dir);
        //     tests_module.addIncludePath(gtest_paths.include_dir);
        //     applyKomputeMacros(tests_module, log_macro, disable_logging);
        //     tests_module.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");
        //     tests_module.addCMacro("FMT_HEADER_ONLY", "1");
        //     tests_module.linkLibrary(kompute);
        //     tests_module.linkLibrary(kp_logger);
        //     tests_module.linkLibrary(gtest_paths.gtest_main);
        //     tests_module.linkSystemLibrary("vulkan", .{});
        //     tests_module.linkSystemLibrary("pthread", .{});

        //     const kompute_tests = b.addExecutable(.{
        //         .name = "kompute_tests",
        //         .root_module = tests_module,
        //     });

        //     b.installArtifact(kompute_tests);
        //     b.step("kompute_tests", "Build the kompute_tests executable").dependOn(&kompute_tests.step);
        //     const run_tests = b.addRunArtifact(kompute_tests);
        //     b.step("test", "Run kompute_tests").dependOn(&run_tests.step);
        // }

        // if (enable_benchmark) {
        //     const benchmark_module = makeCxxModule(b, target, optimize);
        //     benchmark_module.addCSourceFiles(.{
        //         .files = &.{
        //             "benchmark/TestBenchmark.cpp",
        //             "benchmark/shaders/Utils.cpp",
        //         },
        //         .flags = cpp_flags,
        //     });
        //     benchmark_module.addIncludePath(b.path("src/include"));
        //     benchmark_module.addIncludePath(shader_include_dir);
        //     benchmark_module.addIncludePath(fmt_include);
        //     benchmark_module.addIncludePath(b.path("benchmark"));
        //     benchmark_module.addIncludePath(gtest_paths.include_dir);
        //     applyKomputeMacros(benchmark_module, log_macro, disable_logging);
        //     benchmark_module.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");
        //     benchmark_module.addCMacro("FMT_HEADER_ONLY", "1");
        //     benchmark_module.linkLibrary(kompute);
        //     benchmark_module.linkLibrary(kp_logger);
        //     benchmark_module.linkLibrary(gtest_paths.gtest_main);
        //     benchmark_module.linkSystemLibrary("vulkan", .{});
        //     benchmark_module.linkSystemLibrary("pthread", .{});

        //     const kompute_benchmark = b.addExecutable(.{
        //         .name = "kompute_benchmark",
        //         .root_module = benchmark_module,
        //     });

        //     b.installArtifact(kompute_benchmark);
        //     b.step("kompute_benchmark", "Build the kompute_benchmark executable").dependOn(&kompute_benchmark.step);
        // }
    }
}

fn add_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    kompute: *std.Build.Step.Compile,
    log_level: LogLevel,
) void {
    const googletest_dep = b.dependency("googletest", .{
        .target = target,
        .optimize = optimize,
    });
    const gtest_main = googletest_dep.artifact("gtest_main");

    // const test_shader_dir = blk: {
    //     const generated = b.addWriteFiles();
    //     const endian_big = builtin.target.cpu.arch.endian() == .big;
    //     const shaders = [_]struct { src: []const u8, out: []const u8 }{
    //         .{ .src = "test/shaders/glsl/test_logistic_regression_shader.comp", .out = "test_logistic_regression_shader.hpp" },
    //         .{ .src = "test/shaders/glsl/test_op_custom_shader.comp", .out = "test_op_custom_shader.hpp" },
    //         .{ .src = "test/shaders/glsl/test_workgroup_shader.comp", .out = "test_workgroup_shader.hpp" },
    //         .{ .src = "test/shaders/glsl/test_shader.comp", .out = "test_shader.hpp" },
    //     };
    //     for (shaders) |shader| {
    //         const header = shaderHeader(
    //             b,
    //             glslang.?,
    //             cmake_exe.?,
    //             shader.src,
    //             shader.out,
    //             endian_big,
    //         );
    //         _ = generated.addCopyFile(header, shader.out);
    //     }
    //     break :blk generated.getDirectory();
    // };

    const tests_module = makeCxxModule(
        b,
        target,
        optimize,
        &.{
            "test/TestAsyncOperations.cpp",
            "test/TestDestroy.cpp",
            "test/TestImage.cpp",
            "test/TestLogisticRegression.cpp",
            "test/TestManager.cpp",
            "test/TestMultipleAlgoExecutions.cpp",
            "test/TestOpCopyImage.cpp",
            "test/TestOpCopyImageToTensor.cpp",
            "test/TestOpCopyTensor.cpp",
            "test/TestOpCopyTensorToImage.cpp",
            "test/TestOpImageCreate.cpp",
            "test/TestOpShadersFromStringAndFile.cpp",
            "test/TestOpSync.cpp",
            "test/TestOpTensorCreate.cpp",
            "test/TestPushConstant.cpp",
            "test/TestSequence.cpp",
            "test/TestSpecializationConstant.cpp",
            "test/TestTensor.cpp",
            "test/TestWorkgroup.cpp",
            "test/shaders/Utils.cpp",
        },
        log_level,
        cpp_flags,
    );
    tests_module.addIncludePath(b.path("test"));
    tests_module.addIncludePath(kompute.getEmittedIncludeTree());
    tests_module.linkLibrary(kompute);
    tests_module.linkLibrary(gtest_main);
    const kompute_tests = b.addExecutable(.{
        .name = "kompute_tests",
        .root_module = tests_module,
    });
    kompute_tests.step.dependOn(b.getInstallStep());

    const run_tests = b.addRunArtifact(kompute_tests);
    b.step("test", "Run kompute_tests").dependOn(&run_tests.step);
}

fn shaderHeader(
    b: *std.Build,
    glslang: []const u8,
    cmake: []const u8,
    source: []const u8,
    out_basename: []const u8,
    is_big_endian: bool,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{glslang});
    compile.addArg("-V");
    compile.addFileArg(b.path(source));
    compile.addArg("-o");
    const stem = std.fs.path.stem(source);
    const spv = compile.addOutputFileArg(b.fmt("{s}.spv", .{stem}));

    const header = b.addSystemCommand(&.{cmake});
    header.step.dependOn(&compile.step);
    header.addPrefixedFileArg("-DINPUT_SHADER_FILE=", spv);
    const header_path = header.addPrefixedOutputFileArg("-DOUTPUT_HEADER_FILE=", out_basename);
    header.addArg("-DHEADER_NAMESPACE=kp");
    header.addArg(if (is_big_endian) "-DIS_BIG_ENDIAN=1" else "-DIS_BIG_ENDIAN=0");
    header.addArg("-P");
    header.addFileArg(b.path("cmake/bin_file_to_header.cmake"));
    return header_path;
}
