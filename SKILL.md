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
sudo utmm --status
```

### Execute on Guest
```bash
sudo utmm --exec <hostname> "<command>"
# POSIX: use sh syntax (bash/zsh)
# Windows: use cmd.exe syntax (UTF-8). `&&` not `;` for chaining.
```

### File Transfer
```bash
sudo utmm --upload <local-file> <vm>[:<remote-path>]
sudo utmm --download <vm> <remote-path> [<local-path>]
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
zig build test && zig build test-integration   # must pass before deployment
```

### Deploy to Guest

Host LSA syncs `/etc/hosts` — use hostname, not IP:

```bash
# POSIX (Linux/macOS):
scp zig-out/bin/utmm-<target>-<ver> <user>@<hostname>:/opt/utmm/utmm-new
ssh <user>@<hostname> 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname <hostname>'

# Windows:
scp zig-out/bin/utmm-<target>-<ver>.exe Administrator@<hostname>:C:/opt/utmm/utmm-new.exe
ssh Administrator@<hostname> 'C:\opt\utmm\utmm-new.exe --install --hostname <hostname>'
```

## Key Notes

- **sudo required** for all commands except `sshpass` and `--version`
- **Per-command pty**: each exec opens a fresh shell. No `cd`/`export` persistence across commands
- **ConPTY**: `--status` shows `conpty:yes/no`. Windows < 10.0.17763 falls back to pipe mode for sshpass. POSIX always `yes`
- **macOS launchctl** may throttle bootstrap — if `--install` fails, kill processes first then retry
- **Windows SSH** does NOT handle `;` command chaining — use separate SSH calls
- **Windows OpenSSH** must be enabled (`Add-WindowsCapability -Online -Name OpenSSH.Server`)
- **LSA sync** takes ~10-15s after guest restart before it appears in `--status`
- **Hostname resolution**: Host LSA syncs `/etc/hosts` — use `linuxvm`/`macvm`/`windowsvm`/`winx64` instead of IPs in all commands
- **Build output naming**: cross-compiled binaries include version suffix (e.g. `utmm-aarch64-linux-0.14.7`)

## Skills for Specific Workflows

- **Full deployment cycle**: `.claude/skills/deploy/SKILL.md` — build → test → deploy all VMs → verify
- **Clean deploy test**: `.claude/skills/clean-deploy/SKILL.md` — full wipe → rebuild → re-deploy → smoke test
