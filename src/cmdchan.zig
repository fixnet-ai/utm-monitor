//! Lock-free SPSC (Single Producer, Single Consumer) command queue.
//!
//! Connects the IPC server thread (producer) to the Mesh I/O thread (consumer).
//! Commands are small fixed-size structs — no heap allocation in the push/pop path.
//! Large data (file contents) goes through the ring buffer (ringbuf.zig).
//!
//! ## Thread Safety
//!
//! Exactly ONE producer (IPC thread) and ONE consumer (Mesh thread):
//! - Producer: push() → wake_event.set() (notify consumer)
//! - Consumer: popBatch() → process commands
//! - No mutex — lock-free atomic head/tail with acquire/release ordering
//!
//! ## Wake Mechanism
//!
//! After push(), the producer calls wake_event.set() to wake the consumer.
//! The consumer uses poll() on the wake_event fd + UDP socket fd to efficiently
//! wait for either network data or new commands.

const std = @import("std");

/// Max number of commands in the queue (must be power of 2).
pub const QUEUE_CAPACITY: usize = 256;

/// Max length of a string field within a command.
pub const MAX_STR_LEN: usize = 256;

/// Command types sent from IPC thread to Mesh thread.
pub const CmdTag = enum(u8) {
    exec,
    upload,
    download,
    status,
    ping,
};

/// A single command with inline string storage.
/// Total size: 1 + 31 + 32 + 32 + 256 + 4 + 4 ≈ 360 bytes.
/// With QUEUE_CAPACITY=256, total queue memory ≈ 92 KB.
pub const Cmd = struct {
    tag: CmdTag,
    /// Unique operation ID (e.g. "upload_1234567890").
    cmd_id: [32]u8,
    /// Target VM hostname.
    vm: [32]u8,
    /// Argument field: command to exec, file path, etc.
    arg1: [MAX_STR_LEN]u8,
    /// File size for upload commands.
    file_size: u32,
    /// Reserved for future use (alignment padding).
    _reserved: u32 = 0,

    /// Create a zeroed command.
    pub fn zero() Cmd {
        return .{
            .tag = .status,
            .cmd_id = [_]u8{0} ** 32,
            .vm = [_]u8{0} ** 32,
            .arg1 = [_]u8{0} ** MAX_STR_LEN,
            .file_size = 0,
            ._reserved = 0,
        };
    }

    /// Set a string field, truncating to fit.
    fn setStr(dst: []u8, src: []const u8) void {
        const n = @min(src.len, dst.len - 1);
        @memcpy(dst[0..n], src[0..n]);
        @memset(dst[n..], 0);
    }

    /// Create an exec command.
    pub fn exec(cmd_id: []const u8, vm: []const u8, command: []const u8) Cmd {
        var c = Cmd.zero();
        c.tag = .exec;
        setStr(&c.cmd_id, cmd_id);
        setStr(&c.vm, vm);
        setStr(&c.arg1, command);
        return c;
    }

    /// Create an upload command.
    pub fn upload(cmd_id: []const u8, vm: []const u8, dest_path: []const u8, file_size: u32) Cmd {
        var c = Cmd.zero();
        c.tag = .upload;
        setStr(&c.cmd_id, cmd_id);
        setStr(&c.vm, vm);
        setStr(&c.arg1, dest_path);
        c.file_size = file_size;
        return c;
    }

    /// Create a download command.
    pub fn download(cmd_id: []const u8, vm: []const u8, remote_path: []const u8) Cmd {
        var c = Cmd.zero();
        c.tag = .download;
        setStr(&c.cmd_id, cmd_id);
        setStr(&c.vm, vm);
        setStr(&c.arg1, remote_path);
        return c;
    }

    /// Create a status command.
    pub fn status() Cmd {
        var c = Cmd.zero();
        c.tag = .status;
        return c;
    }

    /// Create a ping command.
    pub fn ping(vm: []const u8) Cmd {
        var c = Cmd.zero();
        c.tag = .ping;
        setStr(&c.vm, vm);
        return c;
    }

    /// Get cmd_id as a slice.
    pub fn cmdIdStr(self: *const Cmd) []const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.cmd_id)), 0);
    }

    /// Get vm as a slice.
    pub fn vmStr(self: *const Cmd) []const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.vm)), 0);
    }

    /// Get arg1 as a slice.
    pub fn arg1Str(self: *const Cmd) []const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.arg1)), 0);
    }
};

