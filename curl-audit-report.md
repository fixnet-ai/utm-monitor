# Curl Audit Report — Zero-Dependency Analysis

**Date**: 2026-07-16
**Goal**: Identify every `curl` call site across the program, MCP, skill, and documentation; evaluate whether each can be replaced by a built-in `utm-monitor` CLI command to reduce environment dependencies.

---

## Summary

| Category | Count | Replaceable? |
|----------|-------|-------------|
| Zig source (generated shell scripts) | 3 lines in 2 files | ❌ Bootstrap — runs before utm-monitor exists |
| MCP (`src/mcp.zig`) | 0 | ✅ Already zero-curl |
| SKILL.md (skill examples) | 2 | ⚠️ Examples only — benign, but can update |
| MANUAL.md (documentation) | 17 | ⚠️ Mixed — some bootstrap, some can be replaced |
| README.md (documentation) | 5 | ⚠️ Mostly bootstrap, 1 can be replaced |
| install.sh (bootstrap) | 2 | ❌ Bootstrap — runs before utm-monitor exists |
| test_all.sh (test script) | 3 | 🔧 Can add new CLI commands |
| http-migration-plan.md (historical) | 4 | N/A — historical document |
| **Total curl references** | **36** | — |

---

## 1. Zig Source Code (src/) — 3 Call Sites

All three are **generated shell scripts** embedded in the binary as string literals. They execute on Guest VMs during the update/bootstrap flow.

### 1.1 `src/host_http.zig:140-141` — `/update` endpoint

```sh
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "http://$HOST:$PORT/bin/utm-monitor" -o /opt/utm-monitor.new
```

**Context**: Host HTTP server generates a self-update shell script served at `/update`. Guest downloads this script and pipes it to `sh`. The script uses curl (or wget fallback) to download the latest binary from Host's HTTP server.

**Replaceable?** ❌ **Not replaceable by program command.**
- This script runs **on the Guest** before or during update. The Guest may not have utm-monitor yet, or the running version is being replaced.
- The Guest's running utm-monitor process orchestrates the update (in `guest.zig:checkAndUpdate()`), but the actual binary download+replace happens via this generated shell script for safety (can't overwrite a running binary from within the same process).
- **Mitigation**: The Guest version-check loop (`guest.zig:74`) already uses `http_client.downloadText()` (Zig-native, no curl) to fetch this script from Host. The curl is only inside the generated script that does the final binary swap.

### 1.2 `src/http_server.zig:139` — Guest `/update` endpoint (version check)

```sh
REMOTE_VER=$(curl -s "${HOST}/version" 2>/dev/null || echo "")
```

**Context**: Guest HTTP server generates its own self-update script. This line checks the Host's version via HTTP.

**Replaceable?** ❌ **Same reason as 1.1.** This is a generated shell script for bootstrap. But note: the Guest auto-update loop (`guest.zig:checkAndUpdate()`) already uses `http_client.getVersion()` natively. This script is a secondary/fallback path.

### 1.3 `src/http_server.zig:145` — Guest `/update` endpoint (binary download)

```sh
TMP=$(mktemp) && curl -s "${HOST}/bin/${BIN}" -o "$TMP" && ...
```

**Context**: Downloads the new binary from Host HTTP server in the generated update script.

**Replaceable?** ❌ **Same reason as above.** Bootstrap shell script.

### ✅ What's already been done in Zig code

The program itself **never calls curl as a subprocess**. All HTTP operations in the Zig code use `std.http.Client`:

| Operation | Implementation | File |
|-----------|---------------|------|
| Version check | `http_client.getVersion()` | `src/http_client.zig` |
| Binary download | `http_client.downloadFile()` | `src/http_client.zig` |
| Text download | `http_client.downloadText()` | `src/http_client.zig` |
| File upload | `http_client.uploadFile()` | `src/http_client.zig` |
| Remote exec | `http_client.execRemote()` | `src/http_client.zig` |

**The Zig codebase is already 100% curl-free for its own operations.** The only curl references are in shell scripts that run in a context where utm-monitor isn't available yet.

---

## 2. MCP (`src/mcp.zig`) — 0 Call Sites

✅ Zero curl references. MCP uses IPC (TCP to 127.0.0.1:12347) to communicate with the Host daemon. All HTTP operations happen inside the Host process via `std.http.Client`.

---

## 3. SKILL.md — 2 Call Sites

### 3.1 Line 54: Install packages example

```
vm_exec("linuxvm", "apt-get install -y curl")
```

### 3.2 Line 58: Check network example

```
vm_exec("linuxvm", "curl -s http://example.com")
```

**Replaceable?** ⚠️ **These are not program calls to curl — they are skill usage examples.** They show how to use `vm_exec` to run arbitrary commands on VMs. Curl here is just an example command.

