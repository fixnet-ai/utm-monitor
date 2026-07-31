//! 测试库 — 为集成测试统一重新导出所有 src 模块。
//!
//! Zig 0.16.0 要求每个文件只属于一个模块。集成测试通过
//! `@import("testlib")` 访问所有 src 类型，避免文件冲突。
//!
//! 此文件是 tests 模块链的根 — 所有 @import 使用相对路径
//! 在 src/ 目录内解析。

pub const protocol = @import("protocol.zig");
pub const tcp = @import("tcp.zig");
pub const socks5 = @import("socks5.zig");
pub const dpipe = @import("dpipe.zig");
pub const lsa = @import("lsa.zig");
pub const host = @import("host.zig");
pub const svc = @import("svc.zig");
pub const fail = @import("fail.zig");
pub const config = @import("config.zig");
pub const ipc = @import("ipc.zig");
pub const arp = @import("arp.zig");
pub const guest = @import("guest.zig");
