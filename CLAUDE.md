# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep communication and documentation in English**

## Project Overview

UTM Monitor (`utmm`) — helper tool for UTM virtual machines. UTM VM IPs change
frequently; this program notifies the host of each guest's real IP at all times.
Single Zig binary, dual mode (Guest default, Host with `--host`).

**v0.7.0 auto-upgrade**: Guests detect new Host versions via UDP broadcast and
self-upgrade through a separate `utmm-old` process. Upgrade uses `fork()+execve()`
(POSIX) or `std.process.spawn` (Windows) — zero external shell commands.

**v0.5.0 pty session model**: Each Guest WebSocket connection spawns a persistent
shell (POSIX `posix_openpt` / Windows `CreatePipe`). Commands run in the same
shell session — `cd`, `export`, and shell history survive across `--exec` calls.
Completion detected via `MDELIM:$?\n` exit-code markers in pty output.

Current configuration — four VM targets tracked:
| VM | Hostname | OS | IP | Credentials | App Path |
|----|----------|-----|----|-------------|----------|
| macOS | macvm | aarch64-macos | 192.168.64.4 | root / 111 | /opt/utmm/ |
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.2 | root / 111 | /opt/utmm/ |
| Windows | windowsvm | aarch64-windows | 192.168.65.2 | Administrator / 111 | C:\opt\utmm\ |
| Windows | MODASIAIPC | x86_64-windows | 192.168.3.108 | Administrator / 111 | C:\opt\utmm\ |

## Architecture Design

### Two Run Modes (Same Binary)

- **Guest mode (default)**: Foreground mode — stops background service, runs in
  terminal, restarts service on exit. `--svc`: daemon mode (WebSocket + pty shell).
  `--install --user`: desktop shortcut (UTMM.command / UTMM.bat / utmm.desktop).
  `--version`: print version. `--update-url`: upgrade mode (internal, launched by `utmm-old`).
- **Host mode (`--host`)**: Unified HTTP server on port 2121 — guest registration
  (WebSocket + HTTP announce), management commands (exec/upload/download/kick),
  MCP JSON-RPC, static file serving (/bin/), /etc/hosts sync, auto-upgrade
  binary serving, and periodic UDP version broadcast. All on one port.

### Complete Data Flow

```
                         ┌── MCP HTTP /mcp (JSON-RPC) ← AI Agent
Guest (macvm)    ──WebSocket──┐
Guest (linuxvm)  ──WebSocket──┤──→ Host HTTP :2121 ──┼── GET /bin/ (static files + auto-upgrade)
Guest (windows)  ──WebSocket──┘                      ├── POST /exec, /upload, /download
                         ┌── HTTP POST /announce ────┘   (CLI management commands)
                         │   (backward compat)        └── /etc/hosts sync
                         │                            └── UDP broadcast (version + discovery)
                         │
Guest UDP listener ←── UDP broadcast ──┘  (version check → auto-upgrade trigger)
```

### How a Command Flows (pty model)

```
1. CLI: utmm --exec linuxvm "ls -la"
2. Host HTTP /exec handler → looks up guest shell → builds pty_input frame
   with "ls -la; echo MDELIM:$?\n" appended
3. Host enqueues frame in outgoing_frames[linuxvm]
4. Host WebSocket handler drains queue → writes pty_input to WS
5. Guest wsAnnounceLoop: reads pty_input → writes to pty master fd
6. Shell executes command → output flows through pty → ptyReadLoop sends
   pty_output frames back to Host
7. Host WebSocket handler: appendOpOutput + scanForMarker
8. When MDELIM:N\n found: strip marker, set exit_code=N, fire wake_event
9. HTTP handler: takeOpResult → respond JSON with stdout
```

### WebSocket Binary Protocol (wsproto.zig)

All frames: 1-byte type + type-specific payload. Strings null-terminated,
blobs 4-byte BE length prefix, integers 4-byte BE.

