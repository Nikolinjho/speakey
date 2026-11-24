"""Сборка файлов контекста для CLI Speakey из манифеста корпуса. Тексты в консоль не выводятся."""

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

try:
    from .dataset import ValidationError, read_jsonl
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from Tools.SpeechEvaluation.dataset import ValidationError, read_jsonl

NEIGHBORS = 3


class ContextError(ValueError):
    pass


def context_path(directory, record_id):
    """Имя файла зависит только от хеша id, поэтому любые символы в id безопасны."""
    return Path(directory) / (hashlib.sha256(record_id.encode('utf-8')).hexdigest() + '.json')


def _words(text):
    # Как ContextLexicon.words(in:): буквы и цифры, остальное разделяет слова.
    return re.findall(r'[^\W_]+', text)


def _timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def _ordered(session_rows):
    """По времени, если оно есть у всех записей сессии; иначе по порядку в манифесте."""
    stamps = [_timestamp(row.get('created_at')) for row in session_rows]
    if all(stamp is not None for stamp in stamps):
        return [row for _, _, row in sorted(zip(stamps, range(len(stamps)), session_rows),
                                            key=lambda item: item[:2])]
    return list(session_rows)


def _vocabulary(path):
    try:
        data = json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError, UnicodeError):
        raise ContextError('Не удалось прочитать словарь корпуса') from None
    if not isinstance(data, dict) or any(not isinstance(word, str) or isinstance(count, bool)
                                         or not isinstance(count, int) or count < 1
                                         for word, count in data.items()):
        raise ContextError('Словарь корпуса: ожидается объект слово -> число')
    return data


def build(manifest, output_dir, corpus_vocabulary=None):
    output = Path(output_dir).resolve()
    repository = Path(__file__).resolve().parents[2]
    if output == repository or repository in output.parents:
        raise ContextError('Личный контекст нужно сохранять вне репозитория')
    try:
        rows = read_jsonl(manifest)
    except ValidationError as error:
        raise ContextError(str(error)) from None
    for row in rows:
        if not isinstance(row.get('id'), str) or not row['id'].strip() \
                or not isinstance(row.get('session_id'), str) or not isinstance(row.get('reference', ''), str):
            raise ContextError('Запись манифеста без id или session_id')
    corpus = _vocabulary(corpus_vocabulary) if corpus_vocabulary else None
    sessions = {}
    for row in rows:
        sessions.setdefault(row['session_id'], []).append(row)
    previous = {}
    for session_rows in sessions.values():
        ordered = _ordered(session_rows)
        for index, row in enumerate(ordered):
            previous[row['id']] = ordered[max(0, index - NEIGHBORS):index]
    created = False
    try:
        output.mkdir(mode=0o700)
        created = True
        for row in rows:
            counts = {}
            for neighbor in previous[row['id']]:
                for word in _words(neighbor.get('reference', '')):
                    counts[word] = counts.get(word, 0) + 1
            sources = []
            if counts:
                sources.append(dict(kind='screen', words=counts))
            if corpus:
                sources.append(dict(kind='corpus', words=corpus))
            descriptor = os.open(str(context_path(output, row['id'])),
                                 os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w', encoding='utf-8') as target:
                json.dump(dict(sources=sources), target, ensure_ascii=False, allow_nan=False)
                target.write('\n')
        return len(rows)
    except OSError:
        raise ContextError('Не удалось создать новый приватный каталог контекста') from None
    finally:
        if created and sys.exc_info()[0] is not None:
            shutil.rmtree(str(output))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build', help='Собрать файлы контекста по записям манифеста')
    builder.add_argument('manifest')
    builder.add_argument('--output-dir', required=True)
    builder.add_argument('--corpus-vocabulary')
    args = parser.parse_args(argv)
    try:
        count = build(args.manifest, args.output_dir, args.corpus_vocabulary)
        print(json.dumps(dict(records=count)))
        return 0
    except ContextError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
