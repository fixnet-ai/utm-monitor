//! Auto-upgrade bootstrap — utmm-old detached self-upgrade mechanism.
//!
//! When Guest detects a version mismatch via mesh LSA, it spawns a detached
//! child process (utmm-old) and exits. The child:
//! 1. Stops the system service + kills old utmm processes
//! 2. Initializes mesh networking to discover the Host
//! 3. Downloads the new binary via KCP tunnel (chunked, SHA256-verified)
//! 4. Replaces the binary, starts the service, and exits
//!
//! On any failure after service stop, the old service is restarted to ensure
//! the machine remains reachable.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const protocol = @import("protocol.zig");
const tunproto = @import("tunproto.zig");
const tunnel_mod = @import("tunnel.zig");
const mesh_mod = @import("mesh.zig");
const broadcast = @import("broadcast.zig");
const install = @import("install.zig");

// ═══════════════════════════════════════════════════════════════════════════
// POSIX externs
// ═══════════════════════════════════════════════════════════════════════════

extern "c" fn fork() std.posix.pid_t;
extern "c" fn setsid() std.posix.pid_t;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn kill(pid: std.posix.pid_t, sig: c_int) c_int;
extern "c" fn waitpid(pid: std.posix.pid_t, status: *c_int, options: c_int) std.posix.pid_t;

const SIGKILL: c_int = 9;
const WNOHANG: c_int = 1;

// macOS libproc externs (process enumeration for cleanup)
extern "c" fn proc_listallpids(buffer: ?[*]c_int, buffersize: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

// ═══════════════════════════════════════════════════════════════════════════
// Hex encoding
// ═══════════════════════════════════════════════════════════════════════════

fn hexHash(allocator: std.mem.Allocator, hash: *const [32]u8) ![]const u8 {
    var hex: [64]u8 = undefined;
    for (hash, 0..) |b, j| {
        hex[j * 2] = "0123456789abcdef"[b >> 4];
        hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return try allocator.dupe(u8, &hex);
}

// ═══════════════════════════════════════════════════════════════════════════
// Detached spawn — starts utmm-old as an independent process
// ═══════════════════════════════════════════════════════════════════════════

/// Spawn a detached child process that performs the upgrade.
/// The child runs the same binary with --upgrade --target <arch> flags.
/// After calling this, the parent should exit immediately.
pub fn spawnDetachedUpgrader(
    io: std.Io,
    allocator: std.mem.Allocator,
    target: []const u8,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
) !void {
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_len];

    // Port as string for CLI arg
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{mesh_port});

    if (builtin.os.tag == .windows) {
        try spawnDetachedWindows(allocator, exe_path, target, port_str, peer_mesh);
    } else {
        try spawnDetachedPosix(allocator, exe_path, target, port_str, peer_mesh);
    }
}

/// POSIX: double-fork + setsid + execve. Grandchild is reparented to init (PID 1).
fn spawnDetachedPosix(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    target: []const u8,
    port_str: []const u8,
    peer_mesh: ?[]const u8,
) !void {
    // Pre-allocate Z-terminated strings for execve argv.
    // These are intentionally leaked — the parent exits after this function
    // returns, and the grandchild calls execve which replaces the process image.
    const exe_z = try allocator.dupeZ(u8, exe_path);
    const target_z = try allocator.dupeZ(u8, target);
    const port_z = try allocator.dupeZ(u8, port_str);
    const peer_z: ?[:0]const u8 = if (peer_mesh) |pm| try allocator.dupeZ(u8, pm) else null;

    const pid = fork();
    if (pid < 0) {
        std.log.err("[upgrade] First fork failed", .{});
        return error.ForkFailed;
    }
    if (pid > 0) {
        // Parent: reap first child (non-blocking) and return.
        var status: c_int = 0;
        _ = waitpid(pid, &status, WNOHANG);
        return;
    }

    // First child: create new session, then second fork.
    _ = setsid();

    const pid2 = fork();
    if (pid2 < 0) {
        std.log.err("[upgrade] Second fork failed", .{});
        std.process.exit(1);
    }
    if (pid2 > 0) {
        // First child exits → grandchild reparented to init.
        std.process.exit(0);
    }

    // Grandchild: execve with upgrade flags.
    // String literals are null-terminated by the compiler.
    if (peer_z) |pm_z| {
        const argv = [_:null]?[*:0]const u8{
            exe_z.ptr,  "--upgrade",  "--target",  target_z.ptr,
            "--mesh-port",  port_z.ptr,  "--peer-mesh",  pm_z.ptr,
            null,
        };
        _ = execve(exe_z.ptr, &argv, std.c.environ);
    } else {
        const argv = [_:null]?[*:0]const u8{
            exe_z.ptr,  "--upgrade",  "--target",  target_z.ptr,
            "--mesh-port",  port_z.ptr,
            null,
        };
        _ = execve(exe_z.ptr, &argv, std.c.environ);
    }

    // execve failed
    std.log.err("[upgrade] execve failed in grandchild", .{});
    std.process.exit(1);
}

