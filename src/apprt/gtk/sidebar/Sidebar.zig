//! GTK implementation of Sidegeist's vertical tab cards. AdwTabView remains
//! the owner of tabs; the sidebar is only another view of its page model.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const CoreConfig = @import("../../../config/Config.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const Tab = @import("../class/tab.zig").Tab;
const Surface = @import("../class/surface.zig").Surface;
const ext = @import("../ext.zig");
const model = @import("model.zig");
const Command = @import("command.zig");
const GitPanel = @import("GitPanel.zig");
const i18n = @import("../../../os/main.zig").i18n;
const alloc = std.heap.c_allocator;
const Self = @This();

window: *Window,
box: *gtk.Box,
list: *gtk.ListBox,
panel: *GitPanel,
timer: c_uint,
fields: model.Fields = .{},
show_border: bool = true,
dim_colors: bool = false,

pub fn new(window: *Window, box: *gtk.Box) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const list = gtk.ListBox.new();
    list.setSelectionMode(.none);
    list.setActivateOnSingleClick(1);
    list.as(gtk.Widget).addCssClass("sidebar-tabs");
    list.as(gtk.Widget).setVexpand(1);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.as(gtk.Widget).setVexpand(1);
    scroll.setChild(list.as(gtk.Widget));
    box.append(scroll.as(gtk.Widget));
    const panel = try GitPanel.new(window, box);
    self.* = .{ .window = window, .box = box, .list = list, .panel = panel, .timer = 0 };
    box.as(gtk.Widget).addCssClass("sidegeist");
    _ = gtk.ListBox.signals.row_activated.connect(list, *Self, activated, self, .{});
    _ = gobject.Object.signals.notify.connect(window.getTabView(), *Self, selected, self, .{ .detail = "selected-page" });
    const drop = gtk.DropTarget.new(adw.TabPage.getGObjectType(), .{ .move = true });
    _ = gtk.DropTarget.signals.drop.connect(drop, *Self, dropped, self, .{});
    list.as(gtk.Widget).addController(drop.as(gtk.EventController));
    self.timer = glib.timeoutAddSeconds(2, tick, self);
    return self;
}

pub fn deinit(self: *Self) void {
    _ = glib.Source.remove(self.timer);
    disconnect(self.window.getTabView().as(gobject.Object), self);
    self.list.bindModel(null, null, null, null);
    self.panel.deinit();
    alloc.destroy(self);
}

pub fn configure(self: *Self, config: *const CoreConfig) void {
    self.fields = model.Fields.parse(config.@"sidebar-fields");
    self.show_border = config.@"sidebar-show-tab-border";
    self.dim_colors = config.@"sidebar-dim-inactive-colors";
    const pages = self.window.getTabView().getPages();
    defer pages.unref();
    self.list.bindModel(pages.as(gio.ListModel), Row.create, self, null);
    self.panel.setEnabled(config.@"sidebar-git");
    self.syncDirectory();
}

fn syncDirectory(self: *Self) void {
    const surface = self.window.getActiveSurface();
    self.panel.setDirectory(if (surface) |s| s.getPwd() else null);
}

fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.box.as(gtk.Widget).getMapped() != 0) self.syncDirectory();
    return 1;
}

fn selected(_: *adw.TabView, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
    self.syncDirectory();
}

fn activated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
    const card: *Row = @ptrCast(@alignCast(row.as(gobject.Object).getData("sidegeist-row").?));
    self.window.getTabView().setSelectedPage(card.page);
    if (card.tab.getActiveSurface()) |surface| surface.grabFocus();
}

fn dropped(_: *gtk.DropTarget, value: *gobject.Value, _: f64, y: f64, self: *Self) callconv(.c) c_int {
    const page = gobject.ext.cast(adw.TabPage, value.getObject() orelse return 0) orelse return 0;
    const source = ext.getAncestor(adw.TabView, page.getChild()) orelse return 0;
    const destination = self.window.getTabView();
    const row = self.list.getRowAtY(@intFromFloat(y));
    var position = if (row) |r| r.getIndex() else destination.getNPages();
    if (source == destination) {
        position = @min(position, destination.getNPages() - 1);
        _ = destination.reorderPage(page, @max(destination.getNPinnedPages(), position));
    } else {
        source.transferPage(page, destination, @max(destination.getNPinnedPages(), position));
    }
    destination.setSelectedPage(page);
    if (gobject.ext.cast(Tab, page.getChild())) |tab| {
        if (tab.getActiveSurface()) |surface| surface.grabFocus();
    }
    return 1;
}