| Type | Value | Direction | Purpose |
|------|-------|-----------|---------|
| announce | 1 | guest→host | Guest info (hostname, IP, target, MAC, version, shell) |
| upload_req | 4 | host→guest | Upload file (path + data) |
| upload_resp | 5 | guest→host | Upload result |
| download_req | 6 | host→guest | Download request (path) |
| download_resp | 7 | guest→host | Download result (file data) |
| pty_spawn | 12 | host→guest | Trigger shell spawn (no payload) |
| pty_input | 13 | host→guest | Command for shell stdin (cmd_id + data) |
| pty_output | 14 | guest→host | Shell stdout (cmd_id + data) |
| pty_signal | 15 | host→guest | Signal to foreground process |
| pty_resize | 16 | host→guest | Terminal resize (rows+cols) |

### HostState — Central Shared State (httpd.zig)

All handlers share one `HostState` instance, mutex-protected:
- `guests`: ArrayList of `GuestEntry` (hostname, IP, target, MAC, version, shell)
- `outgoing_frames`: StringHashMap of per-guest FIFO frame queues
- `op_states`: StringHashMap of `OpState` by cmd_id (output buffer, exit_code, done flag)
- `close_requests`: StringHashMap for kick tracking
- `wake_event`: Io.Event signaled on op completion (wakes polling HTTP handlers)

### Key Design Decisions

- Single binary, dual mode — reduced maintenance
- Unified port 2121 for HTTP, WebSocket, MCP, binary serving — replaced UDP + separate MCP port
- **Persistent pty per WebSocket**: POSIX `posix_openpt` + fork + setsid + execve,
  Windows `CreatePipe` + `CreateProcessW("cmd.exe /k")`
