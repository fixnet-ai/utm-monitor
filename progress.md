# Progress Log

## Session: 2026-07-16 (v0.1.0)

### Phase: Git History Reset — v0.1.0 Initial Release
- **Status:** complete
- **Actions:**
  - Reset version from 2.1.0 → 0.1.0 across all files (ver.zig, build.zig.zon, MANUAL.md, test_all.sh, planning files)
  - Reset git history: orphan main branch, current state as initial commit
  - Tag v0.1.0

### Phase 13: Standardize Binary Naming & Zip Packaging
- **Status:** complete
- **Actions:**
  - Unified naming: `utmm-{arch}-{os}[.exe]` convention across all files
  - Expanded from 5 to 8 build targets (added x86_64-linux, x86_64-windows, aarch64-windows)
  - Zip packaging: CI produces `utmm.zip` + `utmm-vX.X.X.zip` with all 8 binaries
  - serve_dir default: `/opt/utmm/` (was exe directory)
  - install.sh: rewrite — download zip, extract, detect arch, symlink
  - All docs, comments, CI, test scripts updated
  - 61/61 tests pass; all 8 cross-compilation targets build successfully


