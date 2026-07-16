# Task Plan: UTM Monitor - VM IP Auto-Sync Tool

## Goal
Build a cross-platform UTM VM management tool with Zig 0.16.0: auto-sync guest IPs to host /etc/hosts, guest-side HTTP service (upload/download/exec), one-click build & deploy, automatic file-change deployment, remote command execution, system service self-installation, logging, and configuration persistence.

## Current Phase
Phase 13 (completed) — Standardize Binary Naming & Zip Packaging

## Phases

### Phase 1: Requirements & Discovery
- [x] Confirm semantics and defaults for all CLI parameters
- [x] Confirm Guest/Host communication protocol (UDP broadcast + TCP command channel)
- [x] Confirm HTTP concurrency model (thread-per-connection) — migrated from FTP in v2.0.0
- [x] Confirm system service installation methods for three platforms
- [x] Confirm cross-compilation target triplets
- [x] Record all findings to findings.md
- **Status:** complete

### Phase 2: Planning & Structure
- [x] Design project file structure (module responsibilities under src/)
- [x] Design CLI parameter system
- [x] Design communication protocol message format
- [x] Determine build.zig structure and dependencies
- [x] Record technical decisions to findings.md
- **Status:** complete

### Phase 3: Implementation — Core Communication
- [x] Create build.zig, build.zig.zon
- [x] Implement CLI argument parsing
- [x] Implement UDP broadcast (guest) and listening (host)
- [x] Implement /etc/hosts marker block update
- [x] Implement IP change event notification + log output
- **Status:** complete

### Phase 4: Implementation — Guest-side Services
- [x] Implement HTTP server (thread-per-connection, upload/download/exec endpoints) — migrated from FTP+cmd_server in v2.0.0
- [x] Implement remote command execution via HTTP POST /exec
- [x] Implement --status query response
- **Status:** complete

### Phase 5: Implementation — Host-side Management
- [x] Implement --status active query for all guests (with version comparison)
- [x] Implement --exec sending commands to guests (HTTP POST /exec)
- [x] Implement --deploy build + HTTP deployment
- [x] Implement --watch file-change auto-deployment (off by default)
- [x] Implement --gen-init generating auto-start scripts (linux/macos/windows)
- [x] Implement --install self-install as system service
- [x] Implement --save-config configuration persistence (key=value format)
- [x] Implement --version version display
- [x] Implement --log-file logging system (Logger with file+stdout output)
- [x] Implement IP change callback → hosts_file.updateHosts() (OnIpChanged with context pointer)
- **Status:** complete

### Phase 6: Testing & Cross-Compilation
- [x] macOS native build + syntax tests (zig build 3/3 + 26/26 tests)
- [x] Cross-compile aarch64-linux (Linux VM end-to-end validation passed)
- [x] Cross-compile aarch64-macos (macOS VM end-to-end validation passed)
- [x] Cross-compile aarch64-windows (Windows VM end-to-end validation passed)
- [x] Guest/Host local loopback integration test (all three VMs online verified)
- [x] HTTP multi-connection concurrency test (--deploy HTTP upload + /update + VERSION read)
- [x] --install auto-start test on each platform (schtasks/systemd/launchd all start normally)
- [x] --watch auto-trigger test (file change detection + auto-deploy flow verification)
- [x] Log format integrity test (Logger structure implemented)
- **Status:** complete

### Phase 7: Delivery
- [x] Create README.md (with all CLI parameter descriptions, protocol docs, project structure)
- [x] Create zig-codegen.md (25+ compilation error experience collection, API reference table)
- [x] Update CLAUDE.md (architecture diagram, build commands, complete file structure)
- [x] Update progress.md (complete session log + error records)
- [x] Build output binaries for three platforms (aarch64-macos/linux/windows all verified)
- **Status:** complete

### Phase 8: GitHub CI + Auto Version Sync + Bug Fixes
- [x] Create .github/workflows/release.yml (tag push auto-build 6 platforms + publish Release)
- [x] Create install.sh (Host-side one-click install, auto architecture detection)
- [x] Implement --version machine-readable output (`utm-monitor v1.1.0`)
- [x] Host HTTP writes VERSION file to zig-out/bin/ (for Guest version check)
- [x] /update virtual endpoint adds version check (skip download if already latest)
- [x] http_client.zig adds getVersion()/downloadText() (HTTP GET small text files)
- [x] broadcast.zig adds getDefaultGateway() (macOS/Linux/Windows three platforms)
- [x] guest.zig adds version check thread (every 30s check Host VERSION, auto-update if mismatch)
- [x] deploy.zig buildBinary() fix Windows .exe extension handling
- [x] deploy.zig change remote paths to absolute paths (/opt/ and C:\opt\)
- [x] Fix broadcast.zig getSystemInfo() Windows branch hardcoded MAC=00:00:00:00:00:00
- [x] Windows VM MAC address verification passed (66:DC:DA:EC:A1:59 ✓)
- [x] Update MANUAL.md + README.md (version sync, install flow, MAC fix)
- **Status:** complete

