"""Antigravity 2.34 moved the CSRF token off the command line into a per-launch daemon file."""
import json, os, sys, tempfile, unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collector

OLD_CMD = "language_server --standalone --csrf_token abc-123 --https_server_port 0"
NEW_CMD = "language_server --standalone --https_server_port 0 --read_host_bridge_token_from_stdin"


def fake_run(cmd_line):
    def run(argv, **kw):
        out = {"pgrep": "1078\n", "ps": cmd_line,
               "lsof": "language_ 1078 TCP 127.0.0.1:49194 (LISTEN)\n"}[argv[0]]
        return SimpleNamespace(stdout=out)
    return run


class EndpointTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def _hub(self, port, pid, token="tok-live"):
        json.dump({"pid": pid, "httpsPort": port - 1, "httpPort": port, "csrfToken": token},
                  open(os.path.join(self.dir, "hub_%d.json" % port), "w"))

    def _endpoint(self, cmd_line):
        with patch.object(collector.subprocess, "run", fake_run(cmd_line)), \
             patch.object(collector, "AG_DAEMON_DIR", self.dir):
            return collector._antigravity_endpoint()

    def test_token_on_the_command_line_still_wins(self):
        self.assertEqual(self._endpoint(OLD_CMD), ("49194", "abc-123"))

    def test_daemon_file_of_the_live_pid_is_used_not_a_leftover(self):
        self._hub(49179, 1561, "tok-stale")
        self._hub(49195, 1078)
        self.assertEqual(self._endpoint(NEW_CMD), ("49194", "tok-live"))

    def test_no_file_for_the_live_pid_reads_as_no_endpoint(self):
        self._hub(49179, 1561, "tok-stale")
        self.assertEqual(self._endpoint(NEW_CMD), (None, None))


if __name__ == "__main__":
    unittest.main()
