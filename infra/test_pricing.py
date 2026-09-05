import importlib.util
import io
from contextlib import redirect_stderr
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collector.py"))
collector = importlib.util.module_from_spec(spec)
with TemporaryDirectory(dir=Path(__file__).parent) as state_dir:
    with patch("os.path.expanduser", side_effect=lambda path: str(Path(state_dir) / path[2:])):
        spec.loader.exec_module(collector)


class PricingTests(unittest.TestCase):
    @patch.object(collector, "fx_rate", return_value=(1.0, None, False))
    def test_known_models(self, _fx_rate):
        counts = {"input_tokens": 1_000_000, "output_tokens": 1_000_000,
                  "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        for model, expected in (("claude-opus-5", 30.0), ("claude-fable-5-1", 60.0),
                                ("claude-sonnet-5", 12.0), ("claude-haiku-4-5", 6.0)):
            with self.subTest(model=model), redirect_stderr(io.StringIO()) as stderr:
                result = collector.price({model: counts})
                self.assertGreater(result["total"], 0)
                self.assertEqual(result["total"], expected)
                self.assertEqual(result["by_model"][0]["cost"], expected)
                self.assertEqual(result["unpriced"], [])
                self.assertEqual(stderr.getvalue(), "")

    @patch.object(collector, "fx_rate", return_value=(1.0, None, False))
    def test_unknown_models_warn(self, _fx_rate):
        counts = {"input_tokens": 100, "output_tokens": 200,
                  "cache_creation_input_tokens": 300, "cache_read_input_tokens": 400}
        models = ["claude-invented-99", "claude-imaginary-99"]
        with redirect_stderr(io.StringIO()) as stderr:
            result = collector.price({model: counts for model in models})
        self.assertEqual(result["unpriced"], models)
        self.assertEqual(stderr.getvalue(), "".join(
            "WARNING: Unpriced model %s (1000 tokens)\n" % model for model in models))


if __name__ == "__main__":
    unittest.main()
