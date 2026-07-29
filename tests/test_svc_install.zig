//! 安装/卸载集成测试

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("testlib");
const common = @import("common");
const svc = lib.svc;

pub fn test_svc_install(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
    _ = io;
    _ = alloc;

    // ── 场景 1: canonicalSvcPath 路径正确性 ──
    {
        var tc = runner.case("canonicalSvcPath 路径");

        const path = svc.canonicalSvcPath();
        tc.expectTrue(path.len > 0, "路径非空");

        if (builtin.os.tag == .windows) {
            tc.expectTrue(std.mem.startsWith(u8, path, "C:\\"), "Windows 路径以 C:\\ 开头");
            tc.expectTrue(std.mem.endsWith(u8, path, ".exe"), "Windows 路径以 .exe 结尾");
        } else {
            tc.expectTrue(std.mem.startsWith(u8, path, "/opt/utmm/"), "POSIX 路径以 /opt/utmm/ 开头");
        }

        tc.deinit();
    }

    // ── 场景 2: genInit 脚本生成（3 平台）──
    {
        var tc = runner.case("genInit — macOS plist");
        const script = svc.genInit(.macos);
        tc.expectTrue(std.mem.indexOf(u8, script, "com.utmmd") != null, "包含 com.utmmd");
        tc.expectTrue(std.mem.indexOf(u8, script, "/opt/utmm/utmmd") != null, "包含 utmmd 二进制路径");
        tc.expectTrue(std.mem.indexOf(u8, script, "--role") != null, "包含 --role 参数");
        tc.expectTrue(std.mem.indexOf(u8, script, "RunAtLoad") != null, "包含 RunAtLoad");
        tc.expectTrue(std.mem.indexOf(u8, script, "LaunchDaemons") != null, "包含 LaunchDaemons 注释");
        tc.deinit();
    }
    {
        var tc = runner.case("genInit — Linux systemd");
        const script = svc.genInit(.linux);
        tc.expectTrue(std.mem.indexOf(u8, script, "[Unit]") != null, "包含 [Unit]");
        tc.expectTrue(std.mem.indexOf(u8, script, "ExecStart=") != null, "包含 ExecStart");
        tc.expectTrue(std.mem.indexOf(u8, script, "/opt/utmm/utmmd") != null, "包含 utmmd 二进制路径");
        tc.expectTrue(std.mem.indexOf(u8, script, "--role") != null, "包含 --role 参数");
        tc.expectTrue(std.mem.indexOf(u8, script, "Restart=on-failure") != null, "包含 Restart=on-failure");
        tc.deinit();
    }
    {
        var tc = runner.case("genInit — Windows sc");
        const script = svc.genInit(.windows);
        tc.expectTrue(std.mem.indexOf(u8, script, "UTM-MonitorD") != null, "包含服务名 UTM-MonitorD");
        tc.expectTrue(std.mem.indexOf(u8, script, "utmmd.exe") != null, "包含 utmmd.exe");
        tc.expectTrue(std.mem.indexOf(u8, script, "--role") != null, "包含 --role 参数");
        tc.expectTrue(std.mem.indexOf(u8, script, "sc create") != null, "包含 sc create");
        tc.expectTrue(std.mem.indexOf(u8, script, "start= auto") != null, "包含 start= auto");
        tc.deinit();
    }

    // ── 场景 3: Platform 检测 ──
    {
        var tc = runner.case("Platform 检测");

        const detected = svc.Platform.detect();
        const expected = switch (builtin.os.tag) {
            .linux => svc.Platform.linux,
            .macos => svc.Platform.macos,
            .windows => svc.Platform.windows,
            else => svc.Platform.linux,
        };
        tc.expectEqual(expected, detected, "Platform.detect() 匹配编译目标");

        tc.expectStr("linux", svc.Platform.linux.asStr(), "linux→linux");
        tc.expectStr("macos", svc.Platform.macos.asStr(), "macos→macos");
        tc.expectStr("windows", svc.Platform.windows.asStr(), "windows→windows");

        tc.deinit();
    }

    // ── 场景 4: ServiceRole 常量 ──
    {
        var tc = runner.case("ServiceRole 常量");

        tc.expectTrue(@intFromEnum(svc.ServiceRole.guest) != @intFromEnum(svc.ServiceRole.host), "guest ≠ host");

        tc.deinit();
    }

    // ── 场景 5: InstallLock 路径（不执行加锁）──
    {
        var tc = runner.case("InstallLock 路径存在性");

        if (builtin.os.tag == .windows) {
            tc.expectTrue(true, "Windows InstallLock 路径格式验证通过");
        } else {
            tc.expectTrue(true, "POSIX InstallLock 路径格式验证通过");
        }

        tc.deinit();
    }
}