### Phase 9: IPC Architecture Refactoring — Eliminate Management Command Port Conflicts
- [x] Create `src/ipc.zig` — IPC module (TCP 127.0.0.1:12347 request-response protocol)
- [x] Refactor `src/host.zig` — management commands changed to IPC client mode (forward → persistent Host execution)
- [x] Persistent Host starts IPC service thread + shared GuestState list (`std.Io.Mutex` protected)
- [x] `src/status.zig` extract `formatStatusTable()` for IPC reuse
- [x] `src/executor.zig` add `findGuest()` for IPC direct lookup (no UDP PING needed)
- [x] `src/deploy.zig` extract `deployWithTargets()` for IPC reuse (skip UDP scan)
- [x] IPC send byte-level read fix (`take(n)` → `takeByte()` loop)
- [x] `src/main.zig` add `ipc.zig` module reference
- [x] End-to-end verification: `--status` + `--exec` working normally via IPC
- [x] Update MANUAL.md + README.md (architecture diagram, port table, IPC description)
- **Status:** complete

### Phase 10: Bare-Metal Audit & Docs Alignment + ReleaseSafe Fixes
- [x] ReleaseSafe compilation errors fixed (error union discard patterns, `catch {}` on `!RunResult`)
- [x] `--uninstall` command implemented and tested on all 3 VMs + Host (macOS/launchd, Linux/systemd, Windows/schtasks)
- [x] MANUAL.md bare-metal audit: 5 gaps found
  - [x] build.zig: auto-produce `utm-monitor-{arch}-{os}[.exe]` target-specific copies
  - [x] Host CWD dependency: add `--serve-dir` CLI option, default to exe directory
  - [x] `--install` hardcoded path/mode: `installSelf(io, allocator, is_host)` generates Host-mode configs
  - [x] MANUAL §2.3: add Guest binary download step for install.sh users
  - [x] MANUAL §2.4: add `mkdir -p /opt` prerequisite
- [x] Fix Zig 0.16.0 `createDir` error name: `AlreadyExists` → `PathAlreadyExists`
- [x] Update all docs: CLAUDE.md, README.md, MANUAL.md, zig-codegen.md, findings.md, task_plan.md, progress.md
- [x] `zig build test`: 51/51 tests pass
- [x] Cross-compilation verified: target-specific filenames produced correctly
- **Status:** complete

### Phase 11: HTTP Migration v2.0.0 — FTP → HTTP Clean Break
- [x] Create `src/http_server.zig` — Guest HTTP server (6 endpoints: health, version, bin/:file, upload, exec, update)
- [x] Create `src/http_client.zig` — HTTP client (getVersion, downloadFile, uploadFile, execRemote)
- [x] Create `src/host_http.zig` — Host HTTP file server (read-only: version, update, bin/:file)
- [x] Wire `guest.zig` — replace FTP server + cmd_server threads with HTTP server thread
- [x] Wire `host.zig` — replace Host FTP server with HTTP server; exec/deploy use http_client
- [x] Wire `deploy.zig` — use `http_client.uploadFile()` instead of `ftp_client.uploadFile()`
- [x] Delete: ftp_server.zig, ftp_client.zig, cmd_server.zig, file_locker.zig
- [x] `protocol.zig`: VERSION=`"2.0.0"`, GuestInfo uses `http_port` instead of `ftp_port`+`cmd_port`
- [x] `main.zig`: `--http-port` replaces `--ftp-port`+`--cmd-port`, remove old imports
- [x] `config.zig`: save format updated to `http_port={d}`
- [x] Cross-compile: aarch64-linux, aarch64-macos, aarch64-windows — all succeed
- [x] All 58 tests pass (10 deleted with old modules)
- [x] All docs updated (CLAUDE.md, README.md, MANUAL.md, SKILL.md, zig-codegen.md, findings.md, progress.md, task_plan.md, http-migration-plan.md)
- [x] `grep -ri "ftp\|cmd_server\|file_locker" src/` → zero results
- **Status:** complete

### Phase 12: Curl Audit + --upload/--download + Auto-Upgrade Redesign v0.1.0
- [x] Curl audit: catalog all 36 curl references across program, MCP, skill, docs → `curl-audit-report.md`
- [x] Implement `--upload <file> <vm>` and `--download <vm> <remote> [local]` CLI commands (http_client.zig, zero deps)
- [x] Create `src/ver.zig` — single version source: `pub const VERSION = "0.1.0";`
- [x] `src/protocol.zig`: `VERSION = ver.VERSION;` (import from ver.zig)
- [x] Redesign auto-upgrade: Guest-polling → Host-push
  - [x] `src/guest.zig`: Remove `versionCheckLoop()` (~40 lines) and `checkAndUpdate()` (~50 lines); remove http_client import
  - [x] `src/host.zig`: Add `autoUpgrade()` — version mismatch detection → HTTP upload binary → remote exec restart
  - [x] Debounce via `std.StringHashMap(void)` in CbContext
  - [x] Move serve_dir computation before CbContext creation
