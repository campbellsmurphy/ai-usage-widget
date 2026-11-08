"""kc_read must not let a dead keychain item shadow a good credentials file."""
import json, os, sys, time, unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai_usage_aggregator as agg

FUTURE = lambda: int(time.time() * 1000) + 3600_000
PAST   = lambda: int(time.time() * 1000) - 3600_000

GOOD    = {"claudeAiOauth": {"accessToken": "at", "refreshToken": "rt", "expiresAt": FUTURE()}}
BLANKED = {"claudeAiOauth": {"accessToken": "", "refreshToken": "", "expiresAt": 0},
           "mcpOAuth": {"some-server": {}}}
LIVE_AT_ONLY = {"claudeAiOauth": {"accessToken": "at", "refreshToken": "", "expiresAt": FUTURE()}}
DEAD_AT_ONLY = {"claudeAiOauth": {"accessToken": "at", "refreshToken": "", "expiresAt": PAST()}}


def _sec_returning(blob):
    """Stand in for the `security` CLI: a dict is a stored item, None is no item."""
    out = MagicMock()
    out.stdout = "" if blob is None else json.dumps(blob)
    return lambda args: out


class KcReadTest(unittest.TestCase):
    def _run(self, keychain, file_blob):
        ctx_file = (patch("builtins.open", side_effect=FileNotFoundError) if file_blob is None
                    else patch("builtins.open", unittest.mock.mock_open(read_data=json.dumps(file_blob))))
        with patch.object(agg, "_sec", side_effect=_sec_returning(keychain)), ctx_file:
            return agg.kc_read()

    def test_blanked_keychain_falls_through_to_good_file(self):
        """The 2026-11-08 failure: expiry blanked the keychain, re-login wrote the file."""
        self.assertEqual(self._run(BLANKED, GOOD), GOOD)

    def test_good_keychain_still_wins(self):
        self.assertEqual(self._run(GOOD, BLANKED), GOOD)

    def test_keychain_only(self):
        self.assertEqual(self._run(GOOD, None), GOOD)

    def test_file_only(self):
        self.assertEqual(self._run(None, GOOD), GOOD)

    def test_no_credentials_anywhere(self):
        self.assertIsNone(self._run(None, None))

    def test_both_unusable_returns_keychain_so_error_reporting_is_unchanged(self):
        """get_access_token must still say signed_out, not no_credentials."""
        blob = self._run(BLANKED, DEAD_AT_ONLY)
        self.assertEqual(blob, BLANKED)
        with patch.object(agg, "kc_read", return_value=blob), patch.object(agg, "backup_once"):
            self.assertEqual(agg.get_access_token(), (None, "signed_out"))

    def test_live_access_token_without_refresh_token_counts_as_usable(self):
        self.assertEqual(self._run(BLANKED, LIVE_AT_ONLY), LIVE_AT_ONLY)

    def test_expired_access_token_without_refresh_token_is_not_usable(self):
        self.assertFalse(agg._usable(DEAD_AT_ONLY))

    def test_usable_tolerates_junk(self):
        for junk in (None, [], "str", {}, {"claudeAiOauth": "not-a-dict"}):
            self.assertFalse(agg._usable(junk))


if __name__ == "__main__":
    unittest.main()
