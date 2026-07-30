# Zig 0.16.0 Coding Experience/Knowledge

This file records compilation issues and solutions encountered while using Zig 0.16.0 in the utmm project.

## Build System

### build.zig.zon

```zig
.{
    .name = .utm_monitor,          // Enum literal, not string
    .version = "1.0.0",
    .fingerprint = 0x...,          // Required field, use the suggested value
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

### build.zig

- Use `b.createModule(...)` instead of `root_source_file`
- Tests use `b.addTest(.{ .root_module = exe.root_module })`

## Network API (std.Io.net)

| Old API | New API (0.16.0) |
|--------|----------------|
| `std.net` / `std.posix.socket` | `std.Io.net` |
| `IpAddress.parse("0.0.0.0", port)` | Same, but returns `!IpAddress` |
| `socket.listen()` | `address.listen(io, .{ .reuse_address = true })` returns `Server` |
| `socket.accept()` | `server.accept(io)` returns `Stream` |
| `socket.bind()` | `address.bind(io, .{ .mode = .dgram/.stream })` returns `Socket` |
| `socket.connect()` | `address.connect(io, .{ .mode = .stream })` returns `Stream` |
| `Socket.Mode.datagram` | `.dgram` |
| ❌ `Socket.getLocalAddress()` | Use `socket.address` field |
| ❌ `Stream.getLocalAddress()` | Use `stream.socket.address` |
| ❌ `std.Io.net.getHostname()` | `std.posix.gethostname(buf)` |

### UDP Datagram Operations

```zig
// Bind for broadcast send + receive
const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
const socket = try addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
defer socket.close(io);

// Send datagram (connectionless — specify dest on every call)
try socket.send(io, &dest_addr, data);

// Receive with timeout
const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(1), .clock = .awake } };
const msg = socket.receiveTimeout(io, &buf, timeout) catch |err| {
    switch (err) {
        error.Timeout => ...,
        else => ...,
    }
};
// msg.from: IpAddress — sender address for response
// msg.data: []u8 — received bytes, slice into caller's buffer
```

- `BindOptions.allow_broadcast = true` — required for sending (Linux+macOS) AND receiving broadcasts (macOS only). Without it on macOS, broadcast packets are silently dropped on receive.
- `Socket.send()` — `(s, io, dest, data)` where `dest` is `*const IpAddress`.
- `Socket.receiveTimeout()` — `(s, io, buffer, timeout)` returns `ReceiveTimeoutError!IncomingMessage` with `.from` and `.data`.

### `std.Io.net` on macOS: kqueue Makes Sockets Non-Blocking

**This is the root cause behind the EAGAIN bug (v0.13.2).**

`std.Io.net.Server.listen()` uses kqueue on macOS, which requires all managed
file descriptors to be non-blocking. The fd returned by `Server.accept()` inherits
this property. Even though we never call `fcntl(O_NONBLOCK)`, the accepted TCP
socket IS non-blocking at the kernel level.

Our TCP I/O model is intentionally split across platforms:
- **Socket setup**: `std.Io.net` (listen/accept/connect) — convenience, reuse_address, FD_CLOEXEC
- **Data I/O**: raw `system.read()`/`system.write()` wrapped by `sockRead()`/`sockWrite()`

This split exists because Zig 0.16.0 uses AFD kernel handles on Windows, which
are incompatible with Winsock2 `recv`/`send`. Cross-platform consistency requires
raw syscalls for data I/O on all platforms.

The consequence: `system.read()` on a kqueue-managed fd returns EAGAIN when no
data is available. `sockRead()`/`sockWrite()` bridge this gap with EAGAIN/EINTR
retry loops, presenting blocking I/O semantics to callers.

```zig
// ✅ CORRECT — all TCP data I/O must go through sockRead/sockWrite
const n = sockRead(fd, buf.ptr, buf.len);
const n = sockWrite(fd, data.ptr, data.len);

// ❌ WRONG — raw system.read/write on sockets from Io.net
const n = system.read(fd, buf.ptr, buf.len);   // EAGAIN on macOS!
const n = system.write(fd, data.ptr, data.len); // EAGAIN on macOS!
```

**Enforcement rule**: NO raw `system.read()` or `system.write()` on any socket fd
in the entire codebase. Always use `tcp.sockRead()` / `tcp.sockWrite()`. This
applies to `tcp.zig`, `ipc.zig`, `guest.zig`, `host.zig`, and any new code.

**Why UDP doesn't have this problem**: LSA reads use `socket.receiveTimeout()`
(Zig's `std.Io.net.Socket` method), which is part of the Io abstraction and
handles kqueue semantics internally.

### ConnectOptions Must Specify mode

```zig
// Error: .{} missing mode
try address.connect(io, .{});

// Correct
try address.connect(io, .{ .mode = .stream }); // TCP
try address.connect(io, .{ .mode = .dgram });  // UDP
```

## Time API (std.Io.Timestamp / Duration / Clock)

| Old API | New API (0.16.0) |
|--------|----------------|
| `Timestamp.now(io, .realtime)` | `Timestamp.now(io, .real)` |
| ❌ `Timestamp.unixSeconds()` | Use `.nanoseconds` field (i96) |
| ❌ `Timestamp.fromNow(io, .{ .seconds = 2 })` | `Timestamp.now(io, .real).addDuration(Duration.fromSeconds(2))` |
| ❌ `Timestamp.compare(...)` | Compare `.nanoseconds` directly |
| ❌ `std.Io.time.sleep()` | `std.Io.sleep(io, duration, .real)` returns error union |
| ❌ `Duration{ .seconds = 2 }` | `Duration.fromSeconds(2)` |
| ❌ `Duration.fromSecs(1)` | `Duration.fromSeconds(1)` |

### Timestamp.now Returns Timestamp Directly (Not Error Union)

```zig
// ✅ CORRECT — now() returns Timestamp, not !Timestamp
const start = std.Io.Timestamp.now(io, .real);

