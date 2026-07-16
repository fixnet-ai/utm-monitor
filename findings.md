# Findings & Decisions

## Requirements
- Zig 0.16.0, cross-compilation for macOS / Linux / Windows
- Single binary, default guest mode, `--host` switches to host mode
- **Guest:** UDP broadcast + HTTP server (upload/download/exec all via HTTP on port 2121)
- **Host:** UDP listener + /etc/hosts updates + all management commands
- **Management:** --install / --gen-init / --deploy / --exec / --status / --watch (off by default) / --save-config / --log-file / --version
- Deploy to three VMs: macvm, linuxvm, windowsvm
- Code style: Chinese comments (simplified), simplicity first

## Research Findings

### Zig 0.16.0 Network API (from zig skill)
- `std.posix.socket` removed → use `std.Io.net`
- `std.net` removed → `std.Io.net.IpAddress.parse()` for address parsing
- Network API requires `Io` instance
- UDP socket / TCP listener under `std.Io.net`

### Zig 0.16.0 I/O (from zig skill)
- `std.fs` → `std.Io.Dir` / `std.Io.File`
- New Writer/Reader API, non-generic, requires buffer
- Juicy Main: `pub fn main(init: std.process.Init) !void`

### Zig 0.16.0 Build System
- `root_source_file` removed → `root_module = b.createModule(.{...})`
- Module imports: `exe.root_module.addImport("name", module)`
- Cross-compilation: set `target` in `b.addExecutable`

### Zig 0.16.0 Threads (from zig skill)
- `std.Thread.Mutex` → `std.Io.Mutex`
- `std.Thread.spawn` still available, requires `Io` instance
- Lock primitives migrated to `std.Io`

### Three-Platform System Service Installation Methods
| Platform | Service Manager | Config Path |
|----------|----------------|-------------|
| macOS | launchd | `~/Library/LaunchAgents/com.utm-monitor.plist` |
| Linux | systemd | `/etc/systemd/system/utm-monitor.service` |
| Windows | Scheduled Task / Registry | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |

### Communication Protocol Design
- **UDP broadcast message** (guest → host):
  ```
  ANNOUNCE\n
  name: macvm\n
  ip: 192.168.64.5\n
  ftp: 2121\n
  cmd: 12346\n
  \n
  ```
- **TCP command channel** (host → guest):
  - Request: `EXEC\ncmd: ls -la\n\n`, Response: `OK\noutput...\n\n` or `ERR\nmessage\n\n`
  - `STATUS` command returns guest running status
- **--status query** (host initiated): send UDP `PING` → wait for guest `ANNOUNCE` reply

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| UDP 12345 | Default port unlikely to conflict |
| FTP 2121 | >1024 no root needed, unlikely to conflict |
| TCP command 12346 | UDP port +1, easy to remember |
| Plain text line protocol | Debuggable, testable via telnet |
| hosts marked block | Precise replacement, doesn't pollute user manual config |
| Guest IP = first non-lo IPv4 | Simple and reliable |
| `std.Io.Threaded` | Stable implementation |
| FTP thread-per-connection | Concurrent by user requirement |
| Passive mode only | Avoid NAT/firewall issues |
| Anonymous FTP | No security risk on local network |
| Cross-compilation: native / x86_64-linux-gnu / x86_64-windows-gnu | Covers three VMs |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| zig skill not found under claude/skills/ | Moved to .claude/skills/ |
| README.md / zig-codegen.md didn't exist | Created in Phase 7 |
| Windows `getSystemInfo()` hardcoded MAC=00:00:00:00:00:00 | Changed to call `getWindowsMac(io, allocator)` for real MAC |
| Windows binary in-use causes SCP upload failure | Stop process with `schtasks /end` + `taskkill` before upload |
| `--exec`/`--status` share UDP port with persistent Host → conflict | ✅ Fixed: Phase 9 IPC architecture refactoring, management commands forwarded to persistent Host via 127.0.0.1:12347 TCP |
| IPC client reading response via `take(n)` unreliable | ✅ Fixed: Changed to `takeByte()` byte-by-byte read until EOF |

## Windows MAC Address Retrieval
- **Primary method**: `getmac /fo csv /nh` — outputs CSV format (2 columns: MAC, Transport), takes first row's first quoted field
- **MAC format conversion**: `getmac` output uses `-` separator (e.g. `66-DC-DA-EC-A1-59`), unified to `:` separator
- **Fallback method**: PowerShell `Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1`
- **Fallback value**: Return `00:00:00:00:00:00` when both methods fail

