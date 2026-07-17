# Task Plan: v0.1.6 Bare-Metal Deployment Validation

## Goal
使用最新发布的 v0.1.6，将所有 VM 和 Host 清理到裸机状态，严格按照文档（README.md + MANUAL.md + SKILL.md）从零部署 Host + 3 Guest。过程中遇到任何错误或文档缺失即停下完善 SKILL.md 和 MANUAL.md，直到文档能完美指导裸机部署全过程，功能正常。

**关键区别 vs 上一轮验证：**
- 使用 GitHub Release (`install.sh` 从 GitHub 下载 utmm.zip) 而非本地构建
- Guest 使用统一的 `install.sh --guest` 模式从 Host HTTP 下载
- v0.1.6 已包含 downloadFile/install.sh/CRLF 等修复

## Phases

### Phase 1: 清理所有遗留程序和服务
- [ ] 停止所有 VM 上的 utmm 进程
- [ ] 删除所有 VM 和 Host 上的自启动服务（launchd/systemd/sc）
- [ ] 清理 Host /etc/hosts 中的 UTM-MONITOR 标记块
- [ ] 删除所有 VM 和 Host 上的 /opt/utmm/ 目录
- [ ] 删除 Host /usr/local/bin/utmm 符号链接
- **Status:** in_progress

### Phase 2: Host 裸机部署
- [ ] 严格按 README.md One-Time Setup 用 install.sh 从 GitHub Release 安装
- [ ] 启动 Host `sudo utmm --host`，验证 HTTP server (2121) 正常
- [ ] 记录所有问题
- **Status:** complete

### Phase 3: Guest 裸机部署
- [ ] linuxvm: `curl http://<gw>:2121/bin/install.sh | sh -s -- --guest --hostname linuxvm`
- [ ] macvm: 同上
- [ ] windowsvm: 下载 install.ps1 后执行
- [ ] 每个 Guest 部署后验证 --status 可见、--exec 可执行
- [ ] 记录所有问题
- **Status:** complete

### Phase 4: 全功能验证
- [ ] --status 显示 3 个 Guest 在线，版本 v0.1.6
- [ ] /etc/hosts 正确包含 3 个条目
- [ ] --exec 在三平台均能执行命令
- [ ] --upload / --download 功能正常
- [ ] 重启持久性验证
- **Status:** complete

### Phase 5: 文档完善与提交
- [ ] 将新发现的问题记录到 SKILL.md / MANUAL.md
- [ ] 补充 FAQ
- [ ] 提交文档修改
- **Status:** complete

### Phase 6: Bug Fixes v0.1.17 → v0.1.19
- [x] Fix Windows exec hang (pipe inheritance deadlock) → v0.1.18
- [x] Fix exec shell operators (", &&, &, |) on all platforms → v0.1.19
- [x] Fix JSON encoding/decoding for commands with special chars
- [x] Fix Windows argv-to-command-line mangling via .bat file approach
- **Status:** complete

## 遇到的错误
| 错误 | 版本 | 解决方案 |
|------|------|---------|
| Windows exec 永久挂起 | v0.1.18 | pipe 继承 → 文件重定向 stdout/stderr + .bat 文件 |
| exec 不支持 " && & \| 等 shell 操作符 | v0.1.19 | JSON 转义 + std.json 解析 + Windows .bat 文件执行 |
| GitHub Release 资产自动改名 | v0.1.6 | `#displayname` 语法 |
| --download/--upload 路径限制未文档化 | v0.1.6 | 更新 MANUAL.md / SKILL.md |
