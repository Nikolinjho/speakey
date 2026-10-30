"""Проверки воспроизводимого лексического сравнения расшифровок."""

import random
import tracemalloc
import unittest

from Tools.SpeechEvaluation import metrics


class MetricsTests(unittest.TestCase):
    def test_identical_text(self):
        """Совпадающий текст не содержит ошибок."""
        result = metrics.score("Привет мир", "Привет мир")
        self.assertEqual(result["wer"], 0.0)
        self.assertEqual(result["cer"], 0.0)
        self.assertEqual(result["word_counts"], {
            "substitutions": 0, "deletions": 0, "insertions": 0,
            "hits": 2, "reference_length": 2,
        })

    def test_edit_counts_and_alignment(self):
        """Выравнивание различает замену, удаление и вставку."""
        result = metrics.score("а б в г д ж", "а х в д ж е")
        self.assertEqual(result["word_counts"], {
            "substitutions": 1, "deletions": 1, "insertions": 1,
            "hits": 4, "reference_length": 6,
        })
        self.assertAlmostEqual(result["wer"], 0.5)
        self.assertEqual(result["alignment"], [
            {"operation": "equal", "reference": "а", "hypothesis": "а"},
            {"operation": "substitute", "reference": "б", "hypothesis": "х"},
            {"operation": "equal", "reference": "в", "hypothesis": "в"},
            {"operation": "delete", "reference": "г", "hypothesis": None},
            {"operation": "equal", "reference": "д", "hypothesis": "д"},
            {"operation": "equal", "reference": "ж", "hypothesis": "ж"},
            {"operation": "insert", "reference": None, "hypothesis": "е"},
        ])

    def test_character_counts(self):
        """CER учитывает пробелы нормализованного текста."""
        result = metrics.score("кот", "кит!")
        self.assertAlmostEqual(result["cer"], 1 / 3)
        self.assertEqual(result["character_counts"]["substitutions"], 1)
        self.assertEqual(result["character_counts"]["reference_length"], 3)

    def test_character_counts_match_full_alignment(self):
        """Счётчики CER совпадают с полным выравниванием, включая равные цены."""
        generator = random.Random(831)
        pairs = [("", ""), ("", "аб"), ("аб", ""), ("аб", "ба")]
        for _ in range(150):
            pairs.append(tuple(
                "".join(generator.choice("абв ") for _ in range(generator.randrange(15)))
                for _ in range(2)
            ))
        for reference, hypothesis in pairs:
            with self.subTest(reference=reference, hypothesis=hypothesis):
                result = metrics.score(reference, hypothesis)
                rate, counts, _ = metrics._align(
                    result["normalized_reference"], result["normalized_hypothesis"],
                )
                self.assertEqual(result["cer"], rate)
                self.assertEqual(result["character_counts"], counts)

    def test_character_scoring_memory_is_bounded(self):
        """Тысяча символов сравнивается без полной матрицы CER в памяти."""
        reference, hypothesis = "аб" * 500, "ба" * 500
        tracemalloc.start()
        try:
            result = metrics.score(reference, hypothesis)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(result["character_counts"]["reference_length"], 1000)
        self.assertGreater(result["cer"], 0)
        self.assertLess(peak, 3 * 1024 * 1024)

    def test_normalization_is_explicit_and_configurable(self):
        """Регистр, пунктуация и ё нормализуются отдельными настройками."""
        result = metrics.score("  ЁЖ,\nидёт! ", "еж идет")
        self.assertEqual(result["wer"], 0)
        self.assertEqual(result["normalized_reference"], "еж идет")
        self.assertEqual(result["normalization"], {
            "unicode_form": "NFC", "lowercase": True,
            "remove_punctuation": True, "fold_yo": True,
            "collapse_whitespace": True,
        })
        strict = metrics.NormalizationPolicy(
            lowercase=False, remove_punctuation=False, fold_yo=False,
        )
        self.assertGreater(metrics.score("ЁЖ!", "еж", normalization=strict)["wer"], 0)

    def test_unicode_equivalence(self):
        """Канонически равные буквы совпадают без NFKC-подмен."""
        self.assertEqual(metrics.score("café", "cafe\u0301")["wer"], 0)
        self.assertGreater(metrics.score("①", "1")["wer"], 0)

    def test_numbers_and_negations_remain_different(self):
        """Числа, знак минуса и отрицание сохраняют различия."""
        for reference, hypothesis in [
            ("не отправляй", "отправляй"), ("15", "пятнадцать"),
            ("1.5", "15"), ("-5", "5"), ("1,5", "15"),
        ]:
            with self.subTest(reference=reference):
                self.assertGreater(metrics.score(reference, hypothesis)["wer"], 0)

    def test_punctuation_does_not_join_words(self):
        """Разделители слов заменяются пробелом."""
        self.assertEqual(metrics.score("привет,мир", "привет мир")["wer"], 0)

    def test_empty_reference_and_unbounded_rate(self):
        """При пустом эталоне доля вставок не определена, WER может превышать 1."""
        self.assertEqual(metrics.score("", "")["wer"], 0)
        inserted = metrics.score("", "лишнее слово")
        self.assertIsNone(inserted["wer"])
        self.assertIsNone(inserted["cer"])
        self.assertEqual(inserted["word_counts"]["insertions"], 2)
        self.assertEqual(metrics.score("да", "да а б")["wer"], 2)
        self.assertEqual(metrics.score("да нет", "")["wer"], 1)

    def test_tie_alignment_is_stable(self):
        """При равной цене замена имеет приоритет над удалением и вставкой."""
        result = metrics.score("а б", "б а")
        self.assertEqual(result["word_counts"]["substitutions"], 2)
        self.assertEqual(result, metrics.score("а б", "б а"))


if __name__ == "__main__":
    unittest.main()
