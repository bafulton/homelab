"""Regression checks for version agreement and unavailable support evidence."""

import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import URLError


spec = importlib.util.spec_from_file_location(
    "check_talos_compatibility", Path(__file__).with_name("check_talos_compatibility.py")
)
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)


class CompatibilityTests(unittest.TestCase):
    def test_mismatched_upgrade_pin_fails_before_fetch(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "talos").mkdir()
            (root / "kubernetes/infra/tuppr").mkdir(parents=True)
            (root / "talos/cluster.yaml").write_text("talosVersion: v1.14.5\nkubernetesVersion: v1.37.2\n")
            (root / "kubernetes/infra/tuppr/values.yaml").write_text("talosVersion: v1.14.4\nkubernetesVersion: v1.37.2\n")
            with patch.object(compatibility, "supported_minors") as fetch:
                with self.assertRaisesRegex(ValueError, "disagree"):
                    compatibility.check(root)
                fetch.assert_not_called()

    def test_unavailable_support_data_fails(self):
        with patch.object(compatibility, "urlopen", side_effect=URLError("unavailable")):
            with self.assertRaises(URLError):
                compatibility.supported_minors("v1.14.5")

    def test_supported_range_comes_from_both_constants(self):
        from io import BytesIO

        constants = b'DefaultKubernetesVersion = "1.37.1"\nSupportedKubernetesVersions = 6'
        with patch.object(compatibility, "urlopen", return_value=BytesIO(constants)):
            self.assertEqual(compatibility.supported_minors("v1.14.5"), range(32, 38))


if __name__ == "__main__":
    unittest.main()