// ❌ WRONG — catch on non-error-union
const start = std.Io.Timestamp.now(io, .real) catch |err| { ... };
```

### Timestamp.nanoseconds is i96

```zig
// GuestState.last_seen type must be i96, not i64
last_seen: i96,  // not i64
```

### Io.Timeout Union Type

`Io.Timeout` is a tagged union, NOT a struct:

```zig
// Io.Timeout definition:
pub const Timeout = union(enum) {
    none,
    duration: Clock.Duration,
    deadline: Clock.Timestamp,
};

// ✅ CORRECT — Duration with clock
const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } };

// ✅ CORRECT — Deadline from now
const deadline = try Io.Timestamp.now(io, .real).addDuration(Io.Duration.fromSeconds(30));
const timeout: Io.Timeout = .{ .deadline = deadline };

// ✅ CORRECT — No timeout
const timeout: Io.Timeout = .none;

// ❌ WRONG — passing Io.Duration directly
wake_event.waitTimeout(Io.Duration.fromSeconds(30)); // type error!

// ❌ WRONG — passing raw u64
wake_event.waitTimeout(30_000_000_000); // type error!
```

**Key rules:**
- `.clock = .awake` for monotonic-like clock (use for timeouts, NOT `.real`)
- `Io.Duration.fromSeconds(n)` creates a `Duration` with second precision
- Nest inside `.duration` union variant: `.{ .duration = .{ .raw = duration, .clock = .awake } }`

## File I/O (std.Io.File / std.Io.Dir)

| Old API | New API (0.16.0) |
|--------|----------------|
| `file.writer(&buf)` | `file.writer(io, &buf)` — requires io parameter |
| `file.reader(&buf)` | `file.reader(io, &buf)` — requires io parameter |
| `stream.writer(&buf)` | `stream.writer(io, &buf)` — Stream.writer also requires io |
| `stream.reader(&buf)` | `stream.reader(io, &buf)` — Stream.reader also requires io |
| `createFile(io, path, .{ .mode = 0o644 })` | `createFile(io, path, .{ .permissions = @enumFromInt(0o644) })` |
| `.mode` in CreateFileOptions | `.permissions` field, value is enum |
| `dir.makeDir(io, path)` | `dir.createDir(io, path, @enumFromInt(0o755))` |
| `dir.rename(io, old, new)` | `dir.rename(old_path, new_dir, new_path, io)` — signature completely changed |
| `iter.next()` | `iter.next(io)` — requires io parameter |

### Permissions is an Enum, Not a Struct

```zig
// Error
.{ .mode = 0o644 }
.{ .mode = 0o755 }

// Correct
@enumFromInt(0o644)  // For createFile use .permissions field
@enumFromInt(0o755)  // For createDir
```

### createDir/createFile Error Names Changed

```zig
// ❌ WRONG — error.AlreadyExists no longer used for directory/file creation
std.Io.Dir.cwd().createDir(io, path, @enumFromInt(0o755)) catch |err| {
    if (err != error.AlreadyExists) return err;
};

// ✅ CORRECT — createDir returns error.PathAlreadyExists
std.Io.Dir.cwd().createDir(io, path, @enumFromInt(0o755)) catch |err| {
    if (err != error.PathAlreadyExists) return err;
};

// ✅ For createFile, delete-then-create is safer
std.Io.Dir.cwd().deleteFile(io, path) catch {};
const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o644) });
```

## Process API (std.process)

| Old API | New API (0.16.0) |
|--------|----------------|
| `RunOptions.stdout = .pipe` | ❌ Field doesn't exist, stdout always piped |
| `executablePath(allocator)` | `executablePath(io, &buf)` returns `!usize` (error union) |
| `getEnvVarOwned(allocator, "HOME")` | Use `std.c.getenv("HOME")` returns `?[*:0]u8` |

## ArrayList (std.ArrayList)

`std.ArrayList(T)` = `Aligned(T, null)` = **unmanaged version** in Zig 0.16.0.

| Old API | New API (0.16.0) |
|--------|----------------|
| `var list = ArrayList(T).init(gpa)` | `var list: ArrayList(T) = .empty` |
| `list.deinit()` | `list.deinit(gpa)` |
| `list.append(item)` | `list.append(gpa, item)` |
| `list.appendSlice(items)` | `list.appendSlice(gpa, items)` |
| `list.writer().print(...)` | `list.print(gpa, "...", .{...})` |

**HashMap** (also unmanaged in 0.16.0):

```zig
// ✅ CORRECT — HashMap/StringHashMap use .init(gpa), NOT .empty
var map = std.StringHashMap(V).init(gpa);
defer {
    // Free values if needed
    map.deinit(); // no gpa param for deinit
}
const gop = try map.getOrPut(key); // no gpa param for getOrPut
```

## Io.Reader / Io.Writer

| Old API | New API (0.16.0) |
|--------|----------------|
| `reader.interface.readByte()` | `reader.interface.takeByte()` |
| `reader.interface.readAll(buf)` | `reader.interface.readSliceAll(buf)` or `reader.interface.readSliceShort(buf)` |
| `Stream.Writer` / `File.Writer` | Different from `Io.Writer`, access underlying Io.Writer via `.interface` field |

### Writer Type Mismatch

```zig
// Error: Stream.Writer cannot convert to Io.Writer
try protocol.buildExecReq(&writer, cmd);

