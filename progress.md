# Progress: v0.1.6 Bare-Metal Deployment Validation

## Session 2026-07-17 (v0.1.6 第二轮验证)
- 开始 v0.1.6 裸机部署验证（使用 GitHub Release）
- ✅ Phase 1: 清理所有 4 台机器
  - 注意：pkill -f utmm 匹配过宽会杀 SSH 会话，需精确匹配
- ✅ Phase 2: Host 裸机部署（v0.1.6 GitHub Release）
  - 发现 Bug 1: `gh release create` 资产自动改名 → 需 `#displayname` 语法
  - GitHub CDN 传播延迟 ~30-60s
- ✅ Phase 3: Guest 裸机部署
  - linuxvm: install.sh --guest 完美运行
  - macvm: install.sh --guest 完美运行
  - windowsvm: 需 scp .ps1 文件后执行（SSH 转义问题，已文档化）
- ✅ Phase 4: 全功能验证
  - --status: 3 VMs v0.1.6 在线
  - /etc/hosts: 正确同步
  - --exec: 三平台正常
  - --upload: 三平台正常 (纯文件名，12 bytes)
  - 发现 Bug 2: --download/--upload 只能操作 /opt/utmm/，纯文件名不含路径
  - --download: 三平台正常 (纯文件名，12 bytes)
  - 重启持久性: linuxvm 重启后 utmm 自动恢复上线
- ✅ Phase 5: 文档完善
  - MANUAL.md: 补充 --upload/--download 路径限制说明
  - SKILL.md: 添加 --download 路径问题 FAQ
  - findings.md: 记录 Bug 1、Bug 2

## Session 2026-07-17 (Bug Fixes v0.1.17 → v0.1.19)

### v0.1.18: Fix Windows exec hang (pipe inheritance deadlock)
- ✅ 根因分析: Zig CreateProcessW bInheritHandles=TRUE → 孙子进程继承 pipe write-end
- ✅ 修复: execWindows() 用 std.process.spawn + 文件 stdout/stderr 替代 std.process.run + pipe
- ✅ 验证: sc query（子进程）、netstat | findstr（管道命令）、5× 连续 rapid exec 全部通过
- ✅ 61 测试通过，8 目标交叉编译通过
- ✅ 已部署: windowsvm v0.1.18 验证通过

### v0.1.19: Fix exec shell operators on all platforms
- ✅ 根因分析: (1) JSON 编码无转义 (2) JSON 解析无逃逸处理 (3) Windows argv→命令行转换
- ✅ 修复: escapeJsonString() + std.json.parseFromSlice() + .bat 文件执行
- ✅ 验证: 三平台 echo "..."、&&、&、| 全部通过
- ✅ 61 测试通过，8 目标交叉编译通过
- ✅ 已部署: macvm/windowsvm/linuxvm 全部 v0.1.19
- ✅ 发布: https://github.com/fixnet-ai/utm-monitor/releases/tag/v0.1.19
- ✅ Memory 文件: windows-exec-pipe-inheritance-fix.md
- ✅ 规划文件: task_plan.md/findings.md/progress.md 更新
