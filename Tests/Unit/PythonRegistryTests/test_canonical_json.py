from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Scripts/lib"))

from pulsephone_contracts.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    encode_document,
    require_int64,
    require_uint64,
    validate_document,
)


class CanonicalJSONParityTests(unittest.TestCase):
    def test_shared_thirty_case_corpus(self) -> None:
        expectation_to_error = {
            "bom": "bom",
            "duplicateKey": "duplicateKey",
            "invalidStringControl": "invalidStringControl",
            "invalidSyntax": "invalidSyntax",
            "invalidUTF8": "invalidUTF8",
            "invalidUnicodeEscape": "invalidUnicodeEscape",
            "negativeZero": "negativeZero",
            "nonCanonical": "nonCanonical",
            "signedOverflow": "signedOverflow",
            "topLevelObject": "topLevelObject",
            "unsignedOverflow": "unsignedOverflow",
            "unsupportedNumber": "unsupportedNumber",
        }
        cases = []
        for line in (ROOT / "Fixtures/contracts/canonical-json/cases.v1.jsonl").read_bytes().splitlines():
            metadata = validate_document(line, 16 * 1024).root
            cases.append(metadata)
            payload = bytes.fromhex(metadata["inputHex"])
            expectation = metadata["expectation"]
            if expectation in expectation_to_error:
                with self.assertRaises(CanonicalJSONError, msg=metadata["name"]) as caught:
                    validate_document(payload, 1 << 20)
                self.assertEqual(caught.exception.kind, expectation_to_error[expectation])
                continue

            document = validate_document(payload, 1 << 20)
            self.assertEqual(document.exact_bytes, payload)
            self.assertEqual(encode_document(document.root), payload)
            if expectation == "canonical":
                self.assertEqual(document.sha256_hex, metadata["expectedSHA256"])
            elif expectation == "rejectUInt64":
                with self.assertRaises(CanonicalJSONError) as caught:
                    require_uint64(document.root["value"])
                self.assertEqual(caught.exception.kind, "integerNotUInt64")
            elif expectation == "rejectInt64":
                with self.assertRaises(CanonicalJSONError) as caught:
                    require_int64(document.root["value"])
                self.assertEqual(caught.exception.kind, "integerNotInt64")
            else:
                self.fail(f"unknown expectation {expectation}")
        self.assertEqual(len(cases), 30)

    def test_encoder_integer_domain_cap_and_domain_separator(self) -> None:
        root = {"z": [2, 1], "a": "e\u0301/é"}
        self.assertEqual(
            encode_document(root),
            '{"a":"e\u0301/é","z":[2,1]}'.encode("utf-8"),
        )
        golden = b'{"a":1}'
        document = validate_document(golden, len(golden))
        self.assertEqual(
            document.domain_separated_sha256_hex("pulsephone.test.canonical.v1"),
            "6205a75879c105dd19638e6cb661688c94eddaebc2139b9ea35c4b4f494bd106",
        )
        with self.assertRaises(CanonicalJSONError) as caught:
            validate_document(golden, len(golden) - 1)
        self.assertEqual(caught.exception.kind, "hardCapExceeded")
        with self.assertRaises(CanonicalJSONError) as caught:
            validate_document(golden, -1)
        self.assertEqual(caught.exception.kind, "invalidMaximumByteCount")


if __name__ == "__main__":
    unittest.main()
