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
    from .context import context_path
    from .dataset import ValidationError, validate_manifest
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from Tools.SpeechEvaluation.audio import AudioError, audio_info
    from Tools.SpeechEvaluation.context import context_path
    from Tools.SpeechEvaluation.dataset import ValidationError, validate_manifest


class RunError(ValueError):
    pass


SECOND_PASS_POLICY = 'always_when_candidates_no_budget_limit_8'

PARAKEET_COMPONENTS = ('Preprocessor.mlmodelc', 'Encoder.mlmodelc', 'Decoder.mlmodelc',
                       'JointDecisionv3.mlmodelc', 'parakeet_vocab.json')


def model_digest(path, engine='whisper'):
    path = Path(path)
    if path.is_symlink():
        raise RunError('Путь к модели не должен быть символической ссылкой')
    if engine == 'qwen':
        try:
            if __package__:
                from .qwen import QwenError, model_digest as qwen_digest
            else:
                from Tools.SpeechEvaluation.qwen import QwenError, model_digest as qwen_digest
            return qwen_digest(path.absolute())
        except QwenError:
            raise RunError('Неполная или изменённая локальная модель Qwen') from None
    if engine == 'whisper':
        if not path.is_file():
            raise RunError('Нужен локальный файл GGML')
        return _sha256(path)
    if engine != 'parakeet' or not path.is_dir() or path.name != 'parakeet-tdt-0.6b-v3':
        raise RunError('Нужен локальный каталог модели Parakeet v3')
    for entry in path.rglob('*'):
        if entry.is_symlink() or not (entry.is_file() or entry.is_dir()):
            raise RunError('Каталог модели содержит ссылку или специальный файл')
    pairs = []
    for name in PARAKEET_COMPONENTS:
        component = path / name
        if not component.exists():
            raise RunError('В каталоге отсутствуют компоненты Parakeet v3')
        files = [component] if component.is_file() else sorted(p for p in component.rglob('*') if p.is_file())
        if not files:
            raise RunError('Пустой компонент Parakeet v3')
        for entry in files:
            relative = entry.relative_to(path).as_posix()
            if not relative.isascii():
                raise RunError('Имена файлов модели должны быть ASCII')
            pairs.append([relative, _sha256(entry)])
    return hashlib.sha256(json.dumps(sorted(pairs), ensure_ascii=False,
        separators=(',', ':')).encode('utf-8')).hexdigest()


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
               stage='raw', timeout=120, engine='whisper', context_dir=None, deterministic=False):
    """Не скачивает веса и не меняет настройки приложения. Ошибка прерывает весь прогон.

    `context_dir` – каталог из `context.py build`: включает второй проход с контекстом (только Whisper).
    `deterministic` – `temperature_inc = 0`, чтобы прогоны «как сейчас» и «с контекстом» были сравнимы.
    `split='all'` берёт все записи манифеста."""
    output = Path(output).resolve()
    repository = Path(__file__).resolve().parents[2]
    if output == repository or repository in output.parents:
        raise RunError('Личные прогоны нужно сохранять вне репозитория')
    if (engine not in ('whisper', 'parakeet', 'qwen') or language not in ('auto', 'ru', 'en') or split not in ('train', 'dev', 'test', 'all')
            or stage not in ('raw', 'echo-cleaned') or isinstance(timeout, bool)
            or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0):
        raise RunError('Неверные параметры прогона')
    if (context_dir is not None or deterministic) and engine != 'whisper':
        raise RunError('Контекст и детерминизм доступны только для Whisper')
    if not isinstance(deterministic, bool):
        raise RunError('Неверные параметры прогона')
    if context_dir is not None:
        context_dir = Path(context_dir).resolve()
        if not context_dir.is_dir():
            raise RunError('Нет каталога контекста')
    created = False
    try:
        manifest_hash = _sha256(manifest)
        rows = validate_manifest(manifest)
        rows = [row for row in rows if split == 'all' or row['split'] == split]
        if not rows:
            raise RunError('Выбранная выборка пустая')
        model_hash = model_digest(model, engine)
        executable, model = Path(os.path.abspath(str(executable))), Path(model).resolve()
        if not executable.is_file() or not os.access(str(executable), os.X_OK):
            raise RunError('Нужен локальный executable')
        executable_hash = _sha256(executable)
        backend_code = Path(__file__).with_name('qwen.py') if engine == 'qwen' else None
        backend_hash = _sha256(backend_code) if backend_code else None
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
                prefix = [str(executable)]
                if engine == 'qwen':
                    prefix.extend(['-m', 'Tools.SpeechEvaluation.qwen'])
                command = prefix + ['transcribe', '--input', row['audio'],
                    '--model', str(model), '--language', language, '--output', str(native_path)]
                if engine == 'parakeet':
                    command.extend(['--engine', engine])
                context_file = None
                if context_dir is not None:
                    context_file = context_path(context_dir, row['id'])
                    if not context_file.is_file():
                        raise RunError('Запись {}: нет файла контекста'.format(index))
                    context_hash = _sha256(context_file)
                    command.extend(['--context', str(context_file)])
                if deterministic:
                    command.extend(['--deterministic', '1'])
                completed = subprocess.run(command,
                    env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=timeout, check=False, cwd=str(repository))
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
                    or result.get('engine', 'whisper') != engine
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
            if deterministic and configuration.get('deterministic') != 'temperature_inc_0':
                raise RunError('Запись {}: движок не подтвердил детерминизм'.format(index))
            context_fields = {}
            if context_dir is not None:
                candidates, first_ms, second_ms = (result.get('context_candidates'),
                                                   result.get('first_ms'), result.get('second_ms'))
                if (not isinstance(candidates, list) or not isinstance(result.get('second_pass'), bool)
                        or not isinstance(result.get('accepted'), bool)
                        or configuration.get('second_pass_policy') != SECOND_PASS_POLICY
                        or any(isinstance(v, bool) or not isinstance(v, int) or v < 0
                               for v in (first_ms, second_ms))
                        or _sha256(context_file) != context_hash):
                    raise RunError('Запись {}: неверный ответ второго прохода'.format(index))
                context_fields = dict(context_sha256=context_hash, context_candidate_count=len(candidates),
                                      second_pass=result['second_pass'], accepted=result['accepted'],
                                      first_ms=first_ms, second_ms=second_ms)
            config = dict(configuration)
            decode_time = result.get('elapsed_seconds')
            if (isinstance(decode_time, bool) or not isinstance(decode_time, (int, float))
                    or not math.isfinite(decode_time) or decode_time < 0):
                raise RunError('Запись {}: неверное время распознавания'.format(index))
            predictions.append(dict(id=row['id'], hypothesis=result[field]))
            measurements.append(dict(id=row['id'], audio_sha256=info['pcm_sha256'],
                input_wav_sha256=input_hash, config=config, config_sha256=config_hash,
                duration_seconds=info['duration_seconds'], wall_seconds=elapsed,
                decode_seconds=decode_time, **context_fields))
            native_path.unlink()
        # Не публикуем успешный протокол, если файл весов изменился во время прогона.
        if model_digest(model, engine) != model_hash or _sha256(executable) != executable_hash:
            raise RunError('Модель или executable изменились во время прогона')
        if _sha256(manifest) != manifest_hash:
            raise RunError('Описание корпуса изменилось во время прогона')
        if backend_code and _sha256(backend_code) != backend_hash:
            raise RunError('Код Qwen изменился во время прогона')
        protocol = dict(schema_version=1, backend='speakey-{}-cli'.format(engine),
            process_mode='fresh-process-per-record', recognition_mode='isolated-{}-defaults'.format(engine),
            stage=stage, language=language, split=split, model_sha256=model_hash,
            executable_sha256=executable_hash, manifest_sha256=manifest_hash,
            started_at_msk=started_at, samples=measurements)
        protocol['deterministic'] = deterministic
        if context_dir is not None:
            # В CLI второй проход идёт при любых кандидатах, без бюджета времени приложения.
            protocol['context'] = dict(second_pass_policy=SECOND_PASS_POLICY, candidate_limit=8)
        if backend_hash:
            protocol['backend_code_sha256'] = backend_hash
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
    parser.add_argument('--split', choices=('train', 'dev', 'test', 'all'), default='test')
    parser.add_argument('--stage', choices=('raw', 'echo-cleaned'), default='raw')
    parser.add_argument('--engine', choices=('whisper', 'parakeet', 'qwen'), default='whisper')
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--context-dir', help='Каталог из context.py build: второй проход с контекстом (Whisper)')
    parser.add_argument('--deterministic', action='store_true', help='temperature_inc = 0 (Whisper)')
    args = parser.parse_args(argv)
    try:
        result = run_corpus(args.manifest, executable=args.executable, model=args.model,
            output=args.output, language=args.language, split=args.split, stage=args.stage,
            timeout=args.timeout, engine=args.engine,
            context_dir=args.context_dir, deterministic=args.deterministic)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except RunError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
