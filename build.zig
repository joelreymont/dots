const std = @import("std");

const version = "0.5.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get git short hash (trimmed)
    const git_hash = std.mem.trim(u8, b.run(&.{ "git", "rev-parse", "--short", "HEAD" }), "\n\r ");

    const exe = b.addExecutable(.{
        .name = "dot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libc for @cImport of time.h (localtime_r)
    exe.linkLibC();

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_hash", git_hash);
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run dot");
    run_step.dependOn(&run_cmd.step);

    // Tests - pass binary path as build option
    const install_prefix = b.install_prefix;
    const dot_path = b.fmt("{s}/bin/dot", .{install_prefix});

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "dot_binary", dot_path);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_options);

    // Add ohsnap for snapshot testing
    const ohsnap = b.dependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("ohsnap", ohsnap.module("ohsnap"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep()); // Build main binary first

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