## Default Gateway Detection (Three Platforms)
| Platform | Method | Key Details |
|----------|--------|-------------|
| macOS | `route -n get default` | Parse `gateway:` line |
| Linux | `/proc/net/route` | Gateway field is hex little-endian (`0x0100A8C0` → `192.168.0.1`) |
| Windows | `route print 0.0.0.0` | Skip header, parse `0.0.0.0` line third column |

## Version Auto-Sync Data Flow
```
Guest every 30s
  → getDefaultGateway()             # Get gateway IP (= Host IP)
  → ftp_client.retrieveText(VERSION)  # FTP RETR read remote version
  → Compare with protocol.VERSION
  → Mismatch → retrieveText(update) → pipe to /bin/sh → auto update+restart
```
- Guest waits 5s after startup for network readiness before starting checks
- `/update` generated script has built-in version check: `$DEST --version 2>&1` vs `curl ftp://HOST:PORT/VERSION`
- Version matches → `exit 0` skip download, mismatch → download and install

## deploy Windows Considerations

- `buildBinary()`: Windows output is `utm-monitor.exe` (with extension), must handle when cp
- Remote paths: must use absolute paths
  - Linux/macOS: `/opt/utm-monitor.new`
  - Windows: `C:\opt\utm-monitor.new.exe`
- Windows restart command: `ping -n 2` sleep → `move /Y` atomic replace → `taskkill /f` kill old process → `start ""` launch
- SCP upload of in-use file will fail → must `schtasks /end` + `taskkill /f /im utm-monitor.exe` first

## IPC Architecture (Phase 9)

### Design Motivation
- `--status`/`--exec`/`--deploy` running as separate processes bind UDP port 12345, conflicting with persistent Host's listener
- Correct architecture: persistent Host = only process binding UDP; management commands forwarded via TCP IPC, CLI only displays results

### IPC Protocol
```
Port: 127.0.0.1:12347 (localhost only, unified across three platforms)
Client → Server: <COMMAND>\n\n
Server → Client: OK\n<output><EOF>  or  ERR\n<error><EOF>
End marker: Server closes connection = EOF
```

### Command Format
| Command | Format | Processing Thread |
|---------|--------|-------------------|
| STATUS | `STATUS` | lock → snapshot GuestState list → formatStatusTable |
| EXEC | `EXEC\n<hostname>\n<cmd>` | lock → findGuest → TCP execRemote → return result |
| DEPLOY | `DEPLOY\n[hostname]` | lock → build DeployTarget list → deployWithTargets |

### Thread Model
```
Main thread:   UDP listener.listenLoop()      ← writes guests ArrayList
FTP thread:    ftp_server.startServer()        ← no shared state
IPC thread:    ipc.startServer(shared_state)   ← read-only guests (locked)
```