- **MDELIM markers**: `; echo MDELIM:$?\n` appended to each command. Host-side
  `scanForMarker` uses `lastIndexOf` — handles echoed command text on macOS/BSD
  (where pty master doesn't support tcsetattr ECHO disable)
- Connection = Shell Session: kick closes WebSocket → pty killed → guest reconnects
  with fresh shell
- **Auto-upgrade via UDP broadcast**: Host broadcasts version every 60s via UDP.
  Guest `udpDiscoveryListener` detects mismatch, spawns `utmm-old` process which
  stops service, kills old processes, downloads new binary via HTTP, replaces, restarts.
  Zero external shell commands — `fork()+execve()` (POSIX) / `std.process.spawn` (Windows).
- `std.http.Server` with `std.Thread` per-connection concurrency
- Zero external dependencies: no Node.js, Python, SSH, curl
- Guest auto-discovers Host via default gateway (UTM Host is the gateway)

## Build & Run

### Build
```bash
zig build                    # Native build → zig-out/bin/utmm
zig build -Dtarget=aarch64-linux-musl    # → zig-out/bin/utmm-aarch64-linux
zig build -Dtarget=x86_64-linux-musl     # → zig-out/bin/utmm-x86_64-linux
zig build -Dtarget=x86-linux-musl        # → zig-out/bin/utmm-x86-linux
zig build -Dtarget=aarch64-macos         # → zig-out/bin/utmm-aarch64-macos
zig build -Dtarget=x86_64-macos          # → zig-out/bin/utmm-x86_64-macos
zig build -Dtarget=aarch64-windows       # → zig-out/bin/utmm-aarch64-windows.exe
zig build -Dtarget=x86_64-windows        # → zig-out/bin/utmm-x86_64-windows.exe
```

> 32-bit x86-linux-musl builds and passes tests. x86-windows has a linker issue
> (`_system@4`) unrelated to our code.

### Tests
```bash
zig build test
```

### Guest Runtime
```bash
utmm                                # Foreground (stop service, run, restart on exit)
utmm --hostname myvm --port 2121   # Custom parameters
utmm --svc                          # Daemon mode (for systemd/launchd/sc)
utmm --host-ip IP                   # Override Host IP (default: auto-detect via gateway)
utmm --log-file PATH                # Log file path
utmm --version                      # Print version and exit
utmm --install                      # Install as system service (Guest: --svc + auto-start)
utmm --install --user               # Create desktop shortcut for foreground launcher
utmm --uninstall                    # Remove system service
utmm --uninstall --user             # Remove desktop shortcut
```

### Host Runtime
```bash
sudo utmm --host                    # Start HTTP server :2121 (foreground)
utmm --host --port 2122             # Custom port
utmm --host --serve-dir PATH        # Static file serve directory (default: exe dir)
utmm --host --hosts-file PATH       # hosts file path (default /etc/hosts)
utmm --host --marker TAG            # hosts marker comment text
utmm --host --config PATH           # Config file path
utmm --host --log-file PATH         # Log file path
utmm --host --install               # Install as system service (Host mode)
utmm --host --uninstall             # Remove system service
utmm --host --save-config           # Save current parameters to config file

# Management Commands (HTTP to 127.0.0.1:2121)
utmm --status                       # All guest status (UDP broadcast discovery)
utmm --exec linuxvm "uname -a"      # Remote exec (pty, env/cd persist)
utmm --kick linuxvm                 # Kill guest shell, force reconnect
utmm --upload file.txt linuxvm      # Upload file
utmm --download linuxvm f.txt ./f.txt  # Download file
utmm --gen-init linux               # Generate auto-start script (linux/macos/windows)
utmm --version                      # Print version and exit
```

## Project File Structure

```
src/
├── main.zig           # Entry point, CLI parsing, mode dispatch, Windows service
├── ver.zig            # Single source of truth for version (bump to trigger auto-upgrade)
├── protocol.zig       # Text protocol constants, UDP discovery, deployment filename mapping
├── wsproto.zig        # Binary WebSocket protocol: 10 msg types, build/parse
├── wsclient.zig       # Guest WebSocket client: TCP connect + HTTP upgrade + frame I/O
├── httpd.zig          # HTTP server core: accept loop + Router + HostState
├── host_http.zig      # HTTP endpoint handlers: /announce, /exec, /ws, /mcp, /bin/
├── host.zig           # Host orchestration: cmd dispatch + HTTP server start + periodic UDP broadcast
├── guest.zig          # Guest entry: system info + UpgradeSignal + wsAnnounceLoop start
├── broadcast.zig      # Guest core: system info, ptySpawn, ptyReadLoop, wsAnnounceLoop, triggerSelfUpgrade
├── upgrade.zig        # Auto-upgrade: utmm-old process (stop→kill→download→replace→start)
├── hosts_file.zig     # /etc/hosts marked block read/write
├── mcp.zig            # MCP JSON-RPC: processJsonRpcWithState — reads HostState
├── install.zig        # Service install/uninstall + desktop shortcuts + --gen-init
├── agent.zig          # Foreground guest: stop service, run TTY, restart on exit
└── config.zig         # Config persistence + file logger
```

## Code of Conduct / Guidelines

Before starting any work, read (if they exist): `./CLAUDE.md`, `./README.md`,
`./zig-codegen.md`.

### Zig 0.16.0 Key Changes
- `std.posix.socket` removed → use `std.Io.net`
- `std.net` removed → use `std.Io.net.IpAddress.parse()`
- Container init: `.{}` → `.empty` / `.init`
- `usingnamespace` / `async`/`await` / `@Type` / `@cImport` — removed
- `std.process.Child.Term` fields lowercase: `.exited`, `.signal`, `.stopped`, `.unknown`
- `std.Io.Threaded.global_single_threaded` uses `Allocator.failing` — never for
  `std.process.run` in daemon contexts

### Io API (0.16.0)
- `Io.Reader` no `.read()` — use `.stream(writer, limit)` or `.streamExact(writer, n)`
- `Io.Writer.write()` returns `usize` — discard with `_ =`
- `Stream.Writer.interface.flush()` to drain buffered data

### PTY Patterns (v0.5.0)
- POSIX: `posix_openpt` → fork → child: `setsid`, `dup2(slave→0,1,2)`,
  `execve(shell, argv, std.c.environ)` — pass `std.c.environ` NOT `{null}`
- macOS/BSD: pty master doesn't support `tcsetattr` ECHO disable.
  Use `lastIndexOf` in host-side marker scanning.
- `Io.Timeout` union: `{ none, duration: Clock.Duration, deadline: Clock.Timestamp }`
  Use `.awake` clock: `.{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } }`

### Development Principles
1. **Think before coding** — state assumptions, present trade-offs
2. **Simplicity first** — minimum code, no speculative features
3. **Precise changes** — only change what's necessary, match existing style
4. **Goal-driven** — define criteria, verify with `zig build test`
