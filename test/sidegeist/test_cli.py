"""Protocol regressions for ghosttyctl; run with python3 -m unittest discover -s test/sidegeist."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

CLI = Path(__file__).resolve().parents[2] / "cli" / "ghosttyctl"


class GhosttyCtlTest(unittest.TestCase):
    def request(self, args, response=b'{"ok":true,"result":{}}\n', tab_id="tab-123"):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "control.sock")
            received = []
            failures = []
            done = threading.Event()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(3)

                def serve():
                    try:
                        with server.accept()[0] as client:
                            client.settimeout(3)
                            with client.makefile("rb") as stream:
                                received.append(json.loads(stream.readline(65536)))
                            # Exercise partial reads, then leave the connection open.
                            client.sendall(response[:5])
                            client.sendall(response[5:])
                            done.wait(3)
                    except Exception as error:
                        failures.append(error)

                thread = threading.Thread(target=serve, daemon=True)
                thread.start()
                env = dict(os.environ, GHOSTTY_SOCKET=path)
                env.pop("GHOSTTY_TAB_ID", None)
                if tab_id:
                    env["GHOSTTY_TAB_ID"] = tab_id
                try:
                    result = subprocess.run([str(CLI), *args], env=env, capture_output=True, text=True, timeout=2)
                finally:
                    done.set()
                    thread.join(timeout=3)
                self.assertFalse(failures)
                self.assertEqual(len(received), 1)
                return result, received[0]

    def test_json_escaping_and_originating_tab(self):
        title = 'Linux "tab" \\ café\n\t\x01'
        result, request = self.request(["rename", title])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request, {"method": "tab.rename", "params": {"tab_id": "tab-123", "title": title}})

    def test_current_targets_shell_tab_and_list_is_global(self):
        for command, params in [("current", {"tab_id": "tab-123"}), ("list", {})]:
            with self.subTest(command=command):
                result, request = self.request([command])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(request["params"], params)

    def test_status_and_notifications(self):
        for args, params in [
            (["set-status", "server", "localhost:3000", "--icon", "network"], {"key": "server", "value": "localhost:3000", "icon": "network"}),
            (["clear-status", "server"], {"key": "server"}),
            (["set-color", "teal"], {"color": "teal"}),
            (["notify", "Build finished"], {"title": "Ghostty", "body": "Build finished"}),
        ]:
            with self.subTest(args=args):
                result, request = self.request(args, tab_id=None)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(request["params"], params)

    def test_server_errors_are_unsuccessful(self):
        result, _ = self.request(["current"], b'{"ok":false,"error":"TabNotFound"}\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("TabNotFound", result.stderr)

    def test_invalid_response(self):
        result, _ = self.request(["list"], b'invalid json\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stderr)

    def test_missing_flag_argument(self):
        result = subprocess.run([str(CLI), "notify", "--body"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
