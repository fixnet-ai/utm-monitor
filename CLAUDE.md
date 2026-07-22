# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep communication and documentation in English**

## Project Overview
This is a helper tool for UTM virtual machines. Because UTM VM IPs change frequently, this program notifies the host of each guest machine's real IP at all times.

A self-starting Zig program that connects to the Host via WebSocket, announcing its name and current IP. It is placed on each guest system to auto-start, while the host runs a unified HTTP server that handles guest registration, management commands, MCP JSON-RPC, and static file serving — all on a single port. The same binary defaults to guest mode, and `--host` switches to host mode.

The program is written in Zig 0.16.0, with cross-compilation on the host to build binaries for all platforms.
Current configuration:
Three VMs (macvm/windows/linux) have their IPs written to `/etc/hosts`.
VM login credentials:
macvm: user=root, passwd=111, app_path=/opt/utmm/
linuxvm: user=root, passwd=111, app_path=/opt/utmm/
windowsvm: user=Administrator, passwd=111, app_path=C:\opt\utmm\

## Architecture Design

### Two Run Modes (Same Binary)
- **Guest mode (default)**: Foreground mode — detects TTY, stops any background service, runs in terminal, restarts service on exit. Non-TTY invocation (e.g., scheduled tasks) falls back to daemon mode with `is_svc = true` — no `--svc` flag needed for schtasks/launchd/systemd. With `--svc`: explicit daemon mode (WebSocket connection to Host + command processing). Use `--install --user` to create a desktop shortcut (UTMM.command / UTMM.bat / utmm.desktop).
- **Host mode (--host)**: Unified HTTP server on port 2121 — guest registration (WebSocket + HTTP announce), management commands (exec/upload/download), MCP JSON-RPC, static file serving (/bin/), and /etc/hosts sync. All on one port. No separate MCP port or process.

### Complete Data Flow
```
                         ┌── MCP HTTP /mcp (JSON-RPC) ← AI Agent
Guest (macvm)    ──WebSocket──┐
Guest (linuxvm)  ──WebSocket──┤──→ Host HTTP :2121 ──┼── GET /bin/ (static file serving)
Guest (windows)  ──WebSocket──┘                      ├── POST /exec, /upload, /download
                         ┌── HTTP POST /announce ─────┘   (CLI management commands)
                         │   (backward compat)        └── /etc/hosts sync
```

### Communication Protocol
- **WebSocket** (port 2121, path `/ws`): Guest persistent connection to Host. Binary frames (1-byte message type + type-specific payload). Handles announce, exec, upload, download. String fields null-terminated, binary data 4-byte big-endian length prefix. No base64/JSON encoding for binary data.
- **HTTP REST** (port 2121): CLI management commands (`--status`/`--exec`/`--upload`/`--download`) send HTTP requests to Host. Host communicates with Guest via WebSocket for command execution.
- **MCP JSON-RPC** (port 2121, path `/mcp`): AI agent entry point. Reads guest table directly from Host memory — no UDP discovery, no state file. Single unified HTTP server.
- **Backward compat HTTP announce** (POST `/announce`): Old guests that don't support WebSocket can still use HTTP polling. Returns pending commands in response.

### Key Design Decisions
- Single binary, dual mode: reduces maintenance burden
- Unified HTTP server on single port (2121): replaces UDP broadcast + TCP binary frames + MCP :2122
- WebSocket persistent connection: Guest→Host real-time push, no polling for commands. Binary frames for exec/upload/download — zero encoding overhead
- **Connection = Shell Session**: Each WebSocket lifecycle is one shell session. After exec completes, Guest sends exec_exit, flushes TCP (200ms), disconnects WebSocket, and reconnects — giving Host a fresh shell session. This removes the need for exec_signal (type 12) — closing the WebSocket implicitly terminates any running command (SIGPIPE/kill on cleanup). Host-side `--kick <vm>` closes a guest's WebSocket connection, failing all pending commands with "disconnected" error.
- `std.http.Server` with `std.Thread` concurrency — each connection gets its own thread
- Zero external dependencies: no Node.js, no Python, no SSH/SCP, no curl — everything via HTTP + WebSocket
- Guest auto-discovers Host via default gateway (UTM Host is the gateway)
- **Windows child processes**: On Windows, `std.process.Init.io` is `global_single_threaded` which uses `Allocator.failing`. Use `std.Io.Threaded.init(gpa, .{})` for `std.process.run` on Windows in daemon/service contexts. In foreground mode (agent.zig), `init.io` from the desktop shortcut works directly.
- **Windows exec wakeup**: POSIX uses poll() with 1s timeout to detect exec completion. Windows has no poll() — the main loop blocks on `readFrame` forever. Solution: exec thread sends a WebSocket PING after setting `exec_done=true`. Host responds with PONG (per RFC 6455), which wakes Guest's `readSmallMessage`. The ping/pong handler is in `host_http.zig` — `readSmallMessage` does NOT auto-respond to pings.

