#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()

def check(name, command, expected, *, cwd=root, env=None):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode != expected:
        raise SystemExit(f'FAIL: {name}: exit {result.returncode}, ожидался {expected}\n{result.stdout}\n{result.stderr}')
    print(f'PASS: {name}: exit {expected}')

engine = (root / 'Sources/Keyboop/Engine.swift').read_text()
handler = engine.split('func handleNeuralFixMarker(', 1)[1].split('private func neuralRequest()', 1)[0]
for forbidden in ['handlePauseFixMarker(', 'lastRealKeyAt', 'AXScreenCheck', 'NSWorkspace', 'RightLayoutRuntimeFactory']:
    if forbidden in handler:
        raise SystemExit(f'FAIL: запрещённый вызов в нейромаркере: {forbidden}')
print('PASS: Нейромаркер не использует паузный порог, AX и загрузчик модели')
tap = (root / 'Sources/Keyboop/EventTap.swift').read_text()
if tap.index('handleNeuralFixMarker(') > tap.index('handlePauseFixMarker('):
    raise SystemExit('FAIL: нейромаркер должен поглощаться до прежней синтетики')
print('PASS: Нейромаркер поглощается до паузного маркера')

with tempfile.TemporaryDirectory(prefix='keyboop-baseline-contracts-') as temporary:
    work = Path(temporary)
    resources = work / 'resources'
    resources.mkdir()
    for source in (root / 'Sources/Keyboop/Resources').glob('trigrams_*.json'):
        shutil.copy2(source, resources)
    check('Отсутствующие файлы словарей отклоняются',
          ['bash', 'scripts/test-layout-detector.sh', 'baseline'], 1,
          env={**os.environ, 'KEYBOOP_DATA_DIR': str(resources)})

    project = work / 'project'
    (project / 'scripts').mkdir(parents=True)
    (project / 'vendor-patches').mkdir()
    (project / 'vendor').mkdir()
    shutil.copy2(root / 'scripts/setup-layout-diagnostics-build.sh', project / 'scripts')
    shutil.copy2(root / 'vendor-patches/fluidaudio-offline.patch', project / 'vendor-patches')
    for name in ['whisper.cpp', 'FluidAudio']:
        subprocess.run(['git', 'clone', '--quiet', '--shared', str(root / 'vendor' / name),
                        str(project / 'vendor' / name)], check=True, capture_output=True)
    command = ['bash', 'scripts/setup-layout-diagnostics-build.sh', '--check-only']
    check('Чистый checkout принимает точный патч', command, 0, cwd=project)
    check('Повторная проверка принимает точный патч', command, 0, cwd=project)
    fluid = project / 'vendor/FluidAudio'
    for path in [fluid / 'Package.swift', fluid / 'Sources/FluidAudio/DownloadUtils.swift']:
        original = path.read_bytes()
        path.write_bytes(original + '\n// локальное изменение\n'.encode())
        check(f'Изменённый {path.name} отклоняется', command, 1, cwd=project)
        path.write_bytes(original)
    (fluid / 'unknown.txt').write_text('неизвестный файл')
    check('Неизвестный файл отклоняется', command, 1, cwd=project)
PY
