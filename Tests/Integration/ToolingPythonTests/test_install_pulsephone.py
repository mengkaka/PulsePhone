from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts" / "install-pulsephone"


class InstallPulsePhoneScriptTests(unittest.TestCase):
    @staticmethod
    def path_guidance(home: Path, shell: str, path: str = "/usr/bin:/bin") -> str:
        script = SCRIPT.read_text(encoding="utf-8")
        beginning = script.index("print_path_guidance() {")
        ending = script.index("\n}\n\ncleanup()", beginning) + 2
        environment = os.environ.copy()
        environment.update(HOME=str(home), SHELL=shell, PATH=path)
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                script[beginning:ending]
                + '\nprint_path_guidance "$HOME/.local/bin/PulsePhone"',
            ],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        return result.stdout

    @staticmethod
    def run_guidance(snippet: str, home: Path, shell: str, zdotdir: Path | None = None):
        environment = os.environ.copy()
        environment.update(HOME=str(home), PATH="/usr/bin:/bin")
        if zdotdir is not None:
            environment["ZDOTDIR"] = str(zdotdir)
        arguments = [shell, "-c", snippet]
        if shell == "/bin/zsh":
            arguments.insert(1, "-f")
        return subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

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

    def test_zsh_guidance_is_copyable_and_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            launcher = home / ".local/bin/PulsePhone"
            launcher.parent.mkdir(parents=True)
            launcher.symlink_to("/usr/bin/true")
            zdotdir = home / "zsh-settings"
            zdotdir.mkdir()
            guidance = self.path_guidance(home, "/bin/zsh")
            self.assertIn(".zshrc", guidance)
            snippet = guidance.split("future terminals:\n\n", 1)[1]
            for _ in range(2):
                result = self.run_guidance(snippet, home, "/bin/zsh", zdotdir)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(str(launcher), result.stdout)
            profile = (zdotdir / ".zshrc").read_text(encoding="utf-8")
            self.assertEqual(profile.count('export PATH="$HOME/.local/bin:$PATH"'), 1)

    def test_bash_guidance_covers_login_and_interactive_shells(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            launcher = home / ".local/bin/PulsePhone"
            launcher.parent.mkdir(parents=True)
            launcher.symlink_to("/usr/bin/true")
            snippet = self.path_guidance(home, "/bin/bash").split(
                "future terminals:\n\n", 1
            )[1]
            for _ in range(2):
                result = self.run_guidance(snippet, home, "/bin/bash")
                self.assertEqual(result.returncode, 0, result.stderr)
            for filename in [".bash_profile", ".bashrc"]:
                profile = (home / filename).read_text(encoding="utf-8")
                self.assertEqual(profile.count('export PATH="$HOME/.local/bin:$PATH"'), 1)

    def test_guidance_does_not_write_through_profile_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            external = home / "existing"
            external.write_text("unchanged\n", encoding="utf-8")
            (home / ".zshrc").symlink_to(external)
            snippet = self.path_guidance(home, "/bin/zsh").split(
                "future terminals:\n\n", 1
            )[1]
            result = self.run_guidance(snippet, home, "/bin/zsh")
            self.assertIn("Cannot safely update", result.stderr)
            self.assertEqual(external.read_text(encoding="utf-8"), "unchanged\n")

    def test_no_guidance_when_path_is_present_and_unknown_shell_stays_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            directory = str(home / ".local/bin")
            self.assertEqual(
                self.path_guidance(home, "/bin/zsh", path=f"/usr/bin:{directory}:/bin"),
                "",
            )
            guidance = self.path_guidance(home, "/bin/fish")
            self.assertIn("Shell /bin/fish is not recognized", guidance)
            self.assertNotIn("future terminals:", guidance)
            self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
