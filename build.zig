const std = @import("std");
const builtin = @import("builtin");

const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
    critical,
    off,
};

pub fn build(b: *std.Build) void {
    const resolved_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tests = b.option(bool, "enable-tests", "Build the kompute_tests executable") orelse false;
    const enable_benchmark = b.option(bool, "enable-benchmark", "Build the kompute_benchmark executable") orelse false;
    const rebuild_shaders = b.option(bool, "build-shaders", "Recompile GLSL into SPIR-V headers for the core library") orelse false;
    const fmt_override = b.option([]const u8, "fmt-include", "Override the fmt include directory") orelse null;
    const glslang_override = b.option([]const u8, "glslang", "Path to glslangValidator") orelse null;
    const log_level_raw = b.option([]const u8, "log-level", "Trace|Debug|Info|Warn|Error|Critical|Off|Default") orelse "Default";

    const log_level = parseLogLevel(log_level_raw, optimize);
    const log_macro = logMacro(log_level);
    const disable_logging = log_level == .off;

    const fmt_include = setupFmt(b, fmt_override) catch {
        std.log.err("fmt headers not found; set -Dfmt-include or install libfmt-dev", .{});
        @panic("missing fmt headers");
    };

    const cpp_flags = &.{
        "-std=c++14",
        "-Wall",
        "-Wextra",
        "-Wpedantic",
    };

    const need_shader_tools = rebuild_shaders or enable_tests;
    var glslang: ?[]const u8 = null;
    var cmake_exe: ?[]const u8 = null;
    if (need_shader_tools) {
        cmake_exe = b.findProgram(&.{"cmake"}, &.{}) catch {
            @panic("cmake is required to convert SPIR-V binaries to headers");
        };
        glslang = findGlslang(b, glslang_override) orelse {
            @panic("glslangValidator is required for shader compilation");
        };
    }

    const shader_include_dir = blk: {
        if (!rebuild_shaders) {
            const copied = b.addWriteFiles();
            _ = copied.addCopyFile(b.path("src/shaders/glsl/ShaderOpMult.hpp.in"), "ShaderOpMult.hpp");
            _ = copied.addCopyFile(b.path("src/shaders/glsl/ShaderLogisticRegression.hpp.in"), "ShaderLogisticRegression.hpp");
            break :blk copied.getDirectory();
        }

        const generated = b.addWriteFiles();
        const endian_big = builtin.target.cpu.arch.endian() == .big;
        const header_a = shaderHeader(
            b,
            glslang.?,
            cmake_exe.?,
            "src/shaders/glsl/ShaderOpMult.comp",
            "ShaderOpMult.hpp",
            endian_big,
        );
        const header_b = shaderHeader(
            b,
            glslang.?,
            cmake_exe.?,
            "src/shaders/glsl/ShaderLogisticRegression.comp",
            "ShaderLogisticRegression.hpp",
            endian_big,
        );
        _ = generated.addCopyFile(header_a, "ShaderOpMult.hpp");
        _ = generated.addCopyFile(header_b, "ShaderLogisticRegression.hpp");
        break :blk generated.getDirectory();
    };

    const logger_module = makeCxxModule(b, resolved_target, optimize);
    logger_module.addCSourceFiles(.{
        .files = &.{"src/logger/Logger.cpp"},
        .flags = cpp_flags,
    });
    logger_module.addIncludePath(b.path("src/include"));
    logger_module.addIncludePath(fmt_include);
    applyKomputeMacros(logger_module, log_macro, disable_logging);
    logger_module.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");
    logger_module.addCMacro("FMT_HEADER_ONLY", "1");
    const kp_logger = b.addLibrary(.{
        .name = "kp_logger",
        .root_module = logger_module,
        .linkage = .static,
    });

    const kompute_module = makeCxxModule(b, resolved_target, optimize);
    kompute_module.addCSourceFiles(.{
        .files = &.{
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
        .flags = cpp_flags,
    });
    kompute_module.addIncludePath(b.path("src/include"));
    kompute_module.addIncludePath(shader_include_dir);
    kompute_module.addIncludePath(fmt_include);
    applyKomputeMacros(kompute_module, log_macro, disable_logging);
    kompute_module.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");
    kompute_module.addCMacro("FMT_HEADER_ONLY", "1");
    kompute_module.linkLibrary(kp_logger);
    kompute_module.linkSystemLibrary("vulkan", .{});
    kompute_module.linkSystemLibrary("pthread", .{});
    const kompute = b.addLibrary(.{
        .name = "kompute",
        .root_module = kompute_module,
        .linkage = .static,
    });

    b.installArtifact(kompute);
    b.installArtifact(kp_logger);
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("src/include"),
        .install_dir = .header,
        .install_subdir = "",
    });
    const install_shaders = b.addInstallDirectory(.{
        .source_dir = shader_include_dir,
        .install_dir = .header,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_headers.step);
    b.getInstallStep().dependOn(&install_shaders.step);
    b.step("kompute", "Build the kompute static library").dependOn(&kompute.step);

    if (enable_tests or enable_benchmark) {
        const gtest_paths = buildGTest(b, resolved_target, optimize, cpp_flags) catch {
            std.log.err("GoogleTest sources not found; install libgtest-dev", .{});
            @panic("missing gtest sources");
        };

        if (enable_tests) {
            const test_shader_dir = blk: {
                const generated = b.addWriteFiles();
                const endian_big = builtin.target.cpu.arch.endian() == .big;
                const shaders = [_]struct { src: []const u8, out: []const u8 }{
                    .{ .src = "test/shaders/glsl/test_logistic_regression_shader.comp", .out = "test_logistic_regression_shader.hpp" },
                    .{ .src = "test/shaders/glsl/test_op_custom_shader.comp", .out = "test_op_custom_shader.hpp" },
                    .{ .src = "test/shaders/glsl/test_workgroup_shader.comp", .out = "test_workgroup_shader.hpp" },
                    .{ .src = "test/shaders/glsl/test_shader.comp", .out = "test_shader.hpp" },
                };
                for (shaders) |shader| {
                    const header = shaderHeader(
                        b,
                        glslang.?,
                        cmake_exe.?,
                        shader.src,
                        shader.out,
                        endian_big,
                    );
                    _ = generated.addCopyFile(header, shader.out);
                }
                break :blk generated.getDirectory();
            };

            const tests_module = makeCxxModule(b, resolved_target, optimize);
            tests_module.addCSourceFiles(.{
                .files = &.{
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
                .flags = cpp_flags,
            });
            tests_module.addIncludePath(b.path("src/include"));
            tests_module.addIncludePath(shader_include_dir);
            tests_module.addIncludePath(fmt_include);
            tests_module.addIncludePath(b.path("test"));
            tests_module.addIncludePath(test_shader_dir);
            tests_module.addIncludePath(gtest_paths.include_dir);
            applyKomputeMacros(tests_module, log_macro, disable_logging);
            tests_module.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");
            tests_module.addCMacro("FMT_HEADER_ONLY", "1");
            tests_module.linkLibrary(kompute);
            tests_module.linkLibrary(kp_logger);
            tests_module.linkLibrary(gtest_paths.gtest_main);
            tests_module.linkSystemLibrary("vulkan", .{});
            tests_module.linkSystemLibrary("pthread", .{});

            const kompute_tests = b.addExecutable(.{
                .name = "kompute_tests",
                .root_module = tests_module,
            });

            b.installArtifact(kompute_tests);
            b.step("kompute_tests", "Build the kompute_tests executable").dependOn(&kompute_tests.step);
            const run_tests = b.addRunArtifact(kompute_tests);
            b.step("test", "Run kompute_tests").dependOn(&run_tests.step);
        }

        if (enable_benchmark) {
            const benchmark_module = makeCxxModule(b, resolved_target, optimize);
            benchmark_module.addCSourceFiles(.{
                .files = &.{
                    "benchmark/TestBenchmark.cpp",
                    "benchmark/shaders/Utils.cpp",
                },
                .flags = cpp_flags,
            });
            benchmark_module.addIncludePath(b.path("src/include"));
            benchmark_module.addIncludePath(shader_include_dir);
            benchmark_module.addIncludePath(fmt_include);
            benchmark_module.addIncludePath(b.path("benchmark"));
            benchmark_module.addIncludePath(gtest_paths.include_dir);
            applyKomputeMacros(benchmark_module, log_macro, disable_logging);
            benchmark_module.addCMacro("KOMPUTE_OPT_USE_SPDLOG", "0");
            benchmark_module.addCMacro("FMT_HEADER_ONLY", "1");
            benchmark_module.linkLibrary(kompute);
            benchmark_module.linkLibrary(kp_logger);
            benchmark_module.linkLibrary(gtest_paths.gtest_main);
            benchmark_module.linkSystemLibrary("vulkan", .{});
            benchmark_module.linkSystemLibrary("pthread", .{});

            const kompute_benchmark = b.addExecutable(.{
                .name = "kompute_benchmark",
                .root_module = benchmark_module,
            });

            b.installArtifact(kompute_benchmark);
            b.step("kompute_benchmark", "Build the kompute_benchmark executable").dependOn(&kompute_benchmark.step);
        }
    }
}

fn makeCxxModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
}

