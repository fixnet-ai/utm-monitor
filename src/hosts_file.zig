//! /etc/hosts marker block management
//!
//! Maintain a block wrapped by marker comments in the hosts file:
//!   # UTM-MONITOR-BEGIN
//!   192.168.64.5  macvm
//!   192.168.64.8  linuxvm
//!   # UTM-MONITOR-END
//!
//! Update logic: read file → replace marker block → write back (write to temp file then rename)

const std = @import("std");
const protocol = @import("protocol.zig");

/// A single hosts entry
pub const HostEntry = struct {
    ip: []const u8,
    name: []const u8,
};

/// Update the marker block in the hosts file
/// If the marker block does not exist, append it to the end of the file
/// Use temp file + rename for atomicity
pub fn updateHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entries: []const HostEntry,
) !void {
    // Read existing file content
    const original = readFile(io, allocator, file_path) catch |err| switch (err) {
        error.FileNotFound => {
            // File does not exist, create a new one
            return writeNewHosts(io, allocator, file_path, entries);
        },
        else => return err,
    };
    defer allocator.free(original);

    // Build new content
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    const begin_line = protocol.HOSTS_MARKER_BEGIN;
    const end_line = protocol.HOSTS_MARKER_END;

    var in_block = false;
    var block_written = false;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");

        if (std.mem.eql(u8, trimmed, begin_line)) {
            // Enter marker block, write new content
            in_block = true;
            try new_content.appendSlice(allocator, begin_line);
            try new_content.append(allocator, '\n');
            for (entries) |entry| {
                try new_content.print(allocator, "{s}  {s}\n", .{ entry.ip, entry.name });
            }
            try new_content.appendSlice(allocator, end_line);
            try new_content.append(allocator, '\n');
            block_written = true;
            continue;
        }

        if (in_block) {
            if (std.mem.eql(u8, trimmed, end_line)) {
                in_block = false;
            }
            // Skip all lines within the block
            continue;
        }

        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    // If no marker block exists in the file, append to the end
    if (!block_written) {
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        try new_content.appendSlice(allocator, begin_line);
        try new_content.append(allocator, '\n');
        for (entries) |entry| {
            try new_content.print(allocator, "{s}  {s}\n", .{ entry.ip, entry.name });
        }
        try new_content.appendSlice(allocator, end_line);
        try new_content.append(allocator, '\n');
    }

    // Write to temp file
    const tmp_path = try std.mem.concat(allocator, u8, &.{ file_path, ".tmp" });
    defer allocator.free(tmp_path);

    try writeFile(io, tmp_path, new_content.items);

    // Atomic rename using the file's parent directory (not cwd, which may change).
    // For absolute paths like /etc/hosts, this opens /etc as the dir handle.
    const parent_dir_path = std.fs.path.dirname(file_path) orelse "/";
    const parent_dir = try std.Io.Dir.cwd().openDir(io, parent_dir_path, .{});
    defer parent_dir.close(io);
    const file_basename = std.fs.path.basename(file_path);
    try parent_dir.rename(tmp_path, parent_dir, file_basename, io);
}

/// Read entire file content
fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size = try file.length(io);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buf);
    return buf;
}

/// Write entire file content
fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = @enumFromInt(0o644) });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

/// Create a new hosts file (with marker block)
fn writeNewHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entries: []const HostEntry,
) !void {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .permissions = @enumFromInt(0o644) });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    try writer.interface.print("{s}\n", .{protocol.HOSTS_MARKER_BEGIN});
    for (entries) |entry| {
        try writer.interface.print("{s}  {s}\n", .{ entry.ip, entry.name });
    }
    try writer.interface.print("{s}\n", .{protocol.HOSTS_MARKER_END});
    try writer.interface.flush();
}

// ========== Tests ==========

test "HostEntry struct basics" {
    const e = HostEntry{ .ip = "10.0.0.1", .name = "testvm" };
    try std.testing.expectEqualStrings("10.0.0.1", e.ip);
    try std.testing.expectEqualStrings("testvm", e.name);
}

test "HostEntry with FQDN" {
    const e = HostEntry{ .ip = "192.168.1.100", .name = "linuxvm.aarch64-linux-musl.utm" };
    try std.testing.expectEqualStrings("192.168.1.100", e.ip);
    try std.testing.expectEqualStrings("linuxvm.aarch64-linux-musl.utm", e.name);
}

test "HostEntry with IPv6 address" {
    const e = HostEntry{ .ip = "fe80::1", .name = "ipv6host" };
    try std.testing.expectEqualStrings("fe80::1", e.ip);
    try std.testing.expectEqualStrings("ipv6host", e.name);
}

test "HostEntry with empty name" {
    const e = HostEntry{ .ip = "1.2.3.4", .name = "" };
    try std.testing.expectEqualStrings("1.2.3.4", e.ip);
    try std.testing.expectEqualStrings("", e.name);
}

test "multiple entries with different IPs" {
    const entries = [_]HostEntry{
        .{ .ip = "10.0.0.1", .name = "vm1" },
        .{ .ip = "10.0.0.2", .name = "vm2" },
        .{ .ip = "10.0.0.3", .name = "vm3" },
    };
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("10.0.0.1", entries[0].ip);
    try std.testing.expectEqualStrings("vm2", entries[1].name);
    try std.testing.expectEqualStrings("10.0.0.3", entries[2].ip);
}
