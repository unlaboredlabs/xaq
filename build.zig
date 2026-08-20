const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("xaq", .{
        .root_source_file = b.path("src/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "xaq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            // ReleaseSmall has no useful symbolic backtraces after stripping.
            // Drop unwind metadata so the shipped executable keeps its size
            // contract as interactive features grow.
            .unwind_tables = if (optimize == .ReleaseSmall) .none else null,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run xaq").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const module_tests = b.addTest(.{ .root_module = module });
    const run_module_tests = b.addRunArtifact(module_tests);
    const perf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/perf.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_perf_tests = b.addRunArtifact(perf_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_perf_tests.step);

    // Keep the benchmarks independent from the selected build mode. They
    // always measure the stripped ReleaseSmall artifact shipped by the project.
    const perf_target = b.addExecutable(.{
        .name = "xaq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSmall,
            .strip = true,
            .unwind_tables = .none,
        }),
    });
    const perf_runner = b.addExecutable(.{
        .name = "xaq-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/perf.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_perf = b.addRunArtifact(perf_runner);
    run_perf.addArtifactArg(perf_target);
    if (b.args) |args| run_perf.addArgs(args);
    const run_perf_pty = b.addSystemCommand(&.{"python3"});
    run_perf_pty.addFileArg(b.path("tools/perf-pty.py"));
    run_perf_pty.addArtifactArg(perf_target);
    if (b.args) |args| run_perf_pty.addArgs(args);
    // Avoid benchmark contention: terminal readiness runs after the short
    // process-startup samples complete.
    run_perf_pty.step.dependOn(&run_perf.step);
    b.step("perf", "Test ReleaseSmall startup and prompt readiness").dependOn(&run_perf_pty.step);

    // Compile without installing: fast feedback and ZLS build-on-save diagnostics.
    b.step("check", "Type-check without installing").dependOn(&exe.step);

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src", "tools" } });
    b.step("fmt", "Format source in place").dependOn(&fmt.step);
}