### Shared State Protection
- `std.ArrayList(listener.GuestState)` + `std.Io.Mutex`
- Listener callback: `mutex.lock(io)` → modify/add entry → `mutex.unlock(io)`
- IPC handler: `mutex.lock(io)` → read (snapshot+release lock or immediate release) → process
- Response building and deploy compilation execute outside lock (time-consuming operations don't hold lock)

### Zig 0.16.0 `std.Io.Mutex` API
```zig
var mutex: std.Io.Mutex = std.Io.Mutex.init;  // init (non-pointer)
mutex.lock(io) catch {};                       // lock (requires Io parameter)
defer mutex.unlock(io);                         // unlock (requires Io parameter)
```
- `std.Thread.Mutex` removed, all lock primitives under `std.Io`
- `lock(io)` and `unlock(io)` both require Io instance (not just lock)
- `init` is a constant, returns struct not pointer

## Bare-Metal Installation Audit (Phase 10)

### Audit Scope
Full verification of MANUAL.md against actual code behavior for both installation paths:
- **Path A**: GitHub Releases + install.sh (production bare-metal)
- **Path B**: Local zig build + manual deployment (development)

### Findings (5 issues identified)

| # | Severity | Finding | Resolution |
|---|----------|---------|------------|
| 1 | 🔴 Critical | `/update` endpoint expected `utm-monitor-{arch}-{os}[.exe]` but `zig build` only produced `utm-monitor` | `build.zig`: Added `addInstallBinFile(exe.getEmittedBin(), target_filename)` after `installArtifact` to auto-produce target-specific copies |
| 2 | 🔴 Critical | Host FTP `serve_dir` defaulted to CWD `"zig-out/bin"`, broken when Host started as system service (CWD = `/`) | Added `--serve-dir PATH` CLI option; default resolved from `executablePath(io, &buf)` → `dirname()` → heap-duplicated for detached FTP thread lifetime |
| 3 | 🟡 Medium | `installSelf()` always generated Guest-mode configs, no `--host` flag for Host-mode service | Signature changed to `installSelf(io, allocator, is_host: bool)`; Host-mode generates plist/unit with `{exe_path} --host` and `WorkingDirectory` |
| 4 | 🟡 Medium | Cross-compilation overwrote native binary (`zig build -Dtarget=aarch64-linux` replaced `zig-out/bin/utm-monitor`) | Resolved by finding #1: target-specific copies coexist with native binary; rebuild native last to restore |
| 5 | 🟢 Low | MANUAL.md §2.4 didn't mention `/opt/` directory prerequisite | Added `sudo mkdir -p /opt` to MANUAL.md |

### Key Code Changes

**build.zig — target-specific binary copies:**
```zig
const target_info = target.result;
const arch_name = @tagName(target_info.cpu.arch);
const os_name = @tagName(target_info.os.tag);
const ext = if (target_info.os.tag == .windows) ".exe" else "";
const target_filename = b.fmt("utm-monitor-{s}-{s}{s}", .{ arch_name, os_name, ext });
const target_install = b.addInstallBinFile(exe.getEmittedBin(), target_filename);
target_install.step.dependOn(&exe.step);
b.getInstallStep().dependOn(&target_install.step);
```

**host.zig — serve_dir resolution:**
```zig
const serve_dir: []const u8 = if (cli.serve_dir) |sd| sd else blk: {
    var exe_buf: [4096]u8 = undefined;
    if (std.process.executablePath(io, &exe_buf)) |exe_len| {
        const exe_path = exe_buf[0..exe_len];
        break :blk gpa.dupe(u8, std.fs.path.dirname(exe_path) orelse ".") catch ".";
    } else |_| { break :blk "."; }
};
```
- Heap-duplicated via `gpa.dupe()` because serve_dir is used by detached FTP thread — stack buffer would be use-after-free
- Intentionally never freed (program-lifetime allocation)

**install.zig — Host-mode service installation:**
- macOS: `<string>{exe_path}</string><string>--host</string>` + logs to `/var/log/utm-monitor-host.log`
- Linux: `ExecStart={exe_path} --host` + `WorkingDirectory={exe_dir}`
- Windows: unchanged (schtasks already uses full path)

## Zig 0.16.0 Error Name Changes

### createDir → error.PathAlreadyExists (not error.AlreadyExists)
Zig 0.16.0 changed the error set for filesystem creation operations:
```zig
// ❌ OLD (pre-0.16.0)
createDir(io, path, ...) catch |err| {
    if (err != error.AlreadyExists) return err;
};

// ✅ NEW (0.16.0)
createDir(io, path, ...) catch |err| {
    if (err != error.PathAlreadyExists) return err;
};
```

### createFile — safer to delete-then-create
```zig
// For overwrite scenarios, deleteFile before createFile avoids PathAlreadyExists:
std.Io.Dir.cwd().deleteFile(io, path) catch {};
const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o644) });
```

## ReleaseSafe Build Error Patterns

### Non-void Error Union Discard (e.g., `std.process.run` → `!RunResult`)
```zig
// ❌ catch {} fails: RunResult and void are incompatible
std.process.run(allocator, io, .{...}) catch {};

// ✅ if/else with |_| discard captures, NO trailing semicolon
if (std.process.run(allocator, io, .{...})) |_| {} else |_| {}
```
Rules:
- `!void` → `catch {}` works (both sides void)
- `!RunResult` → needs `if/else` with `|_|` discards
- `|_|` discard in ReleaseSafe is OK; `_ = err` is NOT (discards error set)
- No trailing `;` after `if/else` block

## Resources
- Zig 0.16.0 Manual: https://ziglang.org/documentation/0.16.0/
- Zig skill: `.claude/skills/zig/SKILL.md`
- CLAUDE.md: project root

## Known Issues & Optimization Backlog (2025-07-16 audit)

> **Note (2025-07-16)**: Items marked 🟢 are solved by the **HTTP migration** (`http-migration` branch, plan at `http-migration-plan.md`). v2.0.0 uses pure `std.http` (Server + Client, zero deps, thread-per-connection). All FTP code, comments, docs, skill, and MCP references will be deleted — clean break, no compatibility period.

### High Priority
| # | Issue | Status |
|---|-------|--------|
| H1 | **Windows FTP STOR loses tail data** | 🟢 Solved by HTTP (Content-Length, single connection) |
| H2 | **Deploy post-upload verification** | 🟢 Solved by HTTP (Content-Length = exact size check) |
| H3 | **cmd_server self-kill on restart** | 🟢 Solved by HTTP (response completes before restart) |
| H4 | **Deploy fallback on FTP failure** | 🟢 Solved by HTTP (no PASV, simpler retry) |

### Medium Priority
| # | Issue | Status |
|---|-------|--------|
| M1 | **`std.posix.read` bare calls** | 🟢 Solved by HTTP (std.http.Client handles I/O) |
| M2 | **IPC read no timeout** | ⚪ Separate fix (not FTP-related) |
| M3 | **Deploy output too terse** | ⚪ Separate improvement |
| M4 | **No retry on transient FTP failures** | 🟢 Solved by HTTP (simpler protocol = easier retry) |

### Low Priority
| # | Issue | Status |
|---|-------|--------|
| L1 | **Config file parsing incomplete**: `config.zig:114` TODO — full config file reading not implemented, only `--save-config` writes. | ⚪ Todo |
| L2 | **Windows service vs scheduled task**: Currently uses `schtasks` for auto-start; proper Windows Service (`sc create`) would be more reliable. | ⚪ Todo |
| L3 | **Binary size**: Linux ReleaseSafe 5.8MB. Consider `ReleaseSmall` or stripping. | ⚪ Todo |
| L4 | **No /metrics endpoint**: Host could expose Prometheus metrics (guest count, IP change events, deploy success rate). | ⚪ Todo |

## HTTP Migration (v2.0.0) — 2026-07-16

### Completed
- FTP server, FTP client, cmd_server, file_locker all deleted
- New: `http_server.zig` (Guest HTTP), `http_client.zig` (HTTP client), `host_http.zig` (Host HTTP)
- Single port 2121 (was 2121 + 12346)
- `protocol.GuestInfo`: `http_port: u16` replaces `ftp_port: u16` + `cmd_port: u16`
- Protocol version bumped to `"2.0.0"`
- CLI: `--http-port` replaces `--ftp-port` + `--cmd-port`
- All 58 tests pass, cross-compilation for all 3 targets succeeds
- All docs updated (CLAUDE.md, README.md, MANUAL.md, SKILL.md, zig-codegen.md, findings.md, progress.md, task_plan.md, http-migration-plan.md)

### Key Design Decisions
- Clean break — no backward compatibility, old code deleted entirely
- Thread-per-connection HTTP (same pattern as old FTP)
- `std.http.Server` + `std.http.Client` from Zig std lib, zero external deps
- Multipart upload parsing: manual string scanning, no external parser
- Exec via JSON POST /exec (simple `{"cmd":"..."}` format)

### Zig 0.16.0 HTTP Patterns Learned
- `Server.init(&reader.interface, &writer.interface)`, `receiveHead()` takes 0 args
- `RespondStreamingOptions` has `respond_options: RespondOptions` and `content_length: ?u64`
- `BodyWriter.writer` is a field (not method), type `Io.Writer`
- No `server.deinit()` or `request.deinit()` in 0.16.0
- `http.Method` is enum type, compared with `== .GET` directly

## Curl Audit (v0.1.0) — 2026-07-16

### Summary
Comprehensive audit of all curl call sites across program, MCP, skill, and docs. Goal: replace curl with built-in Zig CLI commands to reduce environment dependencies.

- **36 total curl references** across all files
- **16 bootstrap**: GitHub Downloads + install.sh + generated shell scripts (cannot be replaced — run before utm-monitor exists)
- **9 replaceable**: Now replaced by new `--upload`/`--download` commands
- **8 documentation**: Updated to use CLI commands instead of curl
- **3 test script**: Testing infrastructure, not production

### Detailed report: `curl-audit-report.md`

## Auto-Upgrade Redesign (v0.1.0) — 2026-07-16

### Motivation
Old model: Guest polls Host every 30s via HTTP → downloads /update script → pipes to shell. Required:
- Guest HTTP client for polling
- `/update` endpoint with generated shell script
- Complex version comparison logic on Guest side
- Guest restart orchestration

### New Design: Host-Push
```
Host receives ANNOUNCE (with Guest version)
  → Compare with own version (from ver.zig)
  → Mismatch → upload correct binary via HTTP → remote exec restart Guest
```

### Key Changes
- **`src/ver.zig`** — single source of truth: `pub const VERSION = "0.1.0";`
- **`src/protocol.zig`** — `VERSION = ver.VERSION;` (imports ver.zig)
- **`src/guest.zig`** — Removed `versionCheckLoop()` (~40 lines), `checkAndUpdate()` (~50 lines), and http_client import. Guest no longer polls.
- **`src/host.zig`** — Callback checks version mismatch → `autoUpgrade()`: uploads binary from serve-dir → remote exec restart. Debounce via `std.StringHashMap(void)`.
- **`build.zig.zon`** — version → `0.1.0`

### Design Decisions
- Clean break — no backward compatibility needed (same binary controls both ends)
- Debounce prevents duplicate upgrades during 3-5 second upgrade window
- Bootstrap curl references (GitHub downloads, install.sh, generated shell scripts) remain unavoidable

## --upload/--download Commands (v0.1.0) — 2026-07-16

### Implementation
- **`src/main.zig`** — Added `cmd_upload`, `upload_file`, `upload_target`, `cmd_download`, `download_target`, `download_remote`, `download_local` fields + CLI parsing
- **`src/host.zig`** — IPC forwarding + direct fallback handlers for UPLOAD/DOWNLOAD commands in ipcHandler
- Uses `http_client.zig` (std.http.Client), zero external dependencies

### Usage
```bash
utm-monitor --host --upload ./f.txt linuxvm     # Upload file to VM
utm-monitor --host --download linuxvm f.txt ./f.txt  # Download file from VM
```

## Binary Naming & Zip Packaging (Phase 13) — 2026-07-16

### Naming Convention
Unified `utmm-{arch}-{os}[.exe]` convention across all code, CI, scripts, and docs:
- `utmm-x86-linux`, `utmm-x86_64-linux`, `utmm-aarch64-linux`
- `utmm-x86_64-macos`, `utmm-aarch64-macos`
- `utmm-x86-windows.exe`, `utmm-x86_64-windows.exe`, `utmm-aarch64-windows.exe`

### Build Targets (5 → 8)
Added x86_64-linux-musl, x86_64-windows, aarch64-windows for full coverage.

### Zip Packaging
CI produces `utmm.zip` (stable latest URL) + `utmm-vX.X.X.zip` (versioned archival) containing all 8 platform binaries.

### Install Flow
1. `install.sh` downloads `utmm.zip` from GitHub Releases
2. Extracts to `/opt/utmm/` (all 8 binaries)
3. Detects Host arch (`uname -m` normalized: arm64→aarch64, x86_64→x86_64, i*86→x86)
4. Creates symlink: `/opt/utmm/utmm` → `utmm-{host-arch}-{host-os}[.exe]`
5. Creates convenience symlink: `/usr/local/bin/utmm` → `/opt/utmm/utmm`

### serve_dir Default
Changed from exe directory to `/opt/utmm/` (or `C:\opt\utmm\` on Windows). Host can now auto-upgrade any Guest architecture without `--serve-dir` flag.

### Key Files Changed
- `build.zig`, `src/protocol.zig` — core naming (two `deploymentFilename()` functions)
- `src/host.zig` — serve_dir default
- `src/host_http.zig`, `src/http_server.zig` — `/update` arch normalization
- `.github/workflows/release.yml` — 8 targets + zip packaging
- `install.sh` — complete rewrite
- `test_all.sh` — updated targets and binary names
- `CLAUDE.md`, `README.md`, `MANUAL.md` — all docs updated

---
*Update this file after every 2 view/browser/search operations*
