# UTM Monitor Skill — build, deploy, daily ops

Remote debugging sidekick. Single Zig binary (`utmm` embeds `utmmd` supervisor).
For VM table, architecture overview, and full reference, see `SKILL.md` (project root)
and `MANUAL.md`.

## Trigger Conditions

Use this skill for: build, cross-compile, deploy to VM, status, exec, file transfer,
sshpass, upgrade, clean deploy, VM troubleshooting.

## VM Table

See `SKILL.md` at project root for the current VM table. Quick reference:

| VM | Hostname | Target | IP | User |
|----|----------|--------|----|------|
| Linux | linuxvm | aarch64-linux-musl | 192.168.64.6 | root |
| macOS | macvm | aarch64-macos | 192.168.65.4 | root |
| Windows ARM | windowsvm | aarch64-windows | 192.168.64.3 | Administrator |
| Windows x64 | winx64 | x86_64-windows | 192.168.3.108 | Administrator |

Password for all VMs: `111`.

## Build

```bash
cat src/ver.txt                     # check version
zig build -Doptimize=ReleaseSafe    # native (Host)
zig build -Doptimize=ReleaseSafe -Dtarget=<target>  # cross-compile
zig build test && zig build test-integration   # must pass before deploy
```

Cross-compile targets: `aarch64-linux-musl`, `x86_64-linux-musl`, `aarch64-macos`,
`aarch64-windows`, `x86_64-windows`, `x86-windows-gnu` (and their x86-linux-musl,
x86_64-macos variants).

Output: `zig-out/bin/utmm-<target>-<version>` (version suffix in filename).

## Deploy

### Host (local macOS)

```bash
sudo zig-out/bin/utmm --host --install
sudo utmm --status
```

### Guest (scp + --install)

```bash
# POSIX:
scp zig-out/bin/utmm-<target>-<ver> <user>@<ip>:/opt/utmm/utmm-new
ssh <user>@<ip> 'chmod +x /opt/utmm/utmm-new && /opt/utmm/utmm-new --install --hostname <hostname>'

# Windows:
# Kill utmmd first (locks exe → AccessDenied):
ssh Administrator@<ip> 'taskkill /F /IM utmmd.exe 2>nul'
scp zig-out/bin/utmm-<target>-<ver>.exe Administrator@<ip>:C:/opt/utmm/utmm-new.exe
ssh Administrator@<ip> 'C:\opt\utmm\utmm-new.exe --install --hostname <hostname>'
```

### Quick Deploy (all VMs)

```bash
utmm --deploy           # build + scp + install all guests
utmm --deploy linuxvm   # single guest
```

## Daily Ops

```bash
sudo utmm --status                                    # all nodes
sudo utmm --exec <vm> "<command>"                     # exec on guest
sudo utmm --upload <file> <vm>[:<remote-path>]        # upload
sudo utmm --download <vm> <remote-path> [<local-path>] # download
sudo utmm --ping <vm>                                 # mesh ping
sudo utmm --upgrade <vm>                              # push upgrade
utmm sshpass -p '<pass>' ssh <user>@<ip> '<cmd>'       # non-interactive SSH
```

## Verify

```bash
sudo utmm --status                        # all VMs online + version match
sudo utmm --exec <vm> "echo OK"           # one per VM
```

## Key Notes

- **sudo required** (except `sshpass` and `--version`)
- **Per-command pty**: no `cd`/`export` persistence across execs
- **LSA sync**: wait 10-15s after guest restart before testing
- **macOS launchctl** may throttle — kill processes before `--install`
- **Windows SSH** doesn't handle `;` chaining — use `&&` or separate calls
- **ConPTY**: check `--status` for `conpty:yes/no`; Windows < 17763 uses pipe fallback
- **Build output has version suffix** — `utmm-aarch64-linux-0.14.7` not `utmm-aarch64-linux`
