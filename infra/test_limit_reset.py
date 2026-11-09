"""The aggregator must read the reset grant with its own token, so a held reset never
renders as none when the collector cannot authenticate (the 2026-11-10 fault)."""
import io, json, os, sys, tempfile, unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai_usage_aggregator as agg


def _body(obj):
    return io.BytesIO(json.dumps(obj).encode())


class GrantParseTest(unittest.TestCase):
    def test_sums_resets_and_takes_the_soonest_expiry(self):
        with patch.object(agg.urllib.request, "urlopen", return_value=_body({"cedar_ember": {
                "grants": [
                    {"resets_left": 1, "label": "late", "ends_at": "2026-12-20T00:00:00Z",
                     "usable_now": True},
                    {"resets_left": 2, "label": "soon", "ends_at": "2026-12-01T00:00:00Z",
                     "usable_now": True}]}})):
            self.assertEqual(agg._claude_limit_reset("t"), {
                "left": 3, "label": "soon",
                "expires_at": "2026-12-01T00:00:00Z", "usable_now": True})

    def test_spent_grants_do_not_count(self):
        with patch.object(agg.urllib.request, "urlopen", return_value=_body(
                {"cedar_ember": {"grants": [{"resets_left": 0, "label": "spent"}]}})):
            self.assertEqual(agg._claude_limit_reset("t"), {"left": 0})

    def test_identifies_as_the_cli_or_the_grant_list_comes_back_empty(self):
        seen = {}

        def fake(req, timeout=None):
            seen["ua"] = req.get_header("User-agent")
            seen["url"] = req.full_url
            return _body({"cedar_ember": {"grants": []}})

        with patch.object(agg.urllib.request, "urlopen", fake):
            agg._claude_limit_reset("t")
        self.assertIn("(external, cli)", seen["ua"])
        self.assertIn("cedar_ember=1", seen["url"])

    def test_a_failed_call_is_unknown_not_zero(self):
        with patch.object(agg.urllib.request, "urlopen", side_effect=OSError("boom")):
            self.assertIsNone(agg._claude_limit_reset("t"))


class CollectorFallbackTest(unittest.TestCase):
    """The collector's reading is a fallback for our own failed grant call, not a
    replacement for a good one."""

    def _usage(self, own_reset, pushed_reset):
        agg._cache.update({"data": None, "ts": 0})
        agg._pushed.update({"at": 0, "claude": {"ok": True, "limit_reset": pushed_reset}})
        tmp = os.path.join(tempfile.mkdtemp(), "usage.json")
        with patch.object(agg, "PROVIDERS", ["claude"]), \
             patch.object(agg, "STATE", tmp), \
             patch.object(agg, "_watch_frozen"), \
             patch.object(agg, "_watch_token_expiry"), \
             patch.object(agg, "fetch_claude",
                          return_value={"ok": True, "limit_reset": own_reset}):
            return agg.get_usage(force=True)["claude"]["limit_reset"]

    def test_own_reading_wins_when_it_succeeded(self):
        self.assertEqual(self._usage({"left": 0}, {"left": 2}), {"left": 0})

    def test_collector_fills_in_when_our_call_failed(self):
        self.assertEqual(self._usage(None, {"left": 2}), {"left": 2})


if __name__ == "__main__":
    unittest.main(verbosity=0)
