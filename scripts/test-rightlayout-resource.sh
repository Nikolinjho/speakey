#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/fetch-rightlayout-model.sh"
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
relative = Path('Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel')
source = root / relative
original = source.read_bytes()
expected_sha = '5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704'
assert hashlib.sha256(original).hexdigest() == expected_sha
manifest = json.loads((root / 'Resources/RightLayout/model.json').read_text())
assert manifest['modelID'] == 'rightlayout-ensemble-20-v1'
assert manifest['sourceCommit'] == '58658d8d4c3b71ed4cfd6b20627196a8145f17f9'
assert manifest['sha256'] == expected_sha
assert manifest['sourceBytes'] == len(original) == 13880886
assert manifest['parameters'] == 3462292
assert manifest['inputLength'] == 20
assert manifest['classes'] == ['ru', 'en', 'he', 'ru_from_en', 'he_from_en', 'en_from_ru', 'en_from_he', 'he_from_ru', 'ru_from_he']
assert (root / 'Sources/Keyboop/Resources/RightLayout/model.json').read_bytes() == (root / 'Resources/RightLayout/model.json').read_bytes()
assert (root / 'Sources/Keyboop/Resources/RightLayout/LICENSE').read_bytes() == (root / 'Resources/RightLayout/LICENSE').read_bytes()
print('PASS: manifest, лицензия и контрольная сумма модели')

with tempfile.TemporaryDirectory(prefix='keyboop-rightlayout-test-') as temporary:
    fixture = Path(temporary)
    (fixture / 'scripts').mkdir()
    shutil.copy2(root / 'scripts/fetch-rightlayout-model.sh', fixture / 'scripts')
    shutil.copytree(root / 'Resources/RightLayout', fixture / 'Resources/RightLayout')
    target = fixture / relative
    target.parent.mkdir(parents=True)
    shutil.copy2(source, target)
    bin_dir = fixture / 'bin'
    bin_dir.mkdir()
    marker = fixture / 'network-used'
    curl = bin_dir / 'curl'
    curl.write_text('#!/bin/bash\nset -eu\ntouch "$TEST_NETWORK_MARKER"\nwhile [ "$#" -gt 0 ]; do\n  if [ "$1" = --output ]; then cp "$TEST_DOWNLOAD_SOURCE" "$2"; exit 0; fi\n  shift\ndone\nexit 99\n')
    curl.chmod(0o755)
    environment = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'TEST_NETWORK_MARKER': str(marker), 'TEST_DOWNLOAD_SOURCE': str(source)}

    def run(*arguments, success):
        result = subprocess.run(['bash', str(fixture / 'scripts/fetch-rightlayout-model.sh'), *arguments], env=environment, text=True, capture_output=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result

    run('--check-only', success=True)
    assert not marker.exists(), '--check-only обратился в сеть'
    damaged = bytearray(original)
    damaged[len(damaged) // 2] ^= 1
    target.write_bytes(damaged)
    run('--check-only', success=False)
    run(success=False)
    assert target.read_bytes() == damaged, 'Несовместимый ресурс перезаписан'
    assert not marker.exists(), 'Несовместимый ресурс вызвал скачивание'
    print('PASS: повреждённая копия отклонена без перезаписи и сети')
    target.unlink()
    run('--check-only', success=False)
    assert not marker.exists(), 'Отсутствующий ресурс вызвал сеть в --check-only'
    run('--unknown', success=False)
    run('--check-only', '--check-only', success=False)
    assert not marker.exists()
    print('PASS: --check-only и неверные аргументы не вызывают сеть')
    damaged_source = fixture / 'corrupt.mlmodel'
    damaged_source.write_bytes(damaged)
    environment['TEST_DOWNLOAD_SOURCE'] = str(damaged_source)
    run(success=False)
    assert marker.exists()
    assert not target.exists(), 'Повреждённое скачивание опубликовано'
    assert not list(target.parent.glob('.LayoutClassifier.*')), 'Остался временный файл'
    print('PASS: повреждённое скачивание не опубликовано')
    environment['TEST_DOWNLOAD_SOURCE'] = str(source)
    run(success=True)
    assert target.read_bytes() == original
    marker.unlink()
    run(success=True)
    assert not marker.exists(), 'Проверенная модель скачана повторно'
    print('PASS: проверенное скачивание сохранено, повторный запуск без сети')

    shutil.copy2(root / 'build-app.sh', fixture / 'build-app.sh')
    shutil.copy2(root / 'Sources/Keyboop/L10n.swift', fixture / 'Sources/Keyboop/L10n.swift')
    app = fixture / 'Existing.app'
    app.mkdir()
    sentinel = app / 'keep.txt'
    sentinel.write_text('Существующий bundle')
    compiler_marker = fixture / 'compiler-used'
    swift = bin_dir / 'swift'
    swift.write_text('#!/bin/bash\nset -eu\ntouch "$TEST_COMPILER_MARKER"\necho "Ожидаемый отказ компилятора" >&2\nexit 73\n')
    swift.chmod(0o755)
    environment.update(KEYBOOP_BUILD_APP=str(app), TEST_COMPILER_MARKER=str(compiler_marker))
    result = subprocess.run(['bash', str(fixture / 'build-app.sh')], env=environment, text=True, capture_output=True)
    assert result.returncode == 73, result.stdout + result.stderr
    assert compiler_marker.exists(), 'Сборка не дошла до компилятора модели'
    assert sentinel.read_text() == 'Существующий bundle'
    assert list(app.iterdir()) == [sentinel], 'Сборка изменила существующее приложение'
    print('PASS: отказ компиляции модели сохраняет существующее приложение')

assert source.read_bytes() == original, 'Настоящий ресурс изменён тестом'
print('PASS: настоящий ресурс не изменён')
PY
