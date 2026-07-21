const std = @import("std");

/// Map build target to simplified deployment filename
/// See utm-vm/MANUAL.md §6.x for the full compatibility matrix
fn deploymentFilename(target: std.Target) []const u8 {
    return switch (target.cpu.arch) {
        .x86 => switch (target.os.tag) {
            .linux => "utmm-x86-linux",
            .windows => "utmm-x86-windows.exe",
            else => "utmm",
        },
        .x86_64 => switch (target.os.tag) {
            .linux => "utmm-x86_64-linux",
            .macos => "utmm-x86_64-macos",
            .windows => "utmm-x86_64-windows.exe",
            else => "utmm",
        },
        .aarch64 => switch (target.os.tag) {
            .linux => "utmm-aarch64-linux",
            .macos => "utmm-aarch64-macos",
            .windows => "utmm-aarch64-windows.exe",
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

    // Windows: link ws2_32 (may be needed by Zig runtime for socket operations)
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    b.installArtifact(exe);

    // Deployment binary with unified filename (e.g. utmm-aarch64-linux, utmm-x86_64-macos, utmm-x86_64-windows.exe)
    // Host reads serve-dir by these names; protocol.deploymentFilename() does the mapping at runtime
    {
        const target_filename = deploymentFilename(target.result);
        const target_install = b.addInstallBinFile(exe.getEmittedBin(), target_filename);
        target_install.step.dependOn(&exe.step);
        b.getInstallStep().dependOn(&target_install.step);
    }

    // Install scripts — copied to zig-out/bin for Host HTTP serving and distribution
    b.installBinFile("install.sh", "install.sh");
    b.installBinFile("install.bat", "install.bat");

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