/// Windows: CreateProcessW with DETACHED_PROCESS + CREATE_NO_WINDOW.
fn spawnDetachedWindows(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    target: []const u8,
    port_str: []const u8,
    peer_mesh: ?[]const u8,
) !void {
    const w = std.os.windows;

    const PROCESS_INFORMATION = extern struct {
        hProcess: w.HANDLE,
        hThread: w.HANDLE,
        dwProcessId: w.DWORD,
        dwThreadId: w.DWORD,
    };

    // Build command line
    const cmd_line = if (peer_mesh) |pm|
        try std.fmt.allocPrint(allocator, "\"{s}\" --upgrade --target {s} --mesh-port {s} --peer-mesh {s}", .{ exe_path, target, port_str, pm })
    else
        try std.fmt.allocPrint(allocator, "\"{s}\" --upgrade --target {s} --mesh-port {s}", .{ exe_path, target, port_str });
    defer allocator.free(cmd_line);

    // Convert to UTF-16LE (null-terminated)
    const cmd_utf16 = try allocator.alloc(u16, cmd_line.len + 1);
    defer allocator.free(cmd_utf16);
    const end_idx = try std.unicode.utf8ToUtf16Le(cmd_utf16, cmd_line);
    cmd_utf16[end_idx] = 0;

    const CreateProcessW = @extern(
        *const fn (lpApplicationName: ?[*:0]const u16, lpCommandLine: [*:0]u16, lpProcessAttributes: ?*w.SECURITY_ATTRIBUTES, lpThreadAttributes: ?*w.SECURITY_ATTRIBUTES, bInheritHandles: w.BOOL, dwCreationFlags: w.DWORD, lpEnvironment: ?w.LPVOID, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *w.STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) w.BOOL,
        .{ .name = "CreateProcessW", .library_name = "kernel32" },
    );
    const CloseHandle = @extern(
        *const fn (hObject: w.HANDLE) callconv(.winapi) w.BOOL,
        .{ .name = "CloseHandle", .library_name = "kernel32" },
    );

    const DETACHED_PROCESS: w.DWORD = 0x00000008;
    const CREATE_NO_WINDOW: w.DWORD = 0x08000000;

    var si: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi: PROCESS_INFORMATION = undefined;

    const flags: w.DWORD = DETACHED_PROCESS | CREATE_NO_WINDOW;
    if (@intFromEnum(CreateProcessW(null, @as([*:0]u16, @ptrCast(cmd_utf16.ptr)), null, null, @enumFromInt(0), flags, null, null, &si, &pi)) == 0) {
        std.log.err("[upgrade] CreateProcessW failed (error: {d})", .{std.os.windows.GetLastError()});
        return error.SpawnFailed;
    }

    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
    std.log.info("[upgrade] Detached upgrade process spawned (pid={d})", .{pi.dwProcessId});
}

// ═══════════════════════════════════════════════════════════════════════════
// Service management
// ═══════════════════════════════════════════════════════════════════════════