// Correct: use .interface field
try protocol.buildExecReq(&writer.interface, cmd);
```

## Thread Synchronization (std.Io.Mutex)

`std.Thread.Mutex` removed in Zig 0.16.0, lock primitives migrated to `std.Io`.

| Old API | New API (0.16.0) |
|--------|----------------|
| ❌ `std.Thread.Mutex` | `std.Io.Mutex` |
| `var m = std.Thread.Mutex{}` | `var m: std.Io.Mutex = std.Io.Mutex.init` |
| `m.lock()` | `m.lock(io) catch {}` — requires Io parameter |
| `m.unlock()` | `m.unlock(io)` — requires Io parameter |

### Usage Pattern

```zig
var mutex: std.Io.Mutex = std.Io.Mutex.init;

// In callback/thread
mutex.lock(io) catch {};
defer mutex.unlock(io);
// ... read/write shared data ...
```

- `init` is a constant, returns struct value (not pointer)
- `lock(io)` and `unlock(io)` **both** require Io instance (not just lock)
- lock/unlock return error union (from Io operations), typically swallowed with `catch {}`
- Ensure `defer unlock` is set immediately after successful `lock` to avoid missing unlock on error path

## Other/Miscellaneous

- `std.Thread.spawn(.{}, fn, .{args})` returns `!Thread`, use `.detach()` to detach
- Juicy Main: `pub fn main(init: std.process.Init) !void`
- args type: `[]const [:0]const u8`
- Container initialization: `.empty` (collections), `.init` (stateful types)
- `usingnamespace` removed
- `@cImport` is deprecated — use `b.addTranslateC()` in build.zig instead
- `std.process.getEnvVarOwned` removed — use `std.c.getenv("HOME")` returns `?[*:0]u8`

## ReleaseSafe Error Handling Patterns

### Discarding Non-void Error Unions (e.g., `std.process.run`)

`std.process.run()` returns `!RunResult` (non-void error union). Common patterns:

```zig
// ❌ WRONG in ReleaseSafe — discards error union
_ = std.process.run(allocator, io, .{...});

// ❌ WRONG — catch {} tries to unify RunResult with void (incompatible)
std.process.run(allocator, io, .{...}) catch {};

// ❌ WRONG — if (expr) |_| {} else |_| {}; with trailing ;
// → "expected statement, found ';'"
if (std.process.run(allocator, io, .{...})) |_| {} else |_| {};

// ❌ WRONG — _ = err in else branch discards error set
if (std.process.run(...)) |result| { _ = result; } else |err| { _ = err; }

// ✅ CORRECT — if/else with |_| discard captures, NO trailing semicolon
if (std.process.run(allocator, io, .{...})) |_| {} else |_| {}

// ✅ CORRECT — for !void functions (like mutex.lock), simple catch {} works
mutex.lock(io) catch {};
```

**Key rules:**
- `!void` error unions → `catch {}` works fine (both sides are void)
- `!RunResult` error unions → need `if/else` with `|_|` discard captures
- `|_|` discard capture is OK in ReleaseSafe (unlike `_ = err` which discards error set)
- The `if/else` without trailing `;` returns void, matching the block's expected type

## TCP Transport Protocol Patterns (v0.2.0 — deleted in v0.3.0)

v0.2.0 used a custom binary frame TCP transport protocol (`transport.zig`). Removed in v0.3.0: TCP transport layer replaced by WebSocket binary frames (`wsproto.zig` + `wsclient.zig`). Frame format was `[4B BE length][1B type][N-byte payload]` with sendMessage/recvMessage helpers. v0.2.5 removed zio async Runtime in favor of `std.Thread` + `std.Io` blocking I/O.

### errdefer + Manual Cleanup = Double-Free

`errdefer` fires on EVERY error return from the function. If you also manually call cleanup before returning an error, the cleanup happens twice:

```zig
// ❌ WRONG — double-free on error paths
var resp: ArrayList(u8) = .empty;
errdefer resp.deinit(allocator);
// ...
if (error_condition) {
    resp.deinit(allocator); // first free
    return error.Failed;    // errdefer fires → second free (double-free!)
}

// ✅ CORRECT — let errdefer handle all error-path cleanup
var resp: ArrayList(u8) = .empty;
errdefer resp.deinit(allocator);
// ...
if (error_condition) {
    // errdefer will clean up resp automatically
    return error.Failed;
}
// Only the success path calls explicit deinit:
resp.deinit(allocator);
return result;
```

## Threaded IO: `Threaded.init(gpa, .{})` vs `global_single_threaded` (v0.2.4)

Zig 0.16.0 provides two pre-built thread pool I/O instances:

| Instance | Allocator | Use Case |
|----------|-----------|----------|
| `std.Io.Threaded.global_single_threaded` | `.failing` | **Never** for `std.process.run` — any internal allocation (e.g., ArenaAllocator in `processSpawnWindows`) causes `OutOfMemory` |
| `std.Io.Threaded.init(gpa, .{})` | Real allocator | **Always** for `std.process.run` on Windows, and for any blocking I/O that may allocate internally |

### Pattern: Blocking I/O on Windows

```zig
// ❌ WRONG — global_single_threaded uses Allocator.failing → OutOfMemory
const result = std.process.run(gpa, std.Io.Threaded.global_single_threaded, .{...});

