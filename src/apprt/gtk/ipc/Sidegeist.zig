//! Sidegeist's newline-delimited JSON protocol over a user-only Unix socket.
//! GIO handles partial/nonblocking reads and writes. Each connection has a
//! request size limit and a deadline, and only peers with our UID are accepted.
const std = @import("std");
const gtk = @import("gtk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const Tab = @import("../class/tab.zig").Tab;
const Sidebar = @import("../sidebar/Sidebar.zig");
const model = @import("../sidebar/model.zig");
const alloc = std.heap.c_allocator;
const Self = @This();
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;

service: *gio.SocketService,
path: [:0]const u8,
file: *gio.File,
inode: u64,
clients: std.AutoHashMapUnmanaged(*Client, void) = .empty,

pub fn new() !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    var path = if (glib.getenv("GHOSTTY_SOCKET")) |v| try alloc.dupeZ(u8, std.mem.span(v)) else try std.fmt.allocPrintSentinel(alloc, "/tmp/ghostty-{d}.sock", .{getuid()}, 0);
    errdefer alloc.free(path);
    // A second independent instance gets its own socket; it must never
    // unlink the first instance's endpoint. Only reclaim refused sockets
    // owned by us, never symlinks, ordinary files or other users' sockets.
    if (!available(path)) {
        const replacement = try std.fmt.allocPrintSentinel(alloc, "/tmp/ghostty-{d}-{d}.sock", .{ getuid(), getpid() }, 0);
        alloc.free(path);
        path = replacement;
        if (!available(path)) return error.SocketInUse;
    }
    if (path.len >= 108) return error.SocketPathTooLong;
    const service = gio.SocketService.new();
    errdefer service.unref();
    const address = gio.UnixSocketAddress.new(path);
    defer address.unref();
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    if (service.as(gio.SocketListener).addAddress(address.as(gio.SocketAddress), .stream, .default, null, null, &err) == 0) return error.BindFailed;
    const file = gio.File.newForPath(path);
    errdefer file.unref();
    errdefer _ = file.delete(null, null);
    if (file.setAttributeUint32("unix::mode", 0o600, .{ .nofollow_symlinks = true }, null, &err) == 0) return error.PermissionsFailed;
    const info = file.queryInfo("unix::inode", .{ .nofollow_symlinks = true }, null, &err) orelse return error.StatFailed;
    defer info.unref();
    self.* = .{ .service = service, .file = file, .path = path, .inode = info.getAttributeUint64("unix::inode") };
    _ = gio.SocketService.signals.incoming.connect(service, *Self, incoming, self, .{});
    service.start();
    std.log.info("Sidegeist IPC listening on {s}", .{path});
    return self;
}

fn available(path: [:0]const u8) bool {
    const file = gio.File.newForPath(path);
    defer file.unref();
    var err: ?*glib.Error = null;
    const info = file.queryInfo("unix::mode,unix::uid", .{ .nofollow_symlinks = true }, null, &err) orelse {
        defer if (err) |e| e.free();
        return if (err) |e| e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.not_found)) != 0 else false;
    };
    defer info.unref();
    if (info.getAttributeUint32("unix::uid") != getuid() or info.getAttributeUint32("unix::mode") & 0o170000 != 0o140000) return false;
    const client = gio.SocketClient.new();
    defer client.unref();
    client.setTimeout(1);
    const address = gio.UnixSocketAddress.new(path);
    defer address.unref();
    if (client.connect(address.as(gio.SocketConnectable), null, &err)) |connection| {
        connection.unref();
        return false;
    }
    defer if (err) |e| e.free();
    if (err) |e| {
        if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.connection_refused)) != 0) return file.delete(null, null) != 0;
    }
    return false;
}