## Build & Run

### Build
```bash
zig build                    # Native build → zig-out/bin/utmm
zig build -Dtarget=aarch64-linux-musl    # → utmm-aarch64-linux
zig build -Dtarget=aarch64-macos   # → utmm-aarch64-macos
zig build -Dtarget=aarch64-windows  # → utmm-aarch64-windows.exe
zig build -Dtarget=x86_64-linux-musl    # → utmm-x86_64-linux
zig build -Dtarget=x86_64-macos   # → utmm-x86_64-macos
zig build -Dtarget=x86_64-windows  # → utmm-x86_64-windows.exe
```

> **Note**: 32-bit x86 targets are now supported again. x86-linux-musl builds and passes tests. x86-windows has a pre-existing linker issue (`_system@4` symbol resolution) unrelated to our code — this is a Zig/LLD toolchain limitation when targeting 32-bit Windows. All modern UTM VMs are aarch64 or x86_64.

### Tests/Testing
```bash
zig build test                                   # All tests
```

### Guest End Runtime
```bash
utmm                                      # Default Guest (foreground: stop service, run, restart on exit)
utmm --hostname myvm --port 2121         # Custom parameters
utmm --svc                                # Daemon mode (launched by service manager)
utmm --install                            # Install as system service (Guest mode)
utmm --install --user                     # Create desktop shortcut (UTMM) for foreground launcher
utmm --uninstall --user                   # Remove desktop shortcut
```

### Host End Runtime
```bash
# ── Persistent Host (background daemon) ──
sudo utmm --host                          # Start HTTP server on :2121 (needs sudo for /etc/hosts)
utmm --host --install                     # Install as system service (launchd/systemd/sc)
utmm --host --uninstall                   # Remove system service
utmm --host --serve-dir /path/to/binaries # Custom binary serve directory

# ── Management Commands (HTTP to Host :2121) ──
utmm --status                             # Query all Guest status
utmm --exec linuxvm "uname -a"            # Remote command execution (no timeout)
utmm --kick linuxvm                      # Close guest WebSocket (cancels running exec)
utmm --upload file.txt linuxvm            # Upload file to Guest (no curl)
utmm --download linuxvm f.txt ./f.txt     # Download file from Guest (no curl)

# Management commands send HTTP requests to Host on 127.0.0.1:2121.
# Host communicates with Guest via WebSocket for command execution.
# Exec uses streaming protocol: exec_start→guest spawns child→exec_stdout chunks→exec_exit.
# No 30s timeout — commands run indefinitely. exec_exit → Guest disconnects, reconnects
# for fresh shell session (Connection = Shell Session). Use --kick to cancel.
```

## Project File Structure
```
src/
├── main.zig           # Entry point, CLI parsing, mode dispatch
├── ver.zig            # Single source of truth for version (bump to trigger auto-upgrade)
├── protocol.zig       # Protocol constants: DEFAULT_PORT, VERSION
├── wsproto.zig        # Binary WebSocket protocol: 12 msg types (announce, exec_req/resp, upload_req/resp, download_req/resp, exec_start/stdout/stdin/exit/signal)
├── wsclient.zig       # Guest WebSocket client: TCP connect + HTTP upgrade + frame I/O
├── httpd.zig          # HTTP server core: accept loop + Router + HostState (guest table + pending queue)
├── host_http.zig      # HTTP endpoint handlers: /announce, /exec, /upload, /download, /ws, /mcp, /bin/
├── guest.zig          # Guest orchestration: WebSocket announce loop (no TCP server)
├── host.zig           # Host orchestration: management cmd dispatch + HTTP server start
├── broadcast.zig      # Guest: getLocalIp/getHostname/getDefaultGateway + wsAnnounceLoop
├── hosts_file.zig     # /etc/hosts marked block read/write
├── mcp.zig            # MCP JSON-RPC handler: processJsonRpcWithState — reads HostState directly
├── install.zig        # --install/--uninstall system service + --gen-init script generation + desktop shortcuts
├── agent.zig          # Guest: foreground mode (stop service, run in TTY, restart on exit)
└── config.zig         # Config persistence + logging system
```