// ✅ CORRECT — dedicated Threaded instance with real allocator
var threaded = std.Io.Threaded.init(gpa, .{});
const block_io = threaded.io();
const result = std.process.run(gpa, block_io, .{...});
```

**When to use this pattern:**
- `std.process.run` on Windows in daemon/service contexts (where `init.io` is `global_single_threaded`)
- `sc stop` / `sc start` calls on Windows (these also use `std.process.run` internally)
- Any blocking I/O operation that may allocate memory internally
- On macOS/Linux: the `block_io` from `std.process.Init` or `Threaded.init` works directly — no special handling needed

### Windows Daemon I/O

On Windows, when running as a service (schtasks), `std.process.Init.io` is `global_single_threaded` which uses `Allocator.failing` — this causes `OutOfMemory` in `processSpawnWindows`. Use a dedicated `Threaded` instance instead:

```zig
fn execWindows(io: Io, gpa: std.mem.Allocator, writer: anytype, cmd: []const u8) !void {
    _ = io; // may be global_single_threaded on Windows service
    var threaded = std.Io.Threaded.init(gpa, .{});
    const block_io = threaded.io();
    const result = try std.process.run(gpa, block_io, .{
        .argv = &.{ "cmd.exe", "/c", cmd },
    });
    // ... process result ...
}
```

## `std.process.Child.Term` Switch Syntax (v0.2.4)

In Zig 0.16.0, `Term` fields are **lowercase** (not PascalCase), and multiple cases can be **combined with commas**:

```zig
// ✅ CORRECT — lowercase fields, combined cases
const exit_code: i32 = switch (result.term) {
    .exited => |code| @intCast(code),
    .signal, .stopped, .unknown => @as(i32, -1),
};

// ✅ CORRECT — explicit per-variant (POSIX: signal/stopped/unknown are distinct)
const exit_code: i32 = switch (result.term) {
    .exited => |code| @intCast(code),
    .signal => @as(i32, -1),
    .stopped => @as(i32, -2),
    .unknown => @as(i32, -3),
};

// ❌ WRONG — PascalCase fields don't exist in 0.16.0
const exit_code: i32 = switch (result.term) {
    .Exited => |code| @intCast(code),  // compile error!
    .Signal => -1,
    ...
};
```

**Key rules:**
- `Term` variants: `.exited`, `.signal`, `.stopped`, `.unknown` (all lowercase)
- Combined cases: `case_a, case_b, case_c => result` (comma-separated, no `|payload|` when combining)
- Each variant captures different payload types — `.exited` captures exit code, others have no payload

## macOS UDP Broadcast Receive Requires `.allow_broadcast`

On macOS, a UDP socket bound to `0.0.0.0` (INADDR_ANY) will NOT receive broadcast
packets unless `.allow_broadcast = true` is set in bind options. This differs from
Linux where `SO_BROADCAST` is only needed for sending.

```zig
// ❌ WRONG — won't receive broadcast packets on macOS
const socket = try addr.bind(io, .{ .mode = .dgram });

// ✅ Correct
const socket = try addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
```

**Symptom**: tcpdump confirms broadcast packets arrive on the interface, but the
Host listener never processes them. Local unicast to 127.0.0.1 still works.

## launchd: std.debug.print Goes to stderr, Not stdout

`std.debug.print` in Zig writes to stderr. launchd plists capture stdout and stderr
separately via `StandardOutPath` and `StandardErrorPath`. If only `StandardOutPath`
is configured, all `std.debug.print` output is lost.

```xml
<!-- Both keys needed to capture all output -->
<key>StandardOutPath</key>
<string>/var/log/utmm-host.log</string>
<key>StandardErrorPath</key>
<string>/var/log/utmm-host-err.log</string>
```

## `std.http.WebSocket.readSmallMessage` Does NOT Auto-Respond to Pings

Zig 0.16.0 `readSmallMessage` (in `std/http/Server.zig`) skips `.pong` frames silently but **returns `.ping` frames to the caller**. The caller MUST explicitly handle pings:

```zig
const msg = ws.readSmallMessage() catch |err| { ... };
if (msg.opcode == .ping) {
    // RFC 6455: respond to ping with pong (control frame, unmasked).
    ws.writeMessage(&.{}, .pong) catch {};
    continue;
}
```

Per RFC 6455 §5.5.2, a server receiving a ping MUST respond with a pong. Zig 0.16.0 does NOT do this automatically — if you don't handle `.ping`, pings are silently ignored.

**This matters for Windows**: POSIX uses `poll()` with timeout to detect exec completion. Windows has no poll — the main loop blocks on `readFrame` forever. The exec thread sends a ping after `exec_done=true` to wake the main loop. Without the ping handler on Host, the pong never comes back and the Guest stays blocked.

## Never Free String Literals with Allocator

```zig
// ❌ WRONG — string literal passed to allocator.free() = bus error
cmd.result.stderr = "disconnected";
// Later: allocator.free(result.stderr); // BOOM: SIGBUS at @memset(bytes, undefined)

