---
name: utmm
description: UTM Monitor 构建、部署与日常运维（build / cross-compile / status / exec / upload / download / sshpass / upgrade / SOCKS5 / VM 排障）。触发词：build / deploy / status / exec / sshpass / 升级 / SOCKS5。
---
# UTM Monitor Skill — build, deploy, daily ops

Remote debugging sidekick. Single Zig binary (`utmm` embeds `utmmd` supervisor),
dual mode (Guest + Host). Hub-spoke SOCKS5 forwarding — Host is the central proxy.
For VM table, architecture, and full reference, see `SKILL.md` (project root) and `MANUAL.md`.

## Trigger Conditions

Use for: build, cross-compile, deploy to VM, status, exec, file transfer, sshpass,
upgrade, SOCKS5 forwarding, clean deploy, VM troubleshooting.

## VM Table

See `SKILL.md` at project root for the current VM table. Quick reference:

| VM | Hostname | Target | IP | User |
|----|----------|--------|----|------|
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.6 | root |
| macOS | macvm | aarch64-macos | 192.168.65.4 | root |
| Windows ARM | windowsvm | aarch64-windows | 192.168.64.3 | Administrator |
| Windows x64 | winx64 | x86_64-windows | 192.168.3.108 | Administrator |

Password for all VMs: `111`.

> **deploy.json**: VM credentials can also be loaded from `/opt/utmm/deploy.json` (see MANUAL.md).

## Build

```bash
cat src/ver.txt                     # check version
zig build -Doptimize=ReleaseSafe    # native (Host)
zig build cross -Doptimize=ReleaseSafe  # all 8 targets in parallel
```

Cross-compile targets: `aarch64-linux-musl`, `x86_64-linux-musl`, `x86-linux-musl`,
`aarch64-macos`, `x86_64-macos`, `aarch64-windows`, `x86_64-windows`, `x86-windows-gnu`.

Output: `zig-out/bin/utmm-<target>-<version>` (cross build) or `zig-out/bin/utmm` (native build).

## Deploy

### Host (local macOS)

```bash
sudo zig-out/bin/utmm --host --install   # install/uninstall need root (writes /opt + launchd service)
sudo utmm --status                       # CLI checks isAdmin() → needs sudo
```

> **In this repo prefer the utmm MCP tools** (`status`/`exec`/`ping`/`upload`/`download`/`sshpass`) — they reach the running Host daemon over the mesh and need no sudo in the agent session.

### Guest (manual scp + --install, using built-in utmm sshpass)

```bash
# POSIX:
utmm sshpass -p 111 scp /opt/utmm/utmm-<target>-<version> <user>@<hostname>:/opt/utmm/utmm-new
utmm sshpass -p 111 ssh <user>@<hostname> 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname <hostname>'

# Windows — use utmm sshpass, kill utmmd first (locks exe → AccessDenied):
utmm sshpass -p 111 ssh Administrator@<hostname> 'taskkill /F /IM utmmd.exe 2>nul'
utmm sshpass -p 111 scp /opt/utmm/utmm-<target>-<version>.exe Administrator@<hostname>:C:/opt/utmm/utmm-new.exe
utmm sshpass -p 111 ssh Administrator@<hostname> 'C:\opt\utmm\utmm-new.exe --install --hostname <hostname>'
```

> **No external sshpass needed** — `utmm sshpass` is built-in. Only `ssh`/`scp` binaries required.

### Quick Deploy (all VMs via Host push)

```bash
utmm --deploy           # build + copy to serve-dir + scp all guests (cached on re-runs)
utmm --deploy linuxvm   # single guest
utmm --upgrade linuxvm  # push upgrade via SOCKS5 mesh (no SSH, zero-downtime)
```

`--deploy` auto-detects cached binaries in serve-dir and skips recompilation.

## Daily Ops

```bash
sudo utmm --status                                    # all nodes (CLI checks isAdmin → sudo; prefer MCP status)
sudo utmm --exec <vm> "<command>"                     # exec on guest (prefer MCP exec)
sudo utmm --upload <file> <vm>[:<remote-path>]        # upload (prefer MCP upload)
sudo utmm --download <vm> <remote-path> [<local-path>] # download (prefer MCP download)
sudo utmm --ping <vm>                                 # mesh ping (prefer MCP ping)
sudo utmm --upgrade <vm>                              # push upgrade
utmm sshpass -p '<pass>' ssh <user>@<hostname> '<cmd>'       # SSH password auth (no sudo)

# SOCKS5 forwarding (from Host):
curl --socks5 localhost:2121 http://linuxvm:8080      # reach any Guest service
# From a Guest, use gateway (Host IP synced to /etc/hosts):
#   curl --socks5 gateway:2121 http://linuxvm:8080
```

## MCP Tools

`utmm --mcp` provides 7 tools via stdio JSON-RPC: `status`, `exec`, `ping`, `upload`,
`download`, `sshpass`, `manual`. See `MANUAL.md` for the full MCP protocol reference.

## Verify

```bash
sudo utmm --status                        # all VMs online + version match
sudo utmm --exec <vm> "echo OK"           # one per VM
```

## Key Notes

- **CLI needs sudo** for `status`/`exec`/`upload`/`download`/`install` (binary checks `isAdmin()`); `sshpass` and `--version` are exempt. **In this repo prefer the utmm MCP tools** (`status`/`exec`/`ping`/`upload`/`download`/`sshpass`) — they reach the running Host daemon over the mesh and need no sudo in the agent session.
- **Hub-spoke SOCKS5**: Host is the only relay; Guests use `gateway:2121`
- **Per-command pty**: no `cd`/`export` persistence across execs
- **LSA sync**: wait 10-15s after guest restart before testing
- **macOS launchctl** may throttle — kill processes before `--install`
- **Windows SSH**: no `;` chaining — use `&&` or separate calls
- **ConPTY**: check `--status` for `conpty:yes/no`; Windows < 17763 uses pipe fallback
- **Build output**: `zig build cross` produces 8 platform binaries in `zig-out/bin/`
