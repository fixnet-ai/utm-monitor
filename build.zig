const std = @import("std");

/// Map build target to versioned deployment filename.
/// Reads ver.txt via @embedFile at build time and appends '-VERSION' suffix.
/// Windows: version is inserted before .exe (utmm-x86_64-windows-0.17.16.exe).
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

/// macOS 代码签名：为二进制构建签名 step（原地 codesign）。
///
/// 构建期用正式开发者证书签名（替代历史 adhoc），目标设备安装不再因签名
/// 缺失/失效被 AMFI 拒载（Apple Silicon SIGKILL）。身份解析优先级：
///   1. `-Dsign-identity`（SHA-1 哈希或证书名；"-" 强制 adhoc）
///   2. 环境变量 UTMM_CODESIGN_IDENTITY
///   3. 自动探测：Developer ID Application 优先，其次 Apple Development
///      （取 find-identity 输出中的哈希签名，规避同名多证书的 ambiguous 歧义）
///   4. 均无（CI / 无证书环境）→ adhoc "-"
///
/// utmmd 必须在嵌入 main.zig 之前签名：内嵌副本与运行期提取到磁盘的副本
/// 字节一致（utmmd.sha256 一致），运行期验签通过即不再重签。
/// 运行期重签点（svc.zig/utmmd.zig/main.zig）均为「先验签后重签」——已有
/// 有效签名的二进制不会被 adhoc 覆盖降级。
fn addMacosSignStep(
    b: *std.Build,
    identity: []const u8,
    bin: std.Build.LazyPath,
    depends_on: *std.Build.Step,
) *std.Build.Step {
    const sign = if (std.mem.eql(u8, identity, "-")) blk: {
        // 显式 adhoc
        const s = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-" });
        s.addFileArg(bin);
        break :blk s;
    } else if (identity.len > 0) blk: {
        // 显式身份：sh -c 'codesign ... "$1" "$0"' IDENTITY PATH（$0=路径 $1=身份）
        const s = b.addSystemCommand(&.{ "sh", "-c", "exec codesign --force --sign \"$1\" \"$0\"" });
        s.addArg(identity);
        s.addFileArg(bin);
        break :blk s;
    } else blk: {
        // 自动探测（step 执行时解析；找不到证书回退 adhoc "-"）
        const s = b.addSystemCommand(&.{"sh", "-c",
            \\ident="$UTMM_CODESIGN_IDENTITY"
            \\[ -n "$ident" ] || ident=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')
            \\[ -n "$ident" ] || ident=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
            \\exec codesign --force --sign "${ident:--}" "$0"
        });
        s.addFileArg(bin);
        break :blk s;
    };
    sign.step.dependOn(depends_on);
    return &sign.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── macOS 签名身份 ──（见 addMacosSignStep 注释）
    const sign_identity = b.option([]const u8, "sign-identity", "macOS codesign identity (SHA-1 hash or certificate name; '-' = force adhoc; default: $UTMM_CODESIGN_IDENTITY or auto-detect)") orelse "";

    // ── zio dependency ──
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_mod = zio_dep.module("zio");

    // ── utmmd rebuild gate ──
    // release.sh 显式决定：supervisor（utmmd）没变 → -Dutmmd=false 复用现有
    // src/embed/<target>/utmmd.bin（字节不变 → 内嵌哈希不变 → deploy 的哈希
    // 检查完全跳过 utmmd 更新，避免全队 service stop/replace/restart 复杂路径）。
    // supervisor 源码有变 → -Dutmmd=true 重建并重嵌。默认 true（开发直跑
    // `zig build` 行为不变）。
    const rebuild_utmmd = b.option(bool, "utmmd", "Rebuild + re-embed the utmmd supervisor (default: true)") orelse true;

    // ── Step 1: Build utmmd (supervisor daemon) — 仅在 rebuild_utmmd 时 ──
    // ReleaseSafe on aarch64-windows produces incorrect code (crash 1067).
    // ReleaseSmall also crashed (c0000005 ACCESS VIOLATION in ucrtbase.dll).
    // Using Debug for Windows avoids cross-compiled optimizer bugs. utmmd is
    // a minimal supervisor (~429KB), so Debug size is not a concern.
    var hash_utmmd_step: ?*std.Build.Step = null;
    if (rebuild_utmmd) {
        const utmmd_optimize: std.builtin.OptimizeMode = if (target.result.os.tag == .windows)
            .Debug
        else
            optimize;
        const utmmd = b.addExecutable(.{
            .name = "utmmd",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/utmmd.zig"),
                .target = target,
                .optimize = utmmd_optimize,
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
        const embed_path = b.fmt("{s}/utmmd.bin", .{target_embed_dir });

        // Ensure target-specific embed subdirectory exists
        const mkdir_embed = b.addSystemCommand(&.{ "mkdir", "-p" });
        mkdir_embed.addArg(target_embed_dir);

        const copy_utmmd = b.addSystemCommand(&.{ "cp", "-f" });
        copy_utmmd.addFileArg(utmmd.getEmittedBin());
        copy_utmmd.addArg(embed_path);
        copy_utmmd.step.dependOn(&utmmd.step);
        copy_utmmd.step.dependOn(&mkdir_embed.step);
        // macOS: 必须嵌入「已签名」的 utmmd —— 内嵌副本与运行期提取到磁盘的
        // 副本字节一致（utmmd.sha256 一致），运行期验签通过即不再重签。
        if (target.result.os.tag == .macos) {
            copy_utmmd.step.dependOn(addMacosSignStep(b, sign_identity, utmmd.getEmittedBin(), &utmmd.step));
        }

        // Pre-compute SHA256 hash of utmmd.bin so main.zig can embed it at compile
        // time without expensive comptime hashing (>20M eval branches for ~2MB binary).
        const hash_utmmd = b.addSystemCommand(&.{ "sh", "-c" });
        hash_utmmd.addArg(b.fmt(
            "shasum -a 256 {s} | cut -d' ' -f1 | tr -d '\\n' > {s}/utmmd.sha256",
            .{ embed_path, target_embed_dir },
        ));
        hash_utmmd.step.dependOn(&copy_utmmd.step);
        hash_utmmd_step = &hash_utmmd.step;
    }

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
    exe.root_module.addImport("zio", zio_mod);
    if (hash_utmmd_step) |hs| exe.step.dependOn(hs);

    // Windows: link ws2_32 (may be needed by Zig runtime for socket operations)
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    // macOS: 构建后签名（正式证书，见 addMacosSignStep）——Apple Silicon 对
    // 签名缺失/失效的二进制直接 SIGKILL。签名必须先于一切 install 拷贝：
    // installArtifact 的 Copy 步骤与本签名步骤都直接依赖 exe.step，若不显式
    // 排序，Copy 可能抢在签名前把未签（linker adhoc）产物拷出去。
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    var macos_sign_step: ?*std.Build.Step = null;
    if (target.result.os.tag == .macos) {
        macos_sign_step = addMacosSignStep(b, sign_identity, exe.getEmittedBin(), &exe.step);
        install_exe.step.dependOn(macos_sign_step.?);
    }

    // Deployment binary with unified filename (e.g. utmm-aarch64-linux, utmm-x86_64-macos, utmm-x86_64-windows.exe)
    // Host reads serve-dir by these names; protocol.deploymentFilename() does the mapping at runtime
    {
        const target_filename = deploymentFilename(b, target.result);
        const target_install = b.addInstallBinFile(exe.getEmittedBin(), target_filename);
        target_install.step.dependOn(&exe.step);
        // macOS: 部署副本必须落在签名之后（serve-dir 的二进制也要有有效签名）
        if (macos_sign_step) |ss| target_install.step.dependOn(ss);
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
        "utmmd.zig",
        "ipc.zig",
    };
    for (standalone_test_modules) |mod_src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}", .{mod_src})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // dpipe.zig and guest.zig import zio — make it available for standalone tests
        mod.addImport("zio", zio_mod);
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
    testlib_mod.addImport("zio", zio_mod);
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

        // utmmd rebuild gate — 与单目标路径同一 -Dutmmd 选项
        var cross_hash_step: ?*std.Build.Step = null;
        if (rebuild_utmmd) {
            // Build utmmd for this target (Debug for Windows — see note above)
            const cross_utmmd_optimize: std.builtin.OptimizeMode = if (tgt.result.os.tag == .windows)
                .Debug
            else
                optimize;
            const cross_utmmd = b.addExecutable(.{
                .name = "utmmd",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/utmmd.zig"),
                    .target = tgt,
                    .optimize = cross_utmmd_optimize,
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
            // macOS: 与本机构建一致 —— 嵌入「已签名」的 utmmd（见 addMacosSignStep）
            if (tgt.result.os.tag == .macos) {
                cross_copy.step.dependOn(addMacosSignStep(b, sign_identity, cross_utmmd.getEmittedBin(), &cross_utmmd.step));
            }

            // Hash utmmd for this target
            const cross_hash = b.addSystemCommand(&.{ "sh", "-c" });
            cross_hash.addArg(b.fmt(
                "shasum -a 256 {s} | cut -d' ' -f1 | tr -d '\\n' > {s}/utmmd.sha256",
                .{ cross_embed_path, cross_target_embed_dir },
            ));
            cross_hash.step.dependOn(&cross_copy.step);
            cross_hash_step = &cross_hash.step;
        }

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
        cross_exe.root_module.addImport("zio", zio_mod);
        if (cross_hash_step) |chs| cross_exe.step.dependOn(chs);
        if (tgt.result.os.tag == .windows) {
            cross_exe.root_module.linkSystemLibrary("ws2_32", .{});
        }

        // Install with deployment filename
        const cross_filename = deploymentFilename(b, tgt.result);
        const cross_install = b.addInstallBinFile(cross_exe.getEmittedBin(), cross_filename);
        cross_install.step.dependOn(&cross_exe.step);

        // macOS: 交叉编译产物构建期签名（正式证书，见 addMacosSignStep）
        if (tgt.result.os.tag == .macos) {
            cross_install.step.dependOn(addMacosSignStep(b, sign_identity, cross_exe.getEmittedBin(), &cross_exe.step));
        }

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
    integration_test.root_module.addImport("zio", zio_mod);

    if (target.result.os.tag == .windows) {
        integration_test.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const run_integration = b.addRunArtifact(integration_test);
    test_integration_step.dependOn(&run_integration.step);
    b.installArtifact(integration_test);
}
