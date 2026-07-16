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

### Timestamp.nanoseconds is i96

```zig
// GuestState.last_seen type must be i96, not i64
last_seen: i96,  // not i64
```

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
| `executablePath(allocator)` | `executablePath(io, &buf)` returns usize |
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
- `comptime { _ = @import("..."); }` at top level to include modules
- Juicy Main: `pub fn main(init: std.process.Init) !void`
- args type: `[]const [:0]const u8`
- Container initialization: `.empty` (collections), `.init` (stateful types)
- `usingnamespace` removed
- `@cImport` will fail to compile, use Zig native API instead
- `std.process.getCwd()` doesn't exist, use `std.process.currentPath(io, &buf)` or `std.c.getcwd(buf, size)`
- In threads, `std.process.currentPath` (IO vtable) may return `error.FileNotFound`, use `std.c.getcwd` for direct libc call to bypass
- `std.process.max_path_bytes` not pub, use `std.fs.max_path_bytes` instead

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

## HTTP Server/Client Implementation Notes (v2.0.0)

FTP was removed in v2.0.0. The HTTP migration eliminated PASV data channel issues, port management complexity, and custom protocol parsing. See `http-migration-plan.md` for the full design.

### Key std.http.Server Patterns (Zig 0.16.0)
- `http.Server.init(&reader.interface, &writer.interface)` — takes pointer to interfaces
- `server.receiveHead()` — 0 args, returns Request
- `request.respond(body, options)` — one-shot response
- `request.respondStreaming(request, buffer, options)` — for large files (RespondStreamingOptions has `respond_options` and `content_length`)
- `http.BodyWriter.writer` — field (not method), type `Io.Writer`
- No `server.deinit()` or `request.deinit()` needed in 0.16.0

### Key std.http.Client Patterns (Zig 0.16.0)
- `http.Client{ .allocator, .io }` → `client.request(method, uri, opts)`
- `sendBodiless()` for GET, `sendBodyComplete(body)` for POST
- `receiveHead(&redirect_buf)` → `response.head.status`

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
