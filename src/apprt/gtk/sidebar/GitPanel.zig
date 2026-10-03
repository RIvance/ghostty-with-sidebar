//! Git operations for the selected tab. Subprocesses never block GTK and all
//! file arguments are literal pathspecs. Destructive operations require an
//! explicit response to a dialog naming what will be discarded.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const Window = @import("../class/window.zig").Window;
const ext = @import("../ext.zig");
const Sidebar = @import("Sidebar.zig");
const Command = @import("command.zig");
const git = @import("git_status.zig");
const i18n = @import("../../../os/main.zig").i18n;
const alloc = std.heap.c_allocator;
const Self = @This();

window: *Window,
expander: *gtk.Expander,
body: *gtk.Box,
branch: *gtk.MenuButton,
branch_menu: *gio.Menu,
summary: *gtk.Label,
files: *gtk.Box,
message: *gtk.Entry,
error_label: *gtk.Label,
spinner: *gtk.Spinner,
pwd: ?[:0]const u8 = null,
root: ?[:0]const u8 = null,
raw_status: []const u8 = "",
raw_branches: []const u8 = "",
job: ?*Command = null,
kind: Kind = .status,
timer: c_uint = 0,
enabled: bool = true,
commit_message: ?[:0]const u8 = null,
confirmation: ?*adw.AlertDialog = null,
discard_file: ?git.File = null,

const Kind = enum { root, status, branches, add, commit, push, pull, checkout, discard, discard_all, clean_all, restore_rename };

pub fn new(window: *Window, parent: *gtk.Box) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const expander = gtk.Expander.new(i18n._("Git"));
    expander.setExpanded(1);
    expander.as(gtk.Widget).addCssClass("sidebar-git");
    const body = gtk.Box.new(.vertical, 6);
    expander.setChild(body.as(gtk.Widget));
    parent.append(expander.as(gtk.Widget));
    const header = gtk.Box.new(.horizontal, 4);
    const branch = gtk.MenuButton.new();
    branch.as(gtk.Widget).addCssClass("flat");
    branch.as(gtk.Widget).setHexpand(1);
    branch.setLabel(i18n._("No Git repository"));
    const spinner = gtk.Spinner.new();
    header.append(branch.as(gtk.Widget));
    header.append(spinner.as(gtk.Widget));
    body.append(header.as(gtk.Widget));
    const summary = Sidebar.label("");
    body.append(summary.as(gtk.Widget));
    const files = gtk.Box.new(.vertical, 2);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.setMaxContentHeight(230);
    scroll.setPropagateNaturalHeight(1);
    scroll.setChild(files.as(gtk.Widget));
    body.append(scroll.as(gtk.Widget));
    const message = gtk.Entry.new();
    message.setPlaceholderText(i18n._("Commit message"));
    body.append(message.as(gtk.Widget));
    const controls = gtk.Box.new(.horizontal, 4);
    const commit_button = gtk.Button.newWithLabel(i18n._("Commit All"));
    commit_button.as(gtk.Widget).setTooltipText(i18n._("Stage all changes and commit"));
    controls.append(commit_button.as(gtk.Widget));
    const pull = Sidebar.iconButton("go-down-symbolic", i18n._("Pull (fast-forward only)"));
    controls.append(pull.as(gtk.Widget));
    const push = Sidebar.iconButton("go-up-symbolic", i18n._("Push"));
    controls.append(push.as(gtk.Widget));
    const discard = Sidebar.iconButton("edit-delete-symbolic", i18n._("Discard All Changes…"));
    controls.append(discard.as(gtk.Widget));
    body.append(controls.as(gtk.Widget));
    const error_label = Sidebar.label("");
    error_label.setWrap(1);
    error_label.setEllipsize(.none);
    error_label.setMaxWidthChars(24);
    error_label.as(gtk.Widget).addCssClass("error");
    error_label.as(gtk.Widget).setVisible(0);
    body.append(error_label.as(gtk.Widget));
    const branch_menu = gio.Menu.new();
    self.* = .{ .window = window, .expander = expander, .body = body, .branch = branch, .branch_menu = branch_menu, .summary = summary, .files = files, .message = message, .error_label = error_label, .spinner = spinner };
    const group = gio.SimpleActionGroup.new();
    defer group.unref();
    const string_type = glib.ext.VariantType.newFor([:0]const u8);
    defer string_type.free();
    ext.actions.addToMap(Self, self, group.as(gio.ActionMap), &.{
        .init("checkout", checkoutAction, string_type),
    });
    // Install actions on the menu's owner before creating its popover so
    // dynamically added branch items resolve the checkout action immediately.
    branch.as(gtk.Widget).insertActionGroup("git", group.as(gio.ActionGroup));
    branch.setMenuModel(branch_menu.as(gio.MenuModel));
    _ = gtk.Button.signals.clicked.connect(discard, *Self, discardAllClicked, self, .{});
    _ = gtk.Button.signals.clicked.connect(push, *Self, pushClicked, self, .{});
    _ = gtk.Button.signals.clicked.connect(pull, *Self, pullClicked, self, .{});
    _ = gtk.Button.signals.clicked.connect(commit_button, *Self, commitClicked, self, .{});
    _ = gtk.Entry.signals.activate.connect(message, *Self, commitActivated, self, .{});
    self.timer = glib.timeoutAddSeconds(2, tick, self);
    return self;
}

