//! exec 断连取消传播集成测试 — 验证「连接生命周期 = 命令生命周期」：
//!
//! Host 断开连接（模拟 agent 取消 / CLI Ctrl-C）→ Guest watcher 检测到
//! → 杀 shell 进程组 → handleExecCmd 快速返回（而非等命令自然跑完）。
//!
//! 用真实 dpipe_shell + 真实子进程验证（POSIX only；Windows 真机验证）。

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("testlib");
const common = @import("common");
const protocol = lib.protocol;
const tcp = lib.tcp;
const guest_mod = lib.guest;

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// handleExecCmd 线程包装：结束后置 finished（std.Thread.join 无超时，
/// 主线程用 deadline 轮询 finished 防测试挂死；失败路径由进程退出兜底）。
const ExecRunner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    info: guest_mod.SystemInfo,
    conn: protocol.Connection,
    payload: []const u8,
    finished: std.atomic.Value(bool),

    fn run(self: *ExecRunner) void {
        guest_mod.handleExecCmd(self.io, self.allocator, self.info, &self.conn, self.payload, null) catch |err| {
            std.debug.print("handleExecCmd error: {}\n", .{err});
        };
        self.finished.store(true, .release);
    }
};

/// 轮询等待条件（50ms 步进），超时返回 false。cond 由调用方闭包提供。
fn waitUntil(io: std.Io, timeout_ns: u64, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) bool {
    const deadline = std.Io.Timestamp.now(io, .awake);
    while (std.Io.Timestamp.now(io, .awake).nanoseconds - deadline.nanoseconds < timeout_ns) {
        if (cond(ctx)) return true;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
    return cond(ctx);
}

pub fn test_exec_cancel(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner) !void {
    if (builtin.os.tag == .windows) {
        var tc = runner.case("exec-cancel: Windows 跳过");
        tc.skip("Windows pipe 模式 + cmd.exe 场景由真机验证");
        tc.deinit();
        return;
    }

    const shell_path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
    const info = guest_mod.SystemInfo{
        .hostname = "testvm",
        .ip = "127.0.0.1",
        .mac = "00:00:00:00:00:00",
        .target = "test-target",
        .iface_name = "lo0",
        .shell = shell_path,
    };

    scenarioDisconnectKillsCommand(io, alloc, runner, info) catch |err| {
        std.debug.print("scenarioDisconnectKillsCommand 异常: {}\n", .{err});
    };
    scenarioNaturalCompletion(io, alloc, runner, info, shell_path);
}

/// 场景 1: Host 断开 → 远端命令被杀（不应等满 sleep 30）
fn scenarioDisconnectKillsCommand(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner, info: guest_mod.SystemInfo) !void {
    {
        var tc = runner.case("exec-cancel: 断连取消杀死远端命令");

        var tmp = common.TempDir.create(io, alloc, "utmm-cancel-") catch |err| {
            std.debug.print("TempDir.create failed: {}\n", .{err});
            tc.skip("无法创建临时目录");
            tc.deinit();
            return;
        };
        defer tmp.deinit();
        const started_path = try tmp.join("started");
        defer alloc.free(started_path);
        const alive_path = try tmp.join("alive");
        defer alloc.free(alive_path);

        const pair = try common.makePair();

        // 命令：touch started 证明已启动；sleep 30 模拟长命令；
        // touch alive 只在未被杀而自然跑完时出现（断言其不存在）。
        const cmd = try std.fmt.allocPrint(alloc, "touch {s}; sleep 30; touch {s}", .{ started_path, alive_path });
        defer alloc.free(cmd);
        const cmd_with_marker = try protocol.buildCmdWithMarker(alloc, info.shell, cmd);
        defer alloc.free(cmd_with_marker);
        const frame = try protocol.buildPtyExecInput(alloc, "cancel-1", cmd_with_marker);
        defer alloc.free(frame);

        var exec_runner = ExecRunner{
            .io = io,
            .allocator = alloc,
            .info = info,
            .conn = .{ .fd = pair.a, .alive = true },
            .payload = frame[1..],
            .finished = std.atomic.Value(bool).init(false),
        };
        const t = try std.Thread.spawn(.{}, ExecRunner.run, .{&exec_runner});

        // 等待命令确实启动（started 文件出现；shell spawn 可能需要 ~1s）
        const StartedCtx = struct { io: std.Io, path: []const u8 };
        const sc = StartedCtx{ .io = io, .path = started_path };
        const started = waitUntil(io, 5_000_000_000, sc, struct {
            fn check(c: StartedCtx) bool {
                return fileExists(c.io, c.path);
            }
        }.check);
        tc.expectTrue(started, "命令已启动（started 文件出现）");

        // 模拟 Host 断连：agent 取消 → Host shutdown + close Guest 连接
        common.sockShutdown(pair.b, 2);
        common.sockClose(pair.b);

        // handleExecCmd 应在 3s 内返回（远小于 sleep 30 的自然时长）
        const FinCtx = struct { flag: *std.atomic.Value(bool) };
        const fc = FinCtx{ .flag = &exec_runner.finished };
        const returned = waitUntil(io, 3_000_000_000, fc, struct {
            fn check(c: FinCtx) bool {
                return c.flag.load(.acquire);
            }
        }.check);
        tc.expectTrue(returned, "断连后 handleExecCmd 3s 内返回（命令被杀而非跑完 sleep 30）");

        // 再观察 1s：alive 若出现 = 命令未被杀（进程组击杀失效）
        if (returned) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            tc.expectTrue(!fileExists(io, alive_path), "进程组被杀（alive 未创建）");
        }

        // 失败兜底：join 最长等 sleep 30 自然结束（有界），成功路径立即返回
        t.join();
        common.sockClose(pair.a);
        tc.deinit();
    }
}