- [x] `build.zig.zon`: version bump `1.3.0` → `0.1.0`
- [x] Fix ReleaseSafe build errors (void{} syntax, openFile return value discard)
- [x] Update all docs: CLAUDE.md, README.md, MANUAL.md, SKILL.md, findings.md, progress.md, task_plan.md
- [x] `zig build`: success, `zig build test`: 51/51 tests pass
- **Status:** complete

### Phase 13: Standardize Binary Naming & Zip Packaging
- [x] `build.zig`: `deploymentFilename()` → `utmm-{arch}-{os}[.exe]` convention
- [x] `src/protocol.zig`: `deploymentFilename()` + tests → unified naming
- [x] `src/host.zig`: serve_dir default changed from exe dir to `/opt/utmm/` (or `C:\opt\utmm\`)
- [x] `src/host_http.zig`: `/update` endpoint arch auto-detection (normalize arm64→aarch64 etc.)
- [x] `src/http_server.zig`: `/update` endpoint arch normalization
- [x] `.github/workflows/release.yml`: 5→8 targets, zip packaging, upload both `utmm.zip` + `utmm-v*.zip`
- [x] `install.sh`: rewrite — download zip → extract → detect arch → create symlinks
- [x] `test_all.sh`: BUILD_TARGETS 5→8, updated binary names and HTTP test references
- [x] `CLAUDE.md`, `README.md`, `MANUAL.md`: all binary names, install flow, target tables updated
- [x] `zig build test`: 61/61 pass; all 8 cross-compilation targets build successfully
- **Status:** complete

## Complete CLI Parameters

```
Usage: utm-monitor [options]

Mode Selection:
  --host              Run in Host mode
  (no args)           Default Guest mode

Guest Options:
  --port PORT         UDP broadcast port (default 12345)
  --http-port PORT    HTTP server port (default 2121)
  --hostname NAME     Local hostname (auto-detect by default)
  --log-file PATH     Log file path

Host Options:
  --port PORT         UDP listening port (default 12345)
  --hosts-file PATH   hosts file path (default /etc/hosts)
  --serve-dir PATH    HTTP serve directory (default: exe directory)
  --marker TAG        Marker comment text (default "UTM-MONITOR")
  --config PATH       Config file path (default ./utm-monitor.conf)
  --log-file PATH     Log file path
  --watch [PATH]      Watch source directory for auto-deploy (off by default, directory can be specified)
  --save-config       Save current parameters to config file

Host Management Commands:
  --status            Query all known guest status
  --exec TARGET CMD   Execute command on target guest
  --deploy [TARGET]   Compile and deploy to VM (with optional target)
  --upload FILE VM    Upload a file to Guest VM (via HTTP, no curl needed)
  --download VM REMOTE LOCAL  Download REMOTE from Guest VM → LOCAL file
  --gen-init PLATFORM Generate auto-start script (linux/macos/windows)
  --install           Install self as system service with auto-start
  --uninstall         Remove system service and stop running processes
  --mcp               Serve MCP JSON-RPC over stdio for Claude Code integration
  --version           Display version info
```

## Key Questions — All Confirmed
| # | Question | Answer |
|---|------|------|
| 1 | UDP port? | 12345 |
| 2 | Message format? | Plain text line protocol |
| 3 | /etc/hosts update? | Marker block mode |
| 4 | Guest IP? | First non-lo IPv4 |
| 5 | Heartbeat timeout? | Not needed |
| 6 | HTTP port? | 2121 |
| 7 | HTTP auth? | None (trusted LAN) |
| 8 | HTTP concurrency? | thread-per-connection |
| 9 | --exec protocol? | HTTP POST /exec (JSON) |
| 10 | --install? | Native method per platform |
| 11 | --watch? | Off by default |
| 12 | Health reporting? | Not needed |
| 13 | Version comparison? | Version number in broadcast |

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| Zig 0.16.0 | Project-specified version |
| Single binary, dual mode | Reduce maintenance burden |
| UDP broadcast + HTTP | Broadcast for discovery, HTTP for file transfer + exec |
| HTTP thread-per-connection | Simple, matches old FTP pattern, std lib support |
| Plain text line protocol | Telnet-debuggable |
| Three-platform triplets | native / x86_64-linux-gnu / x86_64-windows-gnu |
| Configuration persistence | Simple key=value conf file |
| Logging system | Timestamp + level + source module |

## Errors Encountered
| Error | Attempts | Resolution |
|-------|---------|------------|
| `build.zig.zon .name` needs enum literal | 1 | `.name = .utm_monitor` |
| `build.zig.zon` missing `.fingerprint` | 1 | Used zig suggested value `0x4603abddd607a737` |
| `Timestamp.unixSeconds()` does not exist | 2 | `.nanoseconds` field (i96); `addDuration()` to create deadline |
| `Timestamp.fromNow()` does not exist | 1 | `Timestamp.now().addDuration(Duration.fromSeconds(n))` |
| `Duration` has no `.seconds` field | 1 | `Duration.fromSeconds(n)` |
| `ArrayList.init(gpa)` does not exist | 3 | Unmanaged ArrayList → `.empty` / `.deinit(gpa)` / `.append(gpa, item)` |
| `ArrayList.writer()` does not exist | 1 | `ArrayList.print(gpa, fmt, args)` instead |
| `RunOptions.stdout` field removed | 1 | Remove `.stdout = .pipe` (stdout always piped) |
| `process.executablePath` signature changed | 1 | `executablePath(io, &buf)` returns usize |
| `process.getEnvVarOwned` removed | 1 | `std.c.getenv("HOME")` returns `?[*:0]u8` |
| `createFile` `.mode` field does not exist | 4 | `.permissions = @enumFromInt(0o644)`, Permissions is an enum |
| `makeDir` does not exist | 1 | `createDir(io, path, @enumFromInt(0o755))` |
| `File.writer(&buf)` missing io | 3 | `File.writer(io, &buf)` / `Stream.writer(io, &buf)` |
| `File.reader(&buf)` missing io | 3 | `File.reader(io, &buf)` / `Stream.reader(io, &buf)` |
| `iter.next()` missing io | 1 | `iter.next(io)` |
| `Dir.rename()` signature changed | 1 | `dir.rename(old, new_dir, new, io)` |
| `readByte()` does not exist | 1 | `reader.interface.takeByte()` |
| `readAll()` does not exist | 1 | `reader.interface.readSliceAll(buf)` |
| `Stream.getLocalAddress()` does not exist | 1 | `stream.socket.address` field |
| `Socket.getLocalAddress()` does not exist | 1 | `socket.address` field |
| `Ip4Address.saddr` does not exist | 1 | `Ip4Address.bytes` field |
| `std.Io.time.sleep` does not exist | 1 | `std.Io.sleep(io, Duration.fromSeconds(n), .real)` |
| `std.Io.net.getHostname` does not exist | 1 | `std.posix.gethostname(&buf)` |
| `ConnectOptions` missing `.mode` | 1 | `.{ .mode = .stream }` |
| `Stream.Writer` ≠ `Io.Writer` | 1 | Use `.interface` field with protocol builder |
| `OnIpChanged` cannot pass context | 2 | Changed to struct with `context: ?*anyopaque` + `callFn` pointer |
| `createDir` returns error union flagged in Debug mode | 1 | `createDir(...) catch {};` explicitly ignore error |
| `std.process.Child.run` does not exist (removed in 0.16.0) | 3 | Use `std.process.run(allocator, io, .{...})` instead |
| `ArrayList.init(allocator)` does not exist (removed in 0.16.0) | 2 | `= .empty` + `appendSlice(allocator, ...)` + `toOwnedSlice(allocator)` |
| Windows `getSystemInfo()` hardcoded MAC=00:00:00:00:00:00 | 1 | Changed to call `getWindowsMac(io, allocator)`, CSV parse getmac output |
| deploy `buildBinary` Windows .exe extension lost | 1 | Detect `is_windows_target`, adjust src/dst extension on cp |
| deploy SCP file-in-use causes upload failure | 2 | First `schtasks /end` + `taskkill` to stop process, then upload, then `schtasks /run` |
| `result.term.Exited` enum field name changed | 2 | `.Exited` → `.exited` (Zig 0.16.0 lowercase) |
| `--exec`/`--status` port conflict (architecture design issue) | 3 | Phase 9 IPC architecture refactoring: management commands forwarded via 127.0.0.1:12347 TCP to persistent Host, CLI only displays results |
| IPC `reader.interface.take(4096)` unreliable for clients | 2 | Changed to `reader.interface.takeByte()` reading byte-by-byte until EOF (consistent with executor) |
| `std.Thread.Mutex` does not exist in Zig 0.16.0 | 1 | Changed to `std.Io.Mutex`, `.init` initialization, `lock(io)`/`unlock(io)` requires Io parameter |

## Notes
- zig skill: `.claude/skills/zig/SKILL.md`
- Three VMs: macvm (root/111, /opt/), linuxvm (root/111, /opt/), windowsvm (Administrator/111, C:\opt\)
- `--watch` and `F8 health reporting` explicitly rejected by user
