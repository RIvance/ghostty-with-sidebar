#!/usr/bin/env python3
"""Exercise a real Linux build in a disposable X11 desktop and Git repository.

Requires Xvfb, openbox, xdotool, Git, and Python with PyGObject/pyatspi.
Run inside an isolated D-Bus session, e.g.:
  dbus-run-session -- python3 test/sidegeist/linux_smoke.py --binary zig-out/bin/ghostty
All Git mutations are confined to a temporary fixture. No user config is loaded.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--artifacts", type=Path)
args = parser.parse_args()
binary = args.binary.resolve()
cli = Path(__file__).resolve().parents[2] / "cli" / "ghosttyctl"


def run(*argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kwargs).stdout.strip()


with tempfile.TemporaryDirectory(prefix="ghostty-sidegeist-") as directory:
    root = Path(directory)
    artifacts = args.artifacts or root
    artifacts.mkdir(parents=True, exist_ok=True)
    repo, remote = root / "repo", root / "remote.git"
    run("git", "init", "-q", "-b", "main", str(repo))
    run("git", "init", "-q", "--bare", str(remote))

    def git(*argv):
        return run("git", "-C", str(repo), *argv)

    git("config", "user.name", "Sidegeist Test")
    git("config", "user.email", "sidegeist-test@example.invalid")
    (repo / "tracked.txt").write_text("initial\n")
    git("add", ".")
    git("commit", "-qm", "Initial fixture")
    git("remote", "add", "origin", str(remote))
    git("push", "-qu", "origin", "main")
    git("branch", "feature/sidebar")
    (repo / "tracked.txt").write_text("initial\nchanged\n")
    (repo / "draft file.txt").write_text("draft\n")
    config = root / "config"
    config.write_text("gtk-tabs-location = left\n")
    path = str(root / "control.sock")
    processes = []
    logs = []

    def start(argv, name, env=None, **kwargs):
        log = open(artifacts / f"{name}.log", "w")
        logs.append(log)
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, env=env, **kwargs)
        processes.append(process)
        return process

    try:
        read_fd, write_fd = os.pipe()
        xvfb = start(["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1600x1000x24", "-nolisten", "tcp"], "xvfb", pass_fds=(write_fd,))
        os.close(write_fd)
        assert select.select([read_fd], [], [], 10)[0], "Xvfb did not start"
        display = ":" + os.read(read_fd, 32).decode().strip()
        os.close(read_fd)
        os.environ["DISPLAY"] = display
        env = dict(os.environ, GDK_BACKEND="x11", GTK_A11Y="atspi", GSK_RENDERER="cairo", LIBGL_ALWAYS_SOFTWARE="1", GIO_USE_VFS="local", GHOSTTY_SOCKET=path)
        env.pop("GHOSTTY_TAB_ID", None)
        run("dbus-update-activation-environment", "DISPLAY", "GDK_BACKEND", "GTK_A11Y", env=env)
        start(["openbox"], "openbox", env)
        app = start([str(binary), "--config-default-files=false", f"--config-file={config}", "--gtk-single-instance=false", f"--working-directory={repo}", "--confirm-close-surface=false", "--shell-integration=bash", "--command=bash --noprofile --norc"], "ghostty", env)

        import pyatspi
        from gi.repository import GLib

        def pump():
            context = GLib.MainContext.default()
            while context.pending():
                context.iteration(False)

        def wait(predicate, description, timeout=15):
            deadline = time.monotonic() + timeout
            last = None
            while time.monotonic() < deadline:
                assert app.poll() is None, f"Ghostty exited ({app.returncode}) while waiting for {description}"
                pump()
                try:
                    last = predicate()
                    if last:
                        return last
                except (OSError, ValueError, RuntimeError):
                    pass
                time.sleep(.1)
            raise AssertionError(f"Timed out: {description} (last={last!r})")

        def ctl(*argv, tab=None, socket_path=path, check=True):
            ctl_env = dict(env, GHOSTTY_SOCKET=socket_path)
            if tab:
                ctl_env["GHOSTTY_TAB_ID"] = tab
            result = subprocess.run([str(cli), *argv], env=ctl_env, capture_output=True, text=True, timeout=7)
            if check:
                assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def tabs():
            return ctl("list")["result"]["tabs"]

        def walk(obj):
            yield obj
            for child in obj:
                yield from walk(child)

        def nodes():
            pump()
            for candidate in pyatspi.Registry.getDesktop(0):
                if candidate.get_process_id() == app.pid:
                    candidate.setCacheMask(0)
                    yield from walk(candidate)

        def names():
            return [n.name for n in nodes()]

        def activate(name, role=None, index=0):
            def find():
                found = []
                for node in nodes():
                    kind = node.getRoleName()
                    if role and kind != role:
                        continue
                    match = node.name == name
                    if kind == "menu item":
                        match = any(child.name == name for child in walk(node))
                    if match:
                        action = node.queryAction()
                        if kind == "menu item" and action.nActions == 0:
                            found.append(node)
                            continue
                        if action.nActions and any(action.getName(i) in ("click", "activate") for i in range(action.nActions)):
                            found.append(node)
                return found[index] if len(found) > index else None
            node = wait(find, f"action {name}")
            assert node.getState().contains(pyatspi.STATE_SENSITIVE), f"Disabled: {name}"
            action = node.queryAction()
            if node.getRoleName() == "menu item" and action.nActions == 0:
                assert node.queryComponent().grabFocus(), f"Could not focus: {name}"
                key("Return")
                return
            i = next(i for i in range(action.nActions) if action.getName(i) in ("click", "activate"))
            assert action.doAction(i), f"Activation failed: {name}"
            time.sleep(.2)
            pump()

        def key(*keys):
            run("xdotool", "key", "--clearmodifiers", *keys, env=env)
            time.sleep(.2)

        def shell(command):
            run("xdotool", "type", "--clearmodifiers", "--delay", "1", "--", command, env=env)
            key("Return")

        def entry(text):
            node = wait(lambda: next((n for n in nodes() if n.getRoleName() == "text"), None), "text entry")
            assert node.queryEditableText().setTextContents(text)

        def passed(message):
            print("PASS", message, flush=True)

        wait(lambda: Path(path).exists(), "IPC socket", 60)
        wait(lambda: len(tabs()) == 1 and tabs()[0]["pwd"] == str(repo), "initial terminal")
        wait(lambda: "M  tracked.txt" in names(), "Git changes")
        first = tabs()[0]["tab_id"]
        ctl("rename", "First tab", tab=first)
        ctl("set-color", "teal", tab=first)
        ctl("set-status", "server", "localhost:3000", "--icon", "network", tab=first)
        wait(lambda: "localhost:3000" in names(), "status entry")
        assert ctl("current", tab=first)["result"]["color"] == "teal"
        passed("sidebar, branch, changed files, title, status and color")

        # Real terminal environment: all splits must address their owning tab.
        envfile = root / "shell-env"
        shell("printf '%s\\n%s\\n' \"$GHOSTTY_SOCKET\" \"$GHOSTTY_TAB_ID\" > " + shlex.quote(str(envfile)))
        wait(envfile.exists, "shell environment")
        assert envfile.read_text().splitlines() == [path, first], envfile.read_text()
        key("ctrl+shift+o")
        splitfile = root / "split-env"
        run("xdotool", "type", "--clearmodifiers", "--", "printf '%s' \"$GHOSTTY_TAB_ID\" > " + shlex.quote(str(splitfile)), env=env)
        key("Return")
        wait(splitfile.exists, "split environment")
        assert splitfile.read_text() == first
        shell("exit")
        wait(lambda: len(tabs()) == 1, "remaining tab after split exit")
        passed("stable identity inside shells and splits")

        key("ctrl+shift+t")
        wait(lambda: len(tabs()) == 2, "second tab")
        second = next(t["tab_id"] for t in tabs() if t["tab_id"] != first)
        ctl("rename", "Background target", tab=first)
        ctl("rename", "Second tab", tab=second)
        assert ctl("current", tab=first)["result"]["title"] == "Background target"
        assert next(t for t in tabs() if t["is_active"])["tab_id"] == second
        ctl("notify", "Finished", tab=first)
        passed("CLI targets inactive tabs without changing selection")

        # Menu actions use the selected card, even when it is not the active tab.
        activate("Tab Menu", role="toggle button", index=0)
        # GTK 4's AT-SPI bridge omits labels on these generated menu items.
        # Move to New Window follows Rename and Tab Color.
        activate("", role="menu item", index=2)
        wait(lambda: len([n for n in nodes() if n.getRoleName() == "frame"]) == 2, "detached window")
        assert len(tabs()) == 2
        assert ctl("current", tab=first)["result"]["color"] == "teal"
        passed("move to a new window preserves terminal and metadata")

        # Focus the original tab's window and exercise the Git panel.
        window_ids = run("xdotool", "search", "--all", "--onlyvisible", "--pid", str(app.pid), "--name", "Background target", env=env).splitlines()
        run("xdotool", "windowactivate", "--sync", window_ids[-1], env=env)
        entry("Commit from Linux sidebar")
        activate("Commit All", index=0)
        wait(lambda: git("log", "-1", "--format=%s") == "Commit from Linux sidebar", "commit")
        assert git("status", "--porcelain") == ""
        activate("Push", index=0)
        wait(lambda: git("rev-parse", "HEAD") == run("git", "--git-dir", str(remote), "rev-parse", "refs/heads/main"), "push")
        activate("Pull (fast-forward only)", index=0)
        wait(lambda: any(n.name == "Commit All" and n.getRoleName() == "button" and n.getState().contains(pyatspi.STATE_SENSITIVE) for n in nodes()), "pull completion")
        passed("commit, push and pull against a local remote")

        (repo / "tracked.txt").write_text("discard this\n")
        wait(lambda: "M  tracked.txt" in names(), "modified tracked file")
        activate("Discard Changes…", index=0)
        activate("Cancel")
        assert (repo / "tracked.txt").read_text() == "discard this\n"
        activate("Discard Changes…", index=0)
        activate("Discard")
        wait(lambda: (repo / "tracked.txt").read_text() == "initial\nchanged\n", "discard tracked changes")
        (repo / "discard me.txt").write_text("untracked\n")
        wait(lambda: "?  discard me.txt" in names(), "untracked file")
        activate("Discard Changes…", index=0)
        activate("Discard")
        wait(lambda: not (repo / "discard me.txt").exists(), "discard untracked file")
        passed("discard cancellation and confirmed tracked/untracked discard")

        # A branch created outside the sidebar must appear without a file change.
        git("branch", "aaa-live")
        time.sleep(3)
        activate("main", role="toggle button", index=0)
        wait(lambda: len([n for n in nodes() if n.getRoleName() == "menu item"]) == 3, "new branch menu entry")
        activate("", role="menu item", index=0)
        wait(lambda: git("branch", "--show-current") == "aaa-live", "branch checkout")
        wait(lambda: "aaa-live" in names(), "updated branch label")
        activate("aaa-live", role="toggle button", index=0)
        activate("", role="menu item", index=2)
        wait(lambda: git("branch", "--show-current") == "main", "return to main")
        passed("branch refresh and checkout")

        # Protocol framing, malformed requests and clients that stop writing.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as raw:
            raw.settimeout(3)
            raw.connect(path)
            raw.sendall(b'{"method":"tab.')
            raw.sendall(b'list"}\n[]\n')
            with raw.makefile("rb") as reader:
                assert json.loads(reader.readline())["ok"]
                assert not json.loads(reader.readline())["ok"]
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stalled:
            stalled.connect(path)
            assert ctl("list")["ok"]
        assert not ctl("set-color", "blue", tab="missing", check=False)["ok"]
        assert Path(path).stat().st_mode & 0o777 == 0o600
        passed("partial/multiple requests, invalid input, stalled clients and socket permissions")

        # Reload the same running windows into a horizontal tab bar, then back.
        config.write_text("gtk-tabs-location = top\nsidebar-git = false\n")
        app.send_signal(signal.SIGUSR2)
        time.sleep(1)
        assert len(tabs()) == 2
        config.write_text("gtk-tabs-location = left\nsidebar-fields = title\nsidebar-git = false\n")
        app.send_signal(signal.SIGUSR2)
        time.sleep(1)
        assert "localhost:3000" not in names()
        config.write_text("gtk-tabs-location = left\n")
        app.send_signal(signal.SIGUSR2)
        wait(lambda: "localhost:3000" in names(), "restored sidebar fields")
        passed("configuration reload, horizontal tabs and field visibility")

        # Exercise GTK's real drag controllers, including destruction of the
        # source window when its last tab is transferred. The fixture owns
        # both window positions and sizes, so these coordinates are stable.
        def window_id(title):
            return run("xdotool", "search", "--all", "--onlyvisible", "--pid", str(app.pid), "--name", "^" + title + "$", env=env).splitlines()[-1]

        for title, x in (("Background target", 0), ("Second tab", 800)):
            wid = window_id(title)
            run("xdotool", "windowsize", "--sync", wid, "800", "600", env=env)
            run("xdotool", "windowmove", "--sync", wid, str(x), "0", env=env)
            geometry = dict(line.split("=", 1) for line in run("xdotool", "getwindowgeometry", "--shell", wid, env=env).splitlines())
            assert int(geometry["X"]) == x and int(geometry["Y"]) == 0, geometry

        def drag(start, end):
            run("xdotool", "mousemove", "--sync", str(start[0]), str(start[1]), env=env)
            run("xdotool", "mousedown", "1", env=env)
            time.sleep(.2)
            for step in range(1, 11):
                x = round(start[0] + (end[0] - start[0]) * step / 10)
                y = round(start[1] + (end[1] - start[1]) * step / 10)
                run("xdotool", "mousemove", "--sync", str(x), str(y), env=env)
                time.sleep(.06)
            run("xdotool", "mouseup", "1", env=env)
            time.sleep(.5)

        drag((900, 76), (100, 230))
        wait(lambda: len([n for n in nodes() if n.getRoleName() == "frame"]) == 1, "drag between windows")
        assert {t["tab_id"] for t in tabs()} == {first, second}
        drag((100, 76), (100, 270))
        wait(lambda: [t["tab_id"] for t in tabs()] == [second, first], "drag reorder")
        drag((100, 76), (1400, 850))
        wait(lambda: len([n for n in nodes() if n.getRoleName() == "frame"]) == 2, "drag out into new window")
        assert {t["tab_id"] for t in tabs()} == {first, second}
        passed("drag between windows, reorder and detach outside")

        for window_id in run("xdotool", "search", "--all", "--onlyvisible", "--pid", str(app.pid), "--class", "ghostty", env=env).splitlines():
            subprocess.run(["xdotool", "windowquit", window_id], env=env, capture_output=True)
        assert app.wait(timeout=15) == 0
        assert not Path(path).exists(), "socket survived normal shutdown"
        log_text = (artifacts / "ghostty.log").read_text()
        assert "CRITICAL" not in log_text and "panic:" not in log_text and "ERROR:" not in log_text, log_text[-4000:]
        passed("clean window teardown and socket cleanup")
    except Exception:
        try:
            with open(artifacts / "accessibility.txt", "w") as dump:
                for node in nodes():
                    try:
                        action = node.queryAction()
                        actions = [action.getName(i) for i in range(action.nActions)]
                    except NotImplementedError:
                        actions = []
                    print(node.getRoleName(), repr(node.name), actions, file=dump)
        except Exception:
            pass
        if shutil.which("magick") and "env" in locals():
            subprocess.run(["magick", "import", "-window", "root", str(artifacts / "failure.png")], env=env, capture_output=True)
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for log in logs:
            log.close()
