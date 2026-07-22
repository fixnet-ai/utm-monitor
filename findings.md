# Findings: v0.5.0 pty Session Model

## Environment
- Host: macOS aarch64, Zig 0.16.0
- VMs: linuxvm (aarch64-linux-musl), macvm (aarch64-macos), windowsvm (aarch64-windows)
- Current version: v0.5.0

## Architecture Decision Records

### ADR-1: Persistent pty over per-command exec
**Decision**: Spawn a persistent shell (POSIX `posix_openpt` / Windows `CreatePipe`)
per WebSocket connection. Feed commands via pty stdin, read output from pty stdout.
**Rationale**: Users expect `cd` and `export` to persist across commands. v0.4.0
"Connection = Shell Session" model spawned a fresh child process for each command —
no env/cd persistence.
**Consequence**: ~300 lines of exec streaming code deleted. Added ptySpawn, ptyReadLoop,
ptyWrite. Shell session lives for the WebSocket lifetime.

### ADR-2: MDELIM exit-code markers for completion detection
**Decision**: Append `; echo MDELIM:$?\n` (POSIX) or `& echo MDELIM:%errorlevel%\r\n`
(cmd.exe) to every command. Host scans pty output for the marker to detect completion.
**Rationale**: pty merges stdout+stderr — no separate pipe for exit codes. Markers
embedded in the output stream are the simplest cross-platform solution.
**Consequence**: `scanForMarker` uses `lastIndexOf` to handle echoed command text on
macOS/BSD (where pty master doesn't support tcsetattr ECHO disable).

### ADR-3: Outgoing frame queue over direct write
**Decision**: HTTP handlers enqueue binary frames into `HostState.outgoing_frames`
(per-guest FIFO queue). WebSocket handler drains the queue in its main loop.
**Rationale**: WebSocket handler is single-threaded per guest. HTTP handlers run in
separate threads. Queue avoids concurrent write races.
**Consequence**: `OpState` + `wake_event` pattern: HTTP handler enqueues frame,
creates OpState, polls `takeOpResult()` with 30s timeout, sleeps on `wake_event`.

### ADR-4: Unified HTTP server on port 2121
**Decision**: Single `std.http.Server` handles all: WebSocket upgrades, REST API,
MCP JSON-RPC, static file serving. Guest is pure WebSocket client — no TCP server.
**Rationale**: Eliminates UDP broadcast discovery (v0.2.0), TCP binary protocol
server on guest (v0.2.0), and separate MCP port :2122 (v0.2.0).
**Consequence**: Net deletion of ~1100 lines. Guest auto-discovers Host via default
gateway. Single port simplifies firewall and debugging.

### ADR-5: Same binary for Host and Guest
**Decision**: Single `utmm` binary, default Guest mode, `--host` flag for Host mode.
**Rationale**: Reduces maintenance — no need to build/distribute separate host/guest
binaries.
**Consequence**: All modules compiled into one binary. `comptime` block in main.zig
ensures linker includes all modules.

## Platform-Specific Notes

### POSIX pty
- `posix_openpt(O_RDWR)` → `grantpt`/`unlockpt` → `fork()` → child: `setsid()`,
  `ioctl(TIOCSCTTY)`, `dup2(slave→0,1,2)`, `execve(shell, argv, environ)`
- macOS/BSD: pty master fd does NOT support `tcsetattr` (ECHO disable returns error).
  Host-side `scanForMarker` handles echoed command text via `lastIndexOf`.
  Linux: `tcsetattr` on master works normally.
- `execve` must pass `std.c.environ` (parent env), NOT `{null}` (empty env).
  Empty env means no HOME/SHELL/USER, `.bashrc`/`.zshrc` not loaded.

### Windows pty
- `CreatePipe` × 2 (stdin + stdout) → `CreateProcessW("cmd.exe /k")` with
  `STARTF_USESTDHANDLES`. `lpEnvironment=NULL` inherits parent env automatically.
- No `poll()`: main loop blocks on `readFrame`. Timer thread handles periodic
  re-announce. Exec completion signaled via WebSocket PING (wakes `readSmallMessage`).
- `CreateProcessW` + `STARTUPINFOW` must use UTF-16LE command line.
  `std.unicode.utf8ToUtf16LeWithNull` removed in 0.16.0 — manual UTF-16 encode.

### Shell compatibility
- `-l` (POSIX short option) works on all shells: dash, bash, zsh. GNU long option
  `--login` rejected by dash (Debian/Ubuntu `/bin/sh`).
- System services (systemd/launchd) have minimal environments: no HOME, no SHELL.
  `--install` now writes `Environment=SHELL=...` and `Environment=HOME=...` into
  service configs at install time.

## Bug Fixes (v0.5.0)

### CPU 100% on shell exit (all platforms)
**Root cause**: `ptyReadLoop` poll loop only checked `POLL.IN`. When shell exits,
pty master gets `POLL.HUP` — poll returns immediately but HUP was ignored, causing
busy-spin at 100% CPU.
**Fix**: Check `POLL.HUP` before `POLL.IN`, set `pty_dead=true`, break.

### waitTimeout infinite block on guest disconnect
**Root cause**: HTTP/MCP handlers called `wake_event.wait()` (no timeout). If guest
disconnected while a command was in flight, the handler thread blocked forever.
**Fix**: `wake_event.waitTimeout(30s)` in all four locations (host_http.zig × 3,
mcp.zig × 1). New `failAllPendingOps()` called on WS disconnect — marks all pending
ops as done with error, fires wake_event to unblock waiting handlers.

### `Io.Timeout` type mismatch
**Root cause**: `Io.Duration` passed where `Io.Timeout` union expected.
**Fix**: `.{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } }`.
`Io.Clock` uses `.awake` for monotonic-like clock.

### ptySpawn empty environment
**Root cause**: `execve(shell, argv, &[_:null]?[*:0]const u8{null})` passed empty
environment to child shell. HOME/SHELL/USER all empty, .bashrc/.zshrc not loaded.
**Fix**: Changed to `execve(shell, argv, std.c.environ)` — inherits parent process
environment. Windows `CreateProcessW(NULL, ..., NULL, ...)` unaffected (NULL = inherit).

### `--install` missing SHELL/HOME in service configs
**Root cause**: Generated systemd/launchd service files had no `Environment` variables.
Shell spawned by service had no HOME/SHELL.
**Fix**: Added `detectServiceEnv()` — reads `$SHELL`/`$HOME` at install time, falls
back to platform defaults (`/bin/zsh` on macOS, `/bin/bash` on Linux). Both
`genInit` and `installSelf` templates now include environment configuration.

## Known Issues

1. **Auto-upgrade not on WebSocket**: Guest binary self-upgrade uses HTTP download
   (`/bin/utmm-<target>`), not WebSocket. The `downloadAndUpgrade` function in
   broadcast.zig does a separate HTTP request.

2. **CLI upload/download path resolution**: Upload path on guest side is relative to
   `/opt/utmm/` (CWD). Full path support would require the guest to resolve paths.

3. **pty_resize is a stub**: Terminal resize message is parsed but not applied
   (TIOCSWINSZ ioctl not yet called).

4. **killForegroundProcess is a stub**: pty_signal supports per-signal values but
   currently only sends SIGKILL/TerminateProcess to the shell child.

5. **VM suspend/resume may cause stale WebSocket**: If a VM is suspended and the
   Host restarts, the guest may not detect the dead WebSocket connection until the
   next write attempt (which may hang). A TCP keepalive or application-level
   heartbeat could mitigate this.