pub fn deinit(self: *Self) void {
    _ = glib.Source.remove(self.timer);
    if (self.job) |job| job.cancel();
    self.closeConfirmation();
    self.clearDiscard();
    if (self.pwd) |v| alloc.free(v);
    if (self.root) |v| alloc.free(v);
    if (self.commit_message) |v| alloc.free(v);
    if (self.raw_status.len > 0) alloc.free(self.raw_status);
    if (self.raw_branches.len > 0) alloc.free(self.raw_branches);
    self.branch_menu.unref();
    alloc.destroy(self);
}

pub fn setEnabled(self: *Self, value: bool) void {
    self.enabled = value;
    self.expander.as(gtk.Widget).setVisible(@intFromBool(value));
}

pub fn setDirectory(self: *Self, pwd: ?[:0]const u8) void {
    // Finish an explicit operation in the repository where it was started.
    // The next sidebar tick picks up any tab/directory switch afterward.
    if (self.job != null and self.kind != .root and self.kind != .status and self.kind != .branches) return;
    if (std.mem.eql(u8, pwd orelse "", self.pwd orelse "")) return;
    self.closeConfirmation();
    self.clearDiscard();
    if (self.job) |job| job.cancel();
    self.job = null;
    if (self.pwd) |v| alloc.free(v);
    self.pwd = if (pwd) |v| alloc.dupeZ(u8, v) catch null else null;
    if (self.root) |v| alloc.free(v);
    self.root = null;
    self.resetStatus();
    self.branch.setLabel(i18n._("No Git repository"));
    self.branch_menu.removeAll();
    if (self.raw_branches.len > 0) alloc.free(self.raw_branches);
    self.raw_branches = "";
    self.body.as(gtk.Widget).setSensitive(0);
    self.error_label.as(gtk.Widget).setVisible(0);
    if (self.enabled and self.pwd != null) self.run(.root, &.{ "git", "rev-parse", "--show-toplevel" });
}

fn resetStatus(self: *Self) void {
    while (self.files.as(gtk.Widget).getFirstChild()) |child| self.files.remove(child);
    if (self.raw_status.len > 0) alloc.free(self.raw_status);
    self.raw_status = "";
    self.summary.setText("");
}

fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.enabled and self.job == null and self.confirmation == null and self.expander.as(gtk.Widget).getMapped() != 0) {
        if (self.root != null) self.refresh() else if (self.pwd != null) self.run(.root, &.{ "git", "rev-parse", "--show-toplevel" });
    }
    return 1;
}

fn run(self: *Self, kind: Kind, args: []const [:0]const u8) void {
    if (self.job != null) {
        if (kind == .root or kind == .status or kind == .branches) return;
        if (!self.cancelRefresh()) return;
    }
    self.kind = kind;
    self.job = Command.start(if (kind == .root) self.pwd else self.root, args, if (kind == .push or kind == .pull) 120 else 30, completed, self) catch {
        self.showError(std.mem.span(i18n._("Could not start Git. Check that git is installed.")));
        return;
    };
    if (kind != .root and kind != .status and kind != .branches) {
        self.body.as(gtk.Widget).setSensitive(0);
        self.spinner.start();
        self.error_label.as(gtk.Widget).setVisible(0);
    }
}

/// A user action takes priority over polling. Never interrupt another write.
fn cancelRefresh(self: *Self) bool {
    const job = self.job orelse return true;
    if (self.kind != .status and self.kind != .branches) return false;
    job.cancel();
    self.job = null;
    return true;
}

fn refresh(self: *Self) void {
    self.run(.status, &.{ "git", "status", "--porcelain=v2", "--branch", "-z" });
}

