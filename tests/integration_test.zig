//! 集成测试入口 — 单文件可执行，集中管理所有集成测试用例。
//!
//! 结构：
//!   - 统一 Setup: DebugAllocator (内存泄漏检测) + Io + TestRunner
//!   - 各模块 test_xxx() 函数顺序执行
//!   - 统一 Teardown: 内存泄漏检查 + 结果汇总
//!
//! 运行：
//!   zig build test-integration

const std = @import("std");
const common = @import("common");

const test_tcp = @import("test_tcp_frame.zig");
const test_lsa = @import("test_lsa_routing.zig");
const test_dpipe = @import("test_dpipe_relay.zig");
const test_svc = @import("test_svc_install.zig");
const test_exec = @import("test_exec_e2e.zig");
const test_upload = @import("test_upload_e2e.zig");
const test_download = @import("test_download_e2e.zig");
const test_upgrade = @import("test_upgrade_e2e.zig");
const test_ipc = @import("test_ipc_e2e.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;

    // ── Setup ──
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("\n*** 内存泄漏检测: 存在泄漏! ***\n", .{});
            std.process.exit(1);
        }
        std.debug.print("内存检查: 无泄漏\n", .{});
    }
    const alloc = gpa.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var runner = common.TestRunner{};

    // ── 按顺序执行各模块测试 ──
    std.debug.print("\n=== 集成测试开始 ===\n", .{});

    test_tcp.test_tcp_frame(io, alloc, &runner) catch |err| {
        std.debug.print("test_tcp_frame 异常终止: {}\n", .{err});
    };

    test_lsa.test_lsa_routing(io, alloc, &runner) catch |err| {
        std.debug.print("test_lsa_routing 异常终止: {}\n", .{err});
    };

    test_dpipe.test_dpipe_relay(io, alloc, &runner) catch |err| {
        std.debug.print("test_dpipe_relay 异常终止: {}\n", .{err});
    };

    test_svc.test_svc_install(io, alloc, &runner) catch |err| {
        std.debug.print("test_svc_install 异常终止: {}\n", .{err});
    };

    test_exec.test_exec_e2e(io, alloc, &runner) catch |err| {
        std.debug.print("test_exec_e2e 异常终止: {}\n", .{err});
    };

    test_upload.test_upload_e2e(io, alloc, &runner) catch |err| {
        std.debug.print("test_upload_e2e 异常终止: {}\n", .{err});
    };

    test_download.test_download_e2e(io, alloc, &runner) catch |err| {
        std.debug.print("test_download_e2e 异常终止: {}\n", .{err});
    };

    test_upgrade.test_upgrade_e2e(io, alloc, &runner) catch |err| {
        std.debug.print("test_upgrade_e2e 异常终止: {}\n", .{err});
    };

    test_ipc.test_ipc_e2e(io, alloc, &runner) catch |err| {
        std.debug.print("test_ipc_e2e 异常终止: {}\n", .{err});
    };

    // ── Teardown ──
    std.debug.print("\n=== 集成测试结果 ===\n", .{});
    const all_pass = runner.summary();
    if (!all_pass) {
        std.process.exit(1);
    }
}
