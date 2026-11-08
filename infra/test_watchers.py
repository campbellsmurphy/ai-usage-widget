"""The widget must keep saying a row is frozen, and warn before the token lapses."""
import json, os, sys, tempfile, time, unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai_usage_aggregator as agg

H = 3600.0
FROZEN_OUT = {"claude": {"ok": True}, "stale": True}      # the 2026-11-08 payload shape
LIVE_OUT   = {"claude": {"ok": True}}


class FrozenRenotifyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "frozen.json")
        self.sent = []

    def _run(self, out, at):
        def fake_ntfy(title, msg):
            self.sent.append((title, msg)); return True
        with patch.object(agg, "FROZEN_STATE", self.state), \
             patch.object(agg, "_ntfy", fake_ntfy), \
             patch.object(agg.time, "time", return_value=at):
            agg._watch_frozen(out)

    def test_silent_before_the_threshold(self):
        t0 = 1_000_000.0
        self._run(FROZEN_OUT, t0)
        self._run(FROZEN_OUT, t0 + 1.5 * H)
        self.assertEqual(self.sent, [])

    def test_first_alert_at_the_threshold(self):
        t0 = 1_000_000.0
        self._run(FROZEN_OUT, t0)
        self._run(FROZEN_OUT, t0 + 2 * H)
        self.assertEqual(len(self.sent), 1)
        self.assertIn("frozen", self.sent[0][0].lower())

    def test_keeps_saying_so_rather_than_alerting_once(self):
        """The 2026-11-08 gap: one push at 06:33, then 15 h of silence."""
        t0 = 1_000_000.0
        self._run(FROZEN_OUT, t0)
        for h in (2, 4, 8, 10, 14, 17):
            self._run(FROZEN_OUT, t0 + h * H)
        # 2 h, then every 6 h: 2, 8, 14
        self.assertEqual(len(self.sent), 3)

    def test_recovery_still_fires_once(self):
        t0 = 1_000_000.0
        self._run(FROZEN_OUT, t0)
        self._run(FROZEN_OUT, t0 + 2 * H)
        self.sent.clear()
        self._run(LIVE_OUT, t0 + 3 * H)
        self.assertEqual(len(self.sent), 1)
        self.assertIn("recovered", self.sent[0][0].lower())
        self.assertEqual(json.load(open(self.state)), {})

    def test_no_recovery_push_when_it_never_alerted(self):
        t0 = 1_000_000.0
        self._run(FROZEN_OUT, t0)
        self._run(LIVE_OUT, t0 + 0.5 * H)
        self.assertEqual(self.sent, [])

    def test_failed_push_is_retried_not_swallowed(self):
        t0 = 1_000_000.0
        with patch.object(agg, "FROZEN_STATE", self.state), \
             patch.object(agg, "_ntfy", return_value=False), \
             patch.object(agg.time, "time", return_value=t0):
            agg._watch_frozen(FROZEN_OUT)
        with patch.object(agg, "FROZEN_STATE", self.state), \
             patch.object(agg, "_ntfy", return_value=False), \
             patch.object(agg.time, "time", return_value=t0 + 2 * H):
            agg._watch_frozen(FROZEN_OUT)
        self._run(FROZEN_OUT, t0 + 2.1 * H)
        self.assertEqual(len(self.sent), 1)


class TokenExpiryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "token.json")
        self.sent = []

    EXP = 50_000_000.0   # the expiry is fixed; the clock is what moves

    def _run(self, days_left, exp=None):
        exp = (exp or self.EXP) * 1000
        now = exp / 1000.0 - days_left * 86400
        blob = {"claudeAiOauth": {"refreshToken": "rt", "refreshTokenExpiresAt": exp}}
        def fake_ntfy(title, msg):
            self.sent.append((title, msg)); return True
        with patch.object(agg, "TOKEN_STATE", self.state), \
             patch.object(agg, "PROVIDERS", ["claude"]), \
             patch.object(agg, "kc_read", return_value=blob), \
             patch.object(agg, "_ntfy", fake_ntfy), \
             patch.object(agg.time, "time", return_value=now):
            agg._watch_token_expiry()

    def test_quiet_while_the_token_has_a_month_to_run(self):
        self._run(27.5)
        self.assertEqual(self.sent, [])

    def test_warns_at_seven_days_then_at_two(self):
        self._run(6.0)
        self.assertEqual(len(self.sent), 1)
        self._run(5.0)
        self.assertEqual(len(self.sent), 1, "must not repeat the same mark")
        self._run(1.5)
        self.assertEqual(len(self.sent), 2)
        self.assertIn("claude auth login", self.sent[1][1])

    def test_a_fresh_sign_in_rearms_the_warnings(self):
        self._run(6.0)
        self.assertEqual(len(self.sent), 1)
        self._run(6.0, exp=self.EXP + 86400)   # signed in again: later expiry
        self.assertEqual(len(self.sent), 2)

    def test_failed_push_is_retried(self):
        with patch.object(agg, "TOKEN_STATE", self.state), \
             patch.object(agg, "PROVIDERS", ["claude"]), \
             patch.object(agg, "kc_read", return_value={"claudeAiOauth": {
                 "refreshTokenExpiresAt": self.EXP * 1000}}), \
             patch.object(agg, "_ntfy", return_value=False), \
             patch.object(agg.time, "time", return_value=self.EXP - 6 * 86400):
            agg._watch_token_expiry()
        self._run(6.0)
        self.assertEqual(len(self.sent), 1)

    def test_no_credentials_or_no_expiry_is_silent(self):
        for blob in (None, {}, {"claudeAiOauth": {}}, {"claudeAiOauth": "junk"}):
            with patch.object(agg, "TOKEN_STATE", self.state), \
                 patch.object(agg, "PROVIDERS", ["claude"]), \
                 patch.object(agg, "kc_read", return_value=blob), \
                 patch.object(agg, "_ntfy", lambda *a: self.sent.append(a) or True):
                agg._watch_token_expiry()
        self.assertEqual(self.sent, [])

    def test_skipped_when_this_machine_does_not_read_claude(self):
        with patch.object(agg, "TOKEN_STATE", self.state), \
             patch.object(agg, "PROVIDERS", ["grok"]), \
             patch.object(agg, "kc_read", side_effect=AssertionError("must not read")), \
             patch.object(agg, "_ntfy", lambda *a: self.sent.append(a) or True):
            agg._watch_token_expiry()
        self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