fn applyKomputeMacros(module: *std.Build.Module, log_macro: []const u8, disable_logging: bool) void {
    module.addCMacro("KOMPUTE_OPT_ACTIVE_LOG_LEVEL", log_macro);
    module.addCMacro("KOMPUTE_OPT_LOG_LEVEL_DISABLED", if (disable_logging) "1" else "0");
}

fn logMacro(level: LogLevel) []const u8 {
    return switch (level) {
        .trace => "KOMPUTE_LOG_LEVEL_TRACE",
        .debug => "KOMPUTE_LOG_LEVEL_DEBUG",
        .info => "KOMPUTE_LOG_LEVEL_INFO",
        .warn => "KOMPUTE_LOG_LEVEL_WARN",
        .err => "KOMPUTE_LOG_LEVEL_ERROR",
        .critical => "KOMPUTE_LOG_LEVEL_CRITICAL",
        .off => "KOMPUTE_LOG_LEVEL_OFF",
    };
}

fn parseLogLevel(raw: []const u8, optimize: std.builtin.OptimizeMode) LogLevel {
    if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(raw, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(raw, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(raw, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(raw, "critical")) return .critical;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "default")) {
        return switch (optimize) {
            .Debug => .debug,
            else => .info,
        };
    }
    std.log.err("Unknown log level '{s}', falling back to Default", .{raw});
    return switch (optimize) {
        .Debug => .debug,
        else => .info,
    };
}

