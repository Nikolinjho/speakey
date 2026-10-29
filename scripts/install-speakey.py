#!/usr/bin/env python3
"""Stage, stop and replace a local app while retaining its previous bundle."""
import argparse
from datetime import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


def checked(args):
    result = subprocess.run([str(arg) for arg in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError('{} failed (exit {})'.format(Path(args[0]).name, result.returncode))
    return result.stdout


def directory_manifest(source):
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise RuntimeError('Expected a real directory: {}'.format(source))
    result = {}
    for path in sorted(source.rglob('*')):
        info = path.lstat()
        relative = str(path.relative_to(source))
        if stat.S_ISLNK(info.st_mode):
            raise RuntimeError('Refusing symlink in data directory: {}'.format(path))
        if stat.S_ISDIR(info.st_mode):
            result[relative] = ('directory',)
        elif stat.S_ISREG(info.st_mode):
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            result[relative] = ('file', digest.digest())
        else:
            raise RuntimeError('Refusing special file: {}'.format(path))
    return result


def require_identical_or_absent(source, destination):
    expected = directory_manifest(source)
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        existing = directory_manifest(destination)
        for name, value in expected.items():
            if name in existing and existing[name] != value:
                raise RuntimeError('Destination contains conflicting data: {}'.format(destination / name))
    return expected


def copy_directory_safely(source, destination):
    source, destination = Path(source), Path(destination)
    expected = require_identical_or_absent(source, destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.speakey-copy-', dir=str(destination.parent)))
    try:
        shutil.copytree(str(source), str(stage / 'data'), copy_function=shutil.copy2)
        if directory_manifest(stage / 'data') != expected:
            raise RuntimeError('Data changed during copy; installation aborted')
        if not destination.exists() and not destination.is_symlink():
            (stage / 'data').rename(destination)
            return
        require_identical_or_absent(stage / 'data', destination)
        for relative, entry in expected.items():
            target = destination / relative
            if entry[0] == 'directory':
                target.mkdir(exist_ok=True)
            elif not target.exists():
                # hard link создаёт новый файл атомарно и отказывает при совпадении имени.
                os.link(str(stage / 'data' / relative), str(target))
    finally:
        shutil.rmtree(str(stage))


def check_history_key(directory):
    directory = Path(directory)
    if (directory / 'history.enc').exists():
        key = directory / '.histkey'
        if key.is_symlink() or not key.is_file() or key.stat().st_size != 32:
            raise RuntimeError('Encrypted history has no valid original .histkey; refusing migration')


def export_preferences(domain, runner=subprocess.run):
    result = runner(['/usr/bin/defaults', 'export', domain, '-'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError('defaults export failed')
    try:
        values = plistlib.loads(result.stdout)
        if not isinstance(values, dict):
            raise ValueError('not a dictionary')
        return values
    except Exception:
        raise RuntimeError('defaults export returned invalid plist') from None


def import_preferences(domain, values, runner=subprocess.run):
    with tempfile.TemporaryDirectory(prefix='speakey-prefs-') as temporary:
        path = Path(temporary) / 'preferences.plist'
        path.write_bytes(plistlib.dumps(values))
        path.chmod(0o600)
        result = runner(['/usr/bin/defaults', 'import', domain, str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('defaults import failed')


def preference_domains():
    return {value.strip() for value in checked(['/usr/bin/defaults', 'domains']).decode().strip().split(',')}


def backup_state(info, backup):
    support = Path.home() / 'Library' / 'Application Support'
    state = backup / 'state'
    state.mkdir(mode=0o700)
    for name in {info['CFBundleExecutable'], info['CFBundleIdentifier']}:
        source = support / name
        if source.exists() or source.is_symlink():
            check_history_key(source)
            copy_directory_safely(source, state / name)
    domain = info['CFBundleIdentifier']
    if domain in preference_domains():
        path = state / 'preferences.plist'
        path.write_bytes(plistlib.dumps(export_preferences(domain)))
        path.chmod(0o600)


def verify_signature(app):
    checked(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])


def validate_bundle(app, expected_id=None, expected_executable=None):
    app = Path(app)
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError('Expected a real app bundle')
    if (app / 'Contents').is_symlink() or (app / 'Contents' / 'MacOS').is_symlink():
        raise RuntimeError('Refusing symlink bundle directories')
    info_path = app / 'Contents' / 'Info.plist'
    if info_path.is_symlink():
        raise RuntimeError('Refusing symlink Info.plist')
    try:
        info = plistlib.loads(info_path.read_bytes())
        identifier, executable = info['CFBundleIdentifier'], info['CFBundleExecutable']
    except Exception:
        raise RuntimeError('Invalid app Info.plist') from None
    if not isinstance(identifier, str) or not identifier or not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise RuntimeError('Invalid app identity')
    if info.get('CFBundlePackageType') != 'APPL':
        raise RuntimeError('Not an application bundle')
    if expected_id and identifier != expected_id:
        raise RuntimeError('Unexpected bundle identifier')
    if expected_executable and executable != expected_executable:
        raise RuntimeError('Unexpected bundle executable')
    binary = app / 'Contents' / 'MacOS' / executable
    if binary.is_symlink() or not binary.is_file() or not os.access(str(binary), os.X_OK):
        raise RuntimeError('Missing or non-executable app binary')
    verify_signature(app)
    return info


def bundle_processes(app, output=None):
    if output is None:
        output = checked(['/bin/ps', '-axww', '-o', 'pid=', '-o', 'comm=']).decode()
    prefix = str(app) + '/Contents/'
    found = []
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and parts[1].startswith(prefix):
            found.append(int(parts[0]))
    return found


def stop_application(app, timeout=45):
    # NSRunningApplication завершается только при точном совпадении bundleURL.
    script = '''ObjC.import('AppKit');
function run(argv) {
    var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    for (var i = 0; i < apps.count; i++) {
        var app = apps.objectAtIndex(i);
        if (app.bundleURL && ObjC.unwrap(app.bundleURL.path) === argv[0]) {
            app.terminate;
        }
    }
}'''
    checked(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script, str(app)])
    deadline = time.monotonic() + timeout
    while bundle_processes(app):
        if time.monotonic() >= deadline:
            raise RuntimeError('App or helper did not stop; original app preserved. No signals were sent.')
        time.sleep(0.25)
    # Helpers могут завершаться позже GUI. Требуем короткий устойчивый период без процессов.
    time.sleep(1)
    if bundle_processes(app):
        raise RuntimeError('App helper restarted; original app preserved')


def replace_bundle(incoming, target, backup, verify):
    incoming, target, backup = Path(incoming), Path(target), Path(backup)
    original = backup / 'original.app'
    moved_original = False
    installed = False
    try:
        if target.exists():
            if original.exists():
                raise RuntimeError('Original backup already exists')
            target.rename(original)
            moved_original = True
        incoming.rename(target)
        installed = True
        verify(target)
    except BaseException:
        if installed:
            target.rename(backup / 'failed-incoming.app')
        if moved_original:
            original.rename(target)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prepared_app', type=Path)
    parser.add_argument('--target', type=Path, default=Path('/Applications/Speakey.app'))
    parser.add_argument('--expected-id', default='dev.speakey.app.dev')
    parser.add_argument('--expected-installed-id')
    parser.add_argument('--before-install', type=Path)
    parser.add_argument('--no-launch', action='store_true')
    args = parser.parse_args(argv)
    source = args.prepared_app.resolve()
    target = args.target.absolute()
    if target.is_symlink() or target.name != 'Speakey.app' or target.parent.is_symlink():
        raise RuntimeError('Refusing unexpected target path')
    if source == target:
        raise RuntimeError('Prepared app must differ from target')
    validate_bundle(source, expected_id=args.expected_id, expected_executable='Speakey')
    installed_info = None
    if target.exists():
        installed_info = validate_bundle(target, expected_id=args.expected_installed_id or args.expected_id)
        if installed_info.get('CFBundleName') != 'Speakey':
            raise RuntimeError('Refusing to replace a foreign application')
    if args.before_install and (args.before_install.is_symlink() or not args.before_install.is_file()):
        raise RuntimeError('Invalid migration script')
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = target.parent / ('.Speakey-backup-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700)
    incoming = backup / 'incoming.app'
    print('Backup: {}'.format(backup), flush=True)
    # Копия находится на том же томе, поэтому последующее переименование атомарно.
    checked(['/usr/bin/ditto', source, incoming])
    validate_bundle(incoming, expected_id=args.expected_id, expected_executable='Speakey')
    if installed_info:
        stop_application(target)
    if installed_info:
        backup_state(installed_info, backup)
    if args.before_install:
        migration = subprocess.run([sys.executable, str(args.before_install), '--installer', str(Path(__file__).resolve()), '--backup', str(backup)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if migration.returncode:
            details = backup / 'migration-error.txt'
            details.write_bytes(migration.stderr)
            details.chmod(0o600)
            raise RuntimeError('Migration failed; details saved privately: {}'.format(details))
    if bundle_processes(target):
        raise RuntimeError('App restarted during backup; installation aborted')
    replace_bundle(incoming, target, backup,
                   verify=lambda app: validate_bundle(app, expected_id=args.expected_id, expected_executable='Speakey'))
    print('Installed and verified: {}'.format(target), flush=True)
    if not args.no_launch:
        checked(['/usr/bin/open', target])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Installation aborted: {}'.format(error), file=sys.stderr)
        sys.exit(1)
