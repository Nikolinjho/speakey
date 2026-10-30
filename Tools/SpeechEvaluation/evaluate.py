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
    from .metrics import NormalizationPolicy, score
except ImportError:
    from dataset import ValidationError, read_jsonl, validate_manifest
    from metrics import NormalizationPolicy, score


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
    args = parser.parse_args(argv)
    try:
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
