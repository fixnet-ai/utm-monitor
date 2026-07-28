const std = @import("std");

/// Map build target to versioned deployment filename.
/// Reads ver.txt via @embedFile at build time and appends '-VERSION' suffix.
/// Windows: version is inserted before .exe (utmm-x86_64-windows-0.11.19.exe).
/// See utm-vm/MANUAL.md §6.x for the full compatibility matrix.
///
/// 32-bit x86 Windows uses x86-windows-gnu target triple (not x86-windows).
/// Native x86-windows pulls in MinGW _system@4 which triggers a linker warning
/// that Zig 0.16.0 promotes to error. x86-windows-gnu avoids this — the binary
/// is valid PE32 i386 and runs correctly despite the build summary showing "failure".
fn deploymentFilename(b: *std.Build, target: std.Target) []const u8 {
    const embedded_ver = @embedFile("src/ver.txt");
    const version = if (embedded_ver.len > 0 and embedded_ver[embedded_ver.len - 1] == '\n')
        embedded_ver[0 .. embedded_ver.len - 1]
    else
        embedded_ver[0..embedded_ver.len :0];

    const base = switch (target.cpu.arch) {
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

    // Native/default binary stays as plain "utmm" (no version suffix).
    // Only cross-compiled platform targets get the version suffix.
    if (std.mem.eql(u8, base, "utmm")) return "utmm";

    if (target.os.tag == .windows) {
        // base ends with ".exe" — insert version before it
        return b.fmt("{s}-{s}.exe", .{ base[0 .. base.len - 4], version });
    }
    return b.fmt("{s}-{s}", .{ base, version });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Step 1: Build utmmd (supervisor daemon) ──
    const utmmd = b.addExecutable(.{
        .name = "utmmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utmmd.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (target.result.os.tag == .windows) {
        utmmd.root_module.linkSystemLibrary("ws2_32", .{});
    }

    // Copy utmmd binary to src/embed/ for @embedFile by main.zig.
    // addInstallBinFile writes to zig-out/ — use system copy command instead.
    const embed_dir = "src/embed";
    const embed_path = b.fmt("{s}/utmmd.bin", .{embed_dir});
    const copy_utmmd = b.addSystemCommand(&.{ "cp", "-f" });
    copy_utmmd.addFileArg(utmmd.getEmittedBin());
    copy_utmmd.addArg(embed_path);
    copy_utmmd.step.dependOn(&utmmd.step);

    // Pre-compute SHA256 hash of utmmd.bin so main.zig can embed it at compile
    // time without expensive comptime hashing (>20M eval branches for ~2MB binary).
    const hash_utmmd = b.addSystemCommand(&.{ "sh", "-c" });
    hash_utmmd.addArg(b.fmt(
        "shasum -a 256 {s} | cut -d' ' -f1 | tr -d '\\n' > {s}/utmmd.sha256",
        .{ embed_path, embed_dir },
    ));
    hash_utmmd.step.dependOn(&copy_utmmd.step);

    // ── Step 2: Build utmm (main binary, embeds utmmd + sha256) ──
    const exe = b.addExecutable(.{
        .name = "utmm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.step.dependOn(&hash_utmmd.step);

    // Windows: link ws2_32 (may be needed by Zig runtime for socket operations)
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    b.installArtifact(exe);

    // Deployment binary with unified filename (e.g. utmm-aarch64-linux, utmm-x86_64-macos, utmm-x86_64-windows.exe)
    // Host reads serve-dir by these names; protocol.deploymentFilename() does the mapping at runtime
    {
        const target_filename = deploymentFilename(b, target.result);
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

    // Tests — main binary tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    // Tests — refac/layered-arch new modules (P0-P5) + TCP/SOCKS4
    const refac_modules = [_][]const u8{
        "tcpf.zig",
        "socks4.zig",
        "netconn.zig",
    };
    for (refac_modules) |mod_src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}", .{mod_src})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (target.result.os.tag == .windows) {
            mod.linkSystemLibrary("ws2_32", .{});
        }
        const mod_tests = b.addTest(.{ .root_module = mod });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        test_step.dependOn(&run_mod_tests.step);
    }
}
