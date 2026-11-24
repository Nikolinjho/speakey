#!/usr/bin/env python3
"""Локальная проверка корпуса и оценка заранее подготовленных гипотез."""

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import re
import sys
import unicodedata

try:
    from .dataset import ValidationError, read_jsonl, validate_manifest
    from .metrics import NormalizationPolicy, normalize, score
except ImportError:
    from dataset import ValidationError, read_jsonl, validate_manifest
    from metrics import NormalizationPolicy, normalize, score


def _critical_counts(reference, hypothesis, terms):
    expected = actual = 0
    reference = ' '.join(unicodedata.normalize('NFC', reference).split())
    hypothesis = ' '.join(unicodedata.normalize('NFC', hypothesis).split())
    for term in terms:
        term = ' '.join(unicodedata.normalize('NFC', term).split())
        if any(char.isdigit() for char in term):
            # Знак и цифровые разделители относятся к числу, пунктуация предложения — нет.
            pattern = (r'(?<![\w+−-])(?<!\d[.,:/−-])' + re.escape(term)
                       + r'(?!\w|[.,:/−-]\d|%)')
        else:
            pattern = r'(?<!\w)' + re.escape(term) + r'(?!\w)'
        count = len(re.findall(pattern, reference))
        if not count:
            raise ValidationError('critical_terms отсутствует в reference')
        expected += count
        actual += min(count, len(re.findall(pattern, hypothesis)))
    return {'reference_occurrences': expected, 'matched_occurrences': actual,
            'missed_occurrences': expected - actual}


def evaluate_rows(rows, hypotheses):
    predictions = {}
    for index, row in enumerate(hypotheses, 1):
        if (not isinstance(row.get('id'), str) or not row['id'].strip()
                or not isinstance(row.get('hypothesis'), str)):
            raise ValidationError('Гипотеза {}: требуются id и hypothesis'.format(index))
        if row['id'] in predictions:
            raise ValidationError('Повтор id гипотезы')
        predictions[row['id']] = row['hypothesis']
    if set(predictions) != {row['id'] for row in rows}:
        raise ValidationError('Набор id гипотез не совпадает с выбранной выборкой')
    totals = {kind: dict(substitutions=0, deletions=0, insertions=0, hits=0, reference_length=0)
              for kind in ('word_counts', 'character_counts')}
    critical_totals = dict(reference_occurrences=0, matched_occurrences=0, missed_occurrences=0)
    samples = []
    silence_count = silence_false_positives = 0
    for row in rows:
        hypothesis = predictions[row['id']]
        result = score(row['reference'], hypothesis)
        critical = _critical_counts(row['reference'], hypothesis, row.get('critical_terms', []))
        for key in critical_totals:
            critical_totals[key] += critical[key]
        for kind in totals:
            for key in totals[kind]:
                totals[kind][key] += result[kind][key]
        if not row['reference'].strip():
            silence_count += 1
            silence_false_positives += bool(hypothesis.strip())
        samples.append(dict(id=row['id'], split=row['split'], wer=result['wer'], cer=result['cer'],
                            word_counts=result['word_counts'], character_counts=result['character_counts'],
                            critical_terms=critical))
    aggregate = dict(totals, critical_terms=critical_totals, samples=len(rows),
                     duration_seconds=sum(row['duration_seconds'] for row in rows),
                     silence_samples=silence_count, silence_false_positives=silence_false_positives)
    for rate, kind in (('wer', 'word_counts'), ('cer', 'character_counts')):
        counts = totals[kind]
        errors = sum(counts[key] for key in ('substitutions', 'deletions', 'insertions'))
        denominator = counts['reference_length']
        aggregate[rate] = errors / denominator if denominator else (None if errors else 0.0)
    return dict(schema_version=1, source='precomputed_hypotheses',
                normalization=asdict(NormalizationPolicy()), aggregate=aggregate, samples=samples)


DEFAULT_COMMON_WORDS = tuple(Path(__file__).resolve().parents[2] / 'Sources' / 'Speakey' / 'Resources' / name
                             for name in ('words_ru.json', 'words_en.json'))


def _word_errors(sample):
    counts = sample['word_counts']
    return counts['substitutions'] + counts['deletions'] + counts['insertions']


def _read_report(path):
    try:
        report = json.loads(Path(path).read_text(encoding='utf-8'))
        samples = report['samples']
        by_id = {sample['id']: sample for sample in samples}
        for sample in samples:
            _word_errors(sample)
    except (OSError, ValueError, KeyError, TypeError, UnicodeError):
        raise ValidationError('Не удалось прочитать отчёт оценки') from None
    if len(by_id) != len(samples):
        raise ValidationError('Повтор id в отчёте')
    return report, by_id


def _common_words(paths):
    words = set()
    for path in paths:
        try:
            data = json.loads(Path(path).read_text(encoding='utf-8'))
        except (OSError, ValueError, UnicodeError):
            raise ValidationError('Не удалось прочитать список частых слов') from None
        if not isinstance(data, list) or any(not isinstance(word, str) for word in data):
            raise ValidationError('Список частых слов: ожидается массив строк')
        words.update(normalize(word) for word in data)
    return words