/// Stop the system service (Guest daemon).
/// Ignores errors — the service might not be running.
fn stopService(io: std.Io, allocator: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) {
        _ = std.process.run(allocator, io, .{
            .argv = &.{ "sc", "stop", "UTM-Monitor-Guest" },
        }) catch {};
    } else if (builtin.os.tag == .macos) {
        _ = std.process.run(allocator, io, .{
            .argv = &.{ "launchctl", "bootout", "system", "/Library/LaunchDaemons/com.utmm.guest.plist" },
        }) catch {};
    } else {
        // Linux
        _ = std.process.run(allocator, io, .{
            .argv = &.{ "systemctl", "stop", "utmm-guest.service" },
        }) catch {};
    }
    std.log.info("[upgrade] Service stop requested", .{});
}

/// Start the system service (Guest daemon).
/// If start fails, attempts full re-install as fallback.
fn startService(io: std.Io, allocator: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "sc", "start", "UTM-Monitor-Guest" },
        }) catch {
            std.log.err("[upgrade] Failed to start Windows service, attempting re-install", .{});
            install.installSelf(io, allocator, false, null, false) catch {};
            return;
        };
        _ = result;
    } else if (builtin.os.tag == .macos) {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "launchctl", "bootstrap", "system", "/Library/LaunchDaemons/com.utmm.guest.plist" },
        }) catch {
            std.log.err("[upgrade] Failed to bootstrap macOS service, attempting re-install", .{});
            install.installSelf(io, allocator, false, null, false) catch {};
            return;
        };
        _ = result;
    } else {
        // Linux
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "systemctl", "start", "utmm-guest.service" },
        }) catch {
            std.log.err("[upgrade] Failed to start Linux service, attempting re-install", .{});
            install.installSelf(io, allocator, false, null, false) catch {};
            return;
        };
        _ = result;
    }
    std.log.info("[upgrade] Service started", .{});
}

/// Kill other utmm processes (not self).
/// POSIX: enumerate processes and kill those matching our binary path.
/// Windows: skip — sc stop already handles the service process.
fn killOtherUtmmProcesses(io: std.Io, allocator: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) {
        // sc stop handles service process; foreground mode is rare.
        return;
    }

    // Get our own executable path for comparison
    var exe_buf: [4096]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch {
        std.log.err("[upgrade] Cannot get executable path for process cleanup", .{});
        return;
    };
    const my_exe = exe_buf[0..exe_len];
    const my_pid = std.c.getpid();

    if (builtin.os.tag == .macos) {
        killOtherUtmmProcessesMacOS(io, allocator, my_exe, my_pid);
    } else {
        killOtherUtmmProcessesLinux(io, allocator, my_exe, my_pid);
    }
}

fn killOtherUtmmProcessesLinux(
    io: std.Io,
    allocator: std.mem.Allocator,
    my_exe: []const u8,
    my_pid: std.posix.pid_t,
) void {
    _ = allocator;
    // Iterate /proc/<pid>/exe, readlink to get target path, compare.
    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{}) catch {
        std.log.err("[upgrade] Cannot open /proc for process enumeration", .{});
        return;
    };
    defer proc_dir.close(io);

    var iter = proc_dir.iterate();
    var name_buf: [256]u8 = undefined;
    while (iter.next(io) catch null) |entry| {
        // Only numeric directories (PIDs)
        if (entry.name.len == 0) continue;
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (pid == my_pid) continue;

        // Read /proc/<pid>/exe symlink target
        const exe_link = std.fmt.bufPrint(&name_buf, "/proc/{d}/exe", .{pid}) catch continue;
        var link_buf: [4096]u8 = undefined;
        const link_len = std.Io.Dir.readLink(proc_dir, io, exe_link, &link_buf) catch continue;
        const target_path = link_buf[0..@intCast(link_len)];

        if (std.mem.eql(u8, target_path, my_exe)) {
            std.log.info("[upgrade] Killing old utmm process pid={d}", .{pid});
            _ = kill(pid, SIGKILL);
        }
    }
}

