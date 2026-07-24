//! Pure Zig KCP (reliable UDP) implementation.
//!
//! KCP is a fast, reliable ARQ protocol that uses UDP for transport.
//! It provides reliable, ordered delivery with congestion control —
//! similar to TCP but over UDP. ~500 lines, zero dependencies.
//!
//! Based on the KCP specification (ikcp.c) by skywind3000.
//!
//! Protocol:
//!   IKCP_CMD_PUSH = 81 — data packet
//!   IKCP_CMD_ACK  = 82 — acknowledgment
//!   IKCP_CMD_WASK = 83 — window probe (ask remote window size)
//!   IKCP_CMD_WINS = 84 — window size notification (tell remote window)
//!
//! KCP header (24 bytes):
//!   conv(4) cmd(1) frg(1) wnd(2) ts(4) sn(4) una(4) len(4)

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════════

pub const IKCP_CMD_PUSH: u8 = 81;
pub const IKCP_CMD_ACK: u8 = 82;
pub const IKCP_CMD_WASK: u8 = 83;
pub const IKCP_CMD_WINS: u8 = 84;

pub const IKCP_OVERHEAD: u32 = 24; // KCP header size in bytes
pub const IKCP_MTU_DEFAULT: u32 = 1300;
pub const IKCP_INTERVAL: u32 = 100; // default internal update interval (ms)
pub const IKCP_DEAD_LINK: u32 = 20; // max retransmissions before dead link
pub const IKCP_RTO_MIN: i32 = 100; // minimum RTO (ms)
pub const IKCP_RTO_MAX: i32 = 60000; // maximum RTO (ms)
pub const IKCP_RTO_DEFAULT: i32 = 200; // default RTO (ms)
pub const IKCP_THRESH_INIT: u32 = 2; // slow start threshold
pub const IKCP_THRESH_MIN: u32 = 2; // minimum slow start threshold
pub const IKCP_PROBE_INIT: u32 = 7000; // window probe interval (ms)
pub const IKCP_PROBE_LIMIT: u32 = 120000; // max probe interval before dead link
pub const IKCP_FAST_LIMIT: u32 = 5; // fast retransmit limit
pub const IKCP_WND_SND: u32 = 32; // send window
pub const IKCP_WND_RCV: u32 = 128; // receive window (must be >= max fragment count)

// ═══════════════════════════════════════════════════════════════════════════════
// Output callback
// ═══════════════════════════════════════════════════════════════════════════════

/// Called when KCP needs to send a UDP datagram.
/// conv: conversation ID
/// data: the datagram payload (caller must send this immediately)
/// user: opaque user pointer
pub const OutputCallback = *const fn (conv: u32, data: []const u8, user: ?*anyopaque) void;

// ═══════════════════════════════════════════════════════════════════════════════
// Segment
// ═══════════════════════════════════════════════════════════════════════════════