def _rare_missed(reference, hypothesis, common):
    """Слова эталона вне частых и сколько из них потеряно (по числу вхождений, без порядка)."""
    expected = {}
    for word in normalize(reference).split():
        if word not in common and any(char.isalpha() for char in word):
            expected[word] = expected.get(word, 0) + 1
    actual = {}
    for word in normalize(hypothesis).split():
        actual[word] = actual.get(word, 0) + 1
    total = sum(expected.values())
    return total, total - sum(min(count, actual.get(word, 0)) for word, count in expected.items())


def compare_reports(baseline, variant, *, rare=None):
    """Сравнивает два отчёта `evaluate` по одним и тем же записям. В результате нет текстов.

    `rare` = (строки манифеста, гипотезы базы, гипотезы варианта, частые слова) включает метрику
    редких слов: отчёты оценки хранят только счётчики, слова эталона берутся из манифеста.
    """
    base_report, base = _read_report(baseline)
    variant_report, var = _read_report(variant)
    if set(base) != set(var):
        raise ValidationError('Наборы записей в отчётах не совпадают')
    better = worse = same = 0
    worse_ids = []
    totals = dict(baseline=0, variant=0)
    for ident in base:
        before, after = _word_errors(base[ident]), _word_errors(var[ident])
        totals['baseline'] += before
        totals['variant'] += after
        if after < before:
            better += 1
        elif after > before:
            worse += 1
            worse_ids.append(ident)
        else:
            same += 1
    rare_errors = None
    if rare is not None:
        rows, base_hypotheses, variant_hypotheses, common = rare
        base_text = {row['id']: row['hypothesis'] for row in base_hypotheses}
        variant_text = {row['id']: row['hypothesis'] for row in variant_hypotheses}
        rare_errors = dict(reference_occurrences=0, baseline_missed=0, variant_missed=0)
        for row in rows:
            if row['id'] not in base or row['id'] not in base_text or row['id'] not in variant_text:
                continue
            total, missed = _rare_missed(row['reference'], base_text[row['id']], common)
            _, variant_missed = _rare_missed(row['reference'], variant_text[row['id']], common)
            rare_errors['reference_occurrences'] += total
            rare_errors['baseline_missed'] += missed
            rare_errors['variant_missed'] += variant_missed
    return dict(schema_version=1, samples=len(base), better=better, worse=worse, same=same,
                worse_ids=worse_ids, word_errors=totals, rare_word_errors=rare_errors,
                wer=dict(baseline=base_report.get('aggregate', {}).get('wer'),
                         variant=variant_report.get('aggregate', {}).get('wer')))


def write_report(path, report):
    path = Path(path).resolve()
    repository = Path(__file__).resolve().parents[2]
    if path == repository or repository in path.parents:
        raise ValidationError('Личные отчёты нужно сохранять вне репозитория')
    descriptor = None
    try:
        descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            descriptor = None
            json.dump(report, output, ensure_ascii=False, indent=2, allow_nan=False)
            output.write('\n')
    except OSError:
        raise ValidationError('Не удалось создать новый приватный отчёт') from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    validate = commands.add_parser('validate', help='Проверить JSONL и WAV без распознавания')
    validate.add_argument('manifest')
    evaluate = commands.add_parser('evaluate', help='Оценить готовые гипотезы, без запуска ASR')
    evaluate.add_argument('manifest')
    evaluate.add_argument('hypotheses')
    evaluate.add_argument('--split', choices=('train', 'dev', 'test', 'all'), default='test')
    evaluate.add_argument('--output', required=True)
    compare = commands.add_parser('compare', help='Сравнить два отчёта оценки (базовый и вариант)')
    compare.add_argument('baseline_report')
    compare.add_argument('variant_report')
    compare.add_argument('--output', required=True)
    compare.add_argument('--manifest', help='Для метрики редких слов; вместе с обоими файлами гипотез')
    compare.add_argument('--baseline-hypotheses')
    compare.add_argument('--variant-hypotheses')
    compare.add_argument('--common-words', action='append',
                         help='JSON-массив частых слов; можно повторять (по умолчанию words_ru.json и words_en.json)')
    args = parser.parse_args(argv)
    try:
        if args.command == 'compare':
            texts = (args.manifest, args.baseline_hypotheses, args.variant_hypotheses)
            if any(texts) and not all(texts):
                raise ValidationError('Для редких слов нужны манифест и оба файла гипотез')
            rare = None
            if args.manifest:
                rare = (validate_manifest(args.manifest), read_jsonl(args.baseline_hypotheses),
                        read_jsonl(args.variant_hypotheses),
                        _common_words(args.common_words or DEFAULT_COMMON_WORDS))
            report = compare_reports(args.baseline_report, args.variant_report, rare=rare)
            write_report(args.output, report)
            print(json.dumps({key: report[key] for key in ('samples', 'better', 'worse', 'same', 'word_errors',
                                                          'rare_word_errors')}, allow_nan=False))
            return 0
        rows = validate_manifest(args.manifest)
        if args.command == 'validate':
            counts = {split: sum(row['split'] == split for row in rows) for split in ('train', 'dev', 'test')}
            print(json.dumps(dict(valid=True, samples=len(rows), splits=counts)))
        else:
            selected = [row for row in rows if args.split == 'all' or row['split'] == args.split]
            if not selected:
                raise ValidationError('Выбранная выборка пустая')
            report = evaluate_rows(selected, read_jsonl(args.hypotheses))
            write_report(args.output, report)
            print(json.dumps(report['aggregate'], ensure_ascii=False, allow_nan=False))
        return 0
    except ValidationError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
