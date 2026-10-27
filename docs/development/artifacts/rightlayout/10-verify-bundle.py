# Проверка временной dev-сборки без запуска приложения.
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

bundle = Path('/private/tmp/Keyboop_rightlayout.app')
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(bundle)], check=True)
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'ru.keyboop.app.dev'
assert 'SUFeedURL' not in info
resources = bundle / 'Contents/Resources/RightLayout'
source = Path('Sources/Keyboop/Resources/RightLayout')
for name in ['model.json', 'LICENSE', 'profile.json']:
    assert (resources / name).read_bytes() == (source / name).read_bytes(), name
manifest = json.loads((resources / 'model.json').read_bytes())
assert manifest['sha256'] == '5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704'
assert hashlib.sha256((source / 'LayoutClassifier.mlmodel').read_bytes()).hexdigest() == manifest['sha256']
profile = json.loads((resources / 'profile.json').read_bytes())
assert profile['enabled'] is False
assert profile['reason'] == 'recall-gain-below-0.05'
assert (resources / 'LayoutClassifier.mlmodelc').is_dir()
assert sum(p.stat().st_size for p in (resources / 'LayoutClassifier.mlmodelc').rglob('*') if p.is_file()) > 10_000_000
files = sorted(p for p in bundle.rglob('*') if p.is_file() and not p.is_symlink())
hash_tree = hashlib.sha256()
for path in files:
    hash_tree.update(str(path.relative_to(bundle)).encode())
    hash_tree.update(b'\0')
    hash_tree.update(path.read_bytes())
    hash_tree.update(b'\0')
executable = bundle / 'Contents/MacOS/Keyboop'
print(json.dumps({
    'bundleID': info['CFBundleIdentifier'], 'SUFeedURLPresent': 'SUFeedURL' in info,
    'modelSHA256': manifest['sha256'], 'profileEnabled': profile['enabled'],
    'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
    'bundleTreeSHA256': hash_tree.hexdigest(),
    'bundleHashMethod': 'sorted regular files: relative UTF8 path + NUL + bytes + NUL; symlinks excluded',
    'regularFiles': len(files)
}, indent=2))
