from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts" / "element-analyzer-benchmark"
LOADER = importlib.machinery.SourceFileLoader("element_analyzer_benchmark", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None and SPEC.loader is not None
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


def engine(status="succeeded", elapsed=10, inference=7, queue=1):
    return {
        "backend": "test-backend",
        "candidateCount": 2,
        "elapsedMilliseconds": elapsed,
        "inferenceMilliseconds": inference,
        "inputHeight": 200,
        "inputWidth": 100,
        "profileID": "profile.v1",
        "queueWaitMilliseconds": queue,
        "stageTimings": {
            "inputEncodeMicroseconds": 100,
            "requestEncodeMicroseconds": 20,
            "resizeAndColorSpaceMicroseconds": 200,
            "responseDecodeMicroseconds": 30,
            "transportOverheadMicroseconds": 40,
            "transportRoundTripMicroseconds": 7000,
        },
        "status": status,
        "version": "version.v1",
    }


def envelope(raw_udid="secret-device", secret_text="private page text"):
    attempt = {
        "errorCode": None,
        "failureStage": None,
        "provider": "dvt",
        "status": "succeeded",
        "timings": {
            "captureMicroseconds": 100,
            "queueWaitMicroseconds": 10,
            "serviceCloseMicroseconds": 20,
            "serviceOpenMicroseconds": 30,
            "totalMicroseconds": 160,
        },
    }
    return {
        "commandID": "element.snapshot",
        "ok": True,
        "result": {
            "capture": {
                "attempts": [attempt],
                "pixelHeight": 200,
                "pixelWidth": 100,
                "provider": "dvt",
                "sha256": "a" * 64,
            },
            "degradationReasons": [],
            "degraded": False,
            "elements": [{"label": secret_text}, {"label": None}],
            "engines": {
                "appleRegion": engine(),
                "omniparser": engine(),
                "vision": engine(),
            },
            "snapshotGeneration": 4,
            "timings": {
                "analyzerWallMilliseconds": 12,
                "annotationMilliseconds": None,
                "captureMilliseconds": 5,
                "correctionMilliseconds": 1,
                "fusionMilliseconds": 1,
                "sourceDecodeMicroseconds": 250,
            },
        },
        "schemaVersion": 1,
        "target": {"scope": "device", "udid": raw_udid},
    }


class FakeRunner:
    def __init__(self, snapshots):
        self.commands = []
        self.snapshots = list(snapshots)

    def __call__(self, command, timeout):
        self.commands.append((list(command), timeout))
        if command[1] == "stop":
            output = {"commandID": "runtime.stop", "ok": True, "result": {}}
        else:
            output = self.snapshots.pop(0)
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=json.dumps(output).encode("utf-8"),
            stderr=b"",
        )


def arguments(phase="warm", runs=2, warmups=1):
    return argparse.Namespace(
        phase=phase,
        pulsephone="/fake/PulsePhone",
        runs=runs,
        stop_timeout_seconds=30.0,
        timeout_seconds=60.0,
        udid="secret-device",
        warmups=warmups,
    )


