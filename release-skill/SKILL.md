---
name: release
description: >
  Use this skill whenever the user asks to publish a release, create a GitHub
  release, tag a version, or release a new version of utmm. Handles the full
  pipeline: version bump → test → cross-compile 8 targets → zip → git tag →
  gh release create. Trigger on: "release", "publish", "发布", "发版", "tag".
---

# Release — Build, Package & Publish utmm

## Prerequisites

- `gh` CLI authenticated (`gh auth status`)
- Zig 0.16.0 in PATH
- Clean working tree (no uncommitted changes)

## Workflow

### Step 1: Determine version

Read `src/ver.zig` to get the current version. Ask the user what the next version
should be (suggest patch bump, e.g. `0.5.0` → `0.5.1`). If the version is
already bumped and not yet tagged, use that.

### Step 2: Bump version (if needed)

Update these two files:
- `src/ver.zig`: `pub const VERSION = "X.Y.Z";`
- `build.zig.zon`: `.version = "X.Y.Z",`

> **Note**: `build.zig.zon` version field is mainly for the Zig package manager. The single source of truth for the runtime version is `src/ver.zig`.

### Step 3: Run tests

```bash
zig build test
```

Must pass. Stop and fix if any test fails.

### Step 4: Cross-compile all targets + create zip

```bash
./release-skill/build.sh
```

This builds 8 targets into `release/` and creates `utmm.zip`:

| # | Target | Output Binary |
|---|--------|---------------|
| 1 | `x86_64-windows` | `utmm-x86_64-windows.exe` |
| 2 | `aarch64-windows` | `utmm-aarch64-windows.exe` |
| 3 | `x86-windows-gnu` | `utmm-x86-windows.exe` |
| 4 | `x86_64-macos` | `utmm-x86_64-macos` |
| 5 | `aarch64-macos` | `utmm-aarch64-macos` |
| 6 | `x86-linux-musl` | `utmm-x86-linux` |
| 7 | `x86_64-linux-musl` | `utmm-x86_64-linux` |
| 8 | `aarch64-linux-musl` | `utmm-aarch64-linux` |

> **Note**: `x86-windows` (32-bit) uses `x86-windows-gnu` target triple to work around
> a MinGW linker warning (`_system@4`) that Zig promotes to an error.

### Step 5: Commit & tag

```bash
git add -A
git commit -m "vX.Y.Z: <brief summary of changes>"
git tag -a vX.Y.Z -m "vX.Y.Z: <description>"
git push origin main --tags
```

### Step 6: Create GitHub release

```bash
gh release create vX.Y.Z \
  --title "vX.Y.Z: <summary>" \
  --notes "<release notes in markdown>" \
  utmm.zip
```

### Step 7: Verify

Open the release URL printed by `gh release create` and confirm:
- `utmm.zip` is attached
- Release notes are correct
- Tag points to the right commit

## Post-release

After release, the Host's HTTP server auto-serves the new binaries from
`/opt/utmm/`. Guests auto-upgrade on version mismatch — Guest detects version
difference, downloads new binary from Host HTTP `/bin/utmm-<target>`, and
restarts itself.
