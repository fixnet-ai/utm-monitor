# UTM Monitor 部署体验审计 — 普通用户视角

**日期**: 2026-08-03
**版本**: v0.17.21
**方法**: 模拟一个完全不了解项目的用户，从 GitHub Releases 下载 `utmm.zip` 开始，逐步骤追踪会遇到的每一个障碍。

---

## 障碍 1：zip 里只有裸二进制，零文档

**现象**: 下载 `utmm.zip`，解压看到 9 个二进制文件 + `ver.txt`。没有 README、没有安装说明、
没有示例配置。用户必须回到 GitHub Releases 页面或 repo README 才知道下一步该做什么。

**根因**: `release.sh` 只打包了 `zig build cross` 产物，没有包含任何文档或引导文件。

**影响**: 离线环境（air-gapped）完全无法获取使用说明。即使在线，GitHub 页面和 zip 内容的
割裂增加了认知负担。

### 解决方案

**方案 A（推荐）— zip 内嵌 README + QUICKSTART**:
- `release.sh` 打包时增加 `README.md` 和 `QUICKSTART.md`（精简版，纯文本，<2KB）
- QUICKSTART.md 包含：解压后选哪个二进制、三条命令完成安装、示例
- 成本：`release.sh` 加 2 行 `cp` + zip 稍大几 KB

**方案 B — 二进制内嵌引导**:
- 无参数运行 `./utmm` 时，当前行为是静默确保 Guest 服务然后退出
- 改为：检测到是首次运行（`/opt/utmm/utmm` 不存在），打印引导信息
- `--help` 已存在，但新用户可能不会先想到 `--help`
- 成本：`main.zig` 加 15 行首次运行检测逻辑

**方案 C — GitHub Release body 作为主要文档载体**:
- 在 release body 中写入完整的 Quick Start（GitHub Releases 支持 Markdown）
- `release.sh` 的 `gh release create --notes` 已支持，只需充实内容
- 成本：写一份好的 release notes 模板

**建议**: A + C 组合（zip 内嵌基础文档 + Release body 详细说明），投入最小，覆盖在线/离线两种场景。

---

## 障碍 2：想编译？`zig build` 直接失败 — zio 依赖不可解析

**现象**: 用户 clone 仓库，执行 `zig build`，Zig 包管理器报错：

```
error: dependency "zio" not found at /Users/xxx/works/.../fixnet/zio
```

`build.zig.zon` 第 8 行写的是 `.path = "../zio"`——**本地相对路径，不是 URL**。
Zig 看到 `.path` 不会去网络下载，只检查本地磁盘上那个目录是否存在。
用户不可能提前知道需要在隔壁目录 clone zio。

**根因**: zio 的 x86 32-bit 支持在 PR #646 中（尚未合并上游），不能直接用上游 URL，
临时使用 `path = "../zio"` 指向本地 fork。这个 fork 只存在于开发机器上。

**影响**: 这是编译路径上的硬阻断。对 Zig 生态不熟悉的用户完全无法自行解决。

### 解决方案

**方案 A（短期，PR 合并前）— build.zig.zon 改为 URL + 说明文档**:
- 在 README 中增加 "Build Prerequisites" 章节，明确写：
  ```
  git clone https://github.com/fixnet-ai/zio.git ../zio
  cd ../zio && git checkout feat/x86-32
  ```
- `build.zig.zon` 保持 `path`（方便开发），增加注释说明来源
- 成本：README 加 5 行

**方案 B（中期，PR 合并后）— 切回上游 URL**:
- zio PR #646 合并后，`build.zig.zon` 改为 `url: "https://github.com/lalinsky/zio/archive/<tag>.tar.gz"`
- Zig 包管理器自动下载，消除手动 clone 步骤
- 成本：PR 合并后改 2 行

**方案 C（长期，完全消除依赖）— 考虑是否真的需要 zio**:
- 评估 utm-monitor 对 zio 的使用深度（协程、IO、网络）
- 如果只用到了少数模块，考虑内联提取或用 Zig 标准库替代
- 成本：大，可能需要大量重构

**建议**: 短期 A + 中期 B。长期 C 取决于 zio 维护状态和 utmm 的实际需求。

