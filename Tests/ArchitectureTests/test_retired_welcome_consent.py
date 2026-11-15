"""Keep native sources from calling the retired Welcome consent view."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RetiredWelcomeConsentTests(unittest.TestCase):
    def test_no_native_source_constructs_retired_welcome_consent(self):
        constructor = re.compile(r"\bWelcomeScreenshotConsent\s*\(")
        offenders = [
            str(path.relative_to(ROOT))
            for directory in ("Sources", "Tests")
            for path in (ROOT / directory).rglob("*.swift")
            if constructor.search(path.read_text())
        ]
        self.assertEqual(offenders, [], "Use the persisted preference entry point instead")


if __name__ == "__main__":
    unittest.main()
