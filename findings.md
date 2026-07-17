# Findings: v0.1.6 Bare-Metal Deployment Validation

## 环境信息
- Host: macOS (aarch64)
- VMs: linuxvm (aarch64-linux), macvm (aarch64-macos), windowsvm (aarch64-windows)
- 版本: v0.1.6 (GitHub Release)
- 部署方式: install.sh → GitHub Release (Host), install.sh --guest → Host HTTP (Guest)

## Phase 1 发现
- 清理顺利，无新问题
- pkill 需注意匹配精度：`pkill -9 -f utmm` 可能匹配到 SSH 会话自身

## Phase 2 发现

### Bug 1 (DOC/RELEASE): GitHub Release 资产命名
- `gh release create v0.1.6 /tmp/utmm.zip` 自动重命名为 `utmm-v0.1.6.zip`
- 需使用 `file#displayname` 语法: `gh release create v0.1.6 '/tmp/utmm.zip#utmm.zip'`
- GitHub CDN 传播延迟：release 创建后约 30s-60s 后 `/latest/download/` URL 才生效

## Phase 3 发现
- install.sh --guest 模式完美运行，无需任何手动干预
- Windows SSH 部署仍需 scp .ps1 文件方式

## Phase 4 发现

### Bug 2 (DOC): --download/--upload 路径限制未文档化
- `/bin/:filename` 和 `/upload` 端点都有路径遍历保护（拒绝含 `/` 或 `\` 的文件名）
- 只能操作 Guest 上 `/opt/utmm/` 目录中的文件，文件名必须是纯 basename
- 使用完整路径（如 `/opt/utmm/file.txt`）会导致 403 Forbidden → `error.HttpStatusNotOk`
- 错误消息非常误导（显示 "Guest not found" + "AddressInUse"）
- 已更新 MANUAL.md 和 SKILL.md 文档化此限制

## Phase 6 发现 (v0.1.17 → v0.1.19 Bug Fixes)

### Bug 3 (Windows): exec 永久挂起 — pipe 句柄继承
- **根因**: Zig 0.16.0 `CreateProcessW` 设置 `bInheritHandles=TRUE`（`Io/Threaded.zig:16241`）
- `std.process.run` 创建 stdout/stderr pipe → cmd.exe 子进程（尤其是孙子进程）继承 pipe write-end → 进程不退出则 pipe 永不 EOF → `std.process.run` 永久等待
- **修复 (v0.1.18)**: Windows 上使用 `std.process.spawn` + 文件重定向（临时文件）替代 `std.process.run` + pipe
- **副作用**: 临时文件（`utmm_out_*.tmp`、`utmm_err_*.tmp`）可能残留，需 `deleteFile` 清理

### Bug 4 (全平台): exec 不支持 shell 操作符
- **根因 1 - JSON 编码**: `http_client.zig:execRemote` 直接将命令字符串嵌入 JSON (`{"cmd":"{s}"}`)，不转义 `"`、`\`、控制字符 → 含特殊字符的命令产生非法 JSON
- **根因 2 - JSON 解析**: `http_server.zig:extractJsonCmd` 是简单字符串扫描，不处理转义序列 → 合法 JSON 中的 `\"` 也被错误截断
- **根因 3 - Windows argv 转换**: Zig 从 `argv[]` 重建命令行时，cmd.exe 元字符（`&`、`|`、`>`、`<`、`%`、`^`）被破坏
- **修复 (v0.1.19)**:
  1. 客户端 `escapeJsonString()`: 转义 `"` → `\"`、`\` → `\\`、`\n`、`\r`、`\t`
  2. 服务端 `std.json.parseFromSlice()`: 标准 JSON 解析，fallback `extractJsonCmdSimple` 向后兼容
  3. Windows `execWindows()`: 命令写入临时 `.bat` 文件后执行，绕过 argv→命令行转换