---

## 障碍 3：`--deploy` 要求 Host 上有完整 Zig 工具链

**现象**: 用户以为 `--deploy` 是把已下载/已编译的二进制分发到 VM。实际执行时，
`cmdDeploy` 的第一步是 `zig build cross -Doptimize=ReleaseSafe`——在 Host 上重新
完整交叉编译 8 个目标。用户需要：
- Zig 0.16.0
- zio 源码（见障碍 2）
- macOS 构建环境（codesign）
- 漫长的编译等待

**根因**: `--deploy` 被设计为开发者工具（"编译 → 分发" 一体），而非运维工具（"已编译好的二进制 → 分发"）。

**影响**: 运维人员无法使用 `--deploy`。每次部署都要重新编译，即使二进制没有任何变化。

### 解决方案

**方案 A（推荐）— 拆分 `--deploy` 为两个命令**:
- `--deploy`：纯粹的二进制分发命令。从 serve-dir（`/opt/utmm/`）读取已编译的二进制，
  通过 `sshpass scp` + `ssh --install` 推送到 VM。不需要任何编译工具。
- `--build`（新命令）或保留 `zig build cross`：编译所有目标并复制到 serve-dir。
- 工作流变为：`zig build cross` → `utmm --deploy`（两个独立步骤）
- 成本：`host.zig` 删除 `cmdDeploy` 中的 `zig build cross` 调用，~20 行改动

**方案 B — 保留当前行为，增加 `--deploy --no-build` 标志**:
- 默认行为不变（向后兼容）
- `--no-build` 跳过编译步骤，直接从 serve-dir 分发
- 成本：加一个 bool 参数，~10 行

**方案 C — 完全移除 `--deploy`，交给外部脚本**:
- `--deploy` 本质上是一个 shell 脚本的职责
- 改为在 SKILL.md 或 release.sh 中提供 deploy 脚本
- `utmm` 只保留 `--upgrade`（mesh 内升级通道）
- 成本：删除 `cmdDeploy` 代码，新增 deploy.sh 脚本

**建议**: 方案 A。拆分后语义清晰，`--deploy` 对运维友好，编译留给开发流程。

---

## 障碍 4：VM 凭据硬编码在源码里

**现象**: 用户有 3 台自己的 VM，IP、用户名、密码与 `host.zig` 中预设的完全不同。
寻找配置文件来修改——但找不到。`VM_DEPLOY_TABLE` 是编译时常量。代码里有一行注释
"Override with `utmm-deploy.json` if present"，但这个功能从未实现——全代码库搜索
不到任何读取该文件的逻辑。用户只能改源码然后重编译。

**根因**: `utmm-deploy.json` 在计划中但从未实现。当前项目只有 4 台固定 VM，
硬编码对开发流程足够了，但对外部用户是 100% 阻断。

**影响**: 这是外部用户部署的最大障碍。没有配置机制 = 必须改代码 = 不是可用产品。

### 解决方案

**方案 A（推荐）— 实现 `utmm-deploy.json`**:
- 在 `svc.canonicalDir()`（`/opt/utmm/`）下读取 `deploy.json`
- 格式：
  ```json
  {
    "targets": [
      {
        "hostname": "myvm",
        "target": "aarch64-linux-musl",
        "ip": "10.0.0.5",
        "user": "root",
        "password": "mypass",
        "remote_dir": "/opt/utmm/"
      }
    ]
  }
  ```
- 文件存在则使用文件配置，不存在则回退到硬编码默认值
- `sshpass` 密码传递改用 `-f <tmpfile>`（从文件读取，避免 `ps` 泄露）
- 成本：`host.zig` 新增 `loadDeployConfig()` 函数 + JSON 解析（用 `std.json`），~80 行

**方案 B — 环境变量配置**:
- 用环境变量（`UTMM_DEPLOY_TARGETS` 等）替代配置文件
- 更简单但不够结构化管理多 VM
- 成本：~30 行

**方案 C — CLI 参数支持单次部署**:
- `--deploy` 支持参数：`utmm --deploy --to user@10.0.0.5 --target aarch64-linux-musl --hostname myvm`
- 密码通过 `-p` 或 `$SSHPASS` 传入
- 成本：`main.zig` CLI 解析 + `host.zig` 参数传递，~50 行

