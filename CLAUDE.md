# Zig 0.16.0 Development Rules

## Tech Stack & Environment
- **Language**: Zig 0.16.0 (Strictly enforce 0.16.0 syntax, DO NOT use 0.15.x or older deprecated patterns)
- **Tooling**: ZLS (Zig Language Server)

## Critical Code Style & Idioms for 0.16.0
1. **Async & Concurrency**: Zig 0.16.0 has removed the `async`/`await` keywords from the language, but has enhanced async IO through the `std.Io` interface (Future / Completion / event-driven non-blocking IO). Use `std.Io` abstractions; do not spawn raw OS threads unless explicitly required.
2. **Build System (`build.zig`)**: Always use the 0.16.0 `std.Build` API. Many older build functions have been consolidated or renamed. Never use `b.addBuildTask` or older 0.11-0.13 paradigms.
3. **Allocator Handling**: Always pass `allocator: std.mem.Allocator` as the first or last parameter to functions requiring allocation. Do not use global state for allocation.
4. **Error Handling**: Use `try`, `catch`, and `errdefer` for explicit resource tracking immediately after allocation or initialization.
5. **Memory Safety**: Prefer slices over raw pointers. Ensure `defer` and `errdefer` are used to prevent leaks.

## Verification Workflow
- BEFORE generating or refactoring any code, ALWAYS use the `zig-docs` MCP tool to query the Zig 0.16.0 standard library definition.
- DO NOT hallucinate standard library functions. Use `@memcpy` for regular memory copies; `std.mem.copyForwards` / `std.mem.copyBackwards` only for overlapping memory.


# CLAUDE.md

This file provides guidance for AI coding agents (Reasonix and Claude Code) working
in this repository. It is also symlinked as `AGENTS.md` for tools that read the
standard agent memory file.

**Keep communication and documentation in English**



## Project File Structure (22 src files + 13 test files + 2 test scripts)

```
src/
├── main.zig           Entry point, CLI parsing, mode dispatch
├── protocol.zig       All protocol definitions (types, frame serialization, VERSION)
├── fail.zig           Fast-fail helpers (err, msg — noreturn)
├── config.zig         Service config + file logger
├── arp.zig            ARP MAC→IP reverse discovery (Linux/macOS/Windows)
├── lsa.zig            LSA broadcast + node table + /etc/hosts + hostname→IP lookup
├── tcp.zig            TCP socket I/O + connection primitives
├── socks5.zig         SOCKS5 protocol (RFC 1928: CONNECT + BIND + UDP ASSOCIATE)
├── dpipe.zig          DuplexPipe interface + relay engine
├── dpipe_shell.zig    pty ↔ DuplexPipe (posix_openpt/CreatePipe)
├── dpipe_file.zig     file ↔ DuplexPipe + SHA256 verification
├── guest.zig          Guest daemon: TCP :2121 SOCKS5 dispatch + dpipe relay
├── host.zig           Host daemon: LSA + IPC + TCP :2121 SOCKS5 + first-byte dispatch (HTTP MCP)
├── ipc.zig            IPC socket server: CLI request handling (delegates to mcp_handler)
├── mcp.zig            MCP JSON-RPC processor (McpContext, tools/call dispatch)
├── mcp_handler.zig    MCP core business logic: exec/ping/upload/download on Guest (shared by HTTP MCP + IPC)
├── mcp_http.zig       HTTP/1.1 POST parser + transport (single-request-per-connection)
├── sshpass.zig        Built-in SSH password auth (PTY/ConPTY, 100% CLI compatible)
├── svc.zig            Service management (install/uninstall/forceInstall/ensure + Platform/genInit + InstallLock)
├── utmmd.zig          Supervisor daemon: utmm lifecycle, crash recovery, shared memory IPC
├── shm.zig            Shared memory protocol: utmmd↔utmm IPC, heartbeat, commands
└── testlib.zig        Test re-export module (protocol + tcp + dpipe + lsa + host + svc + fail + config)

tests/
├── common.zig              Test infrastructure (TestRunner, TestCase, socket I/O, TempDir)
├── integration_test.zig    Single entry point: setup → all tests → leak check → summary
├── test_tcp_frame.zig      TCP 帧协议 + SOCKS5 集成测试 (pub fn test_tcp_frame)
├── test_lsa_routing.zig    LSA + Dijkstra 集成测试 (pub fn test_lsa_routing)
├── test_dpipe_relay.zig    DuplexPipe relay 集成测试 (pub fn test_dpipe_relay)
├── test_svc_install.zig    安装/卸载集成测试 (pub fn test_svc_install)
├── test_exec_e2e.zig       Exec 端到端集成测试 (pub fn test_exec_e2e)
├── test_upload_e2e.zig     Upload 端到端集成测试 (pub fn test_upload_e2e)
├── test_download_e2e.zig   Download 端到端集成测试 (pub fn test_download_e2e)
├── test_upgrade_e2e.zig    Upgrade 端到端集成测试 (pub fn test_upgrade_e2e)
├── test_arp.zig            ARP MAC→IP 集成测试 (pub fn test_arp)
├── test_hosts.zig          /etc/hosts 同步集成测试 (pub fn test_hosts)
├── test_ipc_e2e.zig        IPC 端到端集成测试 (pub fn test_ipc_e2e)
├── test_mcp_tools.py       MCP 工具测试脚本 (HTTP POST, 7 tools)
└── test_cli_commands.py    CLI 命令测试脚本 (31 checks)
```

> v0.13.0: 20 → 19 files (10 deleted, 4 added later: arp.zig, sshpass.zig, socks5.zig, testlib.zig).
> Deleted: state.zig, broadcast.zig, mesh.zig, hosts_file.zig,
> tunproto.zig, tcpf.zig, socks4.zig, netconn.zig, cmdchan.zig, lock.zig.
> v0.13.2: Integration tests restructured from 8 separate executables to single binary.
> v0.17.11: Python test scripts added for MCP + CLI coverage.
> v0.18.0: Added mcp_handler.zig (core logic) + mcp_http.zig (HTTP transport). MCP stdio → HTTP.

## Code of Conduct / Guidelines

Before starting any work, read (if they exist): `./DESIGN.md`, `./API.md`, .



### Pre-coding Verification

**Zig:**
- Before writing Zig code, confirm 0.16.0 function signatures using the Zig docs tooling available in the current agent — the Reasonix `/zig` skill, or the `zig-docs` / `zig-mcp` MCP tools in Claude Code.
- After completion, verify no compilation errors: run `zig build` in Reasonix, or `plugin:zig-mcp` `zig_diagnostics` in Claude Code.

**Go:**
- Before writing Go code, call Context7 `resolve-library-id` to resolve the package, then `query-docs` to confirm function signatures

### Development Principles
1. **Think before coding** — state assumptions, present trade-offs
2. **Simplicity first** — minimum code, no speculative features
3. **Precise changes** — only change what's necessary, match existing style
4. **Goal-driven** — define criteria, verify with `zig build test`

### Deployment Gating Rule
**Code changes must pass integration tests before deployment to real devices.**
- `zig build test` and `zig build test-integration` must both pass (all scenarios, 0 failures)
- This catches protocol regressions (double MDELIM, frame format mismatches, etc.)
  before they reach physical VMs where debugging is slow and recovery difficult
- No exceptions for "trivial" changes — protocol bugs often come from one-line edits
