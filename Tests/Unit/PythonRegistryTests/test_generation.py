from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Scripts/lib"))


class PythonGenerationTests(unittest.TestCase):
    GENERATED_FILES = ["__init__.py", "registry.py"]

    def test_fresh_staging_and_tracked_output_are_exact(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pulsephone-python-generation-") as temporary:
            temporary_root = Path(temporary)
            staging_root = temporary_root / "staging"
            staging_root.mkdir()
            (staging_root / "stale").write_text("stale", encoding="utf-8")
            staged = self.run_generator("--stage-only", staging_root)
            self.assertEqual(staged.returncode, 0, staged.stdout)
            self.assertFalse((staging_root / "stale").exists())
            generated_root = (
                staging_root / "Scripts/lib/pulsephone_contracts/generated"
            )
            self.assertEqual(
                sorted(item.name for item in generated_root.iterdir()),
                self.GENERATED_FILES,
            )

            verified = self.run_generator(
                "--verify",
                temporary_root / "verify-staging",
                ROOT / "Scripts/lib/pulsephone_contracts/generated",
            )
            self.assertEqual(verified.returncode, 0, verified.stdout)

    def test_single_generator_and_no_parallel_python_allowlist(self) -> None:
        generator_files = [
            item.name
            for item in (ROOT / "Scripts").iterdir()
            if "generate-registr" in item.name
        ]
        self.assertEqual(
            sorted(generator_files),
            ["generate-registries"],
        )
        generated_root = ROOT / "Scripts/lib/pulsephone_contracts/generated"
        self.assertEqual(
            sorted(item.name for item in generated_root.iterdir()),
            self.GENERATED_FILES,
        )
        for path in (ROOT / "Scripts/lib/pulsephone_contracts").rglob("*.py"):
            if generated_root in path.parents:
                continue
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("class StandardErrorCode", source, str(path))
            self.assertNotIn("class RuntimeOperationID", source, str(path))
            self.assertNotIn("WIRE_ENTRIES =", source, str(path))

    def run_generator(
        self,
        action: str,
        staging_root: Path,
        tracked_root: Path = None,
    ) -> subprocess.CompletedProcess:
        arguments = [
            str(ROOT / "Scripts/generate-registries"),
            "python",
            action,
            "--staging-root",
            str(staging_root),
        ]
        if tracked_root is not None:
            arguments += ["--tracked-root", str(tracked_root)]
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(
            arguments,
            cwd=ROOT,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