pub fn deinit(self: *Self) void {
    self.service.stop();
    self.service.as(gio.SocketListener).close();
    Sidebar.disconnect(self.service.as(gobject.Object), self);
    var iter = self.clients.keyIterator();
    while (iter.next()) |client| {
        client.*.server = null;
        client.*.cancellable.cancel();
    }
    self.clients.deinit(alloc);
    // Leave any endpoint that replaced ours untouched.
    if (self.file.queryInfo("unix::inode", .{ .nofollow_symlinks = true }, null, null)) |info| {
        defer info.unref();
        if (info.getAttributeUint64("unix::inode") == self.inode) _ = self.file.delete(null, null);
    }
    self.file.unref();
    self.service.unref();
    alloc.free(self.path);
    alloc.destroy(self);
}

fn incoming(_: *gio.SocketService, connection: *gio.SocketConnection, _: ?*gobject.Object, self: *Self) callconv(.c) c_int {
    if (self.clients.count() >= 32) return 0;
    const credentials = connection.getSocket().getCredentials(null) orelse return 0;
    defer credentials.unref();
    if (credentials.getUnixUser(null) != getuid()) return 0;
    const client = alloc.create(Client) catch return 0;
    self.clients.put(alloc, client, {}) catch {
        alloc.destroy(client);
        return 0;
    };
    connection.ref();
    client.* = .{ .server = self, .connection = connection, .cancellable = gio.Cancellable.new() };
    client.timer = glib.timeoutAddSeconds(10, Client.timeout, client);
    client.read();
    return 1;
}

const Client = struct {
    server: ?*Self,
    connection: *gio.SocketConnection,
    cancellable: *gio.Cancellable,
    input: std.ArrayList(u8) = .empty,
    output: ?[]u8 = null,
    timer: c_uint = 0,

    fn destroy(self: *Client) void {
        if (self.server) |server| _ = server.clients.remove(self);
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        _ = self.connection.as(gio.IOStream).close(null, null);
        self.connection.unref();
        self.cancellable.unref();
        self.input.deinit(alloc);
        if (self.output) |v| alloc.free(v);
        alloc.destroy(self);
    }
    fn timeout(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.cancellable.cancel();
        return 0;
    }
    fn read(self: *Client) void {
        self.connection.as(gio.IOStream).getInputStream().readBytesAsync(4096, 0, self.cancellable, readReady, self);
    }
    fn readReady(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        defer if (err) |e| e.free();
        const bytes = self.connection.as(gio.IOStream).getInputStream().readBytesFinish(result, &err) orelse {
            self.destroy();
            return;
        };
        defer bytes.unref();
        var len: usize = 0;
        const ptr = bytes.getData(&len);
        if (len == 0 or self.server == null or self.input.items.len + len > 65536) {
            self.destroy();
            return;
        }
        self.input.appendSlice(alloc, ptr.?[0..len]) catch {
            self.destroy();
            return;
        };
        self.processOrRead();
    }
    fn processOrRead(self: *Client) void {
        if (self.server == null or self.cancellable.isCancelled() != 0) {
            self.destroy();
            return;
        }
        const newline = std.mem.indexOfScalar(u8, self.input.items, '\n') orelse {
            self.read();
            return;
        };
        const response = dispatch(self.input.items[0..newline]) catch |err| std.json.Stringify.valueAlloc(alloc, .{ .ok = false, .@"error" = @errorName(err) }, .{}) catch {
            self.destroy();
            return;
        };
        defer alloc.free(response);
        self.output = std.fmt.allocPrint(alloc, "{s}\n", .{response}) catch {
            self.destroy();
            return;
        };
        const remaining = self.input.items.len - newline - 1;
        std.mem.copyForwards(u8, self.input.items[0..remaining], self.input.items[newline + 1 ..]);
        self.input.shrinkRetainingCapacity(remaining);
        const output = self.output.?;
        self.connection.as(gio.IOStream).getOutputStream().writeAllAsync(output.ptr, output.len, 0, self.cancellable, writeReady, self);
    }
    fn writeReady(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        defer if (err) |e| e.free();
        const written = self.connection.as(gio.IOStream).getOutputStream().writeAllFinish(result, null, &err);
        if (written == 0) {
            self.destroy();
            return;
        }
        alloc.free(self.output.?);
        self.output = null;
        self.processOrRead();
    }
};

