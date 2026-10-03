# Ghostty Sidegeist

**Personal fork of [Ghostty](https://github.com/ghostty-org/ghostty)** with a sidebar tab system and a built-in git panel, integrated here with a native GTK implementation for Linux. For the official Ghostty terminal, visit [ghostty.org](https://ghostty.org). All credit goes to them.

🧪 **Experimental**

Please note that this is experimental and I built it for my own use.

📦 **[Download Ghostty Sidegeist for macOS](https://github.com/tomreinert/ghostty-sidegeist/releases/latest/download/Ghostty-Sidegeist.zip)**

<img width="1125" height="749" alt="ghostty-sidebar" src="https://github.com/user-attachments/assets/919a9220-4e07-4b2e-b491-c9d385b6585f" />

## Linux build

This checkout includes [Sidegeist](https://github.com/tomreinert/ghostty-sidegeist)
at `d2a8f6b99e59cae6dc7d526609ce4ad982c0649b`, adapted to Ghostty's GTK runtime.
Linux is the target of this integration; the imported macOS code is untested.

With the repository's Nix development environment:

```sh
nix develop --command zig build -Doptimize=ReleaseFast
./zig-out/bin/ghostty --gtk-tabs-location=left
```

On other Linux distributions, install Ghostty's normal GTK build dependencies
and Zig 0.16.0, then run `zig build -Doptimize=ReleaseFast`. Git must be on
`PATH` for the branch labels and Git panel. The build also installs
`zig-out/bin/ghosttyctl`, which requires Python 3.

The sidebar is the default. Drag its divider to resize it. Tab shortcuts and
splits continue to work; right-click a card for rename, color, close, and
move-to-window actions. Drag cards to reorder them or move them between
windows; dropping outside a tab list opens a new window.

```ini
# Use top or bottom for Ghostty's horizontal tab bar instead.
gtk-tabs-location = left
sidebar-fields = title,directory,git-branch,status
sidebar-git = true
sidebar-show-tab-border = true
sidebar-dim-inactive-colors = false
```

The Git panel follows the selected tab's active split. It supports local branch
switching, opening changed files, committing all changes, push, fast-forward
pull, and confirmed discard. Repository updates run asynchronously. Set
`VISUAL` or `EDITOR` to open files in that editor in a terminal tab; otherwise
files open in the desktop's default application.

`GHOSTTY_SOCKET` and `GHOSTTY_TAB_ID` are set in each shell, including splits.
They keep CLI commands aimed at the originating tab even while another tab is
selected or after the tab moves to another window. Independent instances use
separate sockets. Outside Ghostty, the CLI defaults to `/tmp/ghostty-<uid>.sock`;
set `GHOSTTY_SOCKET` to select a different instance.

Linux validation commands:

```sh
nix develop --command zig build test -Dtest-filter=sidebar
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test/sidegeist -v
dbus-run-session -- python3 test/sidegeist/linux_smoke.py --binary zig-out/bin/ghostty
```

The desktop test needs Xvfb, Openbox, xdotool, Git, PyGObject and pyatspi. It
uses temporary repositories and a local remote, loads an isolated config, and
checks shell identities, tab moves, Git actions, IPC, reload and shutdown.

## Sidebar

Replaces the native tab bar with a left sidebar. The top shows rich tab cards; a [git panel](#git-panel) is pinned to the bottom.

- **Title, directory, git branch** — git branch detected automatically, no setup needed
- **Custom status entries** — show ports, environments, or any metadata via CLI
- **Attention indicators** — orange dot on tabs with notifications or bell
- **Drag-and-drop** — reorder tabs by dragging
- **Move between windows** — drag a tab card out of the sidebar and drop it on another window (or anywhere else for a new window); the same actions are in the tab's context menu
- **Theme-aware** — colors derived from your terminal theme
- **Git panel** — branch, changes, and commit / push / pull for the selected tab's repo ([details](#git-panel))

### Config

```
# Choose which tab-card fields to show (default: all)
sidebar-fields = title,directory,git-branch,status

# Show the git panel at the bottom of the sidebar (default: true)
sidebar-git = true
```

### CLI

Use the installed `zig-out/bin/ghosttyctl`, or symlink `cli/ghosttyctl` somewhere on your PATH (e.g. `~/.local/bin/ghosttyctl`). Python 3 is required.

```bash
ghosttyctl rename "My Tab"                                    # rename tab
ghosttyctl notify --title "Done" --body "Build finished"      # send notification
ghosttyctl set-status server "localhost:3000" --icon network  # add status entry
ghosttyctl clear-status server                                # remove it
ghosttyctl set-color blue                                    # color this tab
ghosttyctl list                                               # list all tabs
ghosttyctl current                                            # current tab info
```

### Claude Code

Add to your `~/.claude/CLAUDE.md` so Claude Code can name its tabs and set status:

```markdown
- Rename the workspace using: `ghosttyctl rename "Claude: <name>"`. Name it after the work being done.
- Set sidebar status entries using `ghosttyctl set-status <key> <value> [--icon <sf-symbol>]` and clear with `ghosttyctl clear-status <key>`.
```

## Git panel

A small git panel pinned to the bottom of the sidebar, scoped to the selected tab's repo:

- **Branch + sync** — current branch, ahead/behind, and inline checkout / commit / push / pull
- **Changes** — pending files with colour-coded status (`M` modified, `A` added, `D` deleted, `?` untracked, `U` conflict)
- **Click to open** — click a file to open it in your editor via `$VISUAL`/`$EDITOR` (e.g. Cursor, VS Code)

This one is especially personal, built around how I work day to day. If it's not for you, turn it off with `sidebar-git = false` (see [Config](#config) above).

---
