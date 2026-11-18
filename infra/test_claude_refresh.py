"""An expired CLI token triggers one CLI refresh, then the reread token is used."""
import os, sys, time, unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collector as col

NOW = lambda: time.time() * 1000
LIVE = {"accessToken": "at", "expiresAt": NOW() + 3600_000}
DEAD = {"accessToken": "at", "expiresAt": NOW() - 3600_000}


class RefreshTest(unittest.TestCase):
    def _run(self, reads):
        with patch.object(col, "_read_claude_oauth", side_effect=reads), \
             patch.object(col, "_refresh_claude_cli") as ref, \
             patch.object(col.urllib.request, "urlopen", side_effect=OSError("net")):
            return col.fetch_claude(), ref.call_count

    def test_live_token_does_not_refresh(self):
        out, n = self._run([LIVE])
        self.assertEqual(n, 0)
        self.assertEqual(out, {"error": "OSError"})

    def test_expired_token_refreshes_then_uses_new_one(self):
        out, n = self._run([DEAD, LIVE])
        self.assertEqual(n, 1)
        self.assertEqual(out, {"error": "OSError"})

    def test_refresh_that_fails_still_reports_expired(self):
        out, n = self._run([DEAD, DEAD])
        self.assertEqual(n, 1)
        self.assertEqual(out, {"error": "access_token_expired"})


if __name__ == "__main__":
    unittest.main()