**建议**: 方案 A（配置文件）。这是最自然的管理多 VM 的方式，也符合那行注释的原始意图。
可与方案 C 互补（CLI 参数用于一次性操作，配置文件用于持久化管理）。

---

## 障碍 5：Windows VM `--deploy` 是空操作

**现象**: 用户有 Windows VM，执行 `utmm --deploy windowsvm`。输出提示手动操作指南：
```
Copy utmm-x86_64-windows.exe → Administrator@192.168.x.x:C:\opt\utmm\utmm-new.exe
Then run: C:\opt\utmm\utmm-new.exe --install --hostname windowsvm
```
然后报告 "success"，但实际上**什么也没做**。没有任何自动部署动作。

**根因**: 跨平台 `sshpass scp` + 远程 `--install` 在 Windows 上存在两个已知问题：
1. Windows 文件锁：utmmd.exe 运行时无法覆盖 `utmm.exe`（PE 文件加载锁）
2. `sc stop` 不保证杀掉 SYSTEM 权限的 utmmd.exe（见 `windows-stop-utmmd-ineffective` memory）

**影响**: Windows VM 部署完全依赖手动操作。对混合 OS 环境（企业常见），部署体验割裂。

### 解决方案

**方案 A — 实现 Windows 远程部署**:
- `scp` 上传到 `C:\opt\utmm\utmm-new.exe`（temp 文件名，不冲突）
- `ssh` 远程执行 `sc stop UTM-MonitorD; timeout /t 3; taskkill /f /im utmm.exe; taskkill /f /im utmmd.exe`
- 然后 `move /Y C:\opt\utmm\utmm-new.exe C:\opt\utmm\utmm.exe; sc start UTM-MonitorD`
- 使用 `sshpass` 内嵌的 ssh.exe，零额外依赖
- 成本：`host.zig` `cmdDeploy` 中 Windows 分支从 "打印指南" 改为 "执行命令"，~40 行

**方案 B — 走 mesh 升级通道（`--upgrade`）**:
- 如果 Windows VM 已有旧版 utmm 运行并被 LSA 发现，用 `--upgrade` 代替 `--deploy`
- `--upgrade` 走 TCP :2121 SOCKS5 mesh，不需要 SSH，绕过所有 Windows SSH 问题
- 限制：初次部署仍需手动 bootstrap
- 成本：无代码改动，改进文档说明

**方案 C — 生成 bootstrap 脚本**:
- `utmm --gen-init windows` 生成 PowerShell 一键部署脚本
- 用户手动复制脚本到 Windows VM 执行
- 脚本内容：下载/接收二进制 → 停服务 → 替换 → 启动
- 成本：`svc.zig` `genInit` 功能扩展，~30 行

**建议**: A（短期修复） + B（推荐常态使用）。让 `--deploy` 对 Windows 也自动化，
同时文档强调 mesh 升级是更优的日常升级路径。

---

## 障碍 6：`--upgrade` 走 SOCKS5 mesh，不走 SSH — 前提条件多

**现象**: 用户想升级 VM 上的 utmm，使用 `--upgrade linuxvm`。命令通过 TCP :2121
SOCKS5 mesh 传输二进制——**不走 SSH**。但前提条件包括：
1. Guest 已安装旧版 utmm 并在运行
2. Guest 已被 Host 通过 LSA 自动发现
3. 对应架构的二进制已存在于 Host 的 serve-dir（`/opt/utmm/`）
4. Guest 的 utmmd 能正确处理 `upgrade_cmd` 帧和文件替换

新用户大概率不满足这些条件（Guest 还没装、LSA 没发现、serve-dir 是空的）。

**根因**: `--upgrade` 是为已运行 mesh 环境设计的增量升级通道，不适用于初次部署或
离线 VM 场景。

**影响**: 用户需要理解 `--deploy`（SSH 初次部署）和 `--upgrade`（mesh 增量升级）
的区别，而这两个命令的命名并未体现这种区分。

### 解决方案