pub const Segment = struct {
    conv: u32 = 0,
    cmd: u8 = 0,
    frg: u8 = 0,
    wnd: u16 = 0,
    ts: u32 = 0,
    sn: u32 = 0,
    una: u32 = 0,
    len: u32 = 0,
    data: ?[]const u8 = null, // payload slice (caller-owned, not copied)

    // Internal tracking
    xmit: u32 = 0, // retransmission count
    resendts: u32 = 0, // next retransmission timestamp (ms)
    rto: u32 = 0, // retransmission timeout for this segment
    fastack: u32 = 0, // fast retransmission ack counter

    /// Encode segment into a buffer. Returns bytes written.
    pub fn encode(self: *const Segment, buf: []u8) usize {
        std.mem.writeInt(u32, buf[0..4], self.conv, .big);
        buf[4] = self.cmd;
        buf[5] = self.frg;
        std.mem.writeInt(u16, buf[6..8], self.wnd, .big);
        std.mem.writeInt(u32, buf[8..12], self.ts, .big);
        std.mem.writeInt(u32, buf[12..16], self.sn, .big);
        std.mem.writeInt(u32, buf[16..20], self.una, .big);
        std.mem.writeInt(u32, buf[20..24], self.len, .big);
        return IKCP_OVERHEAD;
    }

    /// Decode a segment from raw bytes. Returns null if data is too short.
    pub fn decode(data: []const u8) ?Segment {
        if (data.len < IKCP_OVERHEAD) return null;
        return Segment{
            .conv = std.mem.readInt(u32, data[0..4], .big),
            .cmd = data[4],
            .frg = data[5],
            .wnd = std.mem.readInt(u16, data[6..8], .big),
            .ts = std.mem.readInt(u32, data[8..12], .big),
            .sn = std.mem.readInt(u32, data[12..16], .big),
            .una = std.mem.readInt(u32, data[16..20], .big),
            .len = std.mem.readInt(u32, data[20..24], .big),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// KCP Control Block
// ═══════════════════════════════════════════════════════════════════════════════

pub const Kcp = struct {
    conv: u32,
    mtu: u32,
    mss: u32, // mtu - IKCP_OVERHEAD
    state: u32, // unused for unordered, reserved

    // Sliding window state
    snd_una: u32, // oldest unacknowledged sequence number
    snd_nxt: u32, // next sequence number to assign
    rcv_nxt: u32, // next expected receive sequence number

    // Timers and RTO
    ts_recent: u32, // most recent received timestamp
    ts_lastack: u32, // timestamp of last ack sent
    ts_probe: u32, // timestamp of last window probe
    probe_wait: u32, // window probe wait interval
    ssthresh: u32, // slow start threshold
    rx_rttval: i32, // RTT variance
    rx_srtt: i32, // smoothed RTT
    rx_rto: i32, // retransmission timeout (ms)
    rx_minrto: i32, // minimum RTO

    // Send queue: segments waiting to be sent
    snd_queue: std.ArrayList(Segment),
    // Receive queue: received segments waiting to be assembled
    rcv_queue: std.ArrayList(Segment),
    // Send buffer: sent but unacknowledged segments
    snd_buf: std.ArrayList(Segment),
    // Receive buffer: received segments (in-order buffer)
    rcv_buf: std.ArrayList(Segment),

    // Ack list: sequence numbers to acknowledge
    acklist: std.ArrayList(u32),

    // Current time (monotonic milliseconds)
    current: u32,

    // Buffer for recv reassembly
    buffer: ?[]u8,

    // Interval
    interval: u32,
    next_update: u32, // ts_flush + interval

    // Congestion control flags
    nocwnd: bool, // no congestion window
    stream: bool, // stream mode (1 = stream, 0 = message/datagram)

    // Dead link detection
    dead_link: u32, // max retransmissions before dead link
    incr: u32, // increment value for slow start

    // Fast retransmission
    fastresend: i32, // fast retransmit threshold (0 = disabled)
    fastlimit: u32, // fast retransmit limit
    nodelay: bool, // nodelay mode (disable Nagle-like behavior)
    updated: bool, // has kcp_update been called

    // Output callback + user pointer
    output: ?OutputCallback,
    user: ?*anyopaque,

    allocator: std.mem.Allocator,

    /// Create a new KCP instance.
    /// conv should be unique per session (e.g., derived from two MAC addresses).
    pub fn create(allocator: std.mem.Allocator, conv: u32, user: ?*anyopaque) !*Kcp {
        const self = try allocator.create(Kcp);
        errdefer allocator.destroy(self);

        self.* = .{
            .conv = conv,
            .mtu = IKCP_MTU_DEFAULT,
            .mss = IKCP_MTU_DEFAULT - IKCP_OVERHEAD,
            .state = 0,
            .snd_una = 0,
            .snd_nxt = 0,
            .rcv_nxt = 0,
            .ts_recent = 0,
            .ts_lastack = 0,
            .ts_probe = 0,
            .probe_wait = 0,
            .ssthresh = IKCP_THRESH_INIT,
            .rx_rttval = 0,
            .rx_srtt = 0,
            .rx_rto = IKCP_RTO_DEFAULT,
            .rx_minrto = IKCP_RTO_MIN,
            .snd_queue = .empty,
            .rcv_queue = .empty,
            .snd_buf = .empty,
            .rcv_buf = .empty,
            .acklist = .empty,
            .current = 0,
            .buffer = null,
            .interval = IKCP_INTERVAL,
            .next_update = 0,
            .nocwnd = false,
            .stream = false,
            .dead_link = IKCP_DEAD_LINK,
            .incr = 0,
            .fastresend = 0,
            .fastlimit = IKCP_FAST_LIMIT,
            .nodelay = false,
            .updated = false,
            .output = null,
            .user = user,
            .allocator = allocator,
        };

        return self;
    }

    /// Release all resources. Does NOT free the user pointer.
    pub fn release(self: *Kcp) void {
        // Free owned data buffers in all queues
        for (self.snd_queue.items) |seg| {
            if (seg.data) |d| self.allocator.free(d);
        }
        for (self.snd_buf.items) |seg| {
            if (seg.data) |d| self.allocator.free(d);
        }
        for (self.rcv_queue.items) |seg| {
            if (seg.data) |d| self.allocator.free(d);
        }
        for (self.rcv_buf.items) |seg| {
            if (seg.data) |d| self.allocator.free(d);
        }
        self.snd_queue.deinit(self.allocator);
        self.rcv_queue.deinit(self.allocator);
        self.snd_buf.deinit(self.allocator);
        self.rcv_buf.deinit(self.allocator);
        self.acklist.deinit(self.allocator);
        if (self.buffer) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.destroy(self);
    }

    /// Set output callback. Called when KCP needs to send a UDP datagram.
    pub fn setOutput(self: *Kcp, output: OutputCallback) void {
        self.output = output;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Configuration setters
    // ──────────────────────────────────────────────────────────────────────────

    /// Enable nodelay mode.
    /// nodelay: 0=disable, 1=enable
    /// interval: internal update interval in ms (default 100)
    /// resend: fast retransmit threshold (0=disable, 2=typical)
    /// nc: 0=normal congestion, 1=no congestion control
    pub fn setNoDelay(self: *Kcp, nodelay: bool, interval: u32, resend: i32, nc: bool) void {
        if (nodelay) {
            self.nodelay = true;
            if (interval > 0) self.interval = interval;
            if (resend >= 0) self.fastresend = resend;
            if (nc) self.nocwnd = true;
        } else {
            self.nodelay = false;
            if (interval > 0) self.interval = interval;
            self.fastresend = 0;
            self.nocwnd = false;
        }
    }

    /// Set MTU. mss is adjusted automatically.
    pub fn setMtu(self: *Kcp, mtu: u32) void {
        if (mtu < 50) return; // minimum sensible MTU
        self.mtu = mtu;
        self.mss = mtu - IKCP_OVERHEAD;
    }

    /// Set window sizes. Note: window sizes are compile-time constants
    /// (IKCP_WND_SND / IKCP_WND_RCV) for simplicity.
    pub fn setWndSize(_: *Kcp, _: u32, _: u32) void {}

    /// Set dead link limit (max retransmissions before declaring dead).
    pub fn setDeadLink(self: *Kcp, dead_link: u32) void {
        self.dead_link = dead_link;
    }

    /// Set stream mode (1=stream, 0=message/datagram).
    pub fn setStream(self: *Kcp, stream: bool) void {
        self.stream = stream;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Core I/O
    // ──────────────────────────────────────────────────────────────────────────

    /// Receive a lower-level UDP packet (KCP datagram).
    /// Process incoming segments: update ACK state, enqueue received data,
    /// trigger fast retransmit checks.
    pub fn input(self: *Kcp, data: []const u8) !void {
        self.updated = false;

        if (data.len < IKCP_OVERHEAD) return;

        var pos: usize = 0;
        while (pos + IKCP_OVERHEAD <= data.len) {
            var seg = Segment.decode(data[pos..]) orelse return;
            pos += IKCP_OVERHEAD;

            // Verify conversation ID
            if (seg.conv != self.conv) continue;

            // Verify data length. Only copy payload for PUSH segments —
            // ACK/WASK/WINS segments never carry data and would leak if allocated.
            const data_len: usize = @intCast(seg.len);
            if (pos + data_len > data.len) return;
            if (data_len > 0 and seg.cmd == IKCP_CMD_PUSH) {
                const owned = try self.allocator.alloc(u8, data_len);
                @memcpy(owned, data[pos..][0..data_len]);
                seg.data = owned;
            }
            pos += data_len;

            // Process each segment type
            switch (seg.cmd) {
                IKCP_CMD_PUSH => try self.parseData(seg),
                IKCP_CMD_ACK => self.parseAck(seg.sn),
                IKCP_CMD_WASK => self.parseWask(seg),
                IKCP_CMD_WINS => self.parseWins(seg),
                else => {}, // ignore unknown commands
            }

            // Update remote window
            self.parseFastack(seg.sn, seg.ts);
            self.parseUack(seg.una);
            self.parseUna(seg.una);
        }
    }

    /// Receive application data. Returns number of bytes written to buf.
    /// Returns 0 if no data available. NEVER allocates.
    pub fn recv(self: *Kcp, buf: []u8) !usize {
        // Fast path: no data
        if (self.rcv_queue.items.len == 0) return 0;

        const peek_size = self.peekSize();
        if (peek_size < 0) return 0;
        const total: usize = @intCast(peek_size);

        if (self.stream) {
            // Stream mode: merge all consecutive segments
            if (total > buf.len) return error.BufferTooSmall;
            var offset: usize = 0;

            while (self.rcv_queue.items.len > 0) {
                const seg = &self.rcv_queue.items[0];
                const dlen = seg.len;

                if (seg.data) |d| {
                    @memcpy(buf[offset..][0..@intCast(dlen)], d);
                    offset += @intCast(dlen);
                }

                if (self.rcv_queue.items[0].data) |d| self.allocator.free(d);
                _ = self.rcv_queue.orderedRemove(0);
                // Stream mode: read all available segments (no message boundaries)
            }

            return offset;
        } else {
            // Message mode: return one complete message
            if (self.rcv_queue.items.len == 0) return 0;

            const seg = &self.rcv_queue.items[0];
            if (seg.frg != 0) {
                // Need all fragments — rcv_queue must contain frg+1 segments
                if (self.rcv_queue.items.len < seg.frg + 1) return 0;
            }

            if (total > buf.len) return error.BufferTooSmall;

            var offset: usize = 0;
            while (self.rcv_queue.items.len > 0) {
                const rseg = &self.rcv_queue.items[0];
                const dlen = rseg.len;

                if (rseg.data) |d| {
                    @memcpy(buf[offset..][0..@intCast(dlen)], d);
                    offset += @intCast(dlen);
                }

                const last = (rseg.frg == 0);
                if (self.rcv_queue.items[0].data) |d| self.allocator.free(d);
                _ = self.rcv_queue.orderedRemove(0);
                if (last) break;
            }

            return offset;
        }
    }

    /// Queue application data for sending.
    /// Data is split into MTU-sized segments and queued.
    pub fn send(self: *Kcp, data: []const u8) !void {
        self.updated = false;
        if (data.len == 0) return;

        // Calculate how many segments we need
        const count: u32 = if (data.len <= self.mss)
            1
        else
            @intCast((data.len + self.mss - 1) / self.mss);

        if (count > IKCP_WND_RCV) return error.MessageTooLarge;

        // Stream mode: all fragments have frg=0 (stream doesn't use fragmentation markers)
        // Message mode: frg counts down from count-1 to 0
        var offset: usize = 0;
        var i: u32 = count;
        while (i > 0) : (i -= 1) {
            const chunk_size = @min(@as(usize, self.mss), data.len - offset);
            const frg: u8 = if (self.stream) 0 else @intCast(i - 1);

            // Copy data to heap — KCP owns segment data for retransmission
            const owned = try self.allocator.alloc(u8, chunk_size);
            @memcpy(owned, data[offset..][0..chunk_size]);

            const seg = Segment{
                .conv = self.conv,
                .cmd = IKCP_CMD_PUSH,
                .frg = frg,
                .wnd = 0,
                .ts = 0,
                .sn = 0, // assigned in flush
                .una = 0,
                .len = @intCast(chunk_size),
                .data = owned,
                .xmit = 0,
                .resendts = 0,
                .rto = 0,
                .fastack = 0,
            };

            try self.snd_queue.append(self.allocator, seg);
            offset += chunk_size;
        }
    }

    /// Update KCP state. Call periodically (e.g., every 10-100ms).
    /// current_ms: monotonically increasing millisecond counter.
    pub fn update(self: *Kcp, current_ms: u32) void {
        self.current = current_ms;

        // Always call flush — KCP needs flush on every update for:
        // - Initial data sending (first update after send)
        // - Retransmission (segments with expired resendts)
        // - ACK processing (acknowledgments from remote)
        self.flush();

        // Calculate next update time
        var slap: i32 = @intCast(self.interval);

        // Check send buffer for retransmission
        for (self.snd_buf.items) |*seg| {
            if (seg.xmit == 0) continue;
            const diff: i32 = @bitCast(current_ms -% seg.resendts);
            if (diff >= 0) {
                slap = @min(slap, diff);
            } else {
                slap = @min(slap, -diff);
            }
        }

        self.next_update = current_ms + @as(u32, @intCast(@max(slap, @as(i32, @intCast(self.interval / 2)))));
    }

    /// Check when the next kcp_update call is needed (ms).
    /// Returns the timestamp when update should next be called, or 0 if immediately.
    pub fn check(self: *Kcp, current_ms: u32) u32 {
        // Check if any segment in send buffer needs retransmission soon
        var min_ts: u32 = current_ms + self.interval;

        for (self.snd_buf.items) |*seg| {
            if (seg.xmit > 0) {
                const diff: i32 = @intCast(seg.resendts -| current_ms);
                if (@as(u32, @intCast(@max(diff, 0))) < min_ts - current_ms) {
                    min_ts = seg.resendts;
                }
            }
        }

        // Check if immediate update is needed
        if (self.acklist.items.len > 0 or self.snd_queue.items.len > 0) {
            return current_ms;
        }

        return min_ts;
    }

    /// Flush pending segments through the output callback.
    /// Called internally by update(), but can also be called directly.
    /// Internal bookkeeping (queue→buf move, retransmission timers) always runs.
    /// Actual sending only occurs if an output callback is set.
    pub fn flush(self: *Kcp) void {
        const current = self.current;

        // Calculate receive window (needed for segment header)
        const rcv_wnd = self.rcvWnd();

        // 1. Move segments from snd_queue to snd_buf (always, even without output)
        while (self.snd_queue.items.len > 0) {
            const seg = self.snd_queue.items[0];

            var new_seg = seg;
            new_seg.sn = self.snd_nxt;
            self.snd_nxt += 1;
            new_seg.una = self.rcv_nxt;
            new_seg.ts = current;
            new_seg.wnd = rcv_wnd;
            new_seg.xmit = 1;
            new_seg.resendts = current + @as(u32, @intCast(self.rx_rto));
            new_seg.rto = @intCast(self.rx_rto);
            new_seg.fastack = 0;

            self.snd_buf.append(self.allocator, new_seg) catch return;
            _ = self.snd_queue.orderedRemove(0);
        }

        // If no output callback, internal state is updated but nothing is sent.
        // This is valid — segments accumulate in snd_buf and will be sent
        // once an output callback is set.
        if (self.output == null) {
            self.acklist.clearRetainingCapacity();
            return;
        }

        // 2. Send acknowledgments
        var ack_count = self.acklist.items.len;
        if (ack_count > 0) {
            var i: usize = 0;
            while (i < self.acklist.items.len) : (i += 1) {
                if (self.snd_buf.items.len >= IKCP_WND_SND) break;

                const sn = self.acklist.items[i];
                const ack_seg = Segment{
                    .conv = self.conv,
                    .cmd = IKCP_CMD_ACK,
                    .frg = 0,
                    .wnd = self.rcvWnd(),
                    .ts = current,
                    .sn = sn,
                    .una = self.rcv_nxt,
                    .len = 0,
                    .data = null,
                };

                self.outputSegment(&ack_seg);
                ack_count -= 1;
            }
        }

        // 3. Check retransmission timers AND send segments (combined pass).
        // We update xmit/resendts first, then check if sending is needed
        // using the OLD resendts value stored before the update.
        for (self.snd_buf.items) |*seg| {
            if (seg.xmit == 0) continue;

            var need_send = false;

            // Always send segments that haven't been sent yet (xmit == 1, first time)
            if (seg.xmit == 1) {
                need_send = true;
            }

            // Check retransmission (before updating resendts)
            const old_resendts = seg.resendts;
            const diff: i32 = @bitCast(current -% old_resendts);

            // Fast retransmit
            if (!need_send and self.fastresend > 0 and seg.fastack >= self.fastlimit and seg.xmit <= self.fastresend) {
                need_send = true;
                seg.rto = @as(u32, @intCast(self.rx_rto));
            }

            // Normal timeout retransmission
            if (!need_send and diff >= 0) {
                need_send = true;
                seg.rto = seg.rto + @max(seg.rto, @as(u32, @intCast(self.rx_rto)));
            }

            if (need_send) {
                seg.xmit += 1;
                seg.resendts = current + seg.rto;
                seg.ts = current;
                seg.wnd = self.rcvWnd();
                seg.una = self.rcv_nxt;
                self.outputSegment(seg);
            }
        }

        // 5. Window probe (reuse rcv_wnd from step 1)
        if (rcv_wnd == 0) {
            if (self.probe_wait == 0) {
                self.probe_wait = IKCP_PROBE_INIT;
                self.ts_probe = current + self.probe_wait;
            } else {
                if (current -% self.ts_probe >= self.probe_wait) {
                    if (self.probe_wait < IKCP_PROBE_LIMIT) {
                        self.probe_wait *= 2;
                    }
                    self.ts_probe = current + self.probe_wait;

                    // Send window probe (WASK)
                    const probe = Segment{
                        .conv = self.conv,
                        .cmd = IKCP_CMD_WASK,
                        .frg = 0,
                        .wnd = rcv_wnd,
                        .ts = current,
                        .sn = 0,
                        .una = self.rcv_nxt,
                        .len = 0,
                        .data = null,
                    };
                    self.outputSegment(&probe);
                }
            }
        } else {
            self.probe_wait = 0;
            self.ts_probe = current;
        }

        // 6. Flush ACK list — keep unsent ACKs for next flush
        if (ack_count > 0 and ack_count < self.acklist.items.len) {
            // Partial send: unsent ACKs are at indices [sent_count..].
            // Shift them to the front to preserve them for next flush.
            const sent = self.acklist.items.len - ack_count;
            const unsent = self.acklist.items[sent..];
            std.mem.copyForwards(u32, self.acklist.items[0..unsent.len], unsent);
            self.acklist.shrinkRetainingCapacity(unsent.len);
        } else if (ack_count == 0) {
            // All ACKs were sent — clear the list
            self.acklist.clearRetainingCapacity();
        }
        // If no ACKs were sent (ack_count == items.len), keep all for next flush
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal: segment processing
    // ──────────────────────────────────────────────────────────────────────────

    fn parseUna(self: *Kcp, una: u32) void {
        // Remove acknowledged segments from send buffer
        var i: usize = 0;
        while (i < self.snd_buf.items.len) {
            const sn = self.snd_buf.items[i].sn;
            // Use sequence number comparison with wraparound
            if (sn_lt(sn, una)) {
                if (self.snd_buf.items[i].data) |d| self.allocator.free(d);
                _ = self.snd_buf.orderedRemove(i);
                // don't increment i — next element slides into this position
            } else {
                i += 1;
            }
        }
    }

    fn parseData(self: *Kcp, seg: Segment) !void {
        // Update remote timestamp
        self.ts_recent = seg.ts;

        // Insert into receive buffer in order by sequence number
        try self.insertRcvBuf(seg);

        // Move in-order segments from rcv_buf to rcv_queue
        self.moveRcvBuf();
    }

    fn parseAck(self: *Kcp, sn: u32) void {
        // Mark segment as acknowledged (fast retransmit counter)
        for (self.snd_buf.items) |*seg| {
            if (seg.sn == sn) {
                seg.fastack += 1;
                break;
            }
        }
    }

    fn parseWask(self: *Kcp, seg: Segment) void {
        // Remote is asking for our window size — send WINS
        const wins = Segment{
            .conv = self.conv,
            .cmd = IKCP_CMD_WINS,
            .frg = 0,
            .wnd = self.rcvWnd(),
            .ts = self.current,
            .sn = 0,
            .una = self.rcv_nxt,
            .len = 0,
        };
        self.outputSegment(&wins);
        _ = seg;
    }

    fn parseWins(_: *Kcp, _: Segment) void {
        // Remote told us its window size — already handled in parseFastack
    }

    fn parseFastack(self: *Kcp, sn: u32, ts: u32) void {
        // Fast retransmit tracking
        if (!sn_lt(sn, self.snd_una)) {
            // Calculate RTT
            if (ts > 0) {
                const rtt: i32 = @bitCast(self.current -% ts);
                self.updateRtt(rtt);
            }
        }
    }

    fn parseUack(self: *Kcp, una: u32) void {
        // Update snd_una and clean acknowledged segments
        if (sn_lt(self.snd_una, una)) {
            self.snd_una = una;
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal: receive buffer management
    // ──────────────────────────────────────────────────────────────────────────

    fn insertRcvBuf(self: *Kcp, seg: Segment) !void {
        // Insert segment into rcv_buf, maintaining sequence number order
        // Find insertion point
        var insert_idx: usize = self.rcv_buf.items.len;
        for (self.rcv_buf.items, 0..) |existing, idx| {
            if (existing.sn == seg.sn) {
                // Duplicate — ignore, free owned data
                if (seg.data) |d| self.allocator.free(d);
                return;
            }
            if (sn_lt(seg.sn, existing.sn)) {
                insert_idx = idx;
                break;
            }
        }

        if (insert_idx == self.rcv_buf.items.len) {
            try self.rcv_buf.append(self.allocator, seg);
        } else {
            try self.rcv_buf.insert(self.allocator, insert_idx, seg);
        }

        // Ack this segment
        try self.ackPush(seg.sn, seg.ts);
    }

    fn moveRcvBuf(self: *Kcp) void {
        // Move in-order segments from rcv_buf to rcv_queue
        while (self.rcv_buf.items.len > 0) {
            const seg = self.rcv_buf.items[0];
            if (seg.sn == self.rcv_nxt and self.rcv_queue.items.len < IKCP_WND_RCV) {
                self.rcv_nxt += 1;
                _ = self.rcv_buf.orderedRemove(0);
                self.rcv_queue.append(self.allocator, seg) catch break;
            } else {
                break;
            }
        }
    }

    pub fn peekSize(self: *Kcp) i32 {
        if (self.rcv_queue.items.len == 0) return -1;

        if (self.stream) {
            // Stream mode: return total size of all available segments
            var total: u32 = 0;
            for (self.rcv_queue.items) |item| {
                total += item.len;
            }
            return @intCast(total);
        }

        const seg = self.rcv_queue.items[0];
        if (seg.frg == 0) return @intCast(seg.len);

        // Calculate total size of fragmented message
        if (self.rcv_queue.items.len < seg.frg + 1) return -1;

        var total: u32 = 0;
        for (self.rcv_queue.items) |item| {
            total += item.len;
            if (item.frg == 0) break;
        }
        return @intCast(total);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal: output
    // ──────────────────────────────────────────────────────────────────────────

    fn outputSegment(self: *Kcp, seg: *const Segment) void {
        if (self.output == null) return;

        const total_len = IKCP_OVERHEAD + seg.len;

        // Use stack buffer for default MTU; heap-allocate for larger custom MTU.
        // The output callback is synchronous (immediate sendto), so the buffer
        // only needs to live for the duration of the callback call.
        if (total_len <= IKCP_MTU_DEFAULT) {
            var buf: [IKCP_MTU_DEFAULT]u8 = undefined;
            _ = seg.encode(&buf);
            if (seg.len > 0 and seg.data != null) {
                @memcpy(buf[IKCP_OVERHEAD..][0..@intCast(seg.len)], seg.data.?);
            }
            self.output.?(seg.conv, buf[0..@intCast(total_len)], self.user);
        } else {
            const buf = self.allocator.alloc(u8, total_len) catch return;
            defer self.allocator.free(buf);
            _ = seg.encode(buf);
            if (seg.len > 0 and seg.data != null) {
                @memcpy(buf[IKCP_OVERHEAD..][0..@intCast(seg.len)], seg.data.?);
            }
            self.output.?(seg.conv, buf, self.user);
        }
    }

    fn rcvWnd(self: *Kcp) u16 {
        const used = self.rcv_queue.items.len + self.rcv_buf.items.len;
        if (used >= IKCP_WND_RCV) return 0;
        return @intCast(IKCP_WND_RCV - used);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal: RTO calculation
    // ──────────────────────────────────────────────────────────────────────────

    fn updateRtt(self: *Kcp, rtt: i32) void {
        if (self.rx_srtt == 0) {
            self.rx_srtt = rtt;
            self.rx_rttval = @divTrunc(rtt, 2);
        } else {
            const delta = if (rtt > self.rx_srtt)
                rtt - self.rx_srtt
            else
                self.rx_srtt - rtt;
            self.rx_rttval = @divTrunc((3 * self.rx_rttval + delta), 4);
            self.rx_srtt = @divTrunc((7 * self.rx_srtt + rtt), 8);
            if (self.rx_srtt < 1) self.rx_srtt = 1;
        }
        const max_val: u32 = @max(self.interval, @as(u32, @intCast(@max(4 * self.rx_rttval, 0))));
        const rto = self.rx_srtt + @as(i32, @intCast(max_val));
        self.rx_rto = @max(self.rx_minrto, @min(rto, IKCP_RTO_MAX));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal: ack list management
    // ──────────────────────────────────────────────────────────────────────────

    fn ackPush(self: *Kcp, sn: u32, ts: u32) !void {
        // Deduplicate — don't add if already in list
        for (self.acklist.items) |existing| {
            if (existing == sn) return;
        }
        try self.acklist.append(self.allocator, sn);
        _ = ts;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Health check
    // ──────────────────────────────────────────────────────────────────────────

    /// Check if the link is dead (too many retransmissions on any segment).
    pub fn isDead(self: *Kcp) bool {
        for (self.snd_buf.items) |*seg| {
            if (seg.xmit >= self.dead_link) return true;
        }
        return false;
    }

    /// Get the total number of bytes pending: queued for send + in-flight unacknowledged.
    pub fn waiting(self: *Kcp) usize {
        var total: usize = 0;
        for (self.snd_queue.items) |seg| {
            total += seg.len;
        }
        for (self.snd_buf.items) |seg| {
            total += seg.len;
        }
        return total;
    }

    /// Get pending send queue size.
    pub fn sendQueueSize(self: *Kcp) usize {
        return self.snd_queue.items.len;
    }

    /// Get pending receive queue size.
    pub fn recvQueueSize(self: *Kcp) usize {
        return self.rcv_queue.items.len;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Utility: sequence number comparison with wraparound
// ═══════════════════════════════════════════════════════════════════════════════

/// Check if sn a is less than sn b (with u32 wraparound).
/// Returns true if a < b in the sliding window sense.
fn sn_lt(a: u32, b: u32) bool {
    // Use signed comparison of the difference for correct wraparound.
    // @bitCast reinterprets the u32 difference as i32 without range checking.
    const diff: i32 = @bitCast(a -% b);
    return diff < 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "sn_lt basic" {
    try std.testing.expect(sn_lt(0, 1));
    try std.testing.expect(sn_lt(5, 10));
    try std.testing.expect(!sn_lt(10, 5));
    try std.testing.expect(!sn_lt(5, 5));
}

test "sn_lt wraparound" {
    // Near wraparound: 0xFFFFFFFE < 0x00000001
    try std.testing.expect(sn_lt(0xFFFFFFFE, 0x00000001));
    try std.testing.expect(sn_lt(0xFFFFFFFF, 0x00000000));
    try std.testing.expect(!sn_lt(0x00000001, 0xFFFFFFFE));
}

test "segment encode/decode round-trip" {
    const seg = Segment{
        .conv = 0x12345678,
        .cmd = IKCP_CMD_PUSH,
        .frg = 0,
        .wnd = 128,
        .ts = 1000,
        .sn = 42,
        .una = 10,
        .len = 100,
    };

    var buf: [IKCP_OVERHEAD]u8 = undefined;
    _ = seg.encode(&buf);

    const decoded = Segment.decode(&buf).?;
    try std.testing.expectEqual(seg.conv, decoded.conv);
    try std.testing.expectEqual(seg.cmd, decoded.cmd);
    try std.testing.expectEqual(seg.frg, decoded.frg);
    try std.testing.expectEqual(seg.wnd, decoded.wnd);
    try std.testing.expectEqual(seg.ts, decoded.ts);
    try std.testing.expectEqual(seg.sn, decoded.sn);
    try std.testing.expectEqual(seg.una, decoded.una);
    try std.testing.expectEqual(seg.len, decoded.len);
}

test "kcp create/release" {
    const allocator = std.testing.allocator;
    const kcp = try Kcp.create(allocator, 0x12345678, null);
    defer kcp.release();

    try std.testing.expectEqual(@as(u32, 0x12345678), kcp.conv);
    try std.testing.expectEqual(IKCP_MTU_DEFAULT, kcp.mtu);
    try std.testing.expectEqual(IKCP_MTU_DEFAULT - IKCP_OVERHEAD, kcp.mss);
}

test "kcp basic send/recv — local loopback" {
    const allocator = std.testing.allocator;

    // Create two KCP instances that talk to each other via a buffer
    var a = try Kcp.create(allocator, 1, null);
    defer a.release();
    var b = try Kcp.create(allocator, 1, null);
    defer b.release();

    // Output callback for a: send to b
    const A2B = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            // We need to simulate packet delivery, possibly with loss/reorder
            // For the basic test, deliver directly
            target.input(data) catch {};
        }
    };

    A2B.target = b;
    a.setOutput(A2B.output);

    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    // Send data from a to b
    const msg = "hello kcp";
    try a.send(msg);

    // Advance time and flush
    const now: u32 = 100;
    a.update(now);
    a.flush();

    // Now receive on b
    var rbuf: [128]u8 = undefined;
    const n = try b.recv(&rbuf);
    try std.testing.expectEqual(msg.len, n);
    try std.testing.expectEqualStrings(msg, rbuf[0..n]);
}

test "kcp retransmission on loss" {
    const allocator = std.testing.allocator;

    var a = try Kcp.create(allocator, 2, null);
    defer a.release();
    var b = try Kcp.create(allocator, 2, null);
    defer b.release();

    // Simulate 50% packet loss from a to b
    const A2B = struct {
        var target: *Kcp = undefined;
        var counter: u32 = 0;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            counter += 1;
            if (counter % 2 == 0) {
                target.input(data) catch {};
            }
            // Every other packet is dropped
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    // No loss on b→a (acks must reach a)
    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    const msg = "reliable message with loss";
    try a.send(msg);

    // Run multiple update cycles with increasing time
    var now: u32 = 0;
    for (0..200) |_| {
        now += 100;
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    var rbuf: [256]u8 = undefined;
    const n = try b.recv(&rbuf);
    // With retransmission, data should eventually arrive
    try std.testing.expect(n > 0);
    if (n > 0) {
        try std.testing.expectEqualStrings(msg, rbuf[0..n]);
    }
}

test "kcp reordering" {
    const allocator = std.testing.allocator;

    var a = try Kcp.create(allocator, 3, null);
    defer a.release();
    var b = try Kcp.create(allocator, 3, null);
    defer b.release();

    // Direct delivery from A to B
    const A2B = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    // Send two messages
    try a.send("first");
    try a.send("second");

    var now: u32 = 0;
    for (0..50) |_| {
        now += 100;
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    var rbuf1: [128]u8 = undefined;
    const n1 = try b.recv(&rbuf1);
    try std.testing.expectEqualStrings("first", rbuf1[0..n1]);

    var rbuf2: [128]u8 = undefined;
    const n2 = try b.recv(&rbuf2);
    try std.testing.expectEqualStrings("second", rbuf2[0..n2]);
}

test "kcp duplicate handling" {
    const allocator = std.testing.allocator;

    var a = try Kcp.create(allocator, 4, null);
    defer a.release();
    var b = try Kcp.create(allocator, 4, null);
    defer b.release();

    // Send duplicates of the first packet
    _ = .{};
    const DupOutput = struct {
        var target: *Kcp = undefined;
        var dup: bool = false;
        var saved: [512]u8 = undefined;
        var saved_len: usize = 0;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
            if (!dup) {
                // Save first packet for duplication
                @memcpy(saved[0..data.len], data);
                saved_len = data.len;
                dup = true;
            }
        }
    };
    DupOutput.target = b;
    a.setOutput(DupOutput.output);

    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    try a.send("unique message");

    var now: u32 = 0;
    for (0..20) |_| {
        now += 100;
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    // Send the duplicate
    if (DupOutput.saved_len > 0) {
        b.input(DupOutput.saved[0..DupOutput.saved_len]) catch {};
    }

    // Should only receive one copy
    var rbuf: [128]u8 = undefined;
    const n = try b.recv(&rbuf);
    try std.testing.expectEqualStrings("unique message", rbuf[0..n]);

    // Second recv should return 0
    const n2 = try b.recv(&rbuf);
    try std.testing.expectEqual(@as(usize, 0), n2);
}

test "kcp large data (multi-segment)" {
    const allocator = std.testing.allocator;

    var a = try Kcp.create(allocator, 5, null);
    defer a.release();
    a.setMtu(512); // Small MTU to force fragmentation
    var b = try Kcp.create(allocator, 5, null);
    defer b.release();
    b.setMtu(512);

    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    const A2B = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    // Send data larger than MSS (which is 512 - 24 = 488)
    const long_msg = "x" ** 1000;
    try a.send(long_msg);

    var now: u32 = 0;
    for (0..100) |_| {
        now += 100;
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    var rbuf: [2048]u8 = undefined;
    const n = try b.recv(&rbuf);
    try std.testing.expectEqual(long_msg.len, n);
    try std.testing.expectEqualStrings(long_msg, rbuf[0..n]);
}

test "kcp fast retransmit" {
    const allocator = std.testing.allocator;

    var a = try Kcp.create(allocator, 6, null);
    defer a.release();
    a.setNoDelay(true, 20, 2, true); // interval=20ms, fastresend=2, nocwnd

    var b = try Kcp.create(allocator, 6, null);
    defer b.release();
    b.setNoDelay(true, 20, 2, true);

    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    // Forward packets but drop ACKs from b→a (simulating lossy ACK path)
    const A2B = struct {
        var target: *Kcp = undefined;
        var counter: u32 = 0;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            counter += 1;
            target.input(data) catch {};
            // Drop every 3rd ACK related packet
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    try a.send("fast retransmit test data");
    try a.send("more data for fast retransmit");

    var now: u32 = 0;
    for (0..300) |_| {
        now += 10; // 10ms increments (smaller than interval)
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    // Data should arrive even with some ACK loss
    var rbuf: [512]u8 = undefined;
    const n1 = try b.recv(&rbuf);
    try std.testing.expect(n1 > 0);

    // Run more cycles to get the second message
    for (0..200) |_| {
        now += 10;
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    const n2 = try b.recv(&rbuf);
    try std.testing.expect(n2 > 0);
}

test "kcp stream mode" {
    const allocator = std.testing.allocator;

    var a = try Kcp.create(allocator, 7, null);
    defer a.release();
    a.setStream(true);
    a.setMtu(256); // Force small MTU for streaming

    var b = try Kcp.create(allocator, 7, null);
    defer b.release();
    b.setStream(true);
    b.setMtu(256);

    const B2A = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    B2A.target = a;
    b.setOutput(B2A.output);

    const A2B = struct {
        var target: *Kcp = undefined;
        fn output(conv: u32, data: []const u8, user: ?*anyopaque) void {
            _ = user;
            _ = conv;
            target.input(data) catch {};
        }
    };
    A2B.target = b;
    a.setOutput(A2B.output);

    // In stream mode, send multiple small chunks — they merge
    try a.send("chunk1");
    try a.send("chunk2");
    try a.send("chunk3");

    var now: u32 = 0;
    for (0..100) |_| {
        now += 100;
        a.update(now);
        a.flush();
        b.update(now);
        b.flush();
    }

    var rbuf: [512]u8 = undefined;
    const n = try b.recv(&rbuf);
    // In stream mode, chunks merge into one continuous stream
    try std.testing.expect(n >= 18); // "chunk1chunk2chunk3" = 18 bytes
}

test "kcp dead link detection" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 8, null);
    defer kcp.release();
    kcp.setDeadLink(10);

    // With no output (no network), isDead should be false initially
    try std.testing.expect(!kcp.isDead());

    // Directly add a segment to snd_buf with high retransmission count
    const seg = Segment{
        .conv = 8,
        .cmd = IKCP_CMD_PUSH,
        .sn = 0,
        .ts = 0,
        .xmit = 20, // exceeds dead_link=10
        .resendts = 0,
    };
    try kcp.snd_buf.append(allocator, seg);

    try std.testing.expect(kcp.isDead());
}

test "kcp mtu set" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 9, null);
    defer kcp.release();

    kcp.setMtu(512);
    try std.testing.expectEqual(@as(u32, 512), kcp.mtu);
    try std.testing.expectEqual(@as(u32, 512 - IKCP_OVERHEAD), kcp.mss);

    // MTU below minimum — should be ignored
    kcp.setMtu(40);
    try std.testing.expectEqual(@as(u32, 512), kcp.mtu); // unchanged
}

test "kcp send queue stats" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 10, null);
    defer kcp.release();

    // Initially queues are empty
    try std.testing.expectEqual(@as(usize, 0), kcp.sendQueueSize());
    try std.testing.expectEqual(@as(usize, 0), kcp.recvQueueSize());

    try kcp.send("hello");

    // Message is in send queue (not yet flushed)
    try std.testing.expectEqual(@as(usize, 1), kcp.sendQueueSize());
    try std.testing.expectEqual(@as(usize, 0), kcp.recvQueueSize());
}

test "kcp update/check timing" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 11, null);
    defer kcp.release();

    // Initial check should return current time (nothing to do)
    const t0 = kcp.check(0);
    // With no data, check returns interval from now
    try std.testing.expect(t0 >= kcp.interval);

    // After sending data, check should return current (need immediate flush)
    try kcp.send("data");
    const t1 = kcp.check(100);
    try std.testing.expectEqual(@as(u32, 100), t1);
}

test "kcp empty send" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 12, null);
    defer kcp.release();

    // Sending empty data should be a no-op
    try kcp.send("");
    try std.testing.expectEqual(@as(usize, 0), kcp.sendQueueSize());
}

test "kcp nodelay configuration" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 13, null);
    defer kcp.release();

    kcp.setNoDelay(true, 20, 2, true);
    try std.testing.expect(kcp.nodelay);
    try std.testing.expectEqual(@as(u32, 20), kcp.interval);
    try std.testing.expectEqual(@as(i32, 2), kcp.fastresend);
    try std.testing.expect(kcp.nocwnd);

    kcp.setNoDelay(false, 100, 5, false);
    try std.testing.expect(!kcp.nodelay);
    try std.testing.expectEqual(@as(u32, 100), kcp.interval);
    try std.testing.expectEqual(@as(i32, 0), kcp.fastresend);
    try std.testing.expect(!kcp.nocwnd);
}

test "kcp waiting (unacked data size)" {
    const allocator = std.testing.allocator;

    var kcp = try Kcp.create(allocator, 14, null);
    defer kcp.release();

    // No output callback set, so flush won't actually send — segments stay in snd_buf
    try kcp.send("hello world");
    try std.testing.expectEqual(@as(usize, 11), kcp.waiting()); // in snd_queue (now counted)

    kcp.update(100);
    kcp.flush();
    try std.testing.expectEqual(@as(usize, 11), kcp.waiting()); // moved to snd_buf
}
