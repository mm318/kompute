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
    kp_logger.installLibraryHeaders(fmt_artifact);
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
    const op_mult_header = shaderHeader(b, "src/shaders/glsl/ShaderOpMult.comp", kompute_module);
    const logistic_reg_header = shaderHeader(b, "src/shaders/glsl/ShaderLogisticRegression.comp", kompute_module);
    kompute_module.linkLibrary(kp_logger);
    kompute_module.linkSystemLibrary("vulkan", .{});
    kompute_module.linkSystemLibrary("pthread", .{});
    const kompute = b.addLibrary(.{
        .name = "kompute",
        .root_module = kompute_module,
        .linkage = .static,
    });
    kompute.installLibraryHeaders(kp_logger);
    kompute.installHeadersDirectory(b.path("src/include"), "", .{ .include_extensions = null });
    kompute.installHeader(op_mult_header, op_mult_header.basename(b, null));
    kompute.installHeader(logistic_reg_header, logistic_reg_header.basename(b, null));
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
    src_path: []const u8,
    mod: *std.Build.Module,
) std.Build.LazyPath {
    const source_filestem = std.fs.path.stem(src_path);
    const source_fileext = std.fs.path.extension(src_path);

    const stage = blk: {
        if (std.ascii.eqlIgnoreCase(source_fileext, ".vert")) {
            break :blk "vertex";
        } else if (std.ascii.eqlIgnoreCase(source_fileext, ".frag")) {
            break :blk "fragment";
        } else {
            break :blk "compute";
        }
    };
    const spv_filename = b.fmt("{s}.spv", .{source_filestem});

    const generated = b.addWriteFiles();

    const compile = b.addSystemCommand(&.{ "slangc", "-target", "spirv", "-entry", "main", "-stage", stage, "-O3" });
    compile.addFileArg(b.path(src_path));
    compile.addArg("-o");
    const spv_file = compile.addOutputFileArg(spv_filename);
    _ = generated.addCopyFile(spv_file, spv_filename);

    const symbol = shaderSymbolName(b, source_filestem, source_fileext);
    const zig_source = b.fmt(
        \\const spv_data = @embedFile("{s}");
        \\
        \\pub export const {s}_DATA: [*]const u8 = spv_data.ptr;
        \\pub export const {s}_SIZE: usize = spv_data.len;
        \\
    ,
        .{ spv_filename, symbol, symbol },
    );
    const spv_objsrc = generated.add(b.fmt("{s}_data.zig", .{source_filestem}), zig_source);

    const c_source = b.fmt(
        \\#ifndef _{s}_H_
        \\#define _{s}_H_
        \\
        \\#include <stdint.h>
        \\
        \\extern const uint8_t* {s}_DATA;
        \\extern const uint32_t {s}_SIZE;
        \\
        \\#endif
        \\
    ,
        .{ symbol, symbol, symbol, symbol },
    );
    const spv_header = generated.add(b.fmt("{s}.h", .{source_filestem}), c_source);

    const obj = b.addObject(.{
        .name = b.fmt("{s}", .{source_filestem}),
        .root_module = b.createModule(.{
            .root_source_file = spv_objsrc,
            .target = mod.resolved_target,
            .optimize = mod.optimize,
        }),
    });

    mod.addObject(obj);

    return spv_header;
}

fn shaderSymbolName(b: *std.Build, stem: []const u8, ext: []const u8) []const u8 {
    std.debug.assert(stem.len > 0);

    var builder = std.ArrayList(u8).initCapacity(b.allocator, 64) catch @panic("OOM");

    appendUpperIdent(b.allocator, &builder, stem);
    if (ext.len > 0) {
        std.debug.assert(ext[0] == '.');
        appendUpperIdent(b.allocator, &builder, ext);
    }
    builder.appendSlice(b.allocator, "_SPV") catch @panic("OOM");

    const raw = builder.toOwnedSlice(b.allocator) catch @panic("OOM");

    return raw;
}

fn appendUpperIdent(gpa: std.mem.Allocator, str: *std.ArrayList(u8), text: []const u8) void {
    for (text) |c| {
        const upper = std.ascii.toUpper(c);
        str.append(gpa, if (std.ascii.isAlphanumeric(upper)) upper else '_') catch @panic("OOM");
    }
}
