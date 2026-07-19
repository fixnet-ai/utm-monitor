# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Keep communication and documentation in English**

## Project Overview
This is a helper tool for UTM virtual machines. Because UTM VM IPs change frequently, this program notifies the host of each guest machine's real IP at all times.

A self-starting Zig program that broadcasts its name and current IP every second. It is placed on each guest system to auto-start, while the host listens for these broadcast messages. When updates are detected, they are synced to the host's `/etc/hosts` file. The same binary defaults to guest mode, and `--host` switches to host mode.

The program is written in Zig 0.16.0, with cross-compilation on the host to build binaries for all platforms.
Current configuration:
Three VMs (macvm/windows/linux) have their IPs written to `/etc/hosts`.
VM login credentials:
macvm: user=root, passwd=111, app_path=/opt/
linuxvm: user=root, passwd=111, app_path=/opt/
windowsvm: user=Administrator, passwd=111, app_path=C:\opt\

## Architecture Design

### Two Run Modes (Same Binary)
- **Guest mode (default)**: Foreground mode — detects TTY, stops any background service, runs in terminal, restarts service on exit. Non-TTY invocation (e.g., scheduled tasks) falls back to daemon mode with `is_svc = true` — no `--svc` flag needed for schtasks/launchd/systemd. With `--svc`: explicit daemon mode (UDP broadcast hostname+IP + TCP transport server on port 2121). Use `--install --user` to create a desktop shortcut (UTMM.command / UTMM.bat / utmm.desktop).
- **Host mode (--host)**: UDP listener + TCP transport + /etc/hosts sync + management commands (--status/--exec etc.)
- **MCP integrated mode (--host --mcp)**: Host + MCP JSON-RPC server in one process, no separate Host daemon needed

### Complete Data Flow
```
Guest (macvm)    ──UDP broadcast──┐                    ┌── TCP(2121) → Version, Health, Exec, Upload, Download
Guest (linuxvm)  ──UDP broadcast──┤──→ Host listener(2121)─┼── TCP(2121) → Guest bootstrap binary serving
Guest (windows)  ──UDP broadcast──┘                    └── hosts file sync
```

### Communication Protocol
- **UDP broadcast** (port 2121): Guest broadcasts `ANNOUNCE\nname: X\nip: Y\n...` every second, Host listens
- **TCP transport** (port 2121): Binary frame protocol (4B big-endian length + 1B message type + payload). Guest serves VERSION_REQ, HEALTH_REQ, EXEC_REQ, FILE_REQ, UPLOAD_REQ. Host serves FILE_REQ for Guest bootstrap.
- **Management commands** (--status/--exec/--upload/--download): Discover Guest IP via UDP broadcast, then connect directly via TCP transport. When UDP port is occupied (Host daemon running), fall back to reading `/tmp/utmm-guests.tsv` state file.
- **Auto-start Host service**: Management commands auto-start the Host daemon via the OS service manager when the UDP port is not bound — no manual `utmm --host` needed
- **Auto-upgrade**: Host detects Guest version mismatch via ANNOUNCE → pushes new binary via TCP UPLOAD_REQ (ETag MD5 verified). Guest uses cross-platform safe rename (old → .old, .next → final) + detached restart via EXEC_REQ. Compatible with Linux/macOS/Windows. No Guest polling. Triggers on: (a) Guest version changed since last seen, OR (b) Host version changed since last upgrade attempt (covers Host binary update without Guest version bump). Uses `last_upgrade_host_version` field in GuestEntry for debounce; passes `target` directly from ANNOUNCE to avoid state file race.

### Key Design Decisions
- Single binary, dual mode: reduces maintenance burden
- UDP broadcast: no target address configuration needed, auto-discovery
- IP change callback → auto-update /etc/hosts marked block
- zio async Runtime: io_uring (Linux) / kqueue (macOS) / IOCP (Windows) — unified async backend replacing std.Thread
- Binary frame TCP protocol: 4B length prefix + 1B type + payload, single connection multiplexing, zero parsing overhead
- Zero external dependencies: no Node.js, no Python, no SSH/SCP, no curl — everything via TCP + UDP
- Host-push auto-upgrade: version mismatch detected in ANNOUNCE → Host pushes binary + restarts Guest. No Guest polling, no shell scripts. Cross-platform safe rename: old→.old, .next→final, spawn restart. ETag MD5 integrity verified on all uploads. Debounce via `last_upgrade_host_version` (prevents re-trigger after Host restart) and `target` passthrough (avoids state file read race).
- **Windows child processes**: zio IOCP backend does not support async pipe I/O for child processes. Use `std.Io.Threaded.init(gpa, .{})` for `std.process.run` on Windows. Never use `Threaded.global_single_threaded` — it uses `Allocator.failing` and causes OutOfMemory in `processSpawnWindows`.

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

