import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[2] / "Scripts/report-workflow-throughput.py"
spec = importlib.util.spec_from_file_location("workflow_throughput", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WorkflowThroughputTests(unittest.TestCase):
    def setUp(self):
        self.values = [
            {"request": "ABC", "outcome": "review", "totalSeconds": 20},
            {"request": "ABC", "outcome": "verified", "totalSeconds": 40},
            {"verified": True, "sourceMediaVerified": True, "differences": [], "expectedProjectUID": "project"},
            {"requestID": "ABC", "sourceMedia": {"hashes": {}}, "expectedSHA256": hashlib.sha256(b"xml").hexdigest()},
            {"projectUID": "project"}, b"xml", 3600,
        ]

    def test_counts_complete_helper_work_and_does_not_claim_pcm_equality(self):
        result = module.make_report(*self.values)
        self.assertEqual(result["analyzeAndApplySeconds"], 60)
        self.assertEqual(result["rawAudioSecondsPerProcessingSecond"], 60)
        self.assertTrue(result["helperProcessingWithinBudget"])
        self.assertFalse(result["processedPCMEqualityEstablished"])
        self.values[-1] = 60
        self.assertFalse(module.make_report(*self.values)["helperProcessingWithinBudget"])

    def test_rejects_failed_unrelated_or_modified_results(self):
        for index, key, value in [(0, "outcome", "failed"), (1, "outcome", "failed"),
                (1, "request", "other"), (3, "requestID", "other"),
                (2, "sourceMediaVerified", False), (2, "verified", False),
                (2, "differences", ["changed effect"]), (2, "expectedProjectUID", "other"),
                (3, "expectedSHA256", "changed"), (3, "sourceMedia", None),
                (0, "totalSeconds", float("nan")), (1, "totalSeconds", 0)]:
            with self.subTest(index=index, key=key):
                values = copy.deepcopy(self.values)
                values[index][key] = value
                with self.assertRaises(ValueError):
                    module.make_report(*values)

    def test_rejects_invalid_raw_duration(self):
        for value in [0, -1, float("inf"), float("nan")]:
            with self.assertRaises(ValueError):
                module.make_report(*self.values[:-1], value)


if __name__ == "__main__":
    unittest.main()