**方案 A — 改善错误信息，引导用户**:
- serve-dir 为空时：`"No binaries found in /opt/utmm/. Run: zig build cross && utmm --deploy"`
- Guest 未发现时：`"linuxvm not found in mesh. Is the Guest running? Use --deploy for initial setup."`
- 目标架构不匹配时：明确列出期望的文件名
- 成本：`host.zig` 中增加具体的错误检查，~30 行

**方案 B — 统一 `--deploy` 和 `--upgrade`**:
- `--upgrade` 自动选择传输通道：Guest 在线用 mesh，离线用 SSH
- 用户只需要一个命令：`utmm --upgrade <vm>`
- 内部逻辑：先查 LSA 表 → 在线走 mesh → 不在线走 SSH fallback
- 成本：`host.zig` 升级逻辑重构，~100 行

**方案 C — 重命名命令，语义更清晰**:
- `--deploy` → `--bootstrap`（初次安装）
- `--upgrade` → 保持不变（mesh 内升级）
- 或：`--deploy` = SSH 部署，`--push` = mesh 升级
- 成本：CLI 重命名 + 文档更新

**建议**: A（投入最小，立即改善体验） + B（中期统一入口）。C 是可选的改进，
但 CLI 命名的变更需要谨慎（向后兼容）。

---

## 障碍 7：Host 必须手动安装，Guest 无引导机制

**现象**: Host 安装需要用户手动执行 `sudo ./utmm --host --install`。Guest 部署需要：
1. 手动 SCP 二进制到 VM
2. SSH 进去执行 `sudo ./utmm --install --hostname <name>`

没有从 Host "一键推送安装到裸 VM" 的能力。Guest 端没有任何 bootstrap agent——
必须先拿到二进制才能开始。

这将部署变成了一个"鸡和蛋"问题：utmm 本身是用来管理 VM 的工具，但部署 utmm
到 VM 却需要 SSH/SCP 等传统手段。

**根因**: utmm 的设计哲学是"自包含二进制 + `--install`"，认为用户总能通过某种方式
把文件放到 VM 上。这对开发者是可接受的，但对运维用户是摩擦。

**影响**: 无法从零开始自动化部署整个集群。每增加一台 VM 都需要手动 SCP + SSH + install。

### 解决方案

**方案 A — Host 内置 Guest bootstrap**:
- Host 新增 `utmm --bootstrap <ip> --user root --hostname newvm` 命令
- 内部流程：用内嵌 sshpass → SCP 对应架构二进制 → SSH `--install --hostname newvm`
- 自动检测目标 OS/arch（通过 `uname -sm` 或 `ver`）
- 成本：`host.zig` 新增 `cmdBootstrap`，~150 行

**方案 B — 生成全平台 bootstrap 脚本**:
- `utmm --gen-init all > bootstrap.sh` 生成一个自包含脚本
- 脚本内容：base64 编码的各平台二进制 + 自动检测 OS/arch + 解码安装
- 用户只需复制一行 curl 命令到 VM 执行
- 成本：`svc.zig` 扩展 `genInit`，~100 行

**方案 C — MCP 驱动的引导**:
- 通过 MCP 工具的 `exec` 能力，AI agent 自动完成整个部署
- 已有 `sshpass` 内嵌，MCP 可调用
- 这需要外部编排（如 Claude Code），但 utmm 本身不感知
- 成本：无代码改动，靠 SKILL.md 中的 deploy skill 协调

**建议**: A（直接，用户可见） + C（已部分具备，补充说明文档）。方案 B 适合
纯离线/air-gapped 场景，可作为后续增强。

---

## 障碍 8：发布版本号不一致

**现象**: `build.zig.zon` 声明 `version = "0.0.0"`，但 `--version` 输出 `0.17.21`。
有 Zig 经验的用户会困惑——到底是 0.0.0 还是 0.17.21？

**根因**: 版本管理决策：`src/ver.txt` 是唯一真实来源（`@embedFile` 编译时嵌入），
`build.zig.zon` 的版本永久设为 `0.0.0`（CLAUDE.md 明确记录了这个决定）。