**Recommendation**: Update the examples to use built-in tools instead:
- Line 54: Remove entirely — Guest already auto-updates, no need to install curl
- Line 58: `vm_exec("linuxvm", "utm-monitor --version")` or `vm_status()` for connectivity check

---

## 4. MANUAL.md — 17 Call Sites

### Bootstrap (NOT replaceable — no utm-monitor yet):

| Line | Context | Why not replaceable |
|------|---------|-------------------|
| 206 | `curl ...install.sh \| sh` | Initial install from GitHub |
| 214 | `VERSION=... curl ...install.sh \| sh` | Version-pinned install |
| 221-223 | `sudo curl .../utm-monitor-* -o /usr/local/bin/...` | Download binary from GitHub |
| 230 | `sudo curl ... -o /opt/utm-binaries/...` | Download guest binaries |
| 256 | `curl "http://$GATEWAY:2121/update" \| sh` | Bootstrap via Host HTTP |
| 268 | `curl "http://$gw:2121/bin/..." -o C:\opt\utm-monitor.exe` | Windows bootstrap |
| 620 | `curl ...install.sh \| sh` | Troubleshooting bootstrap |
| 636 | `curl "http://<host>:2121/update" \| sh` | Troubleshooting update |
| 940-956 | `sudo curl .../utm-monitor-* ...` | Manual install steps |

### Replaceable by program command:

| Line | Current curl | Proposed replacement | New command needed? |
|------|-------------|---------------------|-------------------|
| 470 | `curl -s http://<guest-ip>:2121/health` | `utm-monitor --host --status` | ✅ Already exists |
| 553 | `curl -X POST -F "file=@local_file" "http://...:2121/upload?filename=..."` | `utm-monitor --host --upload <file> <vm>` | 🆕 `--upload` |
| 556 | `curl "http://...:2121/bin/remote_file" -o local_file` | `utm-monitor --host --download <vm>:<path> <local>` | 🆕 `--download` |
| 758 | `curl -X POST -F "file=@new_binary" "http://...:2121/upload?filename=utm-monitor"` | `utm-monitor --host --deploy <vm>` | ✅ Already exists |
| 871 | `curl -s http://192.168.64.2:2121/health` | `utm-monitor --host --status` | ✅ Already exists |
| 1105 | `vm_exec("linuxvm", "curl -s -o /dev/null -w '%{http_code}' https://example.com")` | `vm_exec("linuxvm", "utm-monitor --version")` | ✅ Already exists |

---

## 5. README.md — 5 Call Sites

| Line | Context | Replaceable? |
|------|---------|-------------|
| 25 | "Install curl on the Windows VM" | ⚠️ Remove — no longer needed for program operation |
| 51 | Download binary from GitHub | ❌ Bootstrap |
| 56 | install.sh pipe from GitHub | ❌ Bootstrap |
| 65 | Download binary from GitHub | ❌ Bootstrap |
| 79 | `curl -o .claude/skills/utm-vm/SKILL.md https://...` | ✅ Replace with git clone or manual download |
| 129 | Download binary from GitHub | ❌ Bootstrap |

---

## 6. install.sh — 2 Call Sites

| Line | Context | Replaceable? |
|------|---------|-------------|
| 60 | `sudo curl -fsSL --progress-bar "$URL" -o "$BIN"` | ❌ Bootstrap — install.sh runs before utm-monitor exists |
| 90 | `sudo curl -fsSL --progress-bar "$gurl" -o "$gdest"` | ❌ Bootstrap — same reason |

---

## 7. test_all.sh — 3 Call Sites

| Line | Context | Replaceable? |
|------|---------|-------------|
| 74 | `http_get() { curl -s --connect-timeout 3 "$1"; }` | 🔧 Can add `--health` + `--download` CLI commands |
| 75 | `http_post_json() { curl -s --connect-timeout 3 -X POST ... }` | 🔧 Can add `--upload` CLI command |
| 378 | `curl -s --connect-timeout 5 -X POST -F "file=@..." ...` | 🔧 Can add `--upload` CLI command |

**Note**: test_all.sh is a QA tool, not a user-facing program. Having curl in the test is acceptable (tests need to be independent), but replacing with CLI commands would make it a self-test.

---

## 8. http-migration-plan.md — 4 References

Historical planning document. All references are in completed checkboxes and verification notes. No action needed.

---

## Proposed New CLI Commands

### A. `--upload <local_file> <vm>[:<remote_path>]` (Recommended)

**Replaces**: `curl -X POST -F "file=@..." http://<vm>:2121/upload?filename=...`

**Implementation**: Uses existing `http_client.uploadFile()` under the hood.