fn setupFmt(b: *std.Build, override: ?[]const u8) !std.Build.LazyPath {
    if (override) |path| {
        if (!pathExists(path)) return error.MissingFmt;
        return lazyPathFromString(b, path);
    }

    const candidates = [_][]const u8{
        "/usr/include/fmt",
        "/usr/local/include/fmt",
        "build/_deps/fmt-src/include",
    };
    for (candidates) |candidate| {
        if (pathExists(candidate)) {
            return lazyPathFromString(b, candidate);
        }
    }

    const bundled = "build/_deps/spdlog-src/include/spdlog/fmt/bundled";
    if (pathExists(bundled)) {
        const copied = b.addWriteFiles();
        _ = copied.addCopyDirectory(lazyPathFromString(b, bundled), "fmt", .{});
        return copied.getDirectory();
    }

    return error.MissingFmt;
}

fn findGlslang(b: *std.Build, override: ?[]const u8) ?[]const u8 {
    if (override) |path| return path;
    return b.findProgram(&.{"glslangValidator"}, &.{}) catch null;
}

fn pathExists(raw_path: []const u8) bool {
    if (std.fs.path.isAbsolute(raw_path)) {
        std.fs.accessAbsolute(raw_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(raw_path, .{}) catch return false;
    return true;
}

fn lazyPathFromString(b: *std.Build, raw_path: []const u8) std.Build.LazyPath {
    if (std.fs.path.isAbsolute(raw_path)) {
        return .{ .cwd_relative = raw_path };
    }
    return b.path(raw_path);
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

const GTestPaths = struct {
    gtest: *std.Build.Step.Compile,
    gtest_main: *std.Build.Step.Compile,
    include_dir: std.Build.LazyPath,
};

fn buildGTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cpp_flags: []const []const u8,
) !GTestPaths {
    const gtest_root = "/usr/src/googletest/googletest";
    const gtest_src = "/usr/src/googletest/googletest/src/gtest-all.cc";
    const gtest_main_src = "/usr/src/googletest/googletest/src/gtest_main.cc";
    const gtest_include = "/usr/src/googletest/googletest/include";

    if (!pathExists(gtest_src) or !pathExists(gtest_main_src) or !pathExists(gtest_include)) {
        return error.MissingGTest;
    }

    const gtest_module = makeCxxModule(b, target, optimize);
    gtest_module.addIncludePath(lazyPathFromString(b, gtest_root));
    gtest_module.addIncludePath(lazyPathFromString(b, gtest_include));
    gtest_module.addCSourceFiles(.{
        .files = &.{gtest_src},
        .flags = cpp_flags,
    });
    gtest_module.linkSystemLibrary("pthread", .{});
    const gtest = b.addLibrary(.{
        .name = "gtest",
        .root_module = gtest_module,
        .linkage = .static,
    });

    const gtest_main_module = makeCxxModule(b, target, optimize);
    gtest_main_module.addIncludePath(lazyPathFromString(b, gtest_root));
    gtest_main_module.addIncludePath(lazyPathFromString(b, gtest_include));
    gtest_main_module.addCSourceFiles(.{
        .files = &.{gtest_main_src},
        .flags = cpp_flags,
    });
    gtest_main_module.linkLibrary(gtest);
    gtest_main_module.linkSystemLibrary("pthread", .{});
    const gtest_main = b.addLibrary(.{
        .name = "gtest_main",
        .root_module = gtest_main_module,
        .linkage = .static,
    });

    return .{
        .gtest = gtest,
        .gtest_main = gtest_main,
        .include_dir = lazyPathFromString(b, gtest_include),
    };
}
