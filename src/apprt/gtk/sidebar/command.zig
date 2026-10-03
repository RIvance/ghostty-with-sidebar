//! Nonblocking subprocesses for the sidebar. All callbacks run on GTK's
//! main context. Cancelling detaches the owner before any widgets are freed.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const alloc = std.heap.c_allocator;
const Self = @This();

process: *gio.Subprocess,
cancellable: *gio.Cancellable,
timer: c_uint = 0,
callback: ?*const fn (*anyopaque, Result) void,
userdata: *anyopaque,
timed_out: bool = false,

pub const Result = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,
};

pub fn start(
    cwd: ?[:0]const u8,
    args: []const [:0]const u8,
    timeout_seconds: c_uint,
    callback: *const fn (*anyopaque, Result) void,
    userdata: *anyopaque,
) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const argv = try alloc.allocSentinel(?[*:0]const u8, args.len, null);
    defer alloc.free(argv);
    for (args, argv) |arg, *ptr| ptr.* = arg.ptr;
    const launcher = gio.SubprocessLauncher.new(.{ .stdout_pipe = true, .stderr_pipe = true });
    defer launcher.unref();
    if (cwd) |v| launcher.setCwd(v);
    launcher.setenv("GIT_TERMINAL_PROMPT", "0", 1);
    launcher.setenv("GIT_OPTIONAL_LOCKS", "0", 1);
    launcher.setenv("LC_ALL", "C", 1);
    var err: ?*glib.Error = null;
    const process = launcher.spawnv(@ptrCast(argv.ptr), &err) orelse {
        if (err) |e| {
            std.log.warn("sidebar command: {s}", .{e.f_message orelse "could not start command"});
            e.free();
        }
        return error.SpawnFailed;
    };
    self.* = .{ .process = process, .cancellable = gio.Cancellable.new(), .callback = callback, .userdata = userdata };
    self.timer = glib.timeoutAddSeconds(timeout_seconds, timeout, self);
    process.communicateAsync(null, self.cancellable, finished, self);
    return self;
}

pub fn cancel(self: *Self) void {
    self.callback = null;
    self.process.forceExit();
    self.cancellable.cancel();
}

fn timeout(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    self.timer = 0;
    self.timed_out = true;
    self.process.forceExit();
    self.cancellable.cancel();
    return 0;
}

fn finished(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    defer alloc.destroy(self);
    defer self.process.unref();
    defer self.cancellable.unref();
    if (self.timer != 0) _ = glib.Source.remove(self.timer);
    var stdout: *glib.Bytes = undefined;
    var stderr: *glib.Bytes = undefined;
    var err: ?*glib.Error = null;
    if (self.process.communicateFinish(result, &stdout, &stderr, &err) == 0) {
        defer if (err) |e| e.free();
        if (self.callback) |cb| cb(self.userdata, .{ .ok = false, .stdout = "", .stderr = if (self.timed_out) "Command timed out" else if (err) |e| std.mem.span(e.f_message orelse "Command failed") else "Command failed" });
        return;
    }
    defer stdout.unref();
    defer stderr.unref();
    var out_len: usize = 0;
    var err_len: usize = 0;
    const out_data = stdout.getData(&out_len);
    const err_data = stderr.getData(&err_len);
    if (self.callback) |cb| cb(self.userdata, .{
        .ok = !self.timed_out and self.process.getSuccessful() != 0,
        .stdout = if (out_data) |v| v[0..out_len] else "",
        .stderr = if (self.timed_out) "Command timed out" else if (err_data) |v| v[0..err_len] else "",
    });
}
