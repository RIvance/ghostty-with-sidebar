//! Platform-independent data used by the Sidegeist GTK sidebar and IPC.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Fields = struct {
    title: bool = true,
    directory: bool = true,
    @"git-branch": bool = true,
    status: bool = true,

    pub fn parse(value: ?[]const u8) Fields {
        const text = value orelse return .{};
        var result: Fields = .{ .title = false, .directory = false, .@"git-branch" = false, .status = false };
        var found = false;
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part, " \t\r\n");
            inline for (std.meta.fields(Fields)) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    @field(result, field.name) = true;
                    found = true;
                }
            }
        }
        return if (found) result else .{};
    }
};

pub const Color = enum { none, blue, purple, pink, red, orange, yellow, green, teal, graphite };

pub const Status = struct {
    value: [:0]const u8,
    icon: ?[:0]const u8,
};

pub const Metadata = struct {
    color: Color = .none,
    statuses: std.StringArrayHashMapUnmanaged(Status) = .empty,

    pub fn deinit(self: *Metadata, alloc: Allocator) void {
        while (self.statuses.count() > 0) self.clear(alloc, self.statuses.keys()[0]);
        self.statuses.deinit(alloc);
    }

    pub fn set(self: *Metadata, alloc: Allocator, key: []const u8, value: []const u8, icon: ?[]const u8) !void {
        const owned_key = try alloc.dupe(u8, key);
        errdefer alloc.free(owned_key);
        const owned_value = try alloc.dupeZ(u8, value);
        errdefer alloc.free(owned_value);
        const owned_icon = if (icon) |v| try alloc.dupeZ(u8, v) else null;
        errdefer if (owned_icon) |v| alloc.free(v);
        try self.statuses.ensureUnusedCapacity(alloc, 1);
        self.clear(alloc, key);
        self.statuses.putAssumeCapacity(owned_key, .{ .value = owned_value, .icon = owned_icon });
    }

    pub fn clear(self: *Metadata, alloc: Allocator, key: []const u8) void {
        const old = self.statuses.fetchOrderedRemove(key) orelse return;
        alloc.free(old.key);
        alloc.free(old.value.value);
        if (old.value.icon) |v| alloc.free(v);
    }
};

test "sidebar fields follow Sidegeist defaults and tolerate unknown fields" {
    const t = std.testing;
    try t.expectEqual(Fields{}, Fields.parse(null));
    try t.expectEqual(Fields{}, Fields.parse("unknown,"));
    try t.expectEqual(Fields{ .title = false, .directory = true, .@"git-branch" = true, .status = false }, Fields.parse(" directory,git-branch,unknown "));
}

test "sidebar metadata replaces and removes owned status strings" {
    const t = std.testing;
    var metadata: Metadata = .{};
    defer metadata.deinit(t.allocator);
    try metadata.set(t.allocator, "server", "localhost:3000", "network");
    try metadata.set(t.allocator, "server", "localhost:4000", null);
    try t.expectEqual(@as(usize, 1), metadata.statuses.count());
    try t.expectEqualStrings("localhost:4000", metadata.statuses.get("server").?.value);
    try t.expectEqual(null, metadata.statuses.get("server").?.icon);
    metadata.clear(t.allocator, "missing");
    metadata.clear(t.allocator, "server");
    try t.expectEqual(@as(usize, 0), metadata.statuses.count());
}
