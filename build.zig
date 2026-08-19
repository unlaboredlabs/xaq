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
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_module_tests.step);

    // Compile without installing: fast feedback and ZLS build-on-save diagnostics.
    b.step("check", "Type-check without installing").dependOn(&exe.step);

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src" } });
    b.step("fmt", "Format source in place").dependOn(&fmt.step);
}
