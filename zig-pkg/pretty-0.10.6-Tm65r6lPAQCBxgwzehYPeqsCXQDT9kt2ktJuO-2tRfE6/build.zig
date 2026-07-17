const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export as module to be available for @import("pretty") on user site
    const pretty_module = b.addModule("pretty", .{
        .root_source_file = b.path("src/pretty.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compile library
    const lib = b.addLibrary(.{
        .name = "pretty",
        .root_module = pretty_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Run tests
    const tests = b.addTest(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const step_tests = b.addRunArtifact(tests);

    b.step("test", "Run pretty tests").dependOn(&step_tests.step);

    // Run demo
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.linkLibC();
    const step_demo = b.addRunArtifact(demo);

    b.step("run", "Run pretty demo").dependOn(&step_demo.step);
}