pub const Target = struct { window: *Window, page: *adw.TabPage, tab: *Tab };

/// Resolve a stable tab identity across all windows, including inactive tabs.
/// A null ID means the selected tab in the most recently active window.
pub fn findTab(id: ?[]const u8) ?Target {
    const app = Application.default().as(gtk.Application);
    var windows: ?*glib.List = app.getWindows();
    while (windows) |node| : (windows = node.f_next) {
        const window = gobject.ext.cast(Window, @as(*gobject.Object, @ptrCast(@alignCast(node.f_data orelse continue)))) orelse continue;
        const view = window.getTabView();
        if (id == null and app.getActiveWindow() != window.as(gtk.Window)) continue;
        for (0..@intCast(view.getNPages())) |i| {
            const page = view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            if (if (id) |v| std.mem.eql(u8, v, tab.getId()) else page.getSelected() != 0) {
                return .{ .window = window, .page = page, .tab = tab };
            }
        }
    }
    return null;
}

pub fn moveToNewWindow(page: *adw.TabPage) void {
    const source = ext.getAncestor(adw.TabView, page.getChild()) orelse return;
    const app = Application.default();
    const window = Window.new(app, .none);
    // Match the application's normal new-window path without creating a tab.
    // Detached windows must continue receiving configuration reloads.
    _ = gobject.Object.bindProperty(app.as(gobject.Object), "config", window.as(gobject.Object), "config", .{});
    source.transferPage(page, window.getTabView(), 0);
    window.as(gtk.Window).present();
}

pub fn disconnect(object: *gobject.Object, data: *anyopaque) void {
    _ = gobject.signalHandlersDisconnectMatched(object, .{ .data = true }, 0, 0, null, null, data);
}

pub fn label(text: [:0]const u8) *gtk.Label {
    const result = gtk.Label.new(text);
    result.setXalign(0);
    result.setEllipsize(.end);
    result.as(gtk.Widget).setHexpand(1);
    return result;
}

pub fn iconButton(icon: [:0]const u8, tooltip: [*:0]const u8) *gtk.Button {
    const button = gtk.Button.newFromIconName(icon);
    button.as(gtk.Widget).setTooltipText(tooltip);
    button.as(gtk.Widget).addCssClass("flat");
    button.as(gtk.Widget).setFocusable(0);
    return button;
}