## Code of Conduct / Guidelines

Before starting any work, read the following files (if they exist), then use the **'/superpowers'** plugin for development:
- `./CLAUDE.md`
- `./README.md`
- `./zig-codegen.md`

### Zig 0.16.0 Language Features

- When encountering compilation errors, **must** read `zig-codegen.md` to learn and understand, avoiding repeated mistakes
- Look up correct usage from the [Zig 0.16.0 Language Manual](https://ziglang.org/documentation/0.16.0/), don't guess syntax
- After each compilation issue is resolved, **append experience to `zig-codegen.md`**, continuously accumulating coding knowledge
- Before writing code, enable the zig skill to understand language standards and features

### Key Zig 0.16.0 Changes
- `std.posix.socket` removed, network API migrated to `std.Io.net`
- `std.net` removed, use `std.Io.net.IpAddress.parse()` for address parsing
- `root_source_file` → `root_module = b.createModule(...)`
- Container initialization: `.{}` → `.empty` / `.init`
- `usingnamespace` / `async`/`await` / `@Type` / `@cImport` — removed
- libxev `close()` returns void on kqueue backend (not error union)
- `std.process.Child.Term` fields are lowercase: `.exited`, `.signal`, `.stopped`, `.unknown`. Combine cases: `.signal, .stopped, .unknown =>` (comma-separated, no payload capture)
- `std.Io.Threaded.global_single_threaded` uses `Allocator.failing` — never use for `std.process.run` (causes OutOfMemory). Use `std.Io.Threaded.init(gpa, .{})` instead

### Io API Patterns (0.16.0)
- `Io.Reader` has no `.read()` method. Use `.stream(writer, limit)` to copy to a Writer, or `.streamExact(writer, n)` for exact reads
- `Io.Writer.write()` returns `usize` (bytes written) — must discard with `_ =`
- `Stream.Writer` has `interface: Io.Writer` — use `writer.interface.flush()` to drain buffered data
- `Stream.Reader` has `interface: Io.Reader` — use `reader.interface.streamExact(&writer, n)` for exact reads

### HTTP Server Patterns (0.16.0)
- `http.Server.Request.upgradeRequested()` returns `UpgradeRequest` with `.websocket` field (optional `[]const u8` key)
- `http.Server.Request.respondWebSocket(.{ .key = ws_key })` upgrades to WebSocket
- `WebSocket.readSmallMessage()` blocks until a message arrives, returns `SmallMessage { opcode, data }`
- `WebSocket.writeMessage(data, opcode)` writes a frame; server→client frames are unmasked
- Client-side WebSocket frames MUST be masked (RFC 6455) — handled manually in wsclient.zig

### Threaded I/O Concurrency Patterns
- `std.Thread.spawn(.{}, fn, .{args...})` → `thread.detach()` for fire-and-forget tasks
- `std.Io.net.Stream` with `reader(io, &buf)` / `writer(io, &buf)` for buffered TCP I/O
- Host: `std.http.Server` handles accept loop; each connection dispatched to a handler in its own thread
- Guest: main thread runs WebSocket event loop; exec commands spawn child processes
- On Windows daemon/service contexts, use `std.Io.Threaded.init(gpa, .{})` for `std.process.run` (not `global_single_threaded` — uses `Allocator.failing`)

### 1. Think Before Coding
**Don't assume. Don't hide confusion. Explicitly present trade-offs.**
Clearly state assumptions before implementation, present them when multiple interpretations exist.

### 2. Simplicity First
**Minimum code to solve the problem. No speculative additions.**
Don't add unrequested features, don't create abstractions for single use.

### 3. Precise Changes
**Only change what's necessary. Only clean up messes you create.**
Don't improve adjacent code/comments/formatting, match existing style.

### 4. Goal-Driven Execution
**Define success criteria. Loop until verified passing.**
Turn tasks into verifiable goals: "Write test for X, then implement and verify."