fn completed(data: *anyopaque, result: Command.Result) void {
    const self: *Self = @ptrCast(@alignCast(data));
    self.job = null;
    self.spinner.stop();
    const kind = self.kind;
    if (!result.ok) {
        self.body.as(gtk.Widget).setSensitive(@intFromBool(self.root != null));
        if (kind != .root) self.showError(if (result.stderr.len > 0) result.stderr else "Git command failed");
        return;
    }
    switch (kind) {
        .root => {
            const path = std.mem.trimEnd(u8, result.stdout, "\n");
            self.root = alloc.dupeZ(u8, path) catch return;
            self.body.as(gtk.Widget).setSensitive(1);
            self.refresh();
        },
        .status => {
            if (!std.mem.eql(u8, self.raw_status, result.stdout)) {
                self.render(result.stdout) catch {
                    self.showError("Could not read Git status");
                    return;
                };
            }
            self.run(.branches, &.{ "git", "branch", "--format=%(refname:short)" });
        },
        .branches => {
            if (std.mem.eql(u8, self.raw_branches, result.stdout)) return;
            const branches = alloc.dupe(u8, result.stdout) catch return;
            if (self.raw_branches.len > 0) alloc.free(self.raw_branches);
            self.raw_branches = branches;
            const menu = self.branch_menu;
            menu.removeAll();
            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const name = alloc.dupeZ(u8, line) catch continue;
                defer alloc.free(name);
                const item = gio.MenuItem.new(name, null);
                item.setActionAndTargetValue("git.checkout", glib.Variant.newString(name));
                menu.appendItem(item);
                item.unref();
            }
        },
        .add => self.run(.commit, &.{ "git", "commit", "-m", self.commit_message orelse return }),
        .discard_all => self.run(.clean_all, &.{ "git", "clean", "-fd" }),
        .restore_rename => {
            const file = self.discard_file orelse return;
            self.run(.discard, &.{ "git", "--literal-pathspecs", "rm", "-f", "--", file.path });
        },
        else => {
            self.body.as(gtk.Widget).setSensitive(1);
            if (kind == .commit) self.message.as(gtk.Editable).setText("");
            self.clearDiscard();
            self.resetStatus();
            self.refresh();
        },
    }
}

fn render(self: *Self, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const status = try git.Status.parse(arena.allocator(), bytes);
    self.resetStatus();
    self.raw_status = try alloc.dupe(u8, bytes);
    self.branch.setLabel(status.branch);
    const summary = try std.fmt.allocPrintSentinel(arena.allocator(), "{d} changed  ·  ↑{d} ↓{d}", .{ status.files.items.len, status.ahead, status.behind }, 0);
    self.summary.setText(summary);
    for (status.files.items) |file| {
        const line = gtk.Box.new(.horizontal, 2);
        const open = gtk.Button.new();
        open.as(gtk.Widget).addCssClass("flat");
        open.as(gtk.Widget).setHexpand(1);
        const text = try std.fmt.allocPrintSentinel(arena.allocator(), "{c}  {s}", .{ file.status, file.path }, 0);
        const valid = glib.utf8MakeValid(text, @intCast(text.len));
        defer glib.free(valid);
        open.setChild(Sidebar.label(std.mem.span(valid)).as(gtk.Widget));
        open.as(gtk.Widget).setTooltipText(valid);
        open.as(gtk.Widget).addCssClass(switch (file.status) {
            'A', '?' => "success",
            'D', 'U' => "error",
            else => "warning",
        });
        const discard = Sidebar.iconButton("edit-delete-symbolic", i18n._("Discard Changes…"));
        const item = try alloc.create(FileRow);
        item.* = .{ .panel = self, .file = try copyFile(file) };
        line.as(gobject.Object).setDataFull("sidegeist-file", item, FileRow.destroy);
        _ = gtk.Button.signals.clicked.connect(open, *FileRow, FileRow.open, item, .{});
        _ = gtk.Button.signals.clicked.connect(discard, *FileRow, FileRow.discard, item, .{});
        line.append(open.as(gtk.Widget));
        line.append(discard.as(gtk.Widget));
        self.files.append(line.as(gtk.Widget));
    }
}

fn showError(self: *Self, text: []const u8) void {
    const valid = glib.utf8MakeValid(@ptrCast(text.ptr), @intCast(@min(text.len, 4096)));
    defer glib.free(valid);
    self.error_label.setText(valid);
    self.error_label.as(gtk.Widget).setVisible(1);
}

fn commitClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
    self.commit();
}
fn pushClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
    self.run(.push, &.{ "git", "push" });
}
fn pullClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
    self.run(.pull, &.{ "git", "pull", "--ff-only" });
}
fn discardAllClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
    self.confirmDiscard(null);
}
fn commitActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
    self.commit();
}
fn commit(self: *Self) void {
    if (self.root == null or !self.cancelRefresh()) return;
    const text = std.mem.span(self.message.as(gtk.Editable).getText());
    if (std.mem.trim(u8, text, " \r\n\t").len == 0) {
        self.showError(std.mem.span(i18n._("Enter a commit message.")));
        return;
    }
    const message = alloc.dupeZ(u8, text) catch return;
    if (self.commit_message) |v| alloc.free(v);
    self.commit_message = message;
    self.run(.add, &.{ "git", "add", "-A" });
}
fn checkoutAction(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
    self.run(.checkout, &.{ "git", "switch", "--", std.mem.span((param orelse return).getString(null)) });
}