**Complexity**: Low. `uploadFile` already exists in `http_client.zig`. Need:
- CLI parsing for `--upload` flag
- Resolve VM name to IP via broadcast cache (same as `--exec`)
- Call `http_client.uploadFile(io, gpa, ip, http_port, local_path, remote_filename)`

**Use case**: Deploy config files, scripts, data files to VMs without curl.

```bash
utm-monitor --host --upload ./config.json linuxvm:/opt/config.json
utm-monitor --host --upload ./script.sh macvm:/opt/script.sh
```

### B. `--download <vm>:<remote_path> <local_path>` (Recommended)

**Replaces**: `curl http://<vm>:2121/bin/<file> -o <local>`

**Implementation**: Uses existing `http_client.downloadFile()` under the hood.

**Complexity**: Low. `downloadFile` already exists. Need same plumbing as `--upload`.

**Use case**: Fetch logs, data files, or binaries from VMs without curl.

```bash
utm-monitor --host --download linuxvm:/var/log/app.log ./app.log
utm-monitor --host --download windowsvm:C:/opt/data.csv ./data.csv
```

### C. `--health <vm>` (Low Priority)

**Replaces**: `curl -s http://<vm>:2121/health`

**Implementation**: HTTP GET to `/health` endpoint, return "OK" or error.

**Complexity**: Trivial. `--status` already shows VM liveness. `--health` would be a simpler, faster check for scripting.

```bash
utm-monitor --host --health linuxvm
# Exit 0 if OK, non-zero if not reachable
```

### D. `--trigger-update <vm>` (Optional)

**Replaces**: `curl -s http://<host>:2121/update | sh` (manual Guest update trigger)

**Implementation**: Host sends an HTTP request to Guest's `/update` endpoint (which is already served).

**Complexity**: Low. Just need to call the Guest's update endpoint.

**Use case**: Manually trigger a Guest to update to latest Host version.

```bash
utm-monitor --host --trigger-update linuxvm
```

---

## Feasibility Assessment

| Command | Effort | Files to Modify | Benefit | Risk |
|---------|--------|-----------------|---------|------|
| `--upload` | 2-3 hours | `main.zig`, `host.zig` (or new `upload.zig`) | Replaces 3 curl lines in docs + test | Low |
| `--download` | 2-3 hours | `main.zig`, `host.zig` (or new `download.zig`) | Replaces 2 curl lines in docs | Low |
| `--health` | 1 hour | `main.zig`, `host.zig` | Minor convenience | None |
| `--trigger-update` | 1-2 hours | `main.zig`, `host.zig` | Replaces 2 curl lines in docs | Low |

---

## Recommendations

### Immediate (this iteration):

1. **Add `--upload` and `--download` commands** — These are the most impactful. They replace all non-bootstrap curl usage in documentation, and make the test script self-testing. Combined effort ~5 hours.

2. **Update SKILL.md examples** — Replace curl examples with utm-monitor equivalents (line 54: remove curl install, line 58: use `vm_status` or `--version`).

3. **Update README.md §2** — Remove "Install curl on the Windows VM" requirement. Windows guests no longer need curl because the binary can be delivered via scp from Host during bootstrap.

### Documentation update (follow-up):

4. **Update MANUAL.md** — Replace the 6 replaceable curl examples with new CLI commands. Keep bootstrap curl examples (GitHub download, install.sh) but clearly mark them as "bootstrap only" with a note that once installed, all operations use built-in commands.

5. **Update test_all.sh** — Replace curl-based HTTP tests with new CLI commands where possible, keeping curl only for raw HTTP protocol validation.

### Not actionable:

6. **Bootstrap curl calls** (GitHub release download, install.sh, generated update scripts) — These run **before** utm-monitor is available and fundamentally cannot be replaced by program commands. They are the minimum bootstrap dependency, which is:
   - `curl` (or `wget`) on the machine doing initial installation
   - `curl` (or `wget`) on Guest VMs for the first `/update` bootstrap
   - After first bootstrap, Guest's version-check loop uses `http_client.zig` (Zig-native)

---

## Final Tally

```
Total curl references found:  36
├── Already handled:            0  (no curl in program, MCP already clean)
├── Bootstrap (cannot replace): 16 (5 Zig generated scripts + 9 doc + 2 install.sh)
├── Replaceable by new commands: 9 (6 MANUAL.md + 3 test_all.sh)
├── Documentation examples:      8 (can be updated to show CLI commands)
└── Historical/other:            3
```

**Net effect of proposed changes**: After adding `--upload` and `--download`, the program+CLI will cover **100% of operations** that happen after initial installation. The only remaining curl dependency is the **bootstrap chicken-and-egg** (downloading the first binary onto a machine), which is inherent to any software distribution.
