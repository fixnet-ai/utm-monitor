//! Cross-thread completion notification via atomic flag.
//!
//! The IPC handler thread creates a Completion before submitting a command
//! to the Mesh thread, then blocks on `wait()`. When the Mesh thread finishes
//! processing, it calls `signal()` to wake the IPC handler.
//!
//! ## Design
//!
//! Uses a single `std.atomic.Value(bool)` with acquire/release ordering.
//! The consumer (IPC handler) polls in 1ms intervals until signaled or timeout.
//! This is intentionally simple — no heap allocation, no platform-specific fd.
//!
//! The 1ms poll interval adds negligible latency compared to KCP network
//! delays (10ms+ even on localhost). If sub-ms wake latency is ever needed,
//! replace with Futex (Linux) or `std.Thread.Semaphore`.
//!
//! ## Thread Safety
//!
//! - `signal()`: called by Mesh thread (producer) — atomic store with release
//! - `wait()` / `isSignaled()`: called by IPC handler (consumer) — atomic load with acquire
//! - No mutex, no heap allocation, no platform-specific syscalls

const std = @import("std");

/// Cross-thread completion notification.
///
/// Usage (IPC handler thread):
///   1. completion = Completion.init()
///   2. Register completion in shared map: state.registerCompletion(cmd_id, &completion)
///   3. Push command to CmdQueue
///   4. completion.wait(30000) // blocks until signaled or timeout
///   5. Read results from shared state
///
/// Usage (Mesh thread):
///   1. Process incoming KCP data
///   2. Look up completion by cmd_id in shared map
///   3. Write results to shared state
///   4. completion.signal() // wakes IPC handler
pub const Completion = struct {
    const Self = @This();

    signaled: std.atomic.Value(bool),

    /// Create a new completion in the unsignaled state.
    /// Zero allocation — safe to create on the stack.
    pub fn init() Self {
        return .{ .signaled = std.atomic.Value(bool).init(false) };
    }

    /// Signal completion. Called by the producer (Mesh thread).
    /// Thread-safe: may be called from any thread.
    pub fn signal(self: *Self) void {
        self.signaled.store(true, .release);
    }

    /// Block until signaled, or timeout expires.
    /// Returns true if signaled, false on timeout.
    /// Called by the consumer (IPC handler thread).
    /// Polls every 1ms — acceptable for operation completion (KCP has >10ms latency).
    pub fn wait(self: *Self, io: std.Io, timeout_ms: u32) bool {
        const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + timeout_ms;
        while (true) {
            if (self.signaled.load(.acquire)) {
                // Clear the flag so the Completion can be reused
                self.signaled.store(false, .release);
                return true;
            }
            if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) return false;
            // 1ms poll interval — balances latency vs CPU usage
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch return false;
        }
    }

    /// Non-blocking check: returns true if already signaled.
    /// Does NOT clear the flag — call wait() to consume the signal.
    pub fn isSignaled(self: *const Self) bool {
        return self.signaled.load(.acquire);
    }

    /// Reset to unsignaled state for reuse.
    pub fn reset(self: *Self) void {
        self.signaled.store(false, .release);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "completion init unsignaled" {
    var c = Completion.init();
    try testing.expect(!c.isSignaled());
}

/// Helper: get a minimal Io instance for test use.
fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "completion signal then wait" {
    var c = Completion.init();
    const io = testIo();

    // Signal first, then wait — should return immediately
    c.signal();

    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try testing.expect(c.wait(io, 1000));
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;
    // Should complete in well under 100ms (signaled before wait)
    try testing.expect(elapsed < 50);

    // Flag should be cleared after wait
    try testing.expect(!c.isSignaled());
}

test "completion wait with timeout" {
    var c = Completion.init();
    const io = testIo();

    // No signal — should timeout
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try testing.expect(!c.wait(io, 20));
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;
    // Should be at least close to the timeout (with small tolerance)
    try testing.expect(elapsed >= 15);
}

test "completion wait then signal from another thread" {
    var c = Completion.init();
    const io = testIo();

    // Spawn a thread that signals after a short delay
    const thread = try std.Thread.spawn(.{}, signalAfterDelay, .{&c, 30 * std.time.ns_per_ms, io});
    thread.detach();

    // Wait should succeed
    try testing.expect(c.wait(io, 5000));
}

fn signalAfterDelay(c: *Completion, delay_ns: u64, io: std.Io) void {
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(delay_ns), .awake) catch {};
    c.signal();
}

test "completion multiple signals" {
    var c = Completion.init();
    const io = testIo();

    c.signal();
    try testing.expect(c.wait(io, 100));

    // Second signal
    c.signal();
    try testing.expect(c.wait(io, 100));

    // Should be cleared
    try testing.expect(!c.isSignaled());
}

test "completion two completions independent" {
    var c1 = Completion.init();
    var c2 = Completion.init();
    const io = testIo();

    // Signal c2 only
    c2.signal();

    try testing.expect(c2.isSignaled());
    try testing.expect(!c1.isSignaled());

    // c1 should timeout
    try testing.expect(!c1.wait(io, 10));

    // Signal c1 now
    c1.signal();
    try testing.expect(c1.wait(io, 100));
}

test "completion concurrent threads" {
    var c = Completion.init();
    const io = testIo();

    // Spawn a thread that waits for signal
    const thread = try std.Thread.spawn(.{}, concurrentWaiter, .{&c, io});
    thread.detach();

    // Give the waiter time to enter wait()
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};

    // Signal the waiter
    c.signal();

    // Give time for the waiter to complete
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
}

fn concurrentWaiter(c: *Completion, io: std.Io) void {
    const signaled = c.wait(io, 5000);
    std.debug.assert(signaled);
}

test "completion zero timeout unsignaled" {
    var c = Completion.init();
    const io = testIo();

    // Zero timeout should return immediately without signaling
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try testing.expect(!c.wait(io, 0));
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;
    try testing.expect(elapsed < 5);
}

test "completion zero timeout signaled" {
    var c = Completion.init();
    const io = testIo();

    c.signal();
    try testing.expect(c.wait(io, 0));
}

test "completion reset after signal" {
    var c = Completion.init();
    const io = testIo();

    c.signal();
    try testing.expect(c.isSignaled());

    c.reset();
    try testing.expect(!c.isSignaled());
    try testing.expect(!c.wait(io, 10));
}
