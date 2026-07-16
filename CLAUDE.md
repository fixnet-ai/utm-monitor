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
- **Guest mode (default)**: UDP broadcast hostname+IP + HTTP server (2121)
- **Host mode (--host)**: UDP listener + HTTP file server + /etc/hosts sync + management commands (--status/--deploy/--exec etc.)

### Complete Data Flow
```
Guest (macvm)    ──UDP broadcast──┐                    ┌── HTTP(2121) → Host file serving
Guest (linuxvm)  ──UDP broadcast──┤──→ Host listener(12345)─┼── HTTP(2121) → Host exec/upload
Guest (windows)  ──UDP broadcast──┘                    └── hosts file sync
```

### Communication Protocol
- **UDP broadcast** (port 12345): Guest broadcasts `ANNOUNCE\nname: X\nip: Y\n...` every second, Host listens
- **HTTP** (port 2121): Guest serves /health, /version, /update, /bin/:filename, /upload, /exec; Host serves /version, /bin/:filename for Guest bootstrap
- **IPC** (port 12347): Host internal TCP channel for --status/--exec/--deploy/--upload/--download command forwarding
- **Auto-upgrade**: Host detects Guest version mismatch via ANNOUNCE → pushes new binary via HTTP upload + remote restart. No Guest polling.

### Key Design Decisions
- Single binary, dual mode: reduces maintenance burden
- UDP broadcast: no target address configuration needed, auto-discovery
- IP change callback → auto-update /etc/hosts marked block
- HTTP thread model: one thread per connection, `std.http.Server`/`Client` from standard library
- Zero external dependencies: no Node.js, no Python, no SSH/SCP, no curl — everything via HTTP + UDP
- Host-push auto-upgrade: version mismatch detected in ANNOUNCE → Host pushes binary + restarts Guest. No Guest polling, no shell scripts.

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
zig build -Dtarget=x86-linux-musl    # → utmm-x86-linux
zig build -Dtarget=x86-windows  # → utmm-x86-windows.exe
```

### Tests/Testing
```bash
zig build test                                   # All tests (currently 61)
```

### Guest End Runtime
```bash
utmm                                      # Default Guest
utmm --hostname myvm --port 12345         # Custom parameters
utmm --http-port 2122                     # Custom HTTP port
```

### Host End Runtime
```bash
sudo utmm --host                          # Continuous listener (needs sudo for /etc/hosts)
utmm --host --status                      # Query all Guest status
utmm --host --exec linuxvm "uname -a"     # Remote command execution
utmm --host --deploy                      # Compile+deploy to all VMs
utmm --host --upload file.txt linuxvm     # Upload file to Guest (no curl)
utmm --host --download linuxvm f.txt ./f.txt  # Download file from Guest (no curl)
utmm --host --install                     # Install as system service (Host mode: use --host --install)
utmm --host --uninstall                   # Remove system service
utmm --host --serve-dir /path/to/binaries # Custom HTTP serve directory
utmm --host --mcp                         # Integrated mode: Host + MCP in one process
utmm --mcp                                # Adapter mode: MCP stdio → Host IPC bridge
```

## Project File Structure
```
src/
├── main.zig           # Entry point, CLI parsing, mode dispatch
├── ver.zig            # Single source of truth for version (bump to trigger auto-upgrade)
├── protocol.zig       # Message protocol: constants, GuestInfo, buildAnnounce/Ping/ExecReq
├── guest.zig          # Guest orchestration: HTTP server thread + broadcast loop (no version polling)
├── host.zig           # Host orchestration: management cmd dispatch + listener loop + auto-upgrade
├── broadcast.zig      # Guest: getLocalIp/getHostname/broadcastLoop + getDefaultGateway
├── listener.zig       # Host: UDP listener, IP change detection, OnIpChanged callback
├── hosts_file.zig     # /etc/hosts marked block read/write
├── http_server.zig    # Guest HTTP server: /health, /version, /update, /bin/:filename, /upload, /exec
├── http_client.zig    # HTTP client: GET/POST for version check, exec, upload, download
├── host_http.zig      # Host HTTP file server: /version, /bin/:filename (read-only bootstrap)
├── status.zig         # Host: --status query + formatStatusTable
├── executor.zig       # Host: --exec remote execution + resolveGuest + findGuest
├── deploy.zig         # Host: --deploy build+deploy + --watch file monitoring
├── ipc.zig            # Host: IPC service (127.0.0.1:12347 TCP command forwarding)
├── mcp.zig            # MCP JSON-RPC server (--mcp flag, stdio transport)
├── install.zig        # --install/--uninstall system service + --gen-init script generation
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