fn killOtherUtmmProcessesMacOS(
    io: std.Io,
    allocator: std.mem.Allocator,
    my_exe: []const u8,
    my_pid: std.posix.pid_t,
) void {
    _ = io;

    // proc_listallpids: first call with NULL buf → returns buffer size needed
    const buf_size = proc_listallpids(null, 0);
    if (buf_size <= 0) {
        std.log.err("[upgrade] proc_listallpids failed (size query)", .{});
        return;
    }

    const pid_count: usize = @intCast(@divTrunc(buf_size, @sizeOf(c_int)));
    const pids = allocator.alloc(c_int, pid_count) catch {
        std.log.err("[upgrade] Cannot allocate PID buffer", .{});
        return;
    };
    defer allocator.free(pids);

    const actual = proc_listallpids(pids.ptr, buf_size);
    if (actual <= 0) {
        std.log.err("[upgrade] proc_listallpids failed", .{});
        return;
    }

    const actual_count: usize = @intCast(@divTrunc(actual, @sizeOf(c_int)));
    var path_buf: [4096]u8 = undefined;

    for (pids[0..actual_count]) |pid| {
        if (pid == 0) continue;
        if (pid == my_pid) continue;

        const ret = proc_pidpath(pid, &path_buf, @intCast(path_buf.len));
        if (ret <= 0) continue;

        const target_path = path_buf[0..@intCast(ret)];
        if (std.mem.eql(u8, target_path, my_exe)) {
            std.log.info("[upgrade] Killing old utmm process pid={d}", .{pid});
            _ = kill(pid, SIGKILL);
        }
    }
}

/// Recover from upgrade failure: restart the old service so the machine
/// remains reachable. Never returns — always exits.
fn recoverAndExit(io: std.Io, allocator: std.mem.Allocator) noreturn {
    std.log.err("[upgrade] Upgrade failed — restarting old service for recovery", .{});
    startService(io, allocator);
    std.process.exit(1);
}

// ═══════════════════════════════════════════════════════════════════════════
// Mesh + Tunnel helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Connect to the Host via mesh and return a Tunnel.
/// Quick check for an existing session with data, then actively connect
/// via m.connect(). The Host's tunnel manager uses Guest-initiated sessions
/// for upgrading guests, so we must be the one to create the session.
fn connectToHost(
    io: std.Io,
    allocator: std.mem.Allocator,
    mesh_opt: *?mesh_mod.Mesh,
    timeout_ms: u64,
) !tunnel_mod.Tunnel {
    const deadline = std.Io.Timestamp.addDuration(
        std.Io.Timestamp.now(io, .awake),
        std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
    );

    while (true) {
        if (mesh_opt.*) |*m| {
            // Quick check: any existing session from the Host with data?
            m.sessions_mutex.lock(m.io) catch {};
            var s_it = m.sessions.iterator();
            while (s_it.next()) |s_entry| {
                const sess = s_entry.value_ptr.*;
                if (sess.kcp_inst.peekSize() >= 0) {
                    var lsa_it = m.lsas.iterator();
                    while (lsa_it.next()) |lsa_entry| {
                        if (std.mem.eql(u8, &lsa_entry.key_ptr.*, &sess.remote)) {
                            var role: []const u8 = "";
                            var line_it2 = std.mem.splitScalar(u8, lsa_entry.value_ptr.node_info, '\n');
                            while (line_it2.next()) |line| {
                                if (std.mem.startsWith(u8, line, "role:") and line.len > 5) {
                                    role = line[5..];
                                }
                            }
                            if (std.mem.eql(u8, role, "host")) {
                                const conv = s_entry.key_ptr.*;
                                std.log.info("[upgrade] Using existing Host session conv={d}", .{conv});
                                m.sessions_mutex.unlock(m.io);
                                return tunnel_mod.Tunnel.init(allocator, io, sess);
                            }
                        }
                    }
                }
            }
            m.sessions_mutex.unlock(m.io);

            // Actively connect to the Host. This creates a Guest-initiated
            // session. The Host's tunnel manager will find it on the next
            // scan cycle and spawn handleMeshGuest to process our upgrade_req.
            var lsa_it = m.lsas.iterator();
            while (lsa_it.next()) |entry| {
                const lsa = entry.value_ptr.*;
                const node_id = entry.key_ptr.*;
                var role: []const u8 = "";
                var line_it = std.mem.splitScalar(u8, lsa.node_info, '\n');
                while (line_it.next()) |line| {
                    if (std.mem.startsWith(u8, line, "role:") and line.len > 5) {
                        role = line[5..];
                    }
                }
                if (std.mem.eql(u8, role, "host")) {
                    std.log.info("[upgrade] Connecting to Host...", .{});
                    const sess = m.connect(node_id) catch |err| {
                        std.log.err("[upgrade] connect to Host failed: {} (will retry)", .{err});
                        continue;
                    };
                    return tunnel_mod.Tunnel.init(allocator, io, sess);
                }
            }
            // No Host LSA found yet — wait for it
        }

        // Check timeout
        const remaining = std.Io.Timestamp.durationTo(std.Io.Timestamp.now(io, .awake), deadline);
        if (remaining.nanoseconds <= 0) {
            return error.Timeout;
        }

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
    }
}