// ✅ CORRECT — heap-allocate strings that will be freed
cmd.result.stderr = allocator.dupe(u8, "disconnected") catch "";
```

String literals are in read-only `.rodata` — `allocator.free()` tries to `@memset` the freed memory to `undefined` (for safety), which crashes with SIGBUS. This is Zig's general-purpose allocator safety behavior.

**Pattern**: If a caller unconditionally calls `allocator.free()` on a string field, always heap-allocate it with `allocator.dupe()`, even for constant strings like "disconnected" or "".

## BufferedWriter Must Be Flushed Before Close

`std.Io.File.writer(io, &buf)` returns a `BufWriter`. Data written via `fw.interface.write()`
is buffered in memory and NOT automatically flushed when the writer goes out of scope.
Must explicitly call `fw.interface.flush()` before closing the file, or data is silently lost
(file created with 0 bytes).

```zig
var fw = file.writer(io, &wb);
_ = fw.interface.write(data) catch {}; // <-- data buffered, not on disk yet
fw.interface.flush() catch {};         // <-- REQUIRED: drain buffer to file
```

## POSIX pty (posix_openpt) Patterns (v0.5.0)

### execve Must Pass std.c.environ

The third argument to `execve` is the environment. Passing `{null}` (empty environment)
means the child process has NO environment variables — no HOME, no SHELL, no USER.
`.bashrc` and `.zshrc` will not load because they are gated on `$HOME` or login-shell
detection.

```zig
// ❌ WRONG — empty environment, shell has no HOME/SHELL
_ = std.c.execve(shell_path.ptr, &argv, &[_:null]?[*:0]const u8{null});

// ✅ CORRECT — inherit parent process environment
_ = std.c.execve(shell_path.ptr, &argv, std.c.environ);
```

Windows `CreateProcessW(lpEnvironment=NULL)` auto-inherits parent environment — no bug there.

### pty Spawn Sequence (POSIX)

```zig
const master_fd = std.c.posix_openpt(std.os.O.RDWR);
_ = std.c.grantpt(master_fd);
_ = std.c.unlockpt(master_fd);

const pid = std.c.fork();
if (pid == 0) {
    // Child
    _ = std.c.setsid();
    const slave_fd = std.c.open(std.c.ptsname(master_fd), std.os.O.RDWR, 0);
    _ = std.c.ioctl(slave_fd, std.os.T.IOCSCTTY, 0);
    _ = std.c.dup2(slave_fd, 0);
    _ = std.c.dup2(slave_fd, 1);
    _ = std.c.dup2(slave_fd, 2);
    _ = std.c.close(slave_fd);
    _ = std.c.close(master_fd);
    _ = std.c.execve(shell_path, &argv, std.c.environ);
    std.c._exit(1);
}
// Parent: close slave, keep master_fd
```

### macOS/BSD: tcsetattr on pty Master Not Supported

On macOS (and BSD), the pty master fd does NOT support `tcsetattr` to disable ECHO.
Commands typed into the pty are echoed back in the output stream. To handle this:

```zig
// ❌ WRONG — returns error on macOS
_ = std.c.tcsetattr(master_fd, std.os.T.CSANOW, &termios);

// ✅ CORRECT — Host-side lastIndexOf to find MDELIM after echoed command text
if (std.mem.lastIndexOf(u8, output, "MDELIM:")) |idx| { ... }
```

Linux supports `tcsetattr` on pty master normally — ECHO can be disabled there.

### POLL.HUP Detection Prevents CPU Spin

When the shell exits, the pty master fd becomes readable with `POLL.HUP`. If only
`POLL.IN` is checked, the poll loop spins at 100% CPU because `POLL.HUP` returns
immediately every iteration.

```zig
// ❌ WRONG — spins at 100% CPU on shell exit
var pfds = [_]std.c.pollfd{.{ .fd = master_fd, .events = std.c.POLL.IN }};
_ = std.c.poll(&pfds, -1);
if (pfds[0].revents & std.c.POLL.IN != 0) { ... }

// ✅ CORRECT — check HUP first, then IN
var pfds = [_]std.c.pollfd{.{ .fd = master_fd, .events = std.c.POLL.IN }};
_ = std.c.poll(&pfds, -1);
if (pfds[0].revents & std.c.POLL.HUP != 0) {
    pty_dead = true;
    break;
}
if (pfds[0].revents & std.c.POLL.IN != 0) { ... }
```

### Shell Compatibility: -l vs --login

Use `-l` (POSIX short option) for login shells. The GNU long option `--login` is
rejected by `dash` (Debian/Ubuntu default `/bin/sh`). `-l` works on all shells:
dash, bash, zsh.

```zig
// ✅ CORRECT — works on all POSIX shells
const argv = [_][*:0]const u8{ shell_path.ptr, "-l", null };
```

### Custom wsproto PING Frame for Windows Wakeup (pty model)

Windows has no `poll()` — the main loop blocks on `readFrame` forever. When the
pty read thread detects shell exit (EOF or HUP), it sends a custom wsproto `.ping`
frame (type 9) to wake the main loop from `readFrame`:

```zig
// pty read thread: after detecting EOF/HUP, wake main loop
if (builtin.os.tag == .windows) {
    conn.writeFrame(&.{}, .ping) catch {};
}

// main loop: handle custom ping frame
.ping => {
    // pty thread signaled completion — check pty_dead, reconnect if needed
}
```

This is distinct from RFC 6455 WebSocket ping/pong (handled separately in host_http.zig
for protocol compliance per §5.5.2).

### WebSocket Frame Queue for Cross-Thread Communication

When HTTP handlers (separate threads) need to send frames to a Guest via WebSocket
(single-threaded per guest), use a per-guest FIFO queue protected by a mutex:

```zig
// HostState
outgoing_frames: std.StringHashMap(std.ArrayList([]const u8)),
mutex: std.Io.Mutex,

// HTTP handler thread: enqueue frame
fn enqueueOutgoingFrame(state: *HostState, hostname: []const u8, frame: []const u8) !void {
    state.mutex.lock(io) catch {};
    defer state.mutex.unlock(io);
    const entry = try state.outgoing_frames.getOrPut(hostname);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(gpa, frame);
}

