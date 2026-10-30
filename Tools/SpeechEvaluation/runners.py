"""Последовательный прогон корпуса через явно указанный локальный Speakey CLI."""

import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

try:
    from .audio import AudioError, audio_info
    from .dataset import ValidationError, validate_manifest
except ImportError:
    from audio import AudioError, audio_info
    from dataset import ValidationError, validate_manifest


class RunError(ValueError):
    pass


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _write_private(path, value, *, jsonl=False):
    with os.fdopen(os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600),
                   'w', encoding='utf-8') as target:
        if jsonl:
            for row in value:
                target.write(json.dumps(row, ensure_ascii=False, allow_nan=False)+'\n')
        else:
            json.dump(value, target, ensure_ascii=False, allow_nan=False, indent=2)
            target.write('\n')


def run_corpus(manifest, *, executable, model, output, language='auto', split='test',
               stage='raw', timeout=120):
    """Не скачивает веса и не меняет настройки приложения. Ошибка прерывает весь прогон."""
    output = Path(output).resolve()
    repository = Path(__file__).resolve().parents[2]
    if output == repository or repository in output.parents:
        raise RunError('Личные прогоны нужно сохранять вне репозитория')
    if (language not in ('auto', 'ru', 'en') or split not in ('train', 'dev', 'test')
            or stage not in ('raw', 'echo-cleaned') or isinstance(timeout, bool)
            or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0):
        raise RunError('Неверные параметры прогона')
    created = False
    try:
        manifest_hash = _sha256(manifest)
        rows = validate_manifest(manifest)
        rows = [row for row in rows if row['split'] == split]
        if not rows:
            raise RunError('Выбранная выборка пустая')
        executable, model = Path(executable).resolve(), Path(model).resolve()
        if not executable.is_file() or not os.access(str(executable), os.X_OK) or not model.is_file():
            raise RunError('Нужны локальный executable и файл весов')
        model_hash = _sha256(model)
        executable_hash = _sha256(executable)
        output.mkdir(mode=0o700)
        created = True
        environment = {key: value for key, value in os.environ.items() if not key.startswith('SPEAKEY_')}
        environment['SPEAKEY_SPEECH_CLI'] = '1'
        predictions, measurements = [], []
        started_at = datetime.now(timezone(timedelta(hours=3))).isoformat()
        native_path = output / '.native-result.json'
        for index, row in enumerate(rows, 1):
            info = audio_info(row['audio'])
            input_hash = info['input_wav_sha256']
            started = time.monotonic()
            try:
                completed = subprocess.run([str(executable), 'transcribe', '--input', row['audio'],
                    '--model', str(model), '--language', language, '--output', str(native_path)],
                    env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=timeout, check=False)
            except subprocess.TimeoutExpired:
                raise RunError('Запись {}: таймаут дочернего распознавания'.format(index)) from None
            elapsed = time.monotonic() - started
            if completed.returncode != 0:
                raise RunError('Запись {}: движок завершился с кодом {}'.format(index, completed.returncode))
            os.chmod(str(native_path), 0o600)
            try:
                result = json.loads(native_path.read_text(encoding='utf-8'))
            except (ValueError, UnicodeError):
                raise RunError('Запись {}: неверный ответ движка'.format(index)) from None
            field = 'raw_hypothesis' if stage == 'raw' else 'hypothesis'
            if (not isinstance(result, dict) or not isinstance(result.get(field), str)
                    or result.get('model_sha256') != model_hash or result.get('language') != language
                    or result.get('input_wav_sha256') != input_hash
                    or _sha256(row['audio']) != input_hash
                    or result.get('sample_count') != info['frame_count']
                    or result.get('sample_rate') != 16000):
                raise RunError('Запись {}: ответ не соответствует модели или режиму'.format(index))
            configuration = result.get('config')
            if (not isinstance(configuration, dict) or not isinstance(configuration.get('prompt_sha256'), str)
                    or len(configuration['prompt_sha256']) != 64
                    or any(c not in '0123456789abcdef' for c in configuration['prompt_sha256'])
                    or configuration.get('recognition_hint') != 'disabled_explicitly'):
                raise RunError('Запись {}: не зафиксирована конфигурация распознавания'.format(index))
            if any(not isinstance(key, str) or not isinstance(value, str)
                   for key, value in configuration.items()):
                raise RunError('Запись {}: неверный формат конфигурации'.format(index))
            config_hash = hashlib.sha256(json.dumps(configuration, sort_keys=True,
                ensure_ascii=False, separators=(',', ':')).encode('utf-8')).hexdigest()
            if (result.get('config_sha256') != config_hash
                    or result.get('config_sha256_format') != 'sorted-compact-utf8-v1'):
                raise RunError('Запись {}: хеш конфигурации не совпадает'.format(index))
            config = dict(configuration)
            decode_time = result.get('elapsed_seconds')
            if (isinstance(decode_time, bool) or not isinstance(decode_time, (int, float))
                    or not math.isfinite(decode_time) or decode_time < 0):
                raise RunError('Запись {}: неверное время распознавания'.format(index))
            predictions.append(dict(id=row['id'], hypothesis=result[field]))
            measurements.append(dict(id=row['id'], audio_sha256=info['pcm_sha256'],
                input_wav_sha256=input_hash, config=config, config_sha256=config_hash,
                duration_seconds=info['duration_seconds'], wall_seconds=elapsed,
                decode_seconds=decode_time))
            native_path.unlink()
        # Не публикуем успешный протокол, если файл весов изменился во время прогона.
        if _sha256(model) != model_hash or _sha256(executable) != executable_hash:
            raise RunError('Модель или executable изменились во время прогона')
        if _sha256(manifest) != manifest_hash:
            raise RunError('Описание корпуса изменилось во время прогона')
        protocol = dict(schema_version=1, backend='speakey-whisper-cli',
            process_mode='fresh-process-per-record', recognition_mode='isolated-whisper-defaults',
            stage=stage, language=language, split=split, model_sha256=model_hash,
            executable_sha256=executable_hash, manifest_sha256=manifest_hash,
            started_at_msk=started_at, samples=measurements)
        _write_private(output/'hypotheses.jsonl', predictions, jsonl=True)
        _write_private(output/'run.json', protocol)
        return dict(samples=len(predictions), split=split, stage=stage,
                    process_mode=protocol['process_mode'])
    except (OSError, AudioError, ValidationError):
        raise RunError('Не удалось выполнить локальный прогон') from None
    finally:
        if created and sys.exc_info()[0] is not None:
            shutil.rmtree(str(output))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    parser.add_argument('--executable', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--language', choices=('auto', 'ru', 'en'), default='auto')
    parser.add_argument('--split', choices=('train', 'dev', 'test'), default='test')
    parser.add_argument('--stage', choices=('raw', 'echo-cleaned'), default='raw')
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args(argv)
    try:
        result = run_corpus(args.manifest, executable=args.executable, model=args.model,
            output=args.output, language=args.language, split=args.split, stage=args.stage,
            timeout=args.timeout)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except RunError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