/// Receive binary via chunked file transfer over KCP tunnel.
/// Writes to temp file, incrementally computes SHA256, verifies on file_eof.
/// Returns path to verified temp file. Caller owns returned string.
fn receiveUpgradeBinary(
    io: std.Io,
    allocator: std.mem.Allocator,
    tun: *tunnel_mod.Tunnel,
) ![]const u8 {
    // Create temp file in same directory as executable
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_len];
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    const temp_name: []const u8 = if (builtin.os.tag == .windows) "utmm.next.exe" else "utmm.next";
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ exe_dir, temp_name });
    errdefer allocator.free(temp_path);

    std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const temp_file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
    errdefer {
        temp_file.close(io);
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    }
    var wb: [65536]u8 = undefined;
    var writer = temp_file.writer(io, &wb);

    // Enable fast mode (nocwnd=true) for binary download — the Host
    // sends in controlled batches with explicit flush between them.
    tun.enableFastMode();

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var received: u32 = 0;

    // 5-minute total timeout for the entire download.
    const download_deadline = std.Io.Timestamp.addDuration(
        std.Io.Timestamp.now(io, .awake),
        std.Io.Duration.fromSeconds(300),
    );

    // Receive loop: file_chunk × N → file_eof.
    // KCP is in MESSAGE mode (default) — each tun.send() creates a
    // separate message with boundaries. peekSize() returns the size of
    // the NEXT complete message, recv() returns exactly one message.
    // The first message from the Host may be pty_spawn (sent by
    // handleMeshGuest before it receives our upgrade_req).
    var rbuf: [262144]u8 = undefined;
    var first_message = true;
    var peek_iter: u32 = 0;
    while (true) {
        // Check total timeout
        if (std.Io.Timestamp.durationTo(std.Io.Timestamp.now(io, .awake), download_deadline).nanoseconds <= 0) {
            std.log.err("[upgrade] Download timed out after 5 minutes", .{});
            temp_file.close(io);
            std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
            return error.UpgradeTimeout;
        }

        if (!tun.isAlive()) {
            std.log.err("[upgrade] Tunnel dead during binary download", .{});
            temp_file.close(io);
            std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
            return error.TunnelDeadDuringUpgrade;
        }

        // Wait for a complete message (KCP message mode guarantees boundaries)
        const ps = tun.peekSize();
        if (ps < 0) {
            peek_iter += 1;
            if (peek_iter % 500 == 1) {
                std.log.info("[upgrade] peekSize=-1 iter={}", .{peek_iter});
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
            continue;
        }

        const n = tun.recv(&rbuf) catch |err| {
            std.log.err("[upgrade] Tunnel recv error: {}", .{err});
            temp_file.close(io);
            std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
            return error.UpgradeRecvFailed;
        };
        if (n == 0) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
            continue;
        }

        const msg_type: u8 = rbuf[0];
        const payload = rbuf[1..n];

        // First message is pty_spawn from handleMeshGuest — skip it
        if (first_message and msg_type == @intFromEnum(tunproto.MsgType.pty_spawn)) {
            std.log.info("[upgrade] Skipping pty_spawn ({} bytes)", .{n});
            first_message = false;
            continue;
        }
        first_message = false;

        if (msg_type == @intFromEnum(tunproto.MsgType.file_chunk)) {
            const chunk = tunproto.parseFileChunk(payload) orelse {
                std.log.err("[upgrade] Failed to parse file_chunk at offset", .{});
                temp_file.close(io);
                std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
                return error.UpgradeParseFailed;
            };
            _ = writer.interface.write(chunk.data) catch |e| {
                std.log.err("[upgrade] Write chunk failed: {}", .{e});
                temp_file.close(io);
                std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
                return error.WriteFailed;
            };
            sha256.update(chunk.data);
            received += @intCast(chunk.data.len);
            if (received % 38400 == 0 or received < 10000) {
                std.log.info("[upgrade] Received {} bytes peek_iter={}", .{ received, peek_iter });
            }
            continue;
        }

        if (msg_type == @intFromEnum(tunproto.MsgType.file_eof)) {
            const eof = tunproto.parseFileEof(payload) orelse {
                std.log.err("[upgrade] Failed to parse file_eof", .{});
                temp_file.close(io);
                std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
                return error.UpgradeParseFailed;
            };
            if (eof.exit_code != 0) {
                std.log.err("[upgrade] Host rejected upgrade (exit_code={d})", .{eof.exit_code});
                temp_file.close(io);
                std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
                return error.UpgradeRejected;
            }
            writer.interface.flush() catch {};
            temp_file.close(io);
            var hash: [32]u8 = undefined;
            sha256.final(&hash);
            const actual_hex = try hexHash(allocator, &hash);
            defer allocator.free(actual_hex);
            if (eof.file_hash.len > 0 and !std.mem.eql(u8, actual_hex, eof.file_hash)) {
                std.log.err("[upgrade] SHA256 mismatch: got {s}, expected {s}", .{ actual_hex, eof.file_hash });
                std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
                return error.HashMismatch;
            }
            std.log.info("[upgrade] Received binary ({d} bytes, sha256={s})", .{ received, actual_hex });
            return temp_path;
        }

        // Non-file message — skip it
        std.log.debug("[upgrade] Skipping message type {d} ({d} bytes)", .{ msg_type, n });
    }
}