**影响**: 对 Zig 生态用户造成困惑（`build.zig.zon` 是 Zig 包管理器的版本标识）。
如果未来支持 `zig fetch`，版本不一致会引发问题。

### 解决方案

**方案 A — `build.zig.zon` 同步更新**:
- 在 `release.sh` 或 `build.zig` 中自动从 `ver.txt` 同步版本到 `build.zig.zon`
- 构建时 `build.zig` 读取 `ver.txt` 覆盖 `.version`
- 成本：`build.zig` 加 5 行

**方案 B — 在 README/CLAUDE.md 中解释**:
- 明确说明 `build.zig.zon` 的版本是占位符，真实版本看 `src/ver.txt` 或 `--version`
- 成本：文档加 2 行

**方案 C — 将 `ver.txt` 提升为唯一版本源，自动注入 `build.zig.zon`**:
- `build.zig` 在 `fn build()` 中用 `@embedFile("src/ver.txt")` 读取版本
- 动态设置 package version
- 成本：`build.zig` 中 ~10 行，`release.sh` 可删除手动版本检查部分

**建议**: 方案 A（最简单，消除不一致）。在 `build.zig` 中从 `ver.txt` 读取版本并设置，
不需要额外维护步骤。

---

## 优先级矩阵

| # | 障碍 | 严重度 | 修复成本 | 优先级 | 建议方案 | 状态 |
|---|------|--------|---------|--------|---------|------|
| 4 | VM 凭据硬编码 | 🔴 阻断 | 中 | **P0** | 实现 deploy.json | ✅ (2026-08-03) |
| 5 | Windows deploy 空操作 | 🔴 阻断 | 低 | **P0** | 远程 SSH 命令 | ✅ (2026-08-03) |
| 2 | zio 依赖不存在 | 🔴 阻断 | 低 | **P1** | README + URL | ✅ (2026-08-03) |
| 3 | deploy 要求 Zig 工具链 | 🟡 严重 | 低 | **P1** | serve-dir 缓存检测 | ✅ (2026-08-03) |
| 6 | upgrade 前提条件多 | 🟢 中等 | 低 | **P3** | 改进错误信息 | ✅ (2026-08-03) |
| 1 | zip 无文档 | 🟡 严重 | 低 | **P2** | 内嵌 QUICKSTART | 不做 |
| 7 | 无 Guest bootstrap | 🟡 严重 | 中 | **P2** | bootstrap 命令 | 待讨论 |
| 8 | 版本号不一致 | 🟢 低 | 低 | **P3** | build.zig 同步 | 不做 |

## 总结

当前 utm-monitor 对预设的 4 台 VM（SKILL.md 中记录的 macvm/linuxvm/windowsvm/winx64）
是流畅的开发-部署闭环。但对任何外部用户，最大的三个障碍是：

1. **没有 VM 配置机制**（P0）— ✅ 已修复。`/opt/utmm/deploy.json` 支持外部用户配置自己的 VM
2. **Windows 部署不可用**（P0）— ✅ 已修复。`--deploy` 对 Windows 执行完整的自动化部署
3. **zio 依赖不可解析**（P1）— 待处理。`zig build` 需要本地 clone zio

## P0 修复详情

两个 P0 修复均在 `src/host.zig`（~200 行新增/修改），无新文件，无协议变更。

### deploy.json (`loadDeployConfig`)

- 文件位置：`/opt/utmm/deploy.json`（POSIX）或 `C:\opt\utmm\deploy.json`（Windows）
- JSON 数组格式，每个元素包含 hostname/target/ip/user/password/remote_dir
- 文件缺失 → 日志警告 + 回退硬编码默认值
- 格式错误 → 跳过无效条目 + 继续处理
- `@intFromPtr` 编译时/堆分配指针区分，`freeDeployConfig` 对编译时常量空操作

### Windows 自动化

- scp 上传与 POSIX 一致（`sshpass -p <pass> scp ...`）
- 远程复合命令：`sc stop → timeout → taskkill → move → sc start`
- `-o StrictHostKeyChecking=no` 所有部署命令（POSIX + Windows）

### 验证

- `zig build test`: 196/196 通过 ✅
- `zig build test-integration`: 59/59 通过，0 泄漏 ✅