const TabInfo = struct {
    tab_id: []const u8,
    title: []const u8,
    is_active: bool,
    color: []const u8,
    pwd: ?[]const u8,
};
fn tabInfo(target: Sidebar.Target) TabInfo {
    return .{
        .tab_id = target.tab.getId(),
        .title = std.mem.span(target.page.getTitle()),
        .is_active = target.page.getSelected() != 0 and target.window.as(gtk.Window).isActive() != 0,
        .color = @tagName(target.tab.getSidebarMetadata().color),
        .pwd = if (target.tab.getActiveSurface()) |s| s.getPwd() else null,
    };
}
fn string(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidParams;
    return value.string;
}
fn ok(value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .ok = true, .result = value }, .{});
}

fn dispatch(line: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{ .allocate = .alloc_always });
    if (parsed.value != .object) return error.InvalidRequest;
    const method = try string(parsed.value.object, "method") orelse return error.InvalidRequest;
    const params: std.json.ObjectMap = if (parsed.value.object.get("params")) |v| blk: {
        if (v != .object) return error.InvalidParams;
        break :blk v.object;
    } else .empty;
    if (std.mem.eql(u8, method, "tab.list")) {
        var tabs: std.ArrayList(TabInfo) = .empty;
        var windows: ?*glib.List = Application.default().as(gtk.Application).getWindows();
        while (windows) |node| : (windows = node.f_next) {
            const window = gobject.ext.cast(Window, @as(*gobject.Object, @ptrCast(@alignCast(node.f_data orelse continue)))) orelse continue;
            const view = window.getTabView();
            for (0..@intCast(view.getNPages())) |i| {
                const page = view.getNthPage(@intCast(i));
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
                try tabs.append(a, tabInfo(.{ .window = window, .page = page, .tab = tab }));
            }
        }
        return ok(.{ .tabs = tabs.items });
    }
    const target = Sidebar.findTab(try string(params, "tab_id")) orelse return error.TabNotFound;
    if (std.mem.eql(u8, method, "tab.current")) return ok(tabInfo(target));
    if (std.mem.eql(u8, method, "tab.rename")) {
        const title = try string(params, "title") orelse return error.InvalidParams;
        target.tab.setTitleOverride(if (title.len > 0) try a.dupeZ(u8, title) else null);
        return ok(.{ .renamed = true });
    }
    if (std.mem.eql(u8, method, "tab.set-color")) {
        const name = try string(params, "color") orelse return error.InvalidParams;
        target.tab.getSidebarMetadata().color = std.meta.stringToEnum(model.Color, name) orelse return error.InvalidColor;
        target.tab.notifyMetadata();
        return ok(.{ .color_set = true });
    }
    if (std.mem.eql(u8, method, "tab.set-status")) {
        const key = try string(params, "key") orelse return error.InvalidParams;
        const value = try string(params, "value") orelse return error.InvalidParams;
        if (key.len == 0) return error.InvalidParams;
        try target.tab.getSidebarMetadata().set(alloc, key, value, try string(params, "icon"));
        target.tab.notifyMetadata();
        return ok(.{ .status_set = true });
    }
    if (std.mem.eql(u8, method, "tab.clear-status")) {
        target.tab.getSidebarMetadata().clear(alloc, try string(params, "key") orelse return error.InvalidParams);
        target.tab.notifyMetadata();
        return ok(.{ .status_cleared = true });
    }
    if (std.mem.eql(u8, method, "tab.notify")) {
        const title = try a.dupeZ(u8, try string(params, "title") orelse "Ghostty");
        const body = try a.dupeZ(u8, try string(params, "body") orelse "");
        target.page.setNeedsAttention(@intFromBool(target.page.getSelected() == 0 or target.window.as(gtk.Window).isActive() == 0));
        if (target.tab.getActiveSurface()) |surface| surface.sendDesktopNotification(title, body);
        return ok(.{ .notified = true });
    }
    return error.UnknownMethod;
}