> **Note**: 32-bit x86 targets (x86-linux-musl, x86-windows) are not supported — zio's coroutine implementation does not implement x86 32-bit context switching (`@compileError("unimplemented architecture: x86")` in coroutines.zig:108). zio supports x86_64, aarch64, arm, riscv64/32, loongarch64, powerpc64, and sparc64 — but our release only covers the 6 targets relevant to UTM VMs (aarch64 + x86_64 × linux/macos/windows).

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
sudo utmm --host                          # Continuous listener (needs sudo for /etc/hosts)
utmm --host --install                     # Install as system service (launchd/systemd/sc)
utmm --host --uninstall                   # Remove system service
utmm --host --serve-dir /path/to/binaries # Custom binary serve directory
utmm --host --mcp                         # Integrated mode: Host + MCP in one process

# ── Management Commands (talk to Host/Guest via UDP discover + TCP, NO --host needed) ──
utmm --status                             # Query all Guest status
utmm --exec linuxvm "uname -a"            # Remote command execution
utmm --upload file.txt linuxvm            # Upload file to Guest (no curl)
utmm --download linuxvm f.txt ./f.txt     # Download file from Guest (no curl)
utmm --mcp                                # Adapter mode: MCP stdio → direct UDP+TCP

# Management commands discover Guest IP via UDP broadcast + state file fallback.
# When Host daemon is running (UDP port occupied), they read /tmp/utmm-guests.tsv.
# (v0.1.26+: if Host service is not running, management commands auto-start it via
#  the OS service manager — launchctl/systemctl/sc start — then retry.)
```

## Project File Structure
```
src/
├── main.zig           # Entry point, CLI parsing, mode dispatch
├── ver.zig            # Single source of truth for version (bump to trigger auto-upgrade)
├── protocol.zig       # Message protocol: constants, GuestInfo, buildAnnounce/Ping/ExecReq
├── transport.zig      # Binary frame protocol: 4B len + 1B type + payload over TCP
├── guest.zig          # Guest orchestration: TCP transport server + broadcast loop (no version polling)
├── host.zig           # Host orchestration: management cmd dispatch + listener loop + auto-upgrade + hosts sync
├── broadcast.zig      # Guest: getLocalIp/getHostname/broadcastLoop + getDefaultGateway
├── listener.zig       # Host: UDP listener, IP change detection, OnIpChanged callback
├── hosts_file.zig     # /etc/hosts marked block read/write
├── status.zig         # Host: --status query + formatStatusTable
├── mcp.zig            # MCP JSON-RPC server (--mcp flag, stdio transport, direct UDP+TCP)
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

### zio Async Runtime Patterns
- `Runtime.init(gpa, .{})` → `spawn()` for tasks, `handle.join()` to wait
- `Io.net.Stream` with `writeAll()`/`read()` directly (no buffered wrapper needed for simple cases)
- `Io.net.Stream.Writer` has `interface: Io.Writer` field — use `writer.interface.flush()` to drain buffered data
- `BufWriter` data is lost when it goes out of scope — use persistent reader/writer across calls
- Mutual recursion with error set inference: use explicit `anyerror!T` return type to break dependency loop
- 32-bit x86 not supported by zio coroutines — 6 targets only (aarch64 + x86_64 × linux/macos/windows)
- **Windows IOCP limitation**: zio IOCP does not support async pipe I/O for child processes. Use `std.Io.Threaded.init(gpa, .{})` (not `global_single_threaded`) for `std.process.run` on Windows. macOS/Linux: zio's io_uring/kqueue handles `std.process.run` via blocking I/O without Threaded wrapper

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
