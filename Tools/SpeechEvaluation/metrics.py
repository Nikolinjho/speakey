"""Детерминированные лексические WER/CER без внешних зависимостей.

Это сравнение текста, а не оценка акустики или смысла. CER включает пробелы.
Пустой эталон с непустой гипотезой даёт rate=None и явные счётчики вставок.
Числа не преобразуются в слова. Сохраняются знаки чисел, десятичные
разделители, разделители дат/времени и проценты рядом с цифрами.
"""

from dataclasses import asdict, dataclass
import unicodedata


@dataclass(frozen=True)
class NormalizationPolicy:
    unicode_form: str = "NFC"
    lowercase: bool = True
    remove_punctuation: bool = True
    fold_yo: bool = True
    collapse_whitespace: bool = True


def normalize(text, policy=None):
    """Применяет только явно перечисленные преобразования текста."""
    policy = policy or NormalizationPolicy()
    text = unicodedata.normalize(policy.unicode_form, text)
    if policy.lowercase:
        text = text.lower()
    if policy.fold_yo:
        text = text.replace("ё", "е").replace("Ё", "Е")
    if policy.remove_punctuation:
        chars = []
        for index, char in enumerate(text):
            previous = text[index - 1] if index else ""
            following = text[index + 1] if index + 1 < len(text) else ""
            numeric = (
                char in ".,:/" and previous.isdigit() and following.isdigit()
                or char in "+-−" and following.isdigit()
                or char == "%" and previous.isdigit()
            )
            chars.append(" " if unicodedata.category(char).startswith("P") and not numeric else char)
        text = "".join(chars)
    if policy.collapse_whitespace:
        text = " ".join(text.split())
    return text


def _align(reference, hypothesis):
    """При равной цене выбирает замену, затем удаление, затем вставку."""
    costs = [list(range(len(hypothesis) + 1))]
    for i, expected in enumerate(reference, 1):
        row = [i]
        for j, actual in enumerate(hypothesis, 1):
            row.append(min(costs[i - 1][j - 1] + (expected != actual),
                           costs[i - 1][j] + 1, row[j - 1] + 1))
        costs.append(row)
    i, j = len(reference), len(hypothesis)
    alignment = []
    while i or j:
        if i and j and costs[i][j] == costs[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            operation = "equal" if reference[i - 1] == hypothesis[j - 1] else "substitute"
            alignment.append({"operation": operation, "reference": reference[i - 1], "hypothesis": hypothesis[j - 1]})
            i -= 1
            j -= 1
        elif i and costs[i][j] == costs[i - 1][j] + 1:
            alignment.append({"operation": "delete", "reference": reference[i - 1], "hypothesis": None})
            i -= 1
        else:
            alignment.append({"operation": "insert", "reference": None, "hypothesis": hypothesis[j - 1]})
            j -= 1
    alignment.reverse()
    counts = {
        "substitutions": 0, "deletions": 0, "insertions": 0,
        "hits": 0, "reference_length": len(reference),
    }
    fields = {"equal": "hits", "substitute": "substitutions", "delete": "deletions", "insert": "insertions"}
    for item in alignment:
        counts[fields[item["operation"]]] += 1
    errors = counts["substitutions"] + counts["deletions"] + counts["insertions"]
    rate = errors / len(reference) if reference else (None if errors else 0.0)
    return rate, counts, alignment


def _count_edits(reference, hypothesis):
    """Считает ошибки двумя строками DP, сохраняя приоритеты _align."""
    # Ячейка хранит цену, замены, удаления, вставки и совпадения.
    previous = [(j, 0, 0, j, 0) for j in range(len(hypothesis) + 1)]
    for i, expected in enumerate(reference, 1):
        current = [(i, 0, i, 0, 0)]
        for j, actual in enumerate(hypothesis, 1):
            diagonal, above, left = previous[j - 1], previous[j], current[j - 1]
            changed = expected != actual
            diagonal_cost = diagonal[0] + changed
            deletion_cost, insertion_cost = above[0] + 1, left[0] + 1
            if diagonal_cost <= deletion_cost and diagonal_cost <= insertion_cost:
                current.append((diagonal_cost, diagonal[1] + changed, diagonal[2],
                                diagonal[3], diagonal[4] + (not changed)))
            elif deletion_cost <= insertion_cost:
                current.append((deletion_cost, above[1], above[2] + 1, above[3], above[4]))
            else:
                current.append((insertion_cost, left[1], left[2], left[3] + 1, left[4]))
        previous = current
    errors, substitutions, deletions, insertions, hits = previous[-1]
    counts = {
        "substitutions": substitutions, "deletions": deletions, "insertions": insertions,
        "hits": hits, "reference_length": len(reference),
    }
    rate = errors / len(reference) if reference else (None if errors else 0.0)
    return rate, counts


def score(reference, hypothesis, *, normalization=None):
    """Возвращает WER/CER, счётчики и выравнивание слов в JSON-совместимом виде."""
    policy = normalization or NormalizationPolicy()
    expected = normalize(reference, policy)
    actual = normalize(hypothesis, policy)
    wer, word_counts, alignment = _align(expected.split(), actual.split())
    cer, character_counts = _count_edits(expected, actual)
    return {
        "wer": wer, "cer": cer,
        "word_counts": word_counts, "character_counts": character_counts,
        "alignment": alignment,
        "normalized_reference": expected, "normalized_hypothesis": actual,
        "normalization": asdict(policy),
    }