/// Replace running binary with downloaded temp file and restart service.
fn replaceAndRestart(
    io: std.Io,
    allocator: std.mem.Allocator,
    temp_path: []const u8,
) !void {
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_path = exe_buf[0..exe_len];

    if (builtin.os.tag == .windows) {
        try replaceAndRestartWindows(io, allocator, temp_path, exe_path);
    } else {
        try replaceAndRestartPosix(io, allocator, temp_path, exe_path);
    }
}

fn replaceAndRestartPosix(
    io: std.Io,
    allocator: std.mem.Allocator,
    temp_path: []const u8,
    exe_path: []const u8,
) !void {
    // chmod + atomic rename — safe because the old binary isn't running
    // (service was stopped in Phase A).
    const temp_path_z = try allocator.dupeZ(u8, temp_path);
    defer allocator.free(temp_path_z);
    _ = std.c.chmod(@ptrCast(temp_path_z.ptr), 0o755);

    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), exe_path, io);
    std.log.info("[upgrade] Binary replaced: {s} → {s}", .{ temp_path, exe_path });
}

fn replaceAndRestartWindows(
    io: std.Io,
    allocator: std.mem.Allocator,
    temp_path: []const u8,
    exe_path: []const u8,
) !void {
    // Windows locks running .exe files. Since utmm-old IS the same binary,
    // we cannot directly overwrite it. Solution: write a batch script that
    // waits for utmm-old to exit, then moves the new binary over the old one,
    // starts the service, and self-deletes.
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    const batch = try std.fmt.allocPrint(allocator,
        \\@echo off
        \\timeout /t 2 /nobreak >nul
        \\move /y "{s}" "{s}"
        \\sc start UTM-Monitor-Guest >nul 2>&1
        \\del "%~f0"
    , .{ temp_path, exe_path });
    defer allocator.free(batch);

    const batch_path = try std.fmt.allocPrint(allocator, "{s}\\utmm-upgrade.bat", .{exe_dir});
    defer allocator.free(batch_path);

    std.Io.Dir.cwd().deleteFile(io, batch_path) catch {};
    {
        var bat_file = try std.Io.Dir.cwd().createFile(io, batch_path, .{});
        defer bat_file.close(io);
        try bat_file.writeStreamingAll(io, batch);
    }

    // Spawn detached batch script — it handles move + restart after we exit
    _ = try std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", batch_path },
    });

    std.log.info("[upgrade] Windows batch upgrade script spawned: {s}", .{batch_path});
}