fn clearDiscard(self: *Self) void {
    if (self.discard_file) |file| freeFile(file);
    self.discard_file = null;
}
fn closeConfirmation(self: *Self) void {
    if (self.confirmation) |dialog| {
        Sidebar.disconnect(dialog.as(gobject.Object), self);
        _ = dialog.as(adw.Dialog).close();
        dialog.unref();
        self.confirmation = null;
    }
}
fn confirmDiscard(self: *Self, file: ?git.File) void {
    if (self.confirmation != null or self.root == null or !self.cancelRefresh()) return;
    self.clearDiscard();
    self.discard_file = if (file) |v| copyFile(v) catch return else null;
    const body = if (file) |v| std.fmt.allocPrintSentinel(alloc, "Discard all staged and unstaged changes to {s}? Untracked or added files will be deleted. This cannot be undone.", .{v.path}, 0) catch return else alloc.dupeZ(u8, "Discard all staged and unstaged changes in this repository and delete untracked files? This cannot be undone.") catch return;
    defer alloc.free(body);
    const dialog = adw.AlertDialog.new(i18n._("Discard Changes?"), body);
    _ = dialog.as(gobject.Object).refSink();
    dialog.addResponse("cancel", i18n._("Cancel"));
    dialog.addResponse("discard", i18n._("Discard"));
    dialog.setResponseAppearance("discard", .destructive);
    dialog.setDefaultResponse("cancel");
    dialog.setCloseResponse("cancel");
    self.confirmation = dialog;
    _ = adw.AlertDialog.signals.response.connect(dialog, *Self, discardResponse, self, .{});
    dialog.as(adw.Dialog).present(self.window.as(gtk.Widget));
}
fn discardResponse(dialog: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
    self.confirmation = null;
    defer dialog.unref();
    if (!std.mem.eql(u8, std.mem.span(response), "discard")) {
        self.clearDiscard();
        return;
    }
    if (self.discard_file) |file| {
        if (file.untracked) self.run(.discard, &.{ "git", "--literal-pathspecs", "clean", "-fd", "--", file.path }) else if (file.original_path) |original| self.run(.restore_rename, &.{ "git", "--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--", original }) else if (file.added) self.run(.discard, &.{ "git", "--literal-pathspecs", "rm", "-f", "--", file.path }) else self.run(.discard, &.{ "git", "--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--", file.path });
    } else self.run(.discard_all, &.{ "git", "reset", "--hard", "HEAD" });
}

fn copyFile(file: git.File) !git.File {
    const path = try alloc.dupeZ(u8, file.path);
    errdefer alloc.free(path);
    return .{ .path = path, .original_path = if (file.original_path) |v| try alloc.dupeZ(u8, v) else null, .status = file.status, .untracked = file.untracked, .added = file.added };
}
fn freeFile(file: git.File) void {
    alloc.free(file.path);
    if (file.original_path) |v| alloc.free(v);
}

const FileRow = struct {
    panel: *Self,
    file: git.File,
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *FileRow = @ptrCast(@alignCast(data.?));
        freeFile(self.file);
        alloc.destroy(self);
    }
    fn discard(_: *gtk.Button, self: *FileRow) callconv(.c) void {
        self.panel.confirmDiscard(self.file);
    }
    fn open(_: *gtk.Button, self: *FileRow) callconv(.c) void {
        const root = self.panel.root orelse return;
        const path = std.fs.path.joinZ(alloc, &.{ root, self.file.path }) catch return;
        defer alloc.free(path);
        const editor = glib.getenv("VISUAL") orelse glib.getenv("EDITOR");
        if (editor) |command| {
            var count: c_int = 0;
            var argv: [*:null]?[*:0]u8 = undefined;
            var err: ?*glib.Error = null;
            if (glib.shellParseArgv(command, &count, &argv, &err) == 0 or count == 0) {
                if (err) |e| e.free();
                self.panel.showError("Could not parse VISUAL/EDITOR");
                return;
            }
            defer glib.strfreev(argv);
            var args: std.ArrayList([:0]const u8) = .empty;
            defer args.deinit(alloc);
            for (0..@intCast(count)) |i| args.append(alloc, std.mem.span(argv[i].?)) catch return;
            args.append(alloc, path) catch return;
            // A terminal tab also supports editors such as vim, nano and helix.
            // GUI editors launched from it can reuse their existing window.
            self.panel.window.newTab(null, .{ .command = .{ .direct = args.items }, .working_directory = root, .shell_integration = .none, .title = null });
        } else {
            const file = gio.File.newForPath(path);
            defer file.unref();
            const uri = file.getUri();
            defer glib.free(uri);
            gio.AppInfo.launchDefaultForUriAsync(uri, null, null, null, null);
        }
    }
};