/// Lock-free SPSC command queue.
///
/// Producer (IPC thread) calls push() to enqueue commands.
/// Consumer (Mesh thread) calls popBatch() to dequeue commands.
pub const CmdQueue = struct {
    const Self = @This();
    const mask: u32 = QUEUE_CAPACITY - 1;

    buf: [QUEUE_CAPACITY]Cmd align(64),
    /// Consumer reads from here. Only consumer writes this.
    head: std.atomic.Value(u32),
    /// Producer writes to here. Only producer writes this.
    tail: std.atomic.Value(u32),

    /// Initialize an empty command queue.
    pub fn init() Self {
        return .{
            .buf = [_]Cmd{Cmd.zero()} ** QUEUE_CAPACITY,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
        };
    }

    /// Number of commands available for consumption.
    pub fn available(self: *Self) usize {
        const tp = self.tail.load(.acquire);
        const hp = self.head.load(.acquire);
        return tp -% hp;
    }

    /// Number of free slots for production.
    pub fn free(self: *Self) usize {
        return QUEUE_CAPACITY - self.available();
    }

    /// Push a command into the queue. Returns true if successful, false if full.
    /// Called ONLY by the producer thread.
    pub fn push(self: *Self, cmd: Cmd) bool {
        if (self.free() == 0) return false;

        const tp = self.tail.load(.acquire);
        const idx: u32 = tp & mask;

        // Write command before advancing tail (release makes it visible)
        self.buf[idx] = cmd;
        self.tail.store(tp +% 1, .release);
        return true;
    }

    /// Pop up to `cmds.len` commands. Returns number of commands popped.
    /// Called ONLY by the consumer thread.
    pub fn popBatch(self: *Self, cmds: []Cmd) usize {
        const avail = self.available();
        if (avail == 0) return 0;

        const count: usize = @min(cmds.len, avail);
        const hp = self.head.load(.acquire);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx: u32 = (hp +% @as(u32, @intCast(i))) & mask;
            cmds[i] = self.buf[idx];
        }

        // Advance head after reading (release makes freed slots visible)
        self.head.store(hp +% @as(u32, @intCast(count)), .release);
        return count;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "cmdchan queue init empty" {
    var q = CmdQueue.init();
    try testing.expectEqual(@as(usize, 0), q.available());
    try testing.expectEqual(QUEUE_CAPACITY, q.free());
}

test "cmdchan push/pop single" {
    var q = CmdQueue.init();
    const cmd = Cmd.exec("cmd_1", "linuxvm", "uname -a");

    try testing.expect(q.push(cmd));
    try testing.expectEqual(@as(usize, 1), q.available());

    var cmds: [4]Cmd = undefined;
    const n = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(CmdTag.exec, cmds[0].tag);
    try testing.expectEqualStrings("cmd_1", cmds[0].cmdIdStr());
    try testing.expectEqualStrings("linuxvm", cmds[0].vmStr());
    try testing.expectEqualStrings("uname -a", cmds[0].arg1Str());
    try testing.expectEqual(@as(usize, 0), q.available());
}

test "cmdchan push full queue" {
    var q = CmdQueue.init();

    // Fill the queue
    for (0..QUEUE_CAPACITY) |i| {
        var buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintZ(&buf, "cmd_{d}", .{i}) catch unreachable;
        try testing.expect(q.push(Cmd.exec(id, "vm", "cmd")));
    }

    try testing.expectEqual(QUEUE_CAPACITY, q.available());
    try testing.expectEqual(@as(usize, 0), q.free());

    // Push to full queue should fail
    try testing.expect(!q.push(Cmd.exec("overflow", "vm", "cmd")));
}

test "cmdchan pop empty queue" {
    var q = CmdQueue.init();
    var cmds: [4]Cmd = undefined;
    const n = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 0), n);
}