class ElementAnalyzerBenchmarkTests(unittest.TestCase):
    def test_warmups_are_excluded_and_content_is_redacted(self):
        runner = FakeRunner([envelope(), envelope(), envelope()])
        with mock.patch.object(
            benchmark, "environment_metadata", return_value={"deviceIdentityHash": "b" * 64}
        ), mock.patch.object(
            benchmark, "source_metadata", return_value={"commit": "c" * 40, "trackedTreeDirty": False}
        ):
            document = benchmark.collect(arguments(), runner=runner)
        encoded = benchmark.encode_document(document)

        self.assertEqual(document["status"], "ok")
        self.assertEqual(len(document["runs"]), 2)
        self.assertEqual(document["summary"]["successfulRunCount"], 2)
        self.assertEqual(
            document["runs"][0]["engines"]["vision"][
                "stageTimingsMicroseconds"
            ][
                "transportRoundTripMicroseconds"
            ],
            7000,
        )
        self.assertNotIn(b"private page text", encoded)
        self.assertNotIn(b"secret-device", encoded)
        self.assertNotIn(("a" * 64).encode("ascii"), encoded)
        self.assertEqual(document["stageCoverage"]["transport"], "reported")
        self.assertNotIn(
            "preprocessAndTransportResidualMilliseconds",
            document["runs"][0]["engines"]["vision"],
        )

    def test_cold_phase_stops_runtime_before_each_run(self):
        runner = FakeRunner([envelope(), envelope()])
        with mock.patch.object(
            benchmark, "environment_metadata", return_value={}
        ), mock.patch.object(benchmark, "source_metadata", return_value={}):
            document = benchmark.collect(
                arguments(phase="cold", runs=2, warmups=0),
                runner=runner,
            )

        self.assertEqual(document["status"], "ok")
        self.assertEqual(
            [command[0][1] for command in runner.commands],
            ["stop", "element", "stop", "element"],
        )

    def test_failure_is_bounded_and_does_not_copy_stderr(self):
        def runner(command, timeout):
            output = {
                "commandID": "element.snapshot",
                "error": {"code": "deviceDisconnected", "message": "private"},
                "ok": False,
                "schemaVersion": 1,
                "target": {"scope": "device", "udid": "secret-device"},
            }
            return subprocess.CompletedProcess(
                command,
                1,
                stdout=json.dumps(output).encode("utf-8"),
                stderr=b"secret-device and private page text",
            )

        run = benchmark.invoke_snapshot(
            "/fake/PulsePhone",
            "secret-device",
            10,
            "reconnect",
            0,
            runner,
        )
        encoded = benchmark.encode_document(run)

        self.assertEqual(run["status"], "error")
        self.assertEqual(run["errorCode"], "deviceDisconnected")
        self.assertNotIn(b"secret-device", encoded)
        self.assertNotIn(b"private", encoded)

    def test_rejects_inconsistent_transport_stage_timing(self):
        invalid = envelope()["result"]
        invalid["engines"]["omniparser"]["stageTimings"][
            "transportOverheadMicroseconds"
        ] = 7001
        with self.assertRaises(benchmark.AnalyzerBenchmarkError):
            benchmark.sanitize_result(
                invalid,
                phase="warm",
                sequence=0,
                wall_microseconds=1,
            )

    def test_environment_hashes_identity_and_report_is_bounded(self):
        with tempfile.NamedTemporaryFile() as executable:
            executable.write(b"binary")
            executable.flush()
            metadata = benchmark.environment_metadata(
                "secret-device",
                executable.name,
            )
        encoded = benchmark.encode_document(metadata)

        self.assertEqual(len(metadata["deviceIdentityHash"]), 64)
        self.assertEqual(len(metadata["pulsephoneSHA256"]), 64)
        self.assertNotIn(b"secret-device", encoded)
        with self.assertRaises(benchmark.AnalyzerBenchmarkError):
            benchmark.encode_document({"large": "x" * benchmark.MAX_REPORT_BYTES})

    def test_percentiles_use_nearest_rank(self):
        values = list(range(1, 31))
        self.assertEqual(benchmark.nearest_rank(values, 0.50), 15)
        self.assertEqual(benchmark.nearest_rank(values, 0.95), 29)

    def test_phase_defaults_do_not_require_explicit_zero_warmups(self):
        with tempfile.NamedTemporaryFile() as executable:
            Path(executable.name).chmod(0o700)
            first = benchmark.parse_args([
                "--pulsephone",
                executable.name,
                "--udid",
                "device",
                "--phase",
                "first",
                "--runs",
                "1",
            ])
            warm = benchmark.parse_args([
                "--pulsephone",
                executable.name,
                "--udid",
                "device",
            ])

        self.assertEqual(first.warmups, 0)
        self.assertEqual(warm.warmups, 2)


if __name__ == "__main__":
    unittest.main()
