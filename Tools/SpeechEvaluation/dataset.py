"""Проверка локального корпуса без вывода содержимого расшифровок."""

import json
import math
from pathlib import Path

try:
    from .audio import AudioError, audio_info
    from .metrics import normalize
except ImportError:
    from audio import AudioError, audio_info
    from metrics import normalize


class ValidationError(ValueError):
    pass


def read_jsonl(path):
    rows = []
    try:
        with Path(path).open(encoding='utf-8') as source:
            for line_number, line in enumerate(source, 1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except (ValueError, RecursionError):
                    raise ValidationError('Строка {}: неверный JSON'.format(line_number)) from None
                if not isinstance(row, dict):
                    raise ValidationError('Строка {}: ожидается объект'.format(line_number))
                rows.append(row)
    except (OSError, UnicodeError):
        raise ValidationError('Не удалось прочитать JSONL') from None
    if not rows:
        raise ValidationError('Корпус пуст')
    return rows


def normalized_transcript(text):
    return normalize(text)


def _near_duplicate(left, right):
    # Короткие фразы часто совпадают случайно. Для длинных допускаем не более 12.5% правок.
    left, right = left.split(), right.split()
    if min(len(left), len(right)) < 8:
        return False
    limit = max(len(left), len(right)) // 8
    if abs(len(left) - len(right)) > limit:
        return False
    costs = list(range(len(right) + 1))
    for i, word in enumerate(left, 1):
        row = [i]
        for j, other in enumerate(right, 1):
            row.append(min(costs[j] + 1, row[j - 1] + 1, costs[j - 1] + (word != other)))
        costs = row
    return costs[-1] <= limit


def _audio_info(path):
    try:
        info = audio_info(path)
        return info['duration_seconds'], info['pcm_sha256']
    except AudioError as error:
        raise ValidationError(str(error)) from None


def validate_manifest(path):
    """Возвращает проверенные записи с абсолютными путями и длительностями."""
    path = Path(path)
    rows = read_jsonl(path)
    ids, sessions, texts, audio_hashes = set(), {}, {}, {}
    result = []
    for index, row in enumerate(rows, 1):
        try:
            for field in ('id', 'audio', 'session_id', 'split'):
                if not isinstance(row.get(field), str) or not row[field].strip():
                    raise ValidationError('Неверное поле {}'.format(field))
            if row['id'] in ids:
                raise ValidationError('Повтор id')
            ids.add(row['id'])
            if row['split'] not in ('train', 'dev', 'test'):
                raise ValidationError('Неверное поле split')
            if not isinstance(row.get('reference'), str):
                raise ValidationError('Неверное поле reference')
            if row.get('reference_confirmed') is not True:
                raise ValidationError('Требуется reference_confirmed=true')
            if 'edited_text' in row and not isinstance(row['edited_text'], str):
                raise ValidationError('Неверное поле edited_text')
            if row.get('kind', 'speech') not in ('speech', 'silence'):
                raise ValidationError('Неверное поле kind')
            if row.get('kind') == 'silence' and row['reference'].strip():
                raise ValidationError('У тишины должен быть пустой reference')
            if 'critical_terms' in row and (not isinstance(row['critical_terms'], list) or any(
                    not isinstance(term, str) or not term.strip() for term in row['critical_terms'])):
                raise ValidationError('Неверное поле critical_terms')
            audio_path = (path.parent / row['audio']).resolve()
            duration, digest = _audio_info(audio_path)
            if 'duration_seconds' in row:
                declared = row['duration_seconds']
                if (isinstance(declared, bool) or not isinstance(declared, (int, float))
                        or not math.isfinite(declared) or declared <= 0 or abs(declared - duration) > .01):
                    raise ValidationError('Неверное поле duration_seconds')
            split = row['split']
            normalized = normalized_transcript(row['reference'])
            for previous, previous_split in texts.items():
                if previous_split != split and previous != normalized and _near_duplicate(previous, normalized):
                    raise ValidationError('Утечка near_duplicate между выборками')
            for seen, key, label in ((sessions, row['session_id'], 'session_id'),
                                     (audio_hashes, digest, 'audio'),
                                     (texts, normalized, 'reference')):
                # Пустая расшифровка допустима у нескольких записей тишины.
                if not key:
                    continue
                if key in seen and seen[key] != split:
                    raise ValidationError('Утечка {} между выборками'.format(label))
                seen[key] = split
            result.append(dict(row, audio=str(audio_path), duration_seconds=duration))
        except ValidationError as error:
            raise ValidationError('Запись {}: {}'.format(index, error)) from None
    return result
