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
    def configure_path(
        home: Path, shell: str, path: str = "/usr/bin:/bin", zdotdir: Path | None = None
    ) -> str:
        script = SCRIPT.read_text(encoding="utf-8")
        beginning = script.index("configure_shell_path() {")
        ending = script.index("\n}\n\ncleanup()", beginning) + 2
        environment = os.environ.copy()
        environment.update(HOME=str(home), SHELL=shell, PATH=path)
        environment.pop("ZDOTDIR", None)
        if zdotdir is not None:
            environment["ZDOTDIR"] = str(zdotdir)
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                script[beginning:ending]
                + '\nconfigure_shell_path "$HOME/.local/bin/PulsePhone"',
            ],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        return result.stdout

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

    def test_zsh_profile_is_updated_automatically_and_idempotently(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            launcher = home / ".local/bin/PulsePhone"
            launcher.parent.mkdir(parents=True)
            launcher.symlink_to("/usr/bin/true")
            zdotdir = home / "zsh-settings"
            zdotdir.mkdir()
            for _ in range(2):
                output = self.configure_path(home, "/bin/zsh", zdotdir=zdotdir)
                self.assertIn('export PATH="$HOME/.local/bin:$PATH"', output)
                self.assertIn("future terminals", output)
            profile = (zdotdir / ".zshrc").read_text(encoding="utf-8")
            self.assertEqual(profile.count('export PATH="$HOME/.local/bin:$PATH"'), 1)
            self.assertEqual((zdotdir / ".zshrc").stat().st_mode & 0o777, 0o600)
            new_shell = subprocess.run(
                ["/bin/zsh", "-i", "-c", "command -v PulsePhone"],
                check=True,
                capture_output=True,
                text=True,
                env={"HOME": str(home), "ZDOTDIR": str(zdotdir), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(new_shell.stdout.strip(), str(launcher))

    def test_bash_profiles_cover_login_and_interactive_shells(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            launcher = home / ".local/bin/PulsePhone"
            launcher.parent.mkdir(parents=True)
            launcher.symlink_to("/usr/bin/true")
            for _ in range(2):
                output = self.configure_path(home, "/bin/bash")
                self.assertIn("future terminals", output)
            for filename in [".bash_profile", ".bashrc"]:
                profile = (home / filename).read_text(encoding="utf-8")
                self.assertEqual(profile.count('export PATH="$HOME/.local/bin:$PATH"'), 1)
            new_shell = subprocess.run(
                [
                    "/bin/bash",
                    "--noprofile",
                    "--rcfile",
                    str(home / ".bashrc"),
                    "-i",
                    "-c",
                    "command -v PulsePhone",
                ],
                check=True,
                capture_output=True,
                text=True,
                env={"HOME": str(home), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(new_shell.stdout.strip(), str(launcher))

    def test_installer_does_not_write_through_profile_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            external = home / "existing"
            external.write_text("unchanged\n", encoding="utf-8")
            (home / ".zshrc").symlink_to(external)
            guidance = self.configure_path(home, "/bin/zsh")
            self.assertIn("Cannot safely update", guidance)
            self.assertNotIn("export PATH", guidance)
            self.assertEqual(external.read_text(encoding="utf-8"), "unchanged\n")

    def test_unsafe_bash_profile_emits_no_partial_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / ".bash_profile").write_text("existing\n", encoding="utf-8")
            (home / ".bashrc").mkdir()
            guidance = self.configure_path(home, "/bin/bash")
            self.assertIn("Cannot safely update", guidance)
            self.assertNotIn("export PATH", guidance)
            self.assertEqual((home / ".bash_profile").read_text(), "existing\n")

    def test_partially_configured_bash_still_updates_missing_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            line = 'export PATH="$HOME/.local/bin:$PATH"'
            (home / ".bash_profile").write_text(line + "\n", encoding="utf-8")
            output = self.configure_path(home, "/bin/bash")
            self.assertIn("future terminals", output)
            self.assertEqual((home / ".bash_profile").read_text(), line + "\n")
            self.assertEqual((home / ".bashrc").read_text().count(line), 1)

    def test_unsafe_zdotdir_emits_no_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            target = home / "settings"
            target.mkdir()
            symlink = home / "linked-settings"
            symlink.symlink_to(target, target_is_directory=True)
            guidance = self.configure_path(home, "/bin/zsh", zdotdir=symlink)
            self.assertIn("Cannot safely update", guidance)
            self.assertNotIn("export PATH", guidance)
            self.assertEqual(list(target.iterdir()), [])

    def test_relative_zdotdir_is_not_written(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            guidance = self.configure_path(home, "/bin/zsh", zdotdir=Path("relative"))
            self.assertIn("Cannot safely update", guidance)

    def test_current_path_present_still_configures_future_terminals(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            directory = str(home / ".local/bin")
            output = self.configure_path(
                home, "/bin/zsh", path=f"/usr/bin:{directory}:/bin"
            )
            self.assertIn("future terminals", output)
            self.assertNotIn("To use it in this terminal", output)
            self.assertEqual(
                (home / ".zshrc").read_text().count(
                    'export PATH="$HOME/.local/bin:$PATH"'
                ),
                1,
            )

    def test_unknown_shell_stays_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            guidance = self.configure_path(home, "/bin/fish")
            self.assertIn("Shell /bin/fish is not recognized", guidance)
            self.assertNotIn("export PATH", guidance)
            self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
