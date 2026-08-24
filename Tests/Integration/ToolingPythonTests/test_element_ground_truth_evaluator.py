import copy
import importlib.machinery
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts" / "element-ground-truth-evaluator"
LOADER = importlib.machinery.SourceFileLoader("element_ground_truth_evaluator", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
evaluator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = evaluator
SPEC.loader.exec_module(evaluator)

GROUND_TRUTH_PATH = (
    ROOT / "Fixtures" / "element-current-viewport" / "synthetic-ground-truth.v1.json"
)
PREDICTIONS_PATH = (
    ROOT / "Fixtures" / "element-current-viewport" / "synthetic-predictions.v1.json"
)


class ElementGroundTruthEvaluatorTests(unittest.TestCase):
    def documents(self):
        ground_truth, ground_truth_digest = evaluator.load_document(GROUND_TRUTH_PATH)
        predictions, predictions_digest = evaluator.load_document(PREDICTIONS_PATH)
        return ground_truth, predictions, ground_truth_digest, predictions_digest

    def test_synthetic_fixture_reports_metrics_without_satisfying_release_gate(self):
        ground_truth, predictions, ground_truth_digest, predictions_digest = self.documents()
        report = evaluator.evaluate_documents(
            ground_truth,
            predictions,
            ground_truth_digest,
            predictions_digest,
        )

        self.assertEqual(report["protocol"], evaluator.PROTOCOL)
        self.assertEqual(report["caseCount"], 2)
        self.assertEqual(report["metrics"]["truthCount"], 6)
        self.assertEqual(report["metrics"]["predictionCount"], 7)
        self.assertEqual(report["metrics"]["matchedCount"], 6)
        self.assertEqual(report["metrics"]["precision"], 0.857143)
        self.assertEqual(report["metrics"]["recall"], 1.0)
        self.assertEqual(report["metrics"]["unknownSemanticAccuracy"], 1.0)
        self.assertEqual(report["byType"]["controlCandidate"]["precision"], 0.8)
        self.assertEqual(report["byType"]["text"]["recall"], 1.0)
        self.assertEqual(report["byType"]["unknown"]["recall"], 1.0)
        self.assertEqual(report["coverageByVisualKind"]["icon"]["recall"], 1.0)
        self.assertEqual(report["coverageByVisualKind"]["icon"]["truthCount"], 2)
        self.assertEqual(report["correction"]["caseCount"], 1)
        self.assertEqual(report["correction"]["baseline"]["precision"], 0.5)
        self.assertEqual(report["correction"]["baseline"]["recall"], 0.5)
        self.assertEqual(report["correction"]["final"]["recall"], 1.0)
        self.assertEqual(report["correction"]["meanIoUGain"], 0.444444)
        self.assertEqual(report["correction"]["recallGain"], 0.5)
        self.assertFalse(report["releaseGate"]["datasetCriteriaSatisfied"])
        self.assertFalse(report["releaseGate"]["privacyApprovalPresent"])
        self.assertEqual(report["releaseGate"]["reason"], "syntheticDataset")

    def test_cli_output_is_deterministic_and_contains_no_input_paths(self):
        command = [
            sys.executable,
            str(SCRIPT),
            "--ground-truth",
            str(GROUND_TRUTH_PATH),
            "--predictions",
            str(PREDICTIONS_PATH),
        ]
        first = subprocess.run(command, check=True, capture_output=True, text=True)
        second = subprocess.run(command, check=True, capture_output=True, text=True)

        self.assertEqual(first.stdout, second.stdout)
        report = json.loads(first.stdout)
        self.assertNotIn(str(ROOT), first.stdout)
        self.assertEqual(report["inputDigests"]["groundTruthSHA256"], evaluator.load_document(GROUND_TRUTH_PATH)[1])
        self.assertEqual(report["inputDigests"]["predictionsSHA256"], evaluator.load_document(PREDICTIONS_PATH)[1])

    def test_validation_rejects_mismatch_duplicates_and_invalid_unknown_fields(self):
        ground_truth, predictions, ground_truth_digest, predictions_digest = self.documents()

        mismatched = copy.deepcopy(predictions)
        mismatched["datasetID"] = "different-dataset"
        with self.assertRaises(evaluator.EvaluationError):
            evaluator.evaluate_documents(
                ground_truth,
                mismatched,
                ground_truth_digest,
                predictions_digest,
            )

        duplicate = copy.deepcopy(predictions)
        duplicate["cases"][0]["elements"][1]["predictionID"] = duplicate["cases"][0]["elements"][0]["predictionID"]
        with self.assertRaises(evaluator.EvaluationError):
            evaluator.evaluate_documents(
                ground_truth,
                duplicate,
                ground_truth_digest,
                predictions_digest,
            )

        invalid_unknown = copy.deepcopy(ground_truth)
        invalid_unknown["cases"][0]["elements"][0]["expectedUnknown"] = ["privateSelector"]
        with self.assertRaises(evaluator.EvaluationError):
            evaluator.evaluate_documents(
                invalid_unknown,
                predictions,
                ground_truth_digest,
                predictions_digest,
            )

        unapproved_real = copy.deepcopy(ground_truth)
        unapproved_real["privacyClassification"] = "approvedReal"
        with self.assertRaises(evaluator.EvaluationError):
            evaluator.evaluate_documents(
                unapproved_real,
                predictions,
                ground_truth_digest,
                predictions_digest,
            )

    def test_matching_uses_confidence_order_and_one_to_one_truth_assignment(self):
        truth = [{
            "truthID": "truth",
            "elementType": "controlCandidate",
            "expectedUnknown": [],
            "frame": {"x": 0.0, "y": 0.0, "width": 20.0, "height": 20.0},
            "tapTarget": {"x": 10.0, "y": 10.0},
            "visualKind": "icon",
        }]
        predictions = [
            {
                "predictionID": "low",
                "elementType": "controlCandidate",
                "confidence": 0.1,
                "frame": {"x": 0.0, "y": 0.0, "width": 20.0, "height": 20.0},
                "center": {"x": 10.0, "y": 10.0},
                **{field: None for field in evaluator.UNKNOWN_FIELDS},
            },
            {
                "predictionID": "high",
                "elementType": "controlCandidate",
                "confidence": 0.9,
                "frame": {"x": 1.0, "y": 1.0, "width": 18.0, "height": 18.0},
                "center": {"x": 10.0, "y": 10.0},
                **{field: None for field in evaluator.UNKNOWN_FIELDS},
            },
        ]

        matches = evaluator.match_case(truth, predictions, 0.5)
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0][1]["predictionID"], "high")

    def test_production_element_shape_uses_reported_coordinate_systems(self):
        viewport = {
            "pixelWidth": 120.0,
            "pixelHeight": 240.0,
            "logicalWidth": 60.0,
            "logicalHeight": 120.0,
        }
        element = {
            "center": {
                "pixel": {"x": 30, "y": 50},
                "logicalPoints": {"x": 15, "y": 25},
                "normalized": {"x": 0.25, "y": 0.208333333},
            },
            "confidence": 0.9,
            "elementType": "controlCandidate",
            "enabled": None,
            "frame": {
                "pixel": {"x": 10, "y": 20, "width": 40, "height": 60},
                "logicalPoints": {"x": 5, "y": 10, "width": 20, "height": 30},
                "normalized": {
                    "x": 0.083333333,
                    "y": 0.083333333,
                    "width": 0.333333334,
                    "height": 0.25,
                },
            },
            "hittable": None,
            "identifier": None,
            "label": None,
            "labelSource": "none",
            "selected": None,
            "snapshotID": "element-1",
            "sources": ["omniparser"],
            "trackingID": None,
        }

        normalized = evaluator.validate_prediction_element(element, viewport)
        self.assertEqual(normalized["centerLogical"], {"x": 15.0, "y": 25.0})
        self.assertEqual(
            normalized["centerNormalized"],
            {"x": 0.25, "y": 0.208333333},
        )

        invalid = copy.deepcopy(element)
        invalid["center"]["logicalPoints"]["x"] = 16
        with self.assertRaises(evaluator.EvaluationError):
            evaluator.validate_prediction_element(invalid, viewport)


if __name__ == "__main__":
    unittest.main()
