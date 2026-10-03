//! Parse Git's porcelain v2 protocol, including NUL-delimited paths. Never
//! interpret filenames as shell syntax or as newline-delimited records.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const File = struct {
    path: [:0]const u8,
    original_path: ?[:0]const u8 = null,
    status: u8,
    untracked: bool = false,
    added: bool = false,
};

pub const Status = struct {
    branch: [:0]const u8 = "",
    oid: []const u8 = "",
    ahead: u32 = 0,
    behind: u32 = 0,
    files: std.ArrayList(File) = .empty,

    /// The caller owns an arena for all strings and the file array.
    pub fn parse(alloc: Allocator, bytes: []const u8) !Status {
        var result: Status = .{};
        var records = std.mem.splitScalar(u8, bytes, 0);
        while (records.next()) |line| {
            if (line.len < 2) continue;
            if (std.mem.startsWith(u8, line, "# branch.head ")) {
                result.branch = try alloc.dupeZ(u8, line[14..]);
            } else if (std.mem.startsWith(u8, line, "# branch.oid ")) {
                result.oid = try alloc.dupe(u8, line[13..]);
            } else if (std.mem.startsWith(u8, line, "# branch.ab +")) {
                var counts = std.mem.splitScalar(u8, line[13..], ' ');
                result.ahead = std.fmt.parseInt(u32, counts.next() orelse "0", 10) catch 0;
                const behind = counts.next() orelse "-0";
                result.behind = std.fmt.parseInt(u32, std.mem.trimStart(u8, behind, "-"), 10) catch 0;
            } else if (line[0] == '?' and line[1] == ' ') {
                try result.files.append(alloc, .{ .path = try alloc.dupeZ(u8, line[2..]), .status = '?', .untracked = true });
            } else if (line[0] == '1' or line[0] == '2' or line[0] == 'u') {
                const count: usize = switch (line[0]) {
                    '1' => 8,
                    '2' => 9,
                    else => 10,
                };
                var start: usize = 0;
                for (0..count) |_| {
                    start = (std.mem.indexOfScalarPos(u8, line, start, ' ') orelse return error.InvalidStatus) + 1;
                }
                if (line.len < 4 or start >= line.len) return error.InvalidStatus;
                const original = if (line[0] == '2') try alloc.dupeZ(u8, records.next() orelse return error.InvalidStatus) else null;
                try result.files.append(alloc, .{
                    .path = try alloc.dupeZ(u8, line[start..]),
                    .original_path = original,
                    .status = if (line[0] == 'u') 'U' else if (line[3] != '.') line[3] else line[2],
                    .added = line[0] != 'u' and line[2] == 'A',
                });
            }
        }
        if (std.mem.eql(u8, result.branch, "(detached)")) {
            result.branch = try std.fmt.allocPrintSentinel(alloc, "detached {s}", .{result.oid[0..@min(8, result.oid.len)]}, 0);
        }
        return result;
    }
};

test "sidebar git porcelain handles branches, renames, conflicts and unusual paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const status = try Status.parse(arena.allocator(), "# branch.oid abcdef0123456789\x00# branch.head work\x00# branch.ab +2 -3\x00" ++
        "1 .M N... 100644 100644 100644 a b path with spaces\x00" ++
        "2 R. N... 100644 100644 100644 a b R100 new name\x00old\nname\x00" ++
        "? --flag\nfile\x00u UU N... 100644 100644 100644 100644 a b c conflict\x00");
    try std.testing.expectEqualStrings("work", status.branch);
    try std.testing.expectEqual(@as(u32, 2), status.ahead);
    try std.testing.expectEqual(@as(u32, 3), status.behind);
    try std.testing.expectEqual(@as(usize, 4), status.files.items.len);
    try std.testing.expectEqualStrings("path with spaces", status.files.items[0].path);
    try std.testing.expectEqualStrings("old\nname", status.files.items[1].original_path.?);
    try std.testing.expectEqualStrings("--flag\nfile", status.files.items[2].path);
    try std.testing.expectEqual(@as(u8, 'U'), status.files.items[3].status);
}

test "sidebar git keeps added state when a staged new file is modified again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const status = try Status.parse(arena.allocator(), "1 AM N... 000000 100644 100644 a b new file\x00");
    try std.testing.expectEqual(@as(u8, 'M'), status.files.items[0].status);
    try std.testing.expect(status.files.items[0].added);
}