// ═══════════════════════════════════════════════════════════════════════════
// Main upgrade entry point — called when --upgrade flag is set
// ═══════════════════════════════════════════════════════════════════════════

/// Run the full upgrade sequence. Called by main.zig when --upgrade is set.
/// target: Zig target triplet (e.g. "aarch64-linux-musl")
/// mesh_port: UDP port for mesh discovery
/// peer_mesh: optional direct peer address for local testing
pub fn runUpgrade(
    io: std.Io,
    gpa: std.mem.Allocator,
    target: []const u8,
    mesh_port: u16,
    peer_mesh: ?[]const u8,
) !void {
    std.log.info("[upgrade] Starting utmm-old upgrade for target {s} (mesh :{d})", .{ target, mesh_port });

    // ═══ Phase A: Stop service + kill old processes ═══
    stopService(io, gpa);
    killOtherUtmmProcesses(io, gpa);

    // Wait for port release and process termination
    std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};

    // ═══ Phase B: Mesh init + connect to Host ═══
    const info = broadcast.getSystemInfo(io, gpa) catch |err| {
        std.log.err("[upgrade] getSystemInfo failed: {}", .{err});
        recoverAndExit(io, gpa);
    };

    // Collect broadcast addresses
    var broadcast_addrs = broadcast.getSubnetBroadcasts(gpa) catch |err| {
        std.log.err("[upgrade] getSubnetBroadcasts failed: {}", .{err});
        recoverAndExit(io, gpa);
    };

    // Add explicit peer mesh address for local testing
    if (peer_mesh) |pm| {
        if (protocol.parsePeerMeshAddr(pm)) |peer_addr| {
            broadcast_addrs.append(gpa, peer_addr) catch |err| {
                std.log.err("[upgrade] append peer-mesh '{s}': {}", .{ pm, err });
            };
        } else {
            std.log.err("[upgrade] invalid --peer-mesh '{s}'", .{pm});
        }
    }

    // Dedicated I/O for mesh background thread
    var mesh_threaded = std.Io.Threaded.init(gpa, .{});
    const mesh_io = mesh_threaded.io();

    // Bind UDP socket for mesh
    const bind_addr = net.IpAddress.parse("0.0.0.0", mesh_port) catch |err| {
        std.log.err("[upgrade] Mesh bind addr parse failed: {}", .{err});
        broadcast_addrs.deinit(gpa);
        recoverAndExit(io, gpa);
    };
    const mesh_socket = bind_addr.bind(mesh_io, .{ .mode = .dgram, .allow_broadcast = true }) catch |err| {
        std.log.err("[upgrade] Mesh UDP bind :{d} failed: {}", .{ mesh_port, err });
        broadcast_addrs.deinit(gpa);
        recoverAndExit(io, gpa);
    };

    // Parse node ID from MAC
    const node_id = if (peer_mesh != null)
        mesh_mod.deriveNodeId(info.mac, info.hostname) catch |err| {
            std.log.err("[upgrade] deriveNodeId failed: {}", .{err});
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(gpa);
            recoverAndExit(io, gpa);
        }
    else
        mesh_mod.parseNodeId(info.mac) catch |err| {
            std.log.err("[upgrade] parseNodeId failed: {}", .{err});
            mesh_socket.close(mesh_io);
            broadcast_addrs.deinit(gpa);
            recoverAndExit(io, gpa);
        };

    // Build node_info for LSA broadcast — use "role:upgrading" so Host
    // identifies this as an upgrade process.
    const node_info = std.fmt.allocPrint(gpa,
        "hostname:{s}\nip:{s}\ntarget:{s}\nversion:{s}\nshell:{s}\nrole:upgrading\nstatus:upgrading",
        .{ info.hostname, info.ip, info.target, protocol.VERSION, info.shell },
    ) catch |err| {
        std.log.err("[upgrade] node_info alloc failed: {}", .{err});
        mesh_socket.close(mesh_io);
        broadcast_addrs.deinit(gpa);
        recoverAndExit(io, gpa);
    };

    // Fake upgrade_needed signal — upgrade process doesn't need version
    // checking via LSA (we're already upgrading). Pass a dummy that never
    // gets set to true.
    var dummy_upgrade: broadcast.UpgradeSignal = .{};
    const host_gateway_ip: []const u8 = ""; // Empty = no LSA version check

    var mesh_opt: ?mesh_mod.Mesh = mesh_mod.Mesh.init(gpa, node_id, node_info, mesh_socket, mesh_io, &dummy_upgrade.needed, broadcast_addrs, host_gateway_ip) catch |err| {
        std.log.err("[upgrade] Mesh init failed: {}", .{err});
        gpa.free(node_info);
        mesh_socket.close(mesh_io);
        broadcast_addrs.deinit(gpa);
        recoverAndExit(io, gpa);
    };

    // Spawn mesh.run() in background thread
    const mesh_thread = std.Thread.spawn(.{}, mesh_mod.Mesh.run, .{&mesh_opt.?}) catch |err| {
        std.log.err("[upgrade] Mesh thread spawn failed: {}", .{err});
        mesh_opt.?.deinit();
        mesh_socket.close(mesh_io);
        recoverAndExit(io, gpa);
    };

    defer {
        mesh_opt.?.signalShutdown();
        mesh_thread.join();
        const m_io_save = mesh_opt.?.io;
        mesh_opt.?.deinit();
        mesh_socket.close(m_io_save);
    }

    // ═══ Phase C: Connect to Host + download binary ═══
    var tunnel = connectToHost(io, gpa, &mesh_opt, 15_000) catch |err| {
        std.log.err("[upgrade] connectToHost failed: {}", .{err});
        recoverAndExit(io, gpa);
    };
    defer tunnel.deinit();

    // Send upgrade request
    {
        const req_frame = try tunproto.buildUpgradeReq(gpa, "upgrade", target);
        defer gpa.free(req_frame);
        _ = tunnel.send(req_frame) catch |err| {
            std.log.err("[upgrade] send upgrade request failed: {}", .{err});
            recoverAndExit(io, gpa);
        };
        std.log.info("[upgrade] Sent upgrade request for target {s}", .{target});
    }

    // Receive binary (chunked transfer with SHA256 verification)
    const temp_path = receiveUpgradeBinary(io, gpa, &tunnel) catch |err| {
        std.log.err("[upgrade] receiveUpgradeBinary failed: {}", .{err});
        recoverAndExit(io, gpa);
    };
    defer gpa.free(temp_path);

    // ═══ Phase D: Replace binary + start service ═══
    replaceAndRestart(io, gpa, temp_path) catch |err| {
        std.log.err("[upgrade] replaceAndRestart failed: {}", .{err});
        recoverAndExit(io, gpa);
    };

    // On POSIX, the binary is already replaced. Start the service.
    // On Windows, the batch script handles the move + start.
    if (builtin.os.tag != .windows) {
        startService(io, gpa);
    }

    std.log.info("[upgrade] Upgrade complete — exiting", .{});
    std.process.exit(0);
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "hexHash - produces correct output" {
    var hash: [32]u8 = [_]u8{0} ** 32;
    hash[0] = 0xAB;
    hash[1] = 0xCD;
    hash[31] = 0xFF;

    const hex = try hexHash(std.testing.allocator, &hash);
    defer std.testing.allocator.free(hex);

    try std.testing.expectEqualStrings("ab", hex[0..2]);
    try std.testing.expectEqualStrings("cd", hex[2..4]);
    try std.testing.expectEqualStrings("ff", hex[62..64]);
}

test "spawnDetachedUpgrader - signature" { _ = spawnDetachedUpgrader; }
test "runUpgrade - signature" { _ = runUpgrade; }
test "hexHash - signature" { _ = hexHash; }
