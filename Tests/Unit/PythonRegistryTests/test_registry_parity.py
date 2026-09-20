from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Scripts/lib"))

from pulsephone_contracts.canonical_json import (  # noqa: E402
    domain_separated_sha256_hex,
    encode_document,
    sha256_hex,
    validate_document,
)
from pulsephone_contracts.generated import (  # noqa: E402
    GeneratedWireRegistryID,
    STANDARD_ERROR_DESCRIPTORS,
    StandardErrorCode,
    WIRE_ENTRIES,
    WIRE_SCHEMA_DESCRIPTORS,
)


class RegistryParityTests(unittest.TestCase):
    REGISTRY_FILES = [
        "facts-probe-wire.v1.json",
        "guihost-wire.v1.json",
        "helper-wire.v1.json",
        "runtime-operations.v1.json",
        "runtime-wire-messages.v1.json",
    ]

    def test_generated_python_matches_every_registry_field(self) -> None:
        standard = self.load_contract(ROOT / "Registries/standard-errors.v1.json")
        expected_standard = {entry["code"]: entry for entry in standard["entries"]}
        self.assertEqual({item.value for item in StandardErrorCode}, set(expected_standard))
        self.assertEqual(len(STANDARD_ERROR_DESCRIPTORS), 87)
        for descriptor in STANDARD_ERROR_DESCRIPTORS:
            source = expected_standard[descriptor.code.value]
            self.assertEqual(descriptor.family, source["family"])
            self.assertEqual(descriptor.default_cli_exit, source["defaultCLIExit"])
            self.assertEqual(descriptor.retryable, source["retryable"])
            self.assertEqual(descriptor.details_schema_id, source["detailsSchemaID"])
            self.assertEqual(descriptor.allowed_outcomes, tuple(source["allowedOutcomes"]))
            self.assertEqual(
                descriptor.allowed_lifecycle_phases,
                tuple(source["allowedLifecyclePhases"]),
            )
            self.assertEqual(
                descriptor.allowed_commit_states,
                tuple(source["allowedCommitStates"]),
            )

        expected_entries = {}
        for file_name in self.REGISTRY_FILES:
            registry = self.load_contract(ROOT / "Registries" / file_name)
            for entry in registry["entries"]:
                expected_entries[(registry["registryID"], entry["id"])] = entry
        self.assertEqual(len(expected_entries), 59)
        self.assertEqual(len(WIRE_ENTRIES), 59)
        for generated in WIRE_ENTRIES:
            source = expected_entries[(generated.registry_id.value, generated.id)]
            self.assertEqual(generated.numeric_message_type, source.get("numericMessageType"))
            self.assertEqual(generated.direction.value, source["direction"])
            self.assertEqual(
                tuple(item.value for item in generated.allowed_connection_states),
                tuple(source["allowedConnectionStates"]),
            )
            self.assertEqual(
                generated.request_schema_id.value if generated.request_schema_id else None,
                source.get("requestSchemaID"),
            )
            self.assertEqual(
                generated.response_schema_id.value if generated.response_schema_id else None,
                source.get("responseSchemaID"),
            )
            self.assertEqual(generated.association.value, source["association"])
            self.assertEqual(generated.terminal_policy.value, source["terminalPolicy"])
            self.assertEqual(generated.fd_policy.value, source["fdPolicy"])
            self.assertEqual(generated.payload_limit_class.value, source["payloadLimitClass"])
            self.assertEqual(
                tuple(item.value for item in generated.allowed_event_kinds),
                tuple(source["allowedEventKinds"]),
            )
            self.assertEqual(
                tuple(item.value for item in generated.allowed_error_codes),
                tuple(source["allowedErrorCodes"]),
            )

    def test_schema_descriptors_and_swift_raw_values_match(self) -> None:
        definitions = {}
        for path in sorted((ROOT / "Schemas/wire").glob("**/*.json")):
            self.collect_definitions(self.load_contract(path), path, definitions)
        self.assertEqual(len(definitions), 90)
        self.assertEqual(len(WIRE_SCHEMA_DESCRIPTORS), 90)
        for descriptor in WIRE_SCHEMA_DESCRIPTORS:
            source, path = definitions[descriptor.id.value]
            self.assertEqual(descriptor.source_relative_path, path.relative_to(ROOT).as_posix())
            self.assertEqual(
                descriptor.max_encoded_bytes,
                source.get("x-pulsephone-maxEncodedBytes"),
            )
            self.assertEqual(descriptor.property_names, tuple(sorted(source.get("properties", {}))))
            self.assertEqual(descriptor.required_property_names, tuple(source.get("required", [])))

        swift = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "Sources/PulsePhoneWire/Generated").glob("*.swift"))
        )
        raw_values = {item.value for item in StandardErrorCode}
        raw_values.update(item.id for item in WIRE_ENTRIES)
        raw_values.update(item.id.value for item in WIRE_SCHEMA_DESCRIPTORS)
        raw_values.update(item.value for item in GeneratedWireRegistryID)
        for raw_value in raw_values:
            self.assertIn(f'"{raw_value}"', swift, raw_value)

    def test_python_rebuilds_standard_and_wire_aggregate_hashes(self) -> None:
        standard_paths = [ROOT / "Registries/standard-errors.v1.json"] + sorted(
            (ROOT / "Schemas/details-schemas").glob("**/*.json")
        )
        standard_bytes = self.artifact_set_bytes(
            standard_paths,
            "standardErrorRegistry",
            "standard-errors.v3-20260822",
        )
        self.assertEqual(
            sha256_hex(standard_bytes),
            "753bbbbde92f2a9220f94000ad9e1d8546731e14e76e55f8be69fec600f44db8",
        )
        self.assertEqual(
            domain_separated_sha256_hex(
                "pulsephone.standard-error-registry-set.v1",
                standard_bytes,
            ),
            "0e9cdbee93d04400aa6dee3edc3e24f3e613d5eba77a3ecf0d825429bfe7dbde",
        )

        wire_paths = [ROOT / "Registries" / name for name in self.REGISTRY_FILES]
        wire_paths += sorted((ROOT / "Schemas/wire").glob("**/*.json"))
        wire_bytes = self.artifact_set_bytes(
            wire_paths,
            "wireRegistry",
            "wire-registry.v9-20260822",
        )
        self.assertEqual(
            sha256_hex(wire_bytes),
            "126acc151ce42642c901f73cd733d6af7ce00e28cb81f22c3a3b079528370606",
        )
        self.assertEqual(
            domain_separated_sha256_hex(
                "pulsephone.wire-registry-set.v1",
                wire_bytes,
            ),
            "85414363f1e84a4c9f8fe863319355beab20d2845aded1fb382f6d33094762dd",
        )

    def artifact_set_bytes(self, paths, set_id, revision) -> bytes:
        entries = []
        for path in sorted(paths, key=lambda item: item.relative_to(ROOT).as_posix()):
            exact = path.read_bytes()
            validate_document(exact, 1 << 20)
            entries.append(
                {
                    "relativePath": path.relative_to(ROOT).as_posix(),
                    "sha256": sha256_hex(exact),
                }
            )
        return encode_document(
            {
                "entries": entries,
                "revision": revision,
                "schemaVersion": 1,
                "setID": set_id,
            }
        )

    def load_contract(self, path: Path):
        return validate_document(path.read_bytes(), 1 << 20).root

    def collect_definitions(self, value, path, definitions) -> None:
        if isinstance(value, dict):
            if "$id" in value:
                self.assertNotIn(value["$id"], definitions)
                definitions[value["$id"]] = (value, path)
            for child in value.values():
                self.collect_definitions(child, path, definitions)
        elif isinstance(value, list):
            for child in value:
                self.collect_definitions(child, path, definitions)


if __name__ == "__main__":
    unittest.main()
