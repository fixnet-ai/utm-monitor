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

    // Copy utmmd binary to target-specific embed directory for @embedFile by main.zig.
    // Each target gets its own subdir (e.g., src/embed/aarch64-linux/utmmd.bin)
    // so cross-compiling for multiple targets never overwrites the wrong binary.
    const embed_dir = "src/embed";
    const target_dir = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });
    const target_embed_dir = b.fmt("{s}/{s}", .{ embed_dir, target_dir });
    const embed_path = b.fmt("{s}/utmmd.bin", .{target_embed_dir});

    // Ensure target-specific embed subdirectory exists
    const mkdir_embed = b.addSystemCommand(&.{ "mkdir", "-p" });
    mkdir_embed.addArg(target_embed_dir);

    const copy_utmmd = b.addSystemCommand(&.{ "cp", "-f" });
    copy_utmmd.addFileArg(utmmd.getEmittedBin());
    copy_utmmd.addArg(embed_path);
    copy_utmmd.step.dependOn(&utmmd.step);
    copy_utmmd.step.dependOn(&mkdir_embed.step);

    // Pre-compute SHA256 hash of utmmd.bin so main.zig can embed it at compile
    // time without expensive comptime hashing (>20M eval branches for ~2MB binary).
    const hash_utmmd = b.addSystemCommand(&.{ "sh", "-c" });
    hash_utmmd.addArg(b.fmt(
        "shasum -a 256 {s} | cut -d' ' -f1 | tr -d '\\n' > {s}/utmmd.sha256",
        .{ embed_path, target_embed_dir },
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

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run utmm");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests");

    // Tests — main binary tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    // Run test binary directly via manual Run step to avoid --listen=- protocol
    // hang on macOS (Darwin 25). addRunArtifact would inject --listen=- which
    // deadlocks on this platform. Manually creating the Run step and adding the
    // artifact as argv[0] skips enableTestRunnerMode, so the binary prints results
    // to stdout without the server protocol.
    {
        const run_tests = std.Build.Step.Run.create(b, "run test");
        run_tests.addArtifactArg(exe_tests);
        run_tests.expectExitCode(0);
        test_step.dependOn(&run_tests.step);
    }

    // Standalone test binaries for modules whose tests are not transitively
    // compiled into the main binary through main.zig's @import chain.
    // tcp.zig and lsa.zig tests are already in the main binary (via host.zig),
    // so they are NOT included here to avoid test duplication.
    const standalone_test_modules = [_][]const u8{
        "dpipe.zig",
        "dpipe_shell.zig",
        "dpipe_file.zig",
        "guest.zig",
        "shm.zig",
    };
    for (standalone_test_modules) |mod_src| {
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
        // Same workaround: run directly to avoid --listen=- protocol hang.
        const run_mod_tests = std.Build.Step.Run.create(b, b.fmt("run test {s}", .{mod_src}));
        run_mod_tests.addArtifactArg(mod_tests);
        run_mod_tests.expectExitCode(0);
        test_step.dependOn(&run_mod_tests.step);
    }

    // ── Integration tests (tests/ directory) ──
    // Each test is a standalone executable with pub fn main().
    // Run independently via ./zig-out/bin/<name> or via "zig build test-integration".
    //
    // Zig 0.16.0: one file = one module. Tests import "testlib" (re-exports all src/*
    // as pub const) and "common" (test helpers). No per-file src modules — that would
    // conflict with internal relative @import chains within src files.

    const testlib_mod = b.createModule(.{
        .root_source_file = b.path("src/testlib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_common_mod = b.createModule(.{
        .root_source_file = b.path("tests/common.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Cross-compile all 8 targets in parallel ──
    // zig build cross -Doptimize=ReleaseSafe
    const cross_step = b.step("cross", "Cross-compile all 8 deployment targets in parallel");

    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
        .{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    };

    for (cross_targets) |query| {
        const tgt = b.resolveTargetQuery(query);

        // Build utmmd for this target
        const cross_utmmd = b.addExecutable(.{
            .name = "utmmd",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/utmmd.zig"),
                .target = tgt,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        if (tgt.result.os.tag == .windows) {
            cross_utmmd.root_module.linkSystemLibrary("ws2_32", .{});
        }

        // Copy utmmd to embed dir（使用解析后的 target，非 query 可选字段）
        const cross_embed_dir = b.fmt("{s}-{s}", .{
            @tagName(tgt.result.cpu.arch),
            @tagName(tgt.result.os.tag),
        });
        const cross_target_embed_dir = b.fmt("src/embed/{s}", .{cross_embed_dir});
        const cross_embed_path = b.fmt("{s}/utmmd.bin", .{cross_target_embed_dir});

        const cross_mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
        cross_mkdir.addArg(cross_target_embed_dir);

        const cross_copy = b.addSystemCommand(&.{ "cp", "-f" });
        cross_copy.addFileArg(cross_utmmd.getEmittedBin());
        cross_copy.addArg(cross_embed_path);
        cross_copy.step.dependOn(&cross_utmmd.step);
        cross_copy.step.dependOn(&cross_mkdir.step);

        // Hash utmmd for this target
        const cross_hash = b.addSystemCommand(&.{ "sh", "-c" });
        cross_hash.addArg(b.fmt(
            "shasum -a 256 {s} | cut -d' ' -f1 | tr -d '\\n' > {s}/utmmd.sha256",
            .{ cross_embed_path, cross_target_embed_dir },
        ));
        cross_hash.step.dependOn(&cross_copy.step);

        // Build utmm for this target
        const cross_exe = b.addExecutable(.{
            .name = "utmm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = tgt,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        cross_exe.step.dependOn(&cross_hash.step);
        if (tgt.result.os.tag == .windows) {
            cross_exe.root_module.linkSystemLibrary("ws2_32", .{});
        }

        // Install with deployment filename
        const cross_filename = deploymentFilename(b, tgt.result);
        const cross_install = b.addInstallBinFile(cross_exe.getEmittedBin(), cross_filename);
        cross_install.step.dependOn(&cross_exe.step);

        cross_step.dependOn(&cross_install.step);
    }

    // ── Integration tests ──
    // Single executable with flat test files, shared setup/teardown, memory leak check.
    // Each module defines pub fn test_xxx(io, alloc, runner) — no main() needed.
    const test_integration_step = b.step("test-integration", "Run integration tests");

    const integration_test = b.addExecutable(.{
        .name = "integration_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    integration_test.root_module.addImport("testlib", testlib_mod);
    integration_test.root_module.addImport("common", test_common_mod);

    if (target.result.os.tag == .windows) {
        integration_test.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const run_integration = b.addRunArtifact(integration_test);
    test_integration_step.dependOn(&run_integration.step);
    b.installArtifact(integration_test);
}
