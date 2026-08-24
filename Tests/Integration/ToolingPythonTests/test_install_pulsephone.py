from __future__ import annotations

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts" / "install-pulsephone"


class InstallPulsePhoneScriptTests(unittest.TestCase):
    def test_script_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installer_requires_signed_checksum_verified_release(self):
        script = SCRIPT.read_text(encoding="utf-8")
        for required in [
            'readonly repository="mengkaka/PulsePhone"',
            'readonly asset_name="PulsePhone-macos-arm64.zip"',
            'readonly checksum_name="${asset_name}.sha256"',
            'readonly bundle_identifier="com.pulsephone.PulsePhone"',
            'readonly team_identifier="GZC4TSS5TG"',
            'releases/latest/download',
            'trap cleanup EXIT HUP INT TERM',
            '/usr/bin/mktemp -d -t pulsephone-install',
            '/usr/bin/shasum -a 256',
            '/usr/bin/ditto -x -k',
            '/usr/bin/codesign --verify --deep --strict',
            '/usr/sbin/spctl --assess --type execute',
            'self install',
        ]:
            self.assertIn(required, script)
        self.assertNotIn('sudo ', script)
        self.assertNotIn('${TMPDIR:-/tmp}/pulsephone-install.XXXXXX', script)


if __name__ == "__main__":
    unittest.main()
