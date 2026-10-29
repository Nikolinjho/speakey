import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class OpportunityPilotTests(unittest.TestCase):
    def test_oracle_and_validation(self):
        """Оракул проверяет замороженные семьи и отрицательные примеры."""
        with tempfile.TemporaryDirectory(prefix="speakey-opportunity-tests-") as work:
            output = pathlib.Path(work) / "oracle.json"
            result = subprocess.run(
                ["bash", "scripts/analyze-neural-opportunities.sh", "--oracle-only", "--self-test", "--output", str(output)],
                cwd=ROOT, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            data = json.loads(output.read_text())
            self.assertEqual(data["families"], 40)
            self.assertEqual(data["correctControls"], 40)
            self.assertEqual(data["wrongSamples"], 40)
            self.assertEqual(data["familiesByLanguage"], {"en": 20, "ru": 20})
            self.assertGreater(data["prefixes"], 0)
            self.assertGreaterEqual(data["negativeChecks"], 5)
            self.assertGreaterEqual(data.get("semanticChecks", 0), 5)
            self.assertIsInstance(data.get("wrongModelConfidenceDetails"), dict)
            self.assertEqual(data["qualityOverlap"], 0)
            self.assertEqual(data["mode"], "oracle")
            self.assertTrue(data["pilotSHA256"])
            self.assertLessEqual(data["baselineTruePositives"], data["oracleTruePositives"])
            self.assertEqual(data["oracleTruePositives"] - data["baselineTruePositives"], data["additionalRecallOpportunities"])
            self.assertEqual(sum(data["wrongPrefixCategories"].values()), data["wrongPrefixes"])
            self.assertEqual(sum(data["controlPrefixCategories"].values()), data["controlPrefixes"])

    @unittest.skipUnless(os.environ.get("SPEAKEY_OPPORTUNITY_MODEL_REPORT"), "Нужен результат небольшого CPU-прогона")
    def test_fixed_model_report(self):
        """Счётчики реальной policy сходятся с числом проверенных префиксов."""
        data = json.loads(pathlib.Path(os.environ["SPEAKEY_OPPORTUNITY_MODEL_REPORT"]).read_text())
        self.assertEqual(data["mode"], "fixed-model-counterfactual")
        self.assertEqual(data["fixedMinimumScore"], 0.95)
        self.assertEqual(data["fixedMinimumMargin"], 0.50)
        self.assertGreater(data["modelPredictions"], 0)
        self.assertEqual(sum(data["modelPolicyCategories"].values()), data["prefixes"])
        self.assertEqual(sum(data["wrongModelPolicyCategories"].values()), data["wrongPrefixes"])
        self.assertEqual(sum(data["controlModelPolicyCategories"].values()), data["controlPrefixes"])
        self.assertEqual(sum(data["wrongModelConfidenceDetails"].values()), data["wrongModelPolicyCategories"].get("blocked.confidence", 0))
        self.assertEqual(sum(data["controlModelConfidenceDetails"].values()), data["controlModelPolicyCategories"].get("blocked.confidence", 0))
        self.assertEqual(sum(data["wrongModelWinners"].values()), data["wrongPrefixes"])
        self.assertLessEqual(data["modelTruePositives"], data["wrongSamples"])
        self.assertGreaterEqual(data["wrongTargetScoreMaximum"], 0)
        self.assertLessEqual(data["wrongTargetScoreMaximum"], 1)


if __name__ == "__main__":
    unittest.main()
