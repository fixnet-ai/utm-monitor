const std = @import("std");

/// Map build target to simplified deployment filename
/// See MANUAL.md §6.x for the full compatibility matrix
fn deploymentFilename(target: std.Target) []const u8 {
    return switch (target.cpu.arch) {
        .x86 => switch (target.os.tag) {
            .windows => "utmm.exe",
            .linux => "utmm",
            else => "utmm",
        },
        .x86_64 => switch (target.os.tag) {
            .macos => "utmm.macos",
            .linux => "utmm",
            .windows => "utmm.exe",
            else => "utmm",
        },
        .aarch64 => switch (target.os.tag) {
            .macos => "utmm_arm64.macos",
            .linux => "utmm_arm64",
            .windows => "utmm.exe",
            else => "utmm",
        },
        else => "utmm",
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "utmm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Deployment binary with simplified filename (e.g. utmm.macos, utmm.exe, utmm_arm64)
    // Host reads serve-dir by these names; protocol.deploymentFilename() does the mapping at runtime
    {
        const target_filename = deploymentFilename(target.result);
        const target_install = b.addInstallBinFile(exe.getEmittedBin(), target_filename);
        target_install.step.dependOn(&exe.step);
        b.getInstallStep().dependOn(&target_install.step);
    }

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run utmm");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