// WS handler thread: drain queue
fn drainOutgoingFrames(state: *HostState, hostname: []const u8, ws: *WebSocket) !void {
    while (true) {
        state.mutex.lock(io) catch {};
        const frame = dequeue(state, hostname);
        state.mutex.unlock(io);
        if (frame) |f| {
            try ws.writeMessage(f, .binary);
        } else break;
    }
}
```

### OpState + Io.Event for Command Completion

HTTP handlers need to block until a command completes on the Guest. The Host uses a
shared `std.Io.Event` to wake all waiting HTTP handlers when any op completes:

```zig
// HostState
wake_event: std.Io.Event = .unset,
op_states: std.StringHashMap(OpState),  // keyed by cmd_id

// HTTP handler: enqueue frame, then block with timeout
try state.enqueueOutgoingFrame(hostname, frame);
state.wake_event.waitTimeout(io, .{ .duration = .{
    .raw = std.Io.Duration.fromSeconds(30), .clock = .awake
} }) catch |err| { ... };
state.wake_event.reset();
// Check op state: if done, extract exit_code + output

// WS handler: on pty_output, appendOpOutput → scanForMarker → if done,
// set exit_code + done flag → wake_event.set(io)
```

Key points:
- Single shared `Io.Event` wakes all HTTP handlers; each checks its own cmd_id state
- `.unset` initial state, `.set(io)` to signal, `.waitTimeout(io, timeout)` to block, `.reset()` to clear
- `Io.Event` replaces old `std.Thread.ResetEvent` (removed in 0.16.0)

### `@extern` for Win32 API Functions

Use `@extern` instead of `extern "kernel32"` for Win32 API declarations:

```zig
const ReadFile = @extern(*const fn (
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: std.os.windows.DWORD,
    lpNumberOfBytesRead: ?*std.os.windows.DWORD,
    lpOverlapped: ?*std.os.windows.OVERLAPPED,
) callconv(std.os.windows.WINAPI) std.os.windows.BOOL, .{ .library_name = "kernel32", .name = "ReadFile" });
```

**Key rules:**
- Use `callconv(std.os.windows.WINAPI)` for Win32 functions
- `.library_name` and `.name` in the second argument to `@extern`
- `std.os.windows.HANDLE`, `DWORD`, `BOOL` from `std.os.windows`
- `std.math.maxInt(u32)` for `INFINITE` (instead of `win.INFINITE`)
- `@intFromEnum(TRUE)` / `@intFromEnum(FALSE)` for BOOL comparison

## Endianness: C sockaddr_in s_addr in Zig

`s_addr` is `in_addr_t` (u32) stored by C in **network byte order** (big-endian).
On little-endian systems (macOS aarch64, Linux aarch64/x86_64), Zig reads the u32
field in **host byte order** (little-endian).

```zig
// sin.sin_addr.s_addr — u32 in host byte order on LE
const ip: u32 = sin.sin_addr.s_addr; // 0x0100007F for 127.0.0.1 on LE (not 0x7F000001)
// Must @byteSwap before extracting octets:
const ip_be: u32 = @byteSwap(ip); // 0x7F000001
// Now (ip_be >> 24) == 127 correctly identifies loopback
```

**Key rules:**
- `@byteSwap()` before `>>24`/`>>16`/`>>8` octet extraction from s_addr
- `Ip4Address.bytes` is `[4]u8` in **big-endian** (network byte order)
- Bitwise ops on LE u32 produce correct result (ip | ~netmask), but result is also in LE
- `@byteSwap` again before extracting octets from broadcast result
- Same applies to `bc == 0xFFFFFFFF`, `bc == 0`, `bc == ip` — byteSwap before comparison

## Io.Threaded Windows: net_receive 不支持 concurrent 路径

Zig 0.16.0 `Io.Threaded` 在 Windows 上的 `net_receive` 操作**不支持并发路径**。
标准库源文件 `lib/zig/std/Io/Threaded.zig` 第 3197-3199 行有明确 TODO:

```zig
.net_receive => |*o| {
    // TODO integrate with overlapped I/O or equivalent to avoid this error
    if (concurrency) return error.ConcurrencyUnavailable;
```

**调用链分析:**

```
socket.receiveTimeout()           // 带超时的 receive
  → io.operateTimeout()           // 内部创建 Batch
    → batch.awaitConcurrent()     // concurrent=true
      → batchDrainSubmittedWindows(t, b, true)
        → net_receive case: if (concurrency) return ConcurrencyUnavailable

socket.receive()                  // 无超时的 receive
  → io.operate()                  // 不同路径
    → batch.awaitAsync()          // concurrent=false
      → batchDrainSubmittedWindows(t, b, false)
        → net_receive case: 跳过 concurrency 检查，正常阻塞 I/O
```

**关键区别:** `receiveTimeout` 需要超时支持，走 concurrent 路径（APC + NtDelayExecution）。
但 AFD socket 的 overlapped I/O 回调尚未与 `awaitConcurrent` 的超时机制对接。
`receive`（无超时）走 `awaitAsync`，用 alertable wait (`waitForApcOrAlert`) 阻塞等待，
不涉及超时逻辑，工作正常。

**这是实现层面的 gap，不是架构问题:** 标准库的跨平台抽象是完整的，但 Windows 后端
的网络 concurrent I/O 实现尚未完成。等 Zig 版本升级后标准库补上 overlapped I/O 对接，
用 `receiveTimeout` 即可。

**当前 workaround:**
```zig
if (builtin.os.tag == .windows) {
    // 用阻塞 receive() + CloseHandle 解阻塞代替 receiveTimeout
    const msg = socket.receive(io, &buf) catch |err| { ... };
} else {
    // POSIX 的 receiveTimeout 基于 poll，工作正常
    const msg = socket.receiveTimeout(io, &buf, timeout) catch |err| { ... };
}
```
Shutdown 时主线程通过 atomic pointer 获取 socket handle，调用 `CloseHandle` 取消
阻塞的 `receive()`，使后台线程正常退出。

## SHA256 增量计算 (v0.11.6)

大文件的 SHA256 校验不需要将整个文件加载到内存。使用 `Sha256.init()` /
`.update()` / `.final()` 流式 API：

```zig
const Sha256 = std.crypto.hash.sha2.Sha256;

// 初始化
var sha256 = Sha256.init(.{});

// 逐块更新（每块 8KB，不需要 buffer 整个文件）
sha256.update(chunk1);
sha256.update(chunk2);
// ...

// 获取最终 hash
var hash: [32]u8 = undefined;
sha256.final(&hash);

// 转换为 hex 字符串（64 字符）
fn hexHash(hash: [32]u8, hex_buf: *[64]u8) []const u8 {
    _ = std.fmt.bufPrint(hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
    return hex_buf;
}
```

**关键点**：
- `Sha256.init({})` — 注意传入空 options `{}`（非 `.{}` 初始化，是 struct default）
- `update()` 每次传一块即可，内部状态仅 32 字节
- `final(&hash)` 消费状态并写入 32 字节 hash
- 适用于 GB 级文件 — 内存占用与文件大小无关
- 此 API 来自 `std.crypto.hash.sha2.Sha256`（Zig 0.16）

## Zig 0.16.0 API 适配记录（v0.14.7 sshpass 集成）

### extern "c" fn open() 必须传 3 个参数

Zig 中的 `extern "c" fn open()` 声明要求所有 3 个参数（path, flags, mode），
即使 `O_CREAT` 未设置也必须传 mode=0：

```zig
// ❌ 错误：缺少 mode 参数
const fd = open("/dev/tty", O_RDWR);

// ✅ 正确：显式传 mode=0
const fd = open("/dev/tty", O_RDWR, 0);
```

### allocSentinel 需要 3 个参数

Zig 0.16.0 的 `allocSentinel(T, n, sentinel)` 相比旧版增加了 sentinel 参数：

```zig
// ❌ 旧 API（2 参数）
const arr = allocator.allocSentinel(?[*:0]const u8, cmd_args.len);

// ✅ 新 API（3 参数）
const arr = allocator.allocSentinel(?[*:0]const u8, cmd_args.len, null);
```

### @enumFromInt 对 exhaustive enum 不可用 → 加 _ 变 non-exhaustive

当枚举需要容纳任意底层类型值（如子进程退出码）时，exhaustive enum 的
`@enumFromInt` 在编译期拒绝未定义的 tag 值。添加 `_` 变为 non-exhaustive：

```zig
// ❌ 编译错误：value 255 not in enum
pub const ExitCode = enum(u8) { no_error = 0, ... };
return @enumFromInt(@as(u8, 255));

// ✅ non-exhaustive enum 可容纳任意 u8 值
pub const ExitCode = enum(u8) { no_error = 0, ..., _ };
return @enumFromInt(@as(u8, 255)); // OK
```

### zig build test 的 --listen=- 协议可能卡住

`zig build test` 通过 `b.addRunArtifact()` 运行测试时，测试进程使用
`--listen=-` stdio 协议与构建系统通信。某些情况下此协议会卡住
（构建系统等待测试进程关闭 pipe，但测试进程已结束）。

**解决方案**：分步运行测试
1. 直接运行缓存的测试二进制：`.zig-cache/o/<hash>/test`
2. 或使用 `zig test <file>.zig` 逐个模块运行
3. 用 shell 手动超时检测（macOS 无 `timeout` 命令，可用 `&` + `sleep` + `kill -0`）

### open() 调用处的 allocLowerString 崩溃

`--install` 后若二进制未正确替换（MD5 不匹配），可能是：
- `forceInstall` 的 copy 步骤失败但未报错
- 新进程在旧进程完全退出前就替换了二进制

**解决**：手动 `cp zig-out/bin/utmm /opt/utmm/utmm` 确保二进制一致性。

### KCP 协议实现：序列号回绕比较

C 参考实现使用 `ITimediff(sn, una)` 宏进行 u32 序列号带绕回比较。
Zig 中用 `@bitCast` 将 u32 差值转为 i32 实现相同效果：

```zig
/// Check if sn a is less than sn b (with u32 wraparound).
pub fn sn_lt(a: u32, b: u32) bool {
    const diff: i32 = @bitCast(a -% b);
    return diff < 0;
}
```

**关键点**：
- `-%` 确保差值计算也是 wraparound（对 u32 来说就是普通 subtract，因为 u32 已经 wrap）
- `@bitCast` 将差值按 i32 解释 — 正值表示 a 较大，负值表示 b 较大
- 此方法等同于 C 的 `((i32)((a)-(b)) < 0)`
- **不得使用 `a < b`**：裸比较无法处理 u32 回绕（如 `0xFFFFFFFE < 0x00000001` 为 false，但 SN 语义下应收下）

### KCP flush buffer 设计

flush() 需要将多个 segment 打包到 MTU 大小的 UDP 数据报中。C 参考使用
栈上的 scratch buffer。Zig 的 buffer 分配策略：

```zig
// create/setMtu 时分配
self.buffer = self.allocator.alloc(u8, (mtu + IKCP_OVERHEAD) * 3) catch null;

// flush() 中使用
const buffer = self.buffer orelse return;
var ptr: usize = 0;
// ... 循环编码 segments ...
if (ptr > 0) {
    self.outputData(buffer[0..ptr]);
}
```

**关键点**：
- `* 3` — 最坏情况：ACK + WASK + WINS 各占一个 MTU
- `buffer: ?[]u8` — nullable slice，需要时才分配
- `outputData()` 直接发送 buffer slice，不涉及额外分配
- 批量编码减少了 output callback 调用次数和 UDP syscall 开销

### Zig 0.16: @divTrunc 用于正数除法（floor semantic）

```zig
// 正确：正数除法用 @divTrunc（truncate toward zero = floor for positive）
const rtomin: u32 = @intCast(@divTrunc(self.rx_rto, 8));

// 错误：@divFloor 已移除（Zig 0.14+），@divTrunc 对正数结果相同
```

### Zig 0.16: ArrayList([2]u32) vs ArrayList(u32)

当 acklist 需要存储 (sn, ts) 对时：

```zig
// 旧格式
acklist: std.ArrayList(u32),

// 新格式 — [2]u32 元组
acklist: std.ArrayList([2]u32),

// 追加
try self.acklist.append(self.allocator, .{ sn, ts });

// 访问
const sn = self.acklist.items[i][0];
const ts = self.acklist.items[i][1];
```

**关键点**：
- `.{ sn, ts }` 是 `[2]u32` 字面量
- 二维索引 `items[i][0]` 直接访问，无需中间结构体
- ArrayList 仍可做 append/clearRetainingCapacity 等操作
- 此模式比创建 struct 更轻量（无需定义新类型）

## Windows 交叉编译修复 (v0.14.7)

### std.os.windows API 移除

Zig 0.16.0 移除了 `std.os.windows` 中的多个 API 声明，需要手动 `@extern` 导入：

| 已移除 | 替代方案 |
|--------|---------|
| `std.os.windows.WriteFile` | `@extern` 声明 `kernel32.WriteFile` |
| `std.os.windows.GetStdHandle` | `@extern` 声明 `kernel32.GetStdHandle` |
| `std.os.windows.HRESULT` | 直接定义 `const HRESULT = i32` |

```zig
// ✅ Zig 0.16.0 正确做法
const WriteFile = @extern(
    *const fn (hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD,
               lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL,
    .{ .name = "WriteFile", .library_name = "kernel32" },
);
const GetStdHandle = @extern(
    *const fn (nStdHandle: DWORD) callconv(.winapi) ?HANDLE,
    .{ .name = "GetStdHandle", .library_name = "kernel32" },
);
```

### Windows fd_t 类型差异

`std.posix.fd_t` 在 POSIX 是 `i32`，在 Windows 是 `*anyopaque`（HANDLE）。
跨平台代码不能直接对 `fd_t` 使用 `parseInt`，需要平台分派：

```zig
// ❌ WRONG — 在 Windows 上 parseIparseInt(*anyopaque) 编译失败
const fd_num = std.fmt.parseInt(std.posix.fd_t, argv[i], 10) catch ...;

// ✅ 正确 — 平台分派
const fd_num = if (builtin.os.tag == .windows)
    @as(std.posix.fd_t, @ptrFromInt(std.fmt.parseInt(std.os.windows.DWORD, argv[i], 10) catch ...))
else std.fmt.parseInt(std.posix.fd_t, argv[i], 10) catch ...;
```

### struct 默认值不能使用零指针

Windows 上 `std.posix.fd_t` 是 `*anyopaque`，`@ptrFromInt(0)` 编译报错
"pointer type '*anyopaque' does not allow address zero"。
默认值使用 `undefined` 并在使用前确保已被赋值：

```zig
// ❌ Windows 编译错
pwsrc: PwSource = .{ .fd = 0 },

// ✅ 跨平台
pwsrc: PwSource = .{ .fd = undefined },
```

### DeleteProcThreadAttribute 不存在于 kernel32

`DeleteProcThreadAttribute` 是 Windows SDK 的 inline 函数，不被 kernel32.dll 导出。
应使用 `DeleteProcThreadAttributeList`：

```zig
// ❌ 链接错误: undefined symbol: DeleteProcThreadAttribute
const DeleteProcThreadAttribute = @extern(..., .{ .name = "DeleteProcThreadAttribute", ... });

// ✅ 正确
const DeleteProcThreadAttributeList = @extern(
    ..., .{ .name = "DeleteProcThreadAttributeList", .library_name = "kernel32" },
);
```

### ArrayList 初始化与 append

Zig 0.16.0 中 `ArrayList.append()` 和 `appendSlice()` 需要 Allocator 参数，
初始化使用 `.empty`（不是 `.init(allocator)`）：

```zig
// ✅ Zig 0.16.0 正确用法
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(allocator);
try buf.append(allocator, 'x');
try buf.appendSlice(allocator, "hello");
```

### 跨编译目标编译注意事项

- 原生编译（如 macOS）不会检查 Windows 代码路径的类型错误
- develepment build 成功了不代表所有目标都能编译
- 在 CI 中应包含 `zig build -Dtarget=aarch64-windows` 等交叉编译检查
- `comptime if (builtin.os.tag == ...)` 虽会消除死代码分支，但函数签名和类型定义仍会被检查
