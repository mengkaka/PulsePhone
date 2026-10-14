from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class DoctorToolchainTests(unittest.TestCase):
    def test_go_version_policy_uses_installed_stable_126_series(self):
        with tempfile.TemporaryDirectory() as temporary:
            go = Path(temporary) / "go"
            go.write_text(
                '#!/bin/sh\n[ "$1" = version ] || exit 99\n'
                'printf "go version %s darwin/arm64\\n" "$DOCTOR_TEST_VERSION"\n'
            )
            go.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = temporary + os.pathsep + environment["PATH"]
            for version, accepted in (
                ("go1.26.0", True),
                ("go1.26.2", True),
                ("go1.26.8", True),
                ("go1.26.10", True),
                ("go1.25.9", False),
                ("go1.27.0", False),
                ("go1x26x2", False),
                ("go1.26rc1", False),
                ("go1.26.2rc1", False),
                ("devel go1.26-abcdef", False),
            ):
                with self.subTest(version=version):
                    environment["DOCTOR_TEST_VERSION"] = version
                    result = subprocess.run(
                        ["/usr/bin/make", "--no-print-directory", "doctor"],
                        cwd=ROOT,
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=30,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    if accepted:
                        self.assertIn("state=passed", result.stdout)
                    else:
                        self.assertIn("expected=1.26.x", result.stderr)
                        self.assertIn(version, result.stderr)