/// 场景 2: 命令自然完成不受 watcher 干扰（回归）
fn scenarioNaturalCompletion(io: std.Io, alloc: std.mem.Allocator, runner: *common.TestRunner, info: guest_mod.SystemInfo, shell_path: []const u8) void {
    {
        var tc = runner.case("exec-cancel: 自然完成不受 watcher 干扰");

        const pair = common.makePair() catch {
            tc.skip("无法创建 socketpair");
            tc.deinit();
            return;
        };

        const cmd_with_marker = protocol.buildCmdWithMarker(alloc, shell_path, "echo natural_ok") catch {
            tc.skip("buildCmdWithMarker 失败");
            tc.deinit();
            return;
        };
        defer alloc.free(cmd_with_marker);
        const frame = protocol.buildPtyExecInput(alloc, "natural-1", cmd_with_marker) catch {
            tc.skip("buildPtyExecInput 失败");
            tc.deinit();
            return;
        };
        defer alloc.free(frame);

        var exec_runner = ExecRunner{
            .io = io,
            .allocator = alloc,
            .info = info,
            .conn = .{ .fd = pair.a, .alive = true },
            .payload = frame[1..],
            .finished = std.atomic.Value(bool).init(false),
        };
        const t = std.Thread.spawn(.{}, ExecRunner.run, .{&exec_runner}) catch {
            tc.skip("线程创建失败");
            tc.deinit();
            return;
        };

        // 读帧直到 pty_exec_done（对端行为良好：任何失败路径都会发 done(-1)，
        // 帧必然到达；与 test_exec_e2e 的阻塞 recvFrame 模式一致）
        var exit_code: ?i32 = null;
        while (true) {
            const f = protocol.recvFrame(alloc, pair.b) catch break;
            defer alloc.free(f);
            if (f.len < 1) continue;
            if (f[0] == @intFromEnum(protocol.MsgType.pty_exec_done)) {
                const pd = protocol.parsePtyExecDone(f[1..]) orelse break;
                exit_code = pd.exit_code;
                break;
            }
        }
        tc.expect(exit_code != null, "收到 pty_exec_done（自然完成路径未被误杀）", .{});
        if (exit_code) |ec| {
            tc.expectEqual(@as(i32, 0), ec, "exit code = 0（MDELIM 标记正常传播）");
        }

        // handleExecCmd 应在 done 后快速返回（watcher join ≤250ms + 善后）
        const FinCtx = struct { flag: *std.atomic.Value(bool) };
        const fc = FinCtx{ .flag = &exec_runner.finished };
        const returned = waitUntil(io, 3_000_000_000, fc, struct {
            fn check(c: FinCtx) bool {
                return c.flag.load(.acquire);
            }
        }.check);
        tc.expectTrue(returned, "自然完成后 handleExecCmd 3s 内返回（watcher 无拖延）");

        t.join();
        common.sockClose(pair.a);
        tc.deinit();
    }
}