test "cmdchan batch pop" {
    var q = CmdQueue.init();

    // Push 10 commands
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintZ(&buf, "b_{d}", .{i}) catch unreachable;
        try testing.expect(q.push(Cmd.exec(id, "vm", "cmd")));
    }

    // Pop in batches of 3 — should get 3, 3, 3, 1
    var cmds: [3]Cmd = undefined;
    const n1 = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 3), n1);
    try testing.expectEqualStrings("b_0", cmds[0].cmdIdStr());
    try testing.expectEqualStrings("b_1", cmds[1].cmdIdStr());
    try testing.expectEqualStrings("b_2", cmds[2].cmdIdStr());

    const n2 = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 3), n2);

    const n3 = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 3), n3);

    const n4 = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 1), n4);

    const n5 = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 0), n5);
}

test "cmdchan all command types" {
    var q = CmdQueue.init();

    // Test each command type
    try testing.expect(q.push(Cmd.exec("e1", "vm1", "ls -la")));
    try testing.expect(q.push(Cmd.upload("u1", "vm2", "/opt/utmm/test.bin", 1024)));
    try testing.expect(q.push(Cmd.download("d1", "vm3", "/opt/utmm/test.bin")));
    try testing.expect(q.push(Cmd.status()));
    try testing.expect(q.push(Cmd.ping("vm4")));

    var cmds: [8]Cmd = undefined;
    const n = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 5), n);

    try testing.expectEqual(CmdTag.exec, cmds[0].tag);
    try testing.expectEqualStrings("e1", cmds[0].cmdIdStr());
    try testing.expectEqualStrings("vm1", cmds[0].vmStr());
    try testing.expectEqualStrings("ls -la", cmds[0].arg1Str());

    try testing.expectEqual(CmdTag.upload, cmds[1].tag);
    try testing.expectEqualStrings("u1", cmds[1].cmdIdStr());
    try testing.expectEqualStrings("/opt/utmm/test.bin", cmds[1].arg1Str());
    try testing.expectEqual(@as(u32, 1024), cmds[1].file_size);

    try testing.expectEqual(CmdTag.download, cmds[2].tag);
    try testing.expectEqual(CmdTag.status, cmds[3].tag);
    try testing.expectEqual(CmdTag.ping, cmds[4].tag);
    try testing.expectEqualStrings("vm4", cmds[4].vmStr());
}

test "cmdchan wrap around" {
    var q = CmdQueue.init();

    // Advance positions near u32::MAX to test wrapping
    q.head.store(0xFFFFFFF0, .release);
    q.tail.store(0xFFFFFFF0, .release);

    try testing.expectEqual(@as(usize, 0), q.available());
    try testing.expectEqual(QUEUE_CAPACITY, q.free());

    // Push and pop through the wrap boundary
    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const id = std.fmt.bufPrintZ(&buf, "w_{d}", .{i}) catch unreachable;
        try testing.expect(q.push(Cmd.exec(id, "vm", "cmd")));
    }

    try testing.expectEqual(@as(usize, 100), q.available());

    var cmds: [100]Cmd = undefined;
    const n = q.popBatch(&cmds);
    try testing.expectEqual(@as(usize, 100), n);
    try testing.expectEqual(@as(usize, 0), q.available());

    // Verify order through wrap
    try testing.expectEqualStrings("w_0", cmds[0].cmdIdStr());
    try testing.expectEqualStrings("w_99", cmds[99].cmdIdStr());
}

test "cmdchan string truncation" {
    // Test that strings longer than MAX_STR_LEN are truncated
    const long_str = "x" ** 300;
    const cmd = Cmd.exec("id123", "myvm", long_str);

    try testing.expectEqual(CmdTag.exec, cmd.tag);
    try testing.expectEqualStrings("id123", cmd.cmdIdStr());
    // arg1 should be truncated to MAX_STR_LEN-1 chars (null terminated)
    try testing.expectEqual(@as(usize, MAX_STR_LEN - 1), cmd.arg1Str().len);
}

test "cmdchan zero command" {
    const cmd = Cmd.zero();
    try testing.expectEqual(CmdTag.status, cmd.tag);
    try testing.expectEqualStrings("", cmd.cmdIdStr());
    try testing.expectEqualStrings("", cmd.vmStr());
    try testing.expectEqualStrings("", cmd.arg1Str());
    try testing.expectEqual(@as(u32, 0), cmd.file_size);
}
