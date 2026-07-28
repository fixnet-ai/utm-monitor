//! Lock-free SPSC (Single Producer, Single Consumer) ring buffer.
//!
//! Used for bulk data transfer between IPC thread and Mesh thread during
//! file upload/download operations. Zero heap allocations — stack-allocated
//! fixed-size buffer with atomic position tracking.
//!
//! ## Thread Safety
//!
//! Exactly ONE producer thread and ONE consumer thread. The producer calls
//! write() and consumer calls read(). No mutex needed because:
//! - Only producer writes `write_pos` and reads `read_pos`
//! - Only consumer writes `read_pos` and reads `write_pos`
//! - No write-write contention on position counters
//!
//! ## Memory Ordering
//!
//! Producer: write data → release write_pos (make data visible to consumer)
//! Consumer: acquire write_pos → read data (see producer's writes)
//! Consumer: read data → release read_pos (free space visible to producer)
//! Producer: acquire read_pos → write new data (don't overwrite unread data)

const std = @import("std");

/// Default ring buffer capacity in bytes (must be power of 2).
pub const DEFAULT_CAPACITY: usize = 256 * 1024; // 256 KB

/// Lock-free SPSC ring buffer for byte-level data transfer.
///
/// Producer calls write() to append data, consumer calls read() to consume it.
/// Both positions are monotonic u32 counters — physical index = pos % capacity.
/// u32 wraps every 4 GB, but the difference (write_pos - read_pos) is always
/// correct with wrapping subtraction (-%).
pub fn RingBuf(comptime capacity: usize) type {
    // Validate power-of-2 at compile time
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("RingBuf capacity must be a power of 2, got " ++ std.fmt.comptimePrint("{d}", .{capacity}));
    }

    return struct {
        const Self = @This();
        const mask: u32 = capacity - 1;

        buf: [capacity]u8,
        /// Consumer reads from here. Only consumer writes this.
        read_pos: std.atomic.Value(u32),
        /// Producer writes to here. Only producer writes this.
        write_pos: std.atomic.Value(u32),

        /// Initialize an empty ring buffer.
        pub fn init() Self {
            return .{
                .buf = undefined,
                .read_pos = std.atomic.Value(u32).init(0),
                .write_pos = std.atomic.Value(u32).init(0),
            };
        }

        /// Number of bytes available to read.
        /// Called by consumer (or producer for checking fullness).
        pub fn available(self: *Self) usize {
            const wp = self.write_pos.load(.acquire);
            const rp = self.read_pos.load(.acquire);
            return wp -% rp;
        }

        /// Number of free bytes available for writing.
        /// Called by producer (or consumer for checking emptiness).
        pub fn free(self: *Self) usize {
            return capacity - self.available();
        }

        /// Write data into the ring buffer. Returns number of bytes actually written.
        /// If the buffer is full, returns 0. Partial writes up to available free space.
        /// Called ONLY by the producer thread.
        pub fn write(self: *Self, data: []const u8) usize {
            const free_space = self.free();
            if (free_space == 0) return 0;

            const to_write: usize = @min(data.len, free_space);
            const wp = self.write_pos.load(.acquire);
            const start: u32 = wp & mask;

            if (start + to_write <= capacity) {
                // Single contiguous segment
                @memcpy(self.buf[start..][0..to_write], data[0..to_write]);
            } else {
                // Wrap around: write tail then head
                const first_part = capacity - start;
                @memcpy(self.buf[start..], data[0..first_part]);
                @memcpy(self.buf[0..][0..(to_write - first_part)], data[first_part..to_write]);
            }

            // Release: make written data visible to consumer
            self.write_pos.store(wp +% @as(u32, @intCast(to_write)), .release);
            return to_write;
        }

        /// Read data from the ring buffer. Returns number of bytes actually read.
        /// If the buffer is empty, returns 0. Partial reads up to available data.
        /// Called ONLY by the consumer thread.
        pub fn read(self: *Self, buf: []u8) usize {
            const avail = self.available();
            if (avail == 0) return 0;

            const to_read: usize = @min(buf.len, avail);
            const rp = self.read_pos.load(.acquire);
            const start: u32 = rp & mask;

            if (start + to_read <= capacity) {
                // Single contiguous segment
                @memcpy(buf[0..to_read], self.buf[start..][0..to_read]);
            } else {
                // Wrap around: read tail then head
                const first_part = capacity - start;
                @memcpy(buf[0..first_part], self.buf[start..]);
                @memcpy(buf[first_part..to_read], self.buf[0..][0..(to_read - first_part)]);
            }

            // Release: make freed space visible to producer
            self.read_pos.store(rp +% @as(u32, @intCast(to_read)), .release);
            return to_read;
        }

        /// Write all data, blocking (with yield) until complete.
        /// Called ONLY by the producer thread.
        pub fn writeAll(self: *Self, data: []const u8, io: std.Io) !void {
            var written: usize = 0;
            while (written < data.len) {
                const n = self.write(data[written..]);
                written += n;
                if (written < data.len) {
                    // Buffer full — yield and retry
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                }
            }
        }

        /// Read data, blocking (with yield) until at least one byte is available.
        /// Returns number of bytes read (may be less than buf.len).
        /// Called ONLY by the consumer thread.
        pub fn readWait(self: *Self, buf: []u8, io: std.Io, timeout_ms: u32) !usize {
            const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + timeout_ms;
            while (true) {
                const n = self.read(buf);
                if (n > 0) return n;
                if (std.Io.Timestamp.now(io, .awake).toMilliseconds() > deadline) {
                    return 0; // timeout, no data
                }
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "ringbuf init empty" {
    var rb = RingBuf(1024).init();
    try testing.expectEqual(@as(usize, 0), rb.available());
    try testing.expectEqual(@as(usize, 1024), rb.free());
}

test "ringbuf write/read basic" {
    var rb = RingBuf(1024).init();
    const data = "hello ring buffer";

    const n = rb.write(data);
    try testing.expectEqual(data.len, n);
    try testing.expectEqual(data.len, rb.available());

    var rbuf: [128]u8 = undefined;
    const rn = rb.read(&rbuf);
    try testing.expectEqual(data.len, rn);
    try testing.expectEqualStrings(data, rbuf[0..rn]);
    try testing.expectEqual(@as(usize, 0), rb.available());
}

test "ringbuf write/read partial" {
    var rb = RingBuf(256).init();
    const data = "A" ** 200;

    const n = rb.write(data);
    try testing.expectEqual(data.len, n);

    var rbuf: [64]u8 = undefined;
    const rn = rb.read(&rbuf);
    try testing.expectEqual(@as(usize, 64), rn);
    try testing.expectEqualStrings(data[0..64], rbuf[0..64]);
    try testing.expectEqual(@as(usize, 136), rb.available());

    // Read the rest
    const rn2 = rb.read(&rbuf);
    try testing.expectEqual(@as(usize, 64), rn2);
    const rn3 = rb.read(&rbuf);
    try testing.expectEqual(@as(usize, 64), rn3);
    const rn4 = rb.read(&rbuf);
    try testing.expectEqual(@as(usize, 8), rn4);
    try testing.expectEqual(@as(usize, 0), rb.available());
}

test "ringbuf full buffer" {
    var rb = RingBuf(256).init();
    const data = "B" ** 256;

    const n = rb.write(data);
    try testing.expectEqual(@as(usize, 256), n);
    try testing.expectEqual(@as(usize, 256), rb.available());
    try testing.expectEqual(@as(usize, 0), rb.free());

    // Write to full buffer
    const n2 = rb.write("x");
    try testing.expectEqual(@as(usize, 0), n2);
}

test "ringbuf empty buffer" {
    var rb = RingBuf(256).init();
    var rbuf: [64]u8 = undefined;

    const n = rb.read(&rbuf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "ringbuf wrap around" {
    var rb = RingBuf(256).init();

    // Fill to near capacity
    const n1 = rb.write("X" ** 200);
    try testing.expectEqual(@as(usize, 200), n1);

    // Read most of it
    var rbuf: [150]u8 = undefined;
    _ = rb.read(rbuf[0..150]);

    // Now write more — this should wrap around
    const n2 = rb.write("Y" ** 100);
    try testing.expectEqual(@as(usize, 100), n2);

    // Available should be 200 - 150 + 100 = 150
    try testing.expectEqual(@as(usize, 150), rb.available());

    // Read and verify
    var rbuf2: [200]u8 = undefined;
    const rn = rb.read(&rbuf2);
    try testing.expectEqual(@as(usize, 150), rn);
    // First 50 bytes should be from the first write (remaining after 150-byte read)
    try testing.expectEqualStrings("X" ** 50, rbuf2[0..50]);
    // Next 100 bytes should be from the second write
    try testing.expectEqualStrings("Y" ** 100, rbuf2[50..150]);
}

test "ringbuf write/read cycle" {
    var rb = RingBuf(1024).init();

    // Multiple write/read cycles — use a separate buffer to avoid memcpy aliasing
    var msg_buf: [64]u8 = undefined;
    for (0..10) |i| {
        const msg = std.fmt.bufPrint(&msg_buf, "msg_{d}", .{i}) catch unreachable;
        const n = rb.write(msg);
        try testing.expectEqual(msg.len, n);

        var rbuf: [64]u8 = undefined;
        const rn = rb.read(&rbuf);
        try testing.expectEqual(msg.len, rn);
        try testing.expectEqualStrings(msg, rbuf[0..rn]);
    }
    try testing.expectEqual(@as(usize, 0), rb.available());
}

test "ringbuf u32 counter wrap" {
    var rb = RingBuf(256).init();

    // Simulate near-u32-max positions by directly setting atomic values.
    // This tests that the wrapping arithmetic in available()/free() works
    // correctly when counters have wrapped past u32::MAX.
    rb.read_pos.store(0xFFFFFF00, .release);
    rb.write_pos.store(0xFFFFFF00, .release);

    try testing.expectEqual(@as(usize, 0), rb.available());
    try testing.expectEqual(@as(usize, 256), rb.free());

    const data = "test" ** 64; // 256 bytes → fills buffer
    const n = rb.write(data);
    try testing.expectEqual(@as(usize, 256), n);
    try testing.expectEqual(@as(usize, 256), rb.available());
}