const Row = struct {
    widget: *gtk.ListBoxRow,
    page: *adw.TabPage,
    tab: *Tab,
    surface: ?*Surface = null,
    title: *gtk.Label,
    directory: *gtk.Button,
    directory_label: *gtk.Label,
    branch: *gtk.Label,
    statuses: *gtk.Box,
    attention: *gtk.Image,
    menu: *gtk.MenuButton,
    fields: model.Fields,
    timer: c_uint = 0,
    job: ?*Command = null,
    pwd: ?[:0]const u8 = null,
    detached_query: bool = false,

    fn create(object: *gobject.Object, data: ?*anyopaque) callconv(.c) *gtk.Widget {
        const sidebar: *Self = @ptrCast(@alignCast(data.?));
        const self = alloc.create(Row) catch @panic("oom");
        const page = gobject.ext.cast(adw.TabPage, object).?;
        const tab = gobject.ext.cast(Tab, page.getChild()).?;
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("sidebar-card");
        if (!sidebar.show_border) row.as(gtk.Widget).addCssClass("no-border");
        if (sidebar.dim_colors) row.as(gtk.Widget).addCssClass("dim-colors");
        const body = gtk.Box.new(.vertical, 3);
        row.setChild(body.as(gtk.Widget));
        const heading = gtk.Box.new(.horizontal, 2);
        const title = label("");
        title.as(gtk.Widget).addCssClass("heading");
        const attention = gtk.Image.newFromIconName("media-record-symbolic");
        attention.as(gtk.Widget).addCssClass("attention");
        const menu = gtk.MenuButton.new();
        menu.setIconName("view-more-symbolic");
        menu.as(gtk.Widget).addCssClass("flat");
        menu.as(gtk.Widget).setTooltipText(i18n._("Tab Menu"));
        const close = iconButton("window-close-symbolic", i18n._("Close Tab"));
        heading.append(title.as(gtk.Widget));
        heading.append(attention.as(gtk.Widget));
        heading.append(menu.as(gtk.Widget));
        heading.append(close.as(gtk.Widget));
        body.append(heading.as(gtk.Widget));
        const directory = gtk.Button.new();
        directory.as(gtk.Widget).addCssClass("flat");
        directory.as(gtk.Widget).addCssClass("sidebar-directory");
        const dir_box = gtk.Box.new(.horizontal, 5);
        const dir_label = label("");
        dir_box.append(gtk.Image.newFromIconName("folder-symbolic").as(gtk.Widget));
        dir_box.append(dir_label.as(gtk.Widget));
        directory.setChild(dir_box.as(gtk.Widget));
        body.append(directory.as(gtk.Widget));
        const branch = label("");
        branch.as(gtk.Widget).addCssClass("dim-label");
        body.append(branch.as(gtk.Widget));
        const statuses = gtk.Box.new(.vertical, 2);
        body.append(statuses.as(gtk.Widget));
        page.ref();
        self.* = .{ .widget = row, .page = page, .tab = tab, .title = title, .directory = directory, .directory_label = dir_label, .branch = branch, .statuses = statuses, .attention = attention, .menu = menu, .fields = sidebar.fields };
        row.as(gobject.Object).setDataFull("sidegeist-row", self, destroy);
        _ = gtk.Button.signals.clicked.connect(close, *Row, closeClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(directory, *Row, openDirectory, self, .{});
        _ = gobject.Object.signals.notify.connect(page, *Row, pageChanged, self, .{});
        _ = gobject.Object.signals.notify.connect(tab, *Row, activeSurfaceChanged, self, .{ .detail = "active-surface" });
        _ = Tab.signals.@"metadata-changed".connect(tab, *Row, metadataChanged, self, .{});
        const group = gio.SimpleActionGroup.new();
        const string_type = glib.ext.VariantType.newFor([:0]const u8);
        defer string_type.free();
        ext.actions.addToMap(Row, self, group.as(gio.ActionMap), &.{
            .init("rename", rename, null),                 .init("close", closeAction, null),
            .init("close-others", closeOthers, null),      .init("close-after", closeAfter, null),
            .init("color", color, string_type),            .init("new-window", newWindow, null),
            .init("move-window", moveWindow, string_type),
        });
        row.as(gtk.Widget).insertActionGroup("card", group.as(gio.ActionGroup));
        group.unref();
        self.updateMenu();
        menu.setCreatePopupFunc(createPopup, self, null);
        const gesture = gtk.GestureClick.new();
        gesture.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(gesture, *Row, rightClicked, self, .{});
        row.as(gtk.Widget).addController(gesture.as(gtk.EventController));
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(drag, *Row, dragPrepare, self, .{});
        _ = gtk.DragSource.signals.drag_begin.connect(drag, *Row, dragBegin, self, .{});
        _ = gtk.DragSource.signals.drag_end.connect(drag, *Row, dragEnd, self, .{});
        _ = gtk.DragSource.signals.drag_cancel.connect(drag, *Row, dragCancel, self, .{});
        row.as(gtk.Widget).addController(drag.as(gtk.EventController));
        self.timer = glib.timeoutAddSeconds(2, refresh, self);
        self.update();
        self.watchSurface();
        return row.as(gtk.Widget);
    }

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Row = @ptrCast(@alignCast(data.?));
        _ = glib.Source.remove(self.timer);
        if (self.job) |job| job.cancel();
        if (self.pwd) |pwd| alloc.free(pwd);
        if (self.surface) |s| {
            disconnect(s.as(gobject.Object), self);
            s.unref();
        }
        disconnect(self.page.as(gobject.Object), self);
        disconnect(self.tab.as(gobject.Object), self);
        self.page.unref();
        alloc.destroy(self);
    }

    fn update(self: *Row) void {
        self.title.setText(self.page.getTitle());
        self.widget.as(gtk.Widget).setTooltipText(self.page.getTitle());
        self.title.as(gtk.Widget).setVisible(@intFromBool(self.fields.title));
        self.attention.as(gtk.Widget).setVisible(self.page.getNeedsAttention());
        const widget = self.widget.as(gtk.Widget);
        if (self.page.getSelected() != 0) widget.addCssClass("active") else widget.removeCssClass("active");
        inline for (std.meta.fields(model.Color)) |c| widget.removeCssClass("color-" ++ c.name);
        const metadata = self.tab.getSidebarMetadata();
        var color_buf: [40]u8 = undefined;
        widget.addCssClass(std.fmt.bufPrintZ(&color_buf, "color-{s}", .{@tagName(metadata.color)}) catch unreachable);
        while (self.statuses.as(gtk.Widget).getFirstChild()) |child| self.statuses.remove(child);
        // Match Sidegeist's deterministic ordering by key.
        const keys = alloc.dupe([]const u8, metadata.statuses.keys()) catch return;
        defer alloc.free(keys);
        std.mem.sort([]const u8, keys, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (keys) |key| {
            const status = metadata.statuses.get(key).?;
            const line = gtk.Box.new(.horizontal, 5);
            if (status.icon) |icon| {
                const name: [:0]const u8 = if (std.mem.eql(u8, icon, "network")) "network-workgroup-symbolic" else icon;
                line.append(gtk.Image.newFromIconName(name).as(gtk.Widget));
            }
            line.append(label(status.value).as(gtk.Widget));
            self.statuses.append(line.as(gtk.Widget));
        }
        self.statuses.as(gtk.Widget).setVisible(@intFromBool(self.fields.status));
    }

    fn watchSurface(self: *Row) void {
        if (self.surface) |s| {
            disconnect(s.as(gobject.Object), self);
            s.unref();
        }
        self.surface = if (self.tab.getActiveSurface()) |s| s.ref() else null;
        if (self.surface) |s| _ = gobject.Object.signals.notify.connect(s, *Row, pwdChanged, self, .{ .detail = "pwd" });
        self.syncPwd();
    }

    fn syncPwd(self: *Row) void {
        const pwd = if (self.surface) |s| s.getPwd() else null;
        const text = pwd orelse "";
        const basename = alloc.dupeZ(u8, if (pwd) |v| std.fs.path.basename(v) else "") catch return;
        defer alloc.free(basename);
        self.directory_label.setText(basename);
        self.directory.as(gtk.Widget).setTooltipText(text);
        self.directory.as(gtk.Widget).setVisible(@intFromBool(self.fields.directory and text.len > 0));
        if (std.mem.eql(u8, text, self.pwd orelse "")) return;
        if (self.job) |job| job.cancel();
        self.job = null;
        if (self.pwd) |v| alloc.free(v);
        self.pwd = if (pwd) |v| alloc.dupeZ(u8, v) catch null else null;
        self.branch.setText("");
        self.branch.as(gtk.Widget).setVisible(0);
        self.refreshBranch();
    }

    fn refreshBranch(self: *Row) void {
        if (!self.fields.@"git-branch" or self.job != null) return;
        const pwd = self.pwd orelse return;
        self.detached_query = false;
        self.job = Command.start(pwd, &.{ "git", "symbolic-ref", "--short", "HEAD" }, 5, branchResult, self) catch null;
    }
    fn branchResult(data: *anyopaque, result: Command.Result) void {
        const self: *Row = @ptrCast(@alignCast(data));
        self.job = null;
        if (!result.ok and !self.detached_query) {
            self.detached_query = true;
            self.job = Command.start(self.pwd, &.{ "git", "rev-parse", "--short", "HEAD" }, 5, branchResult, self) catch null;
            return;
        }
        const text = if (result.ok) std.mem.trim(u8, result.stdout, "\n\r") else "";
        const owned = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(owned);
        self.branch.setText(owned);
        self.branch.as(gtk.Widget).setVisible(@intFromBool(text.len > 0));
    }
    fn refresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Row = @ptrCast(@alignCast(data.?));
        if (self.widget.as(gtk.Widget).getMapped() != 0) self.refreshBranch();
        return 1;
    }
    fn pageChanged(_: *adw.TabPage, _: *gobject.ParamSpec, self: *Row) callconv(.c) void {
        self.update();
    }
    fn activeSurfaceChanged(_: *Tab, _: *gobject.ParamSpec, self: *Row) callconv(.c) void {
        self.watchSurface();
    }
    fn pwdChanged(_: *Surface, _: *gobject.ParamSpec, self: *Row) callconv(.c) void {
        self.syncPwd();
    }
    fn metadataChanged(_: *Tab, self: *Row) callconv(.c) void {
        self.update();
    }
    fn closeClicked(_: *gtk.Button, self: *Row) callconv(.c) void {
        if (self.view()) |v| v.closePage(self.page);
    }
    fn closeAction(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Row) callconv(.c) void {
        if (self.view()) |v| v.closePage(self.page);
    }
    fn closeOthers(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Row) callconv(.c) void {
        if (self.view()) |v| v.closeOtherPages(self.page);
    }
    fn closeAfter(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Row) callconv(.c) void {
        if (self.view()) |v| v.closePagesAfter(self.page);
    }
    fn rename(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Row) callconv(.c) void {
        self.tab.promptTabTitle();
    }
    fn color(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Row) callconv(.c) void {
        self.tab.getSidebarMetadata().color = std.meta.stringToEnum(model.Color, std.mem.span((param orelse return).getString(null))) orelse return;
        self.tab.notifyMetadata();
    }
    fn newWindow(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Row) callconv(.c) void {
        moveToNewWindow(self.page);
    }
    fn moveWindow(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Row) callconv(.c) void {
        const target = findTab(std.mem.span((param orelse return).getString(null))) orelse return;
        const source = self.view() orelse return;
        const destination = target.window.getTabView();
        if (source == destination) return;
        const page = self.page;
        page.ref();
        defer page.unref();
        source.transferPage(page, destination, destination.getNPages());
        destination.setSelectedPage(page);
        target.window.as(gtk.Window).present();
    }
    fn view(self: *Row) ?*adw.TabView {
        return ext.getAncestor(adw.TabView, self.tab.as(gtk.Widget));
    }
    fn openDirectory(_: *gtk.Button, self: *Row) callconv(.c) void {
        const file = gio.File.newForPath(self.pwd orelse return);
        defer file.unref();
        const uri = file.getUri();
        defer glib.free(uri);
        gio.AppInfo.launchDefaultForUriAsync(uri, null, null, null, null);
    }
    fn rightClicked(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Row) callconv(.c) void {
        self.updateMenu();
        self.menu.popup();
    }
    fn createPopup(_: *gtk.MenuButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Row = @ptrCast(@alignCast(data.?));
        self.updateMenu();
    }
    fn updateMenu(self: *Row) void {
        const menu = gio.Menu.new();
        defer menu.unref();
        menu.append(i18n._("Rename Tab…"), "card.rename");
        const colors = gio.Menu.new();
        defer colors.unref();
        inline for (std.meta.fields(model.Color)) |c| {
            const item = gio.MenuItem.new(c.name, null);
            item.setActionAndTargetValue("card.color", glib.Variant.newString(c.name));
            colors.appendItem(item);
            item.unref();
        }
        menu.appendSubmenu(i18n._("Tab Color"), colors.as(gio.MenuModel));
        menu.append(i18n._("Move to New Window"), "card.new-window");
        const others = gio.Menu.new();
        defer others.unref();
        var windows: ?*glib.List = Application.default().as(gtk.Application).getWindows();
        while (windows) |node| : (windows = node.f_next) {
            const window = gobject.ext.cast(Window, @as(*gobject.Object, @ptrCast(@alignCast(node.f_data orelse continue)))) orelse continue;
            if (window.getTabView() == self.view()) continue;
            const page = window.getTabView().getSelectedPage() orelse continue;
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const item = gio.MenuItem.new(page.getTitle(), null);
            item.setActionAndTargetValue("card.move-window", glib.Variant.newString(tab.getId()));
            others.appendItem(item);
            item.unref();
        }
        if (others.as(gio.MenuModel).getNItems() > 0) menu.appendSubmenu(i18n._("Move to Window"), others.as(gio.MenuModel));
        menu.append(i18n._("Close Tab"), "card.close");
        menu.append(i18n._("Close Other Tabs"), "card.close-others");
        menu.append(i18n._("Close Tabs After This"), "card.close-after");
        self.menu.setMenuModel(menu.as(gio.MenuModel));
    }
    fn dragPrepare(source: *gtk.DragSource, _: f64, _: f64, self: *Row) callconv(.c) ?*gdk.ContentProvider {
        var value = std.mem.zeroes(gobject.Value);
        _ = value.init(adw.TabPage.getGObjectType());
        defer value.unset();
        value.setObject(self.page.as(gobject.Object));
        const paintable = gtk.WidgetPaintable.new(self.widget.as(gtk.Widget));
        defer paintable.unref();
        source.setIcon(paintable.as(gdk.Paintable), 0, 0);
        return gdk.ContentProvider.newForValue(&value);
    }
    fn dragBegin(_: *gtk.DragSource, _: *gdk.Drag, self: *Row) callconv(.c) void {
        // Reordering or transferring the page removes its row from the model.
        // Keep the callback data alive until GTK has finished the drag.
        self.widget.ref();
    }
    fn dragEnd(_: *gtk.DragSource, _: *gdk.Drag, _: c_int, self: *Row) callconv(.c) void {
        self.widget.unref();
    }
    fn dragCancel(_: *gtk.DragSource, _: *gdk.Drag, reason: gdk.DragCancelReason, self: *Row) callconv(.c) c_int {
        if (reason != .no_target) return 0;
        moveToNewWindow(self.page);
        return 1;
    }
};
