# UTM Monitor Skill

Remote debugging sidekick. Build → deploy → daily ops for VMs and physical machines.
Single Zig binary: `utmm` (embeds `utmmd` supervisor).

## VM Table

| VM | Hostname | Target | IP | User | Password | Shell |
|----|----------|--------|----|------|----------|-------|
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.6 | root | 111 | /bin/bash |
| macOS | macvm | aarch64-macos | 192.168.65.4 | root | 111 | /bin/zsh |
| Windows ARM | windowsvm | aarch64-windows | 192.168.64.3 | Administrator | 111 | cmd.exe |
| Windows x64 | winx64 | x86_64-windows | 192.168.3.108 | Administrator | 111 | cmd.exe |

## Trigger Conditions

Use this skill when the user requests:
- "build" / "compile" / "cross-compile"
- "deploy" / "升级" / "install on VM"
- "status" / "exec on VM" / "upload" / "download"
- "sshpass" / "SSH with password"
- "clean deploy" / "bare metal reset"
- VM troubleshooting / connectivity issues

## Common Operations

### Check Status
```bash
sudo utmm --status    # CLI needs root (binary checks isAdmin). In this repo prefer the utmm MCP `status` tool — no sudo needed.
```

### Execute on Guest
```bash
sudo utmm --exec <hostname> "<command>"   # CLI needs root. In this repo prefer the utmm MCP `exec` tool — no sudo needed.
# POSIX: use sh syntax (bash/zsh)
# Windows: use cmd.exe syntax (UTF-8). `&&` not `;` for chaining.
```

### File Transfer
```bash
sudo utmm --upload <local-file> <vm>[:<remote-path>]   # CLI needs root. In this repo prefer the utmm MCP `upload` tool.
sudo utmm --download <vm> <remote-path> [<local-path>] # CLI needs root. In this repo prefer the utmm MCP `download` tool.
# Windows remote paths: single-quote if backslashes are used in bash
```

### SSH with Password (built-in sshpass)

Built-in non-interactive SSH password auth — identical to standalone `sshpass(1)`.
Works on **Linux, macOS, and Windows** (ConPTY dynamic loading + pipe fallback).
No external sshpass binary needed. This is the primary tool for direct VM access
when MCP tools are not applicable (bootstrap, recovery, pre-install debugging).

```bash
utmm sshpass -p '<pass>' ssh <user>@<hostname> '<command>'
utmm sshpass -f <file> ssh ...      # read password from file
utmm sshpass -e ssh ...             # read password from $SSHPASS
```

### Build
```bash
cat src/ver.txt                     # check current version
zig build -Doptimize=ReleaseSafe    # native (for Host)
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl  # cross-compile
```

**Testing**: `zig build test` may hang on macOS due to a Zig 0.16.0 `--listen=-` protocol bug.
Workaround — run test binaries directly:
```bash
# Unit tests
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/test 2>&1 | tail -5
# Integration tests
perl -e 'alarm 30; exec @ARGV' -- .zig-cache/o/*/integration_test 2>&1
```
Both must pass (0 failures) before deployment.

### MCP Tools Test

Full validation of all 7 MCP tools via HTTP POST against the running Host daemon:
```bash
sudo python3 tests/test_mcp_tools.py
```
Covers `status`, `exec`, `ping`, `upload`, `download`, `sshpass`, `manual`.
Sends JSON-RPC requests via HTTP POST to `http://127.0.0.1:2121/`.
Requires Host daemon running with at least one Guest online (linuxvm for file transfer tests).

### CLI Commands Test

Full validation of all CLI management commands against the running Host daemon:
```bash
sudo python3 tests/test_cli_commands.py
```
Covers `--version`, `--status`, `--ping`, `--exec`, `--upload`, `--download`, `sshpass` (with -V, -h, -p, -f, wrong-password).
Requires Host daemon running with at least one Guest online (linuxvm for file transfer tests).

### Deploy to Guest

**Automated (recommended):** `utmm --deploy` reads `deploy.json`, cross-compiles (cached),
and pushes to all VMs using built-in `utmm sshpass`. See MANUAL.md for deploy.json format.

```bash
utmm --deploy              # all VMs
utmm --deploy linuxvm      # single VM
utmm --upgrade linuxvm     # push via SOCKS5 mesh (no SSH, zero-downtime)
```

**Manual deploy** using built-in `utmm sshpass` (no external sshpass needed):

```bash
# POSIX (Linux/macOS):
utmm sshpass -p <pass> scp /opt/utmm/utmm-<target>-<ver> <user>@<hostname>:/opt/utmm/utmm-new
utmm sshpass -p <pass> ssh <user>@<hostname> 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname <hostname>'

# Windows — kill utmmd first (locks exe → AccessDenied):
utmm sshpass -p <pass> ssh Administrator@<hostname> 'taskkill /F /IM utmmd.exe 2>nul'
utmm sshpass -p <pass> scp /opt/utmm/utmm-<target>-<ver>.exe Administrator@<hostname>:C:/opt/utmm/utmm-new.exe
utmm sshpass -p <pass> ssh Administrator@<hostname> 'C:\opt\utmm\utmm-new.exe --install --hostname <hostname>'
```

## Key Notes

- **CLI needs sudo** for `status`/`exec`/`upload`/`download`/`install` (binary checks `isAdmin()`); `sshpass` and `--version` are exempt. **In this repo prefer the utmm MCP tools** (`status`/`exec`/`ping`/`upload`/`download`/`sshpass`) — they reach the running Host daemon over the mesh and need no sudo in the agent session.
- **No external sshpass** — `utmm sshpass` is built-in for all password-auth operations
- **deploy.json** at `/opt/utmm/deploy.json` configures VM credentials for `--deploy`
- **Serve-dir cache**: `--deploy` skips recompilation when binaries exist in serve-dir
- **Per-command pty**: each exec opens a fresh shell. No `cd`/`export` persistence across commands
- **ConPTY**: `--status` shows `conpty:yes/no`. Windows < 10.0.17763 falls back to pipe mode. POSIX always `yes`
- **macOS launchctl** may throttle bootstrap — if `--install` fails, kill processes first then retry
- **Windows SSH** does NOT handle `;` command chaining — use `&&` or separate calls
- **LSA sync** takes ~10-15s after guest restart before it appears in `--status`
- **Build output naming**: cross-compiled binaries include version suffix (e.g. `utmm-aarch64-linux-0.18.0`)
- **`utmm --upgrade` errors** include actionable guidance (e.g. "run --deploy first")

## Skills for Specific Workflows

- **Full deployment cycle**: `.claude/skills/deploy/SKILL.md` — build → test → deploy all VMs → verify
- **Clean deploy test**: `.claude/skills/clean-deploy/SKILL.md` — full wipe → rebuild → re-deploy → smoke test
