#!/usr/bin/python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
CATALOG_PATH = ROOT / "Registries/command-catalog.v1.json"
ERRORS_PATH = ROOT / "Registries/standard-errors.v1.json"
POLICY_PATH = ROOT / "Verification/evidence-policy.v1.json"
MATRIX_ROOT = ROOT / "Fixtures/product-matrix"
SYNTHETIC_UDID = "A" * 40
FORBIDDEN_ASSEMBLY_ERRORS = {
    "commandNotImplemented",
    "guiHostUnavailable",
    "guiIPCFailure",
    "internalFailure",
    "protocolViolation",
    "runtimeFailed",
    "transportFailure",
    "windowCreateFailed",
}

REQUIREMENT_IDS = [
    "T-005/legacy-basic-command-matrix-l4",
    "T-006/command-parameter-cap-mapping-matrix-l1",
    "T-006/device-command-oracle-matrix-l4",
    "T-006/mutating-command-no-automatic-retry-l3",
    "T-006/text-ipa-bounded-streaming-l4",
    "T-009/gui-help-docs-catalog-projection-l5",
    "T-012/public-command-human-json-result-l5",
]

RUNNER_FILTERS = {
    "T-006/command-parameter-cap-mapping-matrix-l1": (
        "ProductActionTests/testCommandCapsAndNoRetryProjection"
    ),
    "T-006/device-command-oracle-matrix-l4": (
        "ProductActionTests/testDeviceCommandOracleProjection"
    ),
    "T-006/mutating-command-no-automatic-retry-l3": (
        "ProductActionTests/testCommandCapsAndNoRetryProjection"
    ),
    "T-009/gui-help-docs-catalog-projection-l5": (
        "ProductActionTests/testGeneratedPublicProjectionAndReadmeAreCurrent"
    ),
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_canonical(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    value = json.loads(data)
    if canonical_bytes(value) != data:
        raise ValueError(f"noncanonical JSON: {path.relative_to(ROOT)}")
    if not isinstance(value, dict):
        raise ValueError(f"expected object: {path.relative_to(ROOT)}")
    return value


def subject(policy: dict[str, Any], subject_id: str) -> dict[str, Any]:
    matches = [
        row for row in policy["subjectSets"]
        if row["subjectSetID"] == subject_id
    ]
    if len(matches) != 1:
        raise ValueError(f"subject set: {subject_id}")
    return matches[0]


def cli_command_token(command_id: str, variant: str) -> str:
    if command_id.startswith("button."):
        return f"button {variant}"
    words = variant.split()
    if command_id == "runtime.status.device":
        return "runtime status"
    if command_id == "logs.clear.all":
        return "logs clear"
    if words[0] in {"developer-image", "element", "text"}:
        return variant
    return " ".join(words[:2] if words[0] in {
        "device", "diagnostics", "logs", "runtime", "self", "skill", "trace",
    } else words[:1])


def public_surface(catalog: dict[str, Any]) -> dict[str, Any]:
    products = catalog["productActions"]
    supporting = catalog["supportingActions"]
    features = catalog["features"]
    cli_rows = []
    gui_rows = []
    product_rows = []
    for row in products:
        projected = {
            "argumentSchemaID": row["argumentSchemaID"],
            "category": row["category"],
            "commandID": row["commandID"],
            "executionProfileID": row["executionProfileID"],
            "exposures": row["exposures"],
            "loggingProfileID": row["loggingProfileID"],
            "releaseScope": row["releaseScope"],
            "resultSchemaID": row["resultSchemaID"],
        }
        product_rows.append(projected)
        if "cli" in row["exposures"]:
            variant = row["cliVariant"]
            invocation = (
                f"button {variant}"
                if row["commandID"].startswith("button.")
                else variant
            )
            cli_rows.append({
                "argumentSchemaID": row["argumentSchemaID"],
                "category": row["category"],
                "commandID": row["commandID"],
                "commandToken": cli_command_token(row["commandID"], variant),
                "invocation": invocation,
                "releaseScope": row["releaseScope"],
                "resultSchemaID": row["resultSchemaID"],
            })
        if "gui" in row["exposures"]:
            surface = row["guiSurface"]
            gui_row = {
                "commandID": row["commandID"],
                "kind": surface["kind"],
                "releaseScope": row["releaseScope"],
            }
            if "order" in surface:
                gui_row["order"] = surface["order"]
            gui_rows.append(gui_row)
    toolbar_window = [
        row for row in gui_rows if row["kind"] in ("toolbar", "window")
    ]
    owner_bound = [
        row for row in gui_rows if row["kind"] == "ownerBoundInteraction"
    ]
    return {
        "cliRows": cli_rows,
        "counts": {
            "features": len(features),
            "guiToolbarWindow": len(toolbar_window),
            "ownerBoundInteractions": len(owner_bound),
            "productActions": len(products),
            "publicCLIVariants": len(cli_rows),
            "supportingActions": len(supporting),
        },
        "features": [{
            "exposures": row["exposures"],
            "featureID": row["featureID"],
            "releaseScope": row["releaseScope"],
        } for row in features],
        "guiRows": gui_rows,
        "matrixRevision": catalog["matrixRevision"],
        "productActions": product_rows,
        "schemaVersion": 1,
        "supportingActions": [{
            "parentCommandIDs": row["parentCommandIDs"],
            "releaseInheritance": row["releaseInheritance"],
            "resultSchemaID": row["resultSchemaID"],
            "shape": row["shape"],
            "supportingActionID": row["supportingActionID"],
        } for row in supporting],
    }


def behavior_matrix(
    catalog: dict[str, Any],
    policy: dict[str, Any],
) -> dict[str, Any]:
    products = {row["commandID"]: row for row in catalog["productActions"]}
    profiles = {
        row["executionProfileID"]: row
        for row in catalog["executionProfiles"]
    }
    mutating = subject(
        policy, "subject.actions.mutating-no-retry.v1"
    )["productActionIDs"]
    bounded = subject(
        policy, "subject.actions.bounded-streaming.v1"
    )["productActionIDs"]
    legacy = subject(
        policy, "subject.actions.legacy-basic.v1"
    )["productActionIDs"]
    retry_rows = []
    for command_id in mutating:
        profile = profiles[products[command_id]["executionProfileID"]]
        retry_rows.append({
            "automaticRetryPolicy": profile["automaticRetryPolicy"],
            "commandID": command_id,
        })
    oracle_rows = []
    for command_id in sorted(products):
        row = products[command_id]
        bindings = row["policyBindings"]
        if not bindings["candidateOrderIDs"]:
            continue
        oracle_rows.append({
            "candidateOrderIDs": bindings["candidateOrderIDs"],
            "commandID": command_id,
            "fallbackPolicyID": bindings["fallbackPolicyID"],
            "preparationGroupIDs": bindings["preparationGroupIDs"],
        })
    legacy_rule = next(
        row for row in catalog["compatibilityRules"]
        if row["ruleID"] == "compat.preparation.legacy-developer.v2"
    )
    return {
        "automaticRetryRows": retry_rows,
        "boundedStreamingCommandIDs": bounded,
        "deviceCommandOracleRows": oracle_rows,
        "legacyBasicCommandIDs": legacy,
        "legacyOSRange": {
            "maximumMajorExclusive": legacy_rule["parameters"][
                "maximumOSMajorExclusive"
            ],
            "minimumMajor": legacy_rule["parameters"]["minimumOSMajor"],
        },
        "parameterCaps": {
            "afcChunkBytes": 1_048_576,
            "appListDeadlineMilliseconds": 30_000,
            "appListRawPlistBytes": 1_048_576,
            "appListResultBytes": 262_144,
            "linearGestureFrameIntervalMilliseconds": 16,
            "linearGestureMaximumDurationMilliseconds": 30_000,
            "linearGestureMaximumFrames": 4_096,
            "linearGestureMaximumPayloadBytes": 524_288,
            "runtimeCommandPayloadBytes": 1_048_576,
            "textKeyboardCount": 100,
            "textUTF8Bytes": 65_536,
        },
        "schemaVersion": 1,
    }


def integration_coverage() -> dict[str, Any]:
    return {
        "criteria": [
            {
                "anchorPaths": [
                    "Tests/Unit/CommandCatalogTests/CommandMatrixCoverageTests.swift",
                    "Tests/Unit/CommandCatalogTests/GUIExposureTests.swift",
                    "Tests/Unit/CommandCatalogTests/NegativeExposureTests.swift",
                ],
                "criterionID": "contract",
                "requirementFamilies": ["T-009", "T-016"],
            },
            {
                "anchorPaths": [
                    "Fixtures/requirements/T-001/canonical-udid-collision-l1/case.v1.json",
                    "Fixtures/requirements/T-001/multi-device-target-selection-l4/case.v1.json",
                    "Fixtures/requirements/T-001/video-control-source-binding-l4/case.v1.json",
                    "Tests/Integration/GUIHostTests/VideoBindingTests.swift",
                ],
                "criterionID": "targetSafety",
                "requirementFamilies": ["T-001", "T-007", "T-014", "T-021"],
            },
            {
                "anchorPaths": [
                    "Tests/Integration/GUIHostTests/GUIHostOpenTests.swift",
                    "Tests/Integration/GUIHostTests/LiveToolbarGoldenTests.swift",
                    "Tests/Integration/GUIHostTests/LiveWindowTests.swift",
                    "Tests/Integration/GUIHostTests/MediaPermissionTests.swift",
                    "Tests/Integration/GUIHostTests/VideoBindingTests.swift",
                ],
                "criterionID": "gui",
                "requirementFamilies": ["T-008", "T-009", "T-011", "T-014"],
            },
            {
                "anchorPaths": [
                    "Tests/Unit/CLIContractTests/AppListCLITests.swift",
                    "Tests/Unit/CLIContractTests/ArgumentPreflightTests.swift",
                    "Tests/Unit/CLIContractTests/DevicePrepareCLITests.swift",
                    "Tests/Unit/CLIContractTests/OutputAdapterTests.swift",
                    "Tests/Unit/CLIContractTests/RuntimeStatusAndStopTests.swift",
                ],
                "criterionID": "cli",
                "requirementFamilies": ["T-006", "T-012", "T-015"],
            },
            {
                "anchorPaths": [
                    "GoHelpers/internal/direct/oneshot_contract_test.go",
                    "Tests/Integration/ProductActionTests/CommandSubmissionVerticalSliceTests.swift",
                    "Tests/Integration/ProductActionTests/PreparationProductIntegrationTests.swift",
                    "Tests/Integration/RuntimeBootstrapTests/AppListRuntimeTests.swift",
                    "Tests/Unit/LifecycleTests/StreamSessionTests.swift",
                    "Tests/Unit/PreparationCoordinatorTests/CoordinatorTests.swift",
                    "Tests/Unit/SchedulerTests/DeviceSchedulerTests.swift",
                ],
                "criterionID": "lifecycle",
                "requirementFamilies": [
                    "T-010", "T-013", "T-015", "T-020", "T-021"
                ],
            },
        ],
        "requiredRequirementFamilies": [
            "T-001", "T-006", "T-008", "T-009", "T-010", "T-011",
            "T-012", "T-013", "T-014", "T-015", "T-016", "T-020",
            "T-021",
        ],
        "schemaVersion": 1,
    }


def readme_bytes(
    surface: dict[str, Any],
    behavior: dict[str, Any],
    primary_hashes: dict[str, str],
) -> bytes:
    counts = surface["counts"]
    lines = [
        "<!-- Generated by Tests/Integration/ProductMatrixTests/product_matrix.py. -->",
        "# PulsePhone",
        "",
        "PulsePhone is a macOS 14+ command-line and live-control client for USB-connected iPhones. The public surface below is projected from the frozen command catalog; implementation evidence is not a release or physical-device compatibility claim.",
        "",
        "Use PulsePhone on supported iPhones without installing Xcode. It does not install or depend on WebDriver or an XCTest Runner.",
        "",
        "## Public Contract",
        "",
        f"- Command matrix: `{surface['matrixRevision']}`",
        f"- Product Actions: {counts['productActions']}",
        f"- Supporting Actions: {counts['supportingActions']}",
        f"- Non-command features: {counts['features']}",
        f"- Public CLI variants: {counts['publicCLIVariants']}",
        f"- GUI toolbar/window rows: {counts['guiToolbarWindow']}",
        f"- Owner-bound GUI interactions: {counts['ownerBoundInteractions']}",
        "",
        "## Install",
        "",
        "Install the latest signed, notarized macOS arm64 release:",
        "",
        "```sh",
        "curl -fsSL https://raw.githubusercontent.com/mengkaka/PulsePhone/main/Scripts/install-pulsephone | /bin/bash",
        "```",
        "",
        "The installer downloads `PulsePhone-macos-arm64.zip` and its `.sha256` file from the latest GitHub Release, verifies the archive, bundle ID, signing team, and Gatekeeper assessment, runs `PulsePhone self install`, then removes its temporary download. It installs to `~/Applications/PulsePhone.app` and provides `~/.local/bin/PulsePhone`; do not run it with `sudo`.",
        "",
        "For inspection before execution, download the script and read it locally before passing it to `/bin/bash`.",
        "",
        "### Agent Skill",
        "",
        "After the CLI is installed, publish the bundled PulsePhone skill for Codex, Claude Code, or both:",
        "",
        "```sh",
        "PulsePhone skill install --agent codex",
        "PulsePhone skill install --agent claude-code",
        "PulsePhone skill install --agent all",
        "```",
        "",
        "Install to another agent's absolute skill root with `PulsePhone skill install --skill-root /absolute/path`. Use `PulsePhone skill status` to inspect managed targets. If a managed skill was edited locally, rerun the install with `--force` only when replacing those managed files is intended.",
        "",
        "## OmniParser",
        "",
        "OmniParser is disabled by default, so element snapshots use local analysis and do not send screenshots to a network service. Use the whitelisted local configuration keys when needed; settings are stored under `~/Library/Application Support/PulsePhone/Configuration/` and are used by newly started device runtimes.",
        "",
        "```sh",
        "PulsePhone config --help",
        "PulsePhone config get omniparser.endpoint",
        "PulsePhone config set omniparser.endpoint https://omni.example.com/parse/",
        "PulsePhone config clear omniparser.endpoint",
        "```",
        "",
        "## CLI",
        "",
        "Every public command supports human output and `--json`; success is written to stdout, progress and human errors to stderr, and JSON terminal output is exactly one envelope.",
        "",
        "| Invocation | Command ID | Shape | Argument | Result | Scope |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for row in surface["cliRows"]:
        lines.append(
            f"| `PulsePhone {row['invocation']}` | `{row['commandID']}` | "
            f"`{row['category']}` | `{row['argumentSchemaID']}` | "
            f"`{row['resultSchemaID']}` | `{row['releaseScope']}` |"
        )
    lines.extend([
        "",
        "## Live GUI",
        "",
        "Toolbar order is catalog-owned and stable for a window lifetime. Pointer and keyboard interactions are owner-bound streams; Camera, Microphone, Input Monitoring, video, audio, and device control degrade independently.",
        "",
        "| Command ID | Surface | Order | Scope |",
        "| --- | --- | ---: | --- |",
    ])
    for row in surface["guiRows"]:
        order = str(row.get("order", "-"))
        lines.append(
            f"| `{row['commandID']}` | `{row['kind']}` | {order} | "
            f"`{row['releaseScope']}` |"
        )
    caps = behavior["parameterCaps"]
    lines.extend([
        "",
        "## Execution Boundaries",
        "",
        "- Commands bind to one canonical UDID and connection epoch; unverified video source mappings remain identity placeholders.",
        "- Accepted mutating work is never retried automatically.",
        "- Finite commands may wait for implicit capability preparation and then re-plan; streams fail fast while preparation is incomplete.",
        f"- Text input is capped at {caps['textUTF8Bytes']} UTF-8 bytes; IPA transfer uses chunks of at most {caps['afcChunkBytes']} bytes.",
        f"- App listing has a {caps['appListDeadlineMilliseconds']} ms running deadline, rejects raw plist pages above {caps['appListRawPlistBytes']} bytes, and caps the normalized result at {caps['appListResultBytes']} bytes.",
        f"- Linear gestures are capped at {caps['linearGestureMaximumDurationMilliseconds']} ms, {caps['linearGestureMaximumFrames']} frames, and {caps['linearGestureMaximumPayloadBytes']} encoded bytes.",
        "- iOS 14 through 16 uses only the cataloged legacy subset; iOS 17+ uses modern routes. No cross-OS fallback is allowed after commit.",
        "",
        "## Verification",
        "",
        "```sh",
        "make check",
        "make verify-m2-gate",
        "```",
        "",
        "Tracked projections:",
        "",
        f"- `Fixtures/product-matrix/public-surface.v1.json` `{primary_hashes['public-surface.v1.json']}`",
        f"- `Fixtures/product-matrix/behavior-matrix.v1.json` `{primary_hashes['behavior-matrix.v1.json']}`",
        f"- `Fixtures/product-matrix/integration-coverage.v1.json` `{primary_hashes['integration-coverage.v1.json']}`",
        "",
    ])
    return "\n".join(lines).encode("utf-8")


def requirement_outputs(
    surface: dict[str, Any],
    behavior: dict[str, Any],
    primary_hashes: dict[str, str],
    readme: bytes,
    errors: dict[str, Any],
) -> dict[str, bytes]:
    outputs: dict[str, bytes] = {}
    public_cli_ids = [row["commandID"] for row in surface["cliRows"]]
    gui_ids = [row["commandID"] for row in surface["guiRows"]]
    retry_ids = [row["commandID"] for row in behavior["automaticRetryRows"]]
    expected_by_id: dict[str, dict[str, Any]] = {
        "T-005/legacy-basic-command-matrix-l4": {
            "commandIDs": behavior["legacyBasicCommandIDs"],
            "deviceEvidenceRequired": True,
            "osRange": behavior["legacyOSRange"],
        },
        "T-006/command-parameter-cap-mapping-matrix-l1": {
            "outcome": "passed",
            "parameterCaps": behavior["parameterCaps"],
        },
        "T-006/device-command-oracle-matrix-l4": {
            "oracleRows": behavior["deviceCommandOracleRows"],
            "outcome": "passed",
        },
        "T-006/mutating-command-no-automatic-retry-l3": {
            "automaticRetryPolicy": "never",
            "commandIDs": retry_ids,
            "outcome": "passed",
        },
        "T-006/text-ipa-bounded-streaming-l4": {
            "commandIDs": behavior["boundedStreamingCommandIDs"],
            "deviceEvidenceRequired": True,
            "ipaChunkBytes": behavior["parameterCaps"]["afcChunkBytes"],
            "textUTF8Bytes": behavior["parameterCaps"]["textUTF8Bytes"],
        },
        "T-009/gui-help-docs-catalog-projection-l5": {
            "counts": surface["counts"],
            "guiCommandIDs": gui_ids,
            "outcome": "passed",
            "publicCLICommandIDs": public_cli_ids,
            "readmeSHA256": sha256(readme),
        },
        "T-012/public-command-human-json-result-l5": {
            "errorExitCodes": sorted({
                row["defaultCLIExit"] for row in errors["entries"]
            }),
            "humanChannels": {
                "failure": "stderr",
                "progress": "stderr",
                "success": "stdout",
            },
            "jsonTerminalEnvelopeKeys": [
                "commandID", "metadata", "ok", "result", "schemaVersion",
                "target",
            ],
            "publicCLICommandIDs": public_cli_ids,
            "successExitCode": 0,
        },
    }
    clock_by_id = {
        "T-005/legacy-basic-command-matrix-l4": "real",
        "T-006/command-parameter-cap-mapping-matrix-l1": "virtual",
        "T-006/device-command-oracle-matrix-l4": "virtual",
        "T-006/mutating-command-no-automatic-retry-l3": "virtual",
        "T-006/text-ipa-bounded-streaming-l4": "virtual",
        "T-009/gui-help-docs-catalog-projection-l5": "virtual",
        "T-012/public-command-human-json-result-l5": "virtual",
    }
    for requirement_id in REQUIREMENT_IDS:
        family, slug = requirement_id.split("/", 1)
        definition_path = (
            ROOT / "Verification/release-requirements" / family
            / f"{slug}.v1.json"
        )
        definition = load_canonical(definition_path)
        input_value = {
            "behaviorMatrixSHA256": primary_hashes["behavior-matrix.v1.json"],
            "integrationCoverageSHA256": primary_hashes[
                "integration-coverage.v1.json"
            ],
            "matrixRevision": surface["matrixRevision"],
            "publicSurfaceSHA256": primary_hashes["public-surface.v1.json"],
            "requirementID": requirement_id,
            "schemaVersion": 1,
        }
        input_data = canonical_bytes(input_value)
        case_value = {
            "caseClass": definition["caseClass"],
            "caseKey": requirement_id,
            "clockMode": clock_by_id[requirement_id],
            "contractRefs": definition["contractRefs"],
            "expectedRef": "expected.v1.json",
            "fixtureExecutionProfileID": definition[
                "fixtureExecutionProfileID"
            ],
            "inputRefs": [{
                "relativePath": "input/input.v1.json",
                "sha256": sha256(input_data),
            }],
            "level": definition["level"],
            "preconditions": [],
            "primaryVerificationID": definition["verificationID"],
            "privacyClass": "synthetic",
            "schemaVersion": 1,
            "title": definition["title"],
            "verificationIDs": [definition["verificationID"]],
        }
        root = f"Fixtures/requirements/{requirement_id}"
        outputs[f"{root}/case.v1.json"] = canonical_bytes(case_value)
        outputs[f"{root}/expected.v1.json"] = canonical_bytes(
            expected_by_id[requirement_id]
        )
        outputs[f"{root}/input/input.v1.json"] = input_data
        if requirement_id in RUNNER_FILTERS:
            adapter = {
                "adapterKind": "swiftTest",
                "executionSuiteID": definition["executionSuiteID"],
                "invocation": {
                    "swiftTest": {
                        "filter": RUNNER_FILTERS[requirement_id],
                        "testTarget": "PulsePhoneProductMatrixTests",
                    }
                },
                "oracle": {
                    "fixtureExpected": {
                        "fixtureRelativePath": f"{root}/"
                    }
                },
                "oracleKind": "fixtureExpected",
                "requirementID": requirement_id,
                "schemaVersion": 1,
            }
            outputs[
                f"Verification/runner-adapters/{requirement_id}.v1.json"
            ] = canonical_bytes(adapter)
    return outputs


def expected_outputs() -> dict[str, bytes]:
    catalog = load_canonical(CATALOG_PATH)
    errors = load_canonical(ERRORS_PATH)
    policy = load_canonical(POLICY_PATH)
    surface = public_surface(catalog)
    behavior = behavior_matrix(catalog, policy)
    coverage = integration_coverage()
    primary = {
        "behavior-matrix.v1.json": canonical_bytes(behavior),
        "integration-coverage.v1.json": canonical_bytes(coverage),
        "public-surface.v1.json": canonical_bytes(surface),
    }
    primary_hashes = {name: sha256(data) for name, data in primary.items()}
    outputs = {
        f"Fixtures/product-matrix/{name}": data
        for name, data in primary.items()
    }
    readme = readme_bytes(surface, behavior, primary_hashes)
    outputs["README.md"] = readme
    outputs.update(requirement_outputs(
        surface, behavior, primary_hashes, readme, errors
    ))
    return outputs


def write_outputs(outputs: dict[str, bytes]) -> None:
    for relative, data in outputs.items():
        path = ROOT / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.chmod(path, 0o644)


def check_outputs(outputs: dict[str, bytes]) -> None:
    failures = []
    for relative, expected in outputs.items():
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"missing {relative}")
            continue
        actual = path.read_bytes()
        if actual != expected:
            failures.append(f"stale {relative}")
    actual_matrix = {
        path.relative_to(ROOT).as_posix()
        for path in MATRIX_ROOT.iterdir()
        if path.is_file()
    }
    expected_matrix = {
        relative for relative in outputs
        if relative.startswith("Fixtures/product-matrix/")
    }
    if actual_matrix != expected_matrix:
        failures.append("product matrix file set mismatch")
    for criterion in integration_coverage()["criteria"]:
        for relative in criterion["anchorPaths"]:
            if not (ROOT / relative).is_file():
                failures.append(f"missing integration anchor {relative}")
    if failures:
        raise SystemExit("\n".join(failures))


def bundled_command_cases() -> dict[str, list[str]]:
    target = ["--udid", SYNTHETIC_UDID]
    return {
        "app.install": ["install", "--path", "/tmp/PulsePhone-Smoke.ipa", *target],
        "app.list": ["apps", *target],
        "app.launch": ["launch", "--bundle-id", "com.example.smoke", *target],
        "app.uninstall": ["uninstall", "--bundle-id", "com.example.smoke", *target],
        "button.appSwitcher": ["button", "app-switcher", *target],
        "button.home": ["button", "home", *target],
        "button.lock": ["button", "lock", *target],
        "button.mute": ["button", "mute", *target],
        "button.volumeDown": ["button", "volume-down", *target],
        "button.volumeUp": ["button", "volume-up", *target],
        "catalog.commands": ["commands"],
        "developerImage.check": ["developer-image", "check", *target],
        "developerImage.list": ["developer-image", "list"],
        "device.info": ["device", "info", *target],
        "device.list": ["devices"],
        "device.prepare": ["device", "prepare", *target],
        "device.rotate": ["rotate", "--direction", "left", *target],
        "device.status": ["status", *target],
        "diagnostics.start": ["diagnostics", "start", *target],
        "diagnostics.stop": ["diagnostics", "stop", *target],
        "element.snapshot": ["element", "snapshot", *target],
        "live.launch": ["live", *target],
        "logs.clear.all": ["logs", "clear", "--all"],
        "logs.clear.device": ["logs", "clear", *target],
        "logs.prune": ["logs", "prune"],
        "product.version": ["version"],
        "runtime.status.device": ["runtime", "status", *target],
        "runtime.status.global": ["runtime", "status"],
        "runtime.stop": ["stop", *target],
        "screenshot.cli": [
            "screenshot", "--output", "/tmp/PulsePhone-Smoke.png", *target,
        ],
        "text.clear": ["text", "clear", *target],
        "text.cursor": [
            "text", "cursor", "--move", "right", "--count", "1", *target,
        ],
        "text.inputSource.next": ["text", "input-source", "next", *target],
        "text.key": ["text", "key", "--key", "a", *target],
        "text.type": ["type", "--text", "smoke", *target],
        "touch.drag": [
            "drag", "--from", "0,0", "--to", "1,1", "--duration", "100", *target,
        ],
        "touch.swipe": [
            "swipe", "--from", "0,0", "--to", "1,1", "--duration", "100", *target,
        ],
        "touch.tap": ["tap", "--x", "0.25", "--y", "0.75", *target],
        "trace.start": ["trace", "start", *target],
        "trace.stop": ["trace", "stop", *target],
    }


def gui_host_pids(executable: Path) -> set[int]:
    expected = f"{executable} --gui-host"
    output = subprocess.run(
        ["/bin/ps", "-axo", "pid=,command="],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    result: set[int] = set()
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == expected:
            result.add(int(fields[0]))
    return result


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def terminate_new_gui_hosts(executable: Path, baseline: set[int]) -> None:
    targets = sorted(gui_host_pids(executable) - baseline)
    for pid in targets:
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 2
    while targets and time.monotonic() < deadline:
        targets = [pid for pid in targets if process_exists(pid)]
        if targets:
            time.sleep(0.02)
    for pid in targets:
        os.kill(pid, signal.SIGKILL)


def invoke_bundle(
    executable: Path,
    arguments: list[str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(executable), *arguments, "--json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=70,
    )


def bundled_public_surface_smoke(bundle: Path) -> None:
    executable = bundle.resolve() / "Contents/MacOS/PulsePhone"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise SystemExit(f"invalid bundle executable: {executable}")
    surface = load_canonical(MATRIX_ROOT / "public-surface.v1.json")
    expected_ids = [row["commandID"] for row in surface["cliRows"]]
    cases = bundled_command_cases()
    static_help_ids = {
        "self.install", "skill.install", "skill.status", "skill.uninstall",
    }
    non_destructive_ids = set(expected_ids) - static_help_ids
    if len(expected_ids) != 44 or non_destructive_ids != set(cases):
        raise SystemExit("public command case set mismatch")
    errors = load_canonical(ERRORS_PATH)
    exits = {row["code"]: row["defaultCLIExit"] for row in errors["entries"]}
    baseline_gui_hosts = gui_host_pids(executable)
    failures: list[str] = []
    try:
        for command_id in expected_ids:
            if command_id in static_help_ids:
                result = subprocess.run(
                    [str(executable), *command_id.split("."), "--help"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=10,
                )
                command_path = command_id.replace(".", " ")
                if result.returncode != 0 or result.stderr or command_path not in result.stdout:
                    failures.append(f"{command_id}: static help route failed")
                continue
            result = invoke_bundle(executable, cases[command_id])
            stdout_lines = [line for line in result.stdout.splitlines() if line]
            if len(stdout_lines) != 1 or result.stderr:
                failures.append(
                    f"{command_id}: stdoutLines={len(stdout_lines)} stderr={result.stderr!r}"
                )
                continue
            try:
                envelope = json.loads(stdout_lines[0])
            except json.JSONDecodeError as error:
                failures.append(f"{command_id}: invalid JSON: {error}")
                continue
            if envelope.get("commandID") != command_id:
                failures.append(
                    f"{command_id}: projected commandID={envelope.get('commandID')!r}"
                )
                continue
            error = envelope.get("error")
            code = error.get("code") if isinstance(error, dict) else None
            if code in FORBIDDEN_ASSEMBLY_ERRORS:
                failures.append(f"{command_id}: unassembled production path: {code}")
                continue
            expected_exit = 0 if envelope.get("ok") is True else exits.get(code)
            if expected_exit is None or result.returncode != expected_exit:
                failures.append(
                    f"{command_id}: exit={result.returncode} "
                    f"expected={expected_exit} code={code}"
                )
    finally:
        try:
            invoke_bundle(executable, ["stop", "--udid", SYNTHETIC_UDID])
        except (OSError, subprocess.SubprocessError):
            pass
        terminate_new_gui_hosts(executable, baseline_gui_hosts)
    if failures:
        raise SystemExit("\n".join(failures))


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--smoke-bundle")
    arguments = parser.parse_args()
    if arguments.smoke_bundle:
        bundled_public_surface_smoke(Path(arguments.smoke_bundle))
        print("pulsephone-bundled-public-surface.v1 state=passed variants=44")
        return 0
    outputs = expected_outputs()
    if arguments.write:
        write_outputs(outputs)
    else:
        check_outputs(outputs)
    print(
        "pulsephone-product-matrix.v1 "
        f"state={'written' if arguments.write else 'passed'} "
        f"files={len(outputs)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
