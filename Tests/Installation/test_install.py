import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[2] / 'scripts' / 'install-speakey.py'
spec = importlib.util.spec_from_file_location('speakey_installer', MODULE_PATH)
installer = importlib.util.module_from_spec(spec)
if MODULE_PATH.exists():
    spec.loader.exec_module(installer)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_copy_preserves_hidden_key_and_refuses_conflicting_destination(self):
        """Копия сохраняет скрытый ключ и не перезаписывает чужие данные."""
        source, target = self.root / 'source', self.root / 'target'
        source.mkdir()
        (source / '.histkey').write_bytes(b'key')
        (source / 'history.enc').write_bytes(b'history')
        installer.copy_directory_safely(source, target)
        self.assertEqual((target / '.histkey').read_bytes(), b'key')
        installer.copy_directory_safely(source, target)
        (target / 'history.enc').write_bytes(b'other')
        with self.assertRaises(RuntimeError):
            installer.copy_directory_safely(source, target)
        self.assertEqual((target / 'history.enc').read_bytes(), b'other')
        self.assertEqual((source / 'history.enc').read_bytes(), b'history')

    def test_rejects_symlinks_and_missing_history_key(self):
        """Миграция отклоняет ссылки и историю без исходного ключа."""
        source = self.root / 'source'
        source.mkdir()
        (source / 'history.enc').write_bytes(b'history')
        with self.assertRaises(RuntimeError):
            installer.check_history_key(source)
        (source / '.histkey').write_bytes(b'k' * 32)
        installer.check_history_key(source)
        (source / 'outside').symlink_to(self.root)
        with self.assertRaises(RuntimeError):
            installer.copy_directory_safely(source, self.root / 'target')
        self.assertFalse((self.root / 'target').exists())

    def test_merge_preserves_existing_extra_files_and_empty_directories(self):
        """Перенос объединяет пустые папки и сохраняет существующие файлы."""
        source, target = self.root / 'source', self.root / 'target'
        source.mkdir(); target.mkdir()
        (source / 'models').mkdir(); (target / 'models').mkdir()
        (source / 'history.enc').write_bytes(b'history')
        (target / 'extra').write_bytes(b'keep')
        installer.copy_directory_safely(source, target)
        self.assertEqual((target / 'history.enc').read_bytes(), b'history')
        self.assertEqual((target / 'extra').read_bytes(), b'keep')

    def test_preferences_transport_preserves_types_and_user_text(self):
        """Перенос defaults сохраняет пользовательские строки и типы."""
        values = {'text': 'Previous Name should stay', 'enabled': True, 'count': 3,
                  'nested': {'items': [b'opaque', 'text']}}
        seen = []
        def run(args, **kwargs):
            seen.append(args)
            if args[1] == 'export':
                return subprocess.CompletedProcess(args, 0, plistlib.dumps(values), b'')
            if args[1] == 'import':
                self.assertEqual(plistlib.loads(Path(args[3]).read_bytes()), values)
                return subprocess.CompletedProcess(args, 0, b'', b'')
            raise AssertionError(args)
        exported = installer.export_preferences('old.example', runner=run)
        installer.import_preferences('dev.speakey.app.dev', exported, runner=run)
        self.assertEqual(exported, values)
        self.assertEqual(seen[1][2], 'dev.speakey.app.dev')

    def test_preferences_failure_does_not_expose_payload(self):
        """Ошибка defaults не выводит содержимое настроек."""
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, b'secret', b'secret')
        with self.assertRaisesRegex(RuntimeError, '^defaults export failed$'):
            installer.export_preferences('example', runner=run)

    def make_app(self, root, identifier='dev.speakey.app.dev', executable='Speakey'):
        app = root / 'Speakey.app'
        (app / 'Contents' / 'MacOS').mkdir(parents=True)
        (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': executable,
            'CFBundlePackageType': 'APPL', 'CFBundleName': 'Speakey'}))
        binary = app / 'Contents' / 'MacOS' / executable
        binary.write_bytes(b'executable')
        binary.chmod(0o755)
        return app

    def test_staged_identity_and_signature_are_required(self):
        """Стадия проверяет имя executable, bundle ID и строгую подпись."""
        app = self.make_app(self.root)
        with patch.object(installer, 'verify_signature') as verify:
            installer.validate_bundle(app, expected_id='dev.speakey.app.dev', expected_executable='Speakey')
            verify.assert_called_once_with(app)
            with self.assertRaises(RuntimeError):
                installer.validate_bundle(app, expected_id='foreign.app')
            (app / 'Contents' / 'MacOS' / 'Speakey').chmod(0o644)
            with self.assertRaises(RuntimeError):
                installer.validate_bundle(app)

    def test_replacement_restores_original_on_validation_failure(self):
        """Провал после замены возвращает исходный бандл из резервной копии."""
        old_dir, new_dir, backup = self.root / 'old', self.root / 'new', self.root / 'backup'
        old_dir.mkdir(); new_dir.mkdir(); backup.mkdir()
        target = self.make_app(old_dir, executable='Previous')
        incoming = self.make_app(new_dir)
        with self.assertRaises(RuntimeError):
            installer.replace_bundle(incoming, target, backup, verify=lambda _: (_ for _ in ()).throw(RuntimeError('bad')))
        self.assertTrue((target / 'Contents' / 'MacOS' / 'Previous').exists())
        self.assertTrue((backup / 'failed-incoming.app' / 'Contents' / 'MacOS' / 'Speakey').exists())

    def test_replacement_keeps_original_backup_after_success(self):
        """Успешная замена сохраняет исходное приложение в резервной копии."""
        old_dir, new_dir, backup = self.root / 'old', self.root / 'new', self.root / 'backup'
        old_dir.mkdir(); new_dir.mkdir(); backup.mkdir()
        target = self.make_app(old_dir, executable='Previous')
        incoming = self.make_app(new_dir)
        installer.replace_bundle(incoming, target, backup, verify=lambda _: None)
        self.assertTrue((backup / 'original.app' / 'Contents' / 'MacOS' / 'Previous').exists())
        self.assertTrue((target / 'Contents' / 'MacOS' / 'Speakey').exists())

    def test_second_rename_failure_restores_original(self):
        """Ошибка переименования incoming не оставляет приложение отсутствующим."""
        old_dir, new_dir, backup = self.root / 'old', self.root / 'new', self.root / 'backup'
        old_dir.mkdir(); new_dir.mkdir(); backup.mkdir()
        target = self.make_app(old_dir, executable='Previous')
        incoming = self.make_app(new_dir)
        real_rename = Path.rename
        def rename(path, destination):
            if path == incoming:
                raise OSError('simulated rename failure')
            return real_rename(path, destination)
        with patch.object(Path, 'rename', rename), self.assertRaises(OSError):
            installer.replace_bundle(incoming, target, backup, verify=lambda _: None)
        self.assertTrue((target / 'Contents' / 'MacOS' / 'Previous').exists())
        self.assertTrue(incoming.exists())

    def test_invalid_stage_aborts_before_quit(self):
        """Плохая подпись стадии не закрывает исходное приложение."""
        source_dir, target_dir = self.root / 'source', self.root / 'target'
        source_dir.mkdir(); target_dir.mkdir()
        source, target = self.make_app(source_dir), self.make_app(target_dir)
        def command(args):
            if str(args[0]) == '/usr/bin/ditto':
                import shutil
                shutil.copytree(str(args[1]), str(args[2]))
            return b''
        def signature(app):
            if app.name == 'incoming.app':
                raise RuntimeError('bad stage signature')
        with patch.object(installer, 'checked', side_effect=command), patch.object(installer, 'verify_signature', side_effect=signature), patch.object(installer, 'stop_application') as stop, patch('builtins.print'):
            with self.assertRaisesRegex(RuntimeError, 'bad stage signature'):
                installer.main([str(source), '--target', str(target), '--no-launch'])
        stop.assert_not_called()
        self.assertTrue(target.exists())

    def test_stop_timeout_sends_no_signal_and_preserves_app(self):
        """Таймаут helper прерывает установку без принудительного завершения."""
        app = self.make_app(self.root)
        with patch.object(installer, 'checked', return_value=b'') as command, patch.object(installer, 'bundle_processes', return_value=[42]), patch.object(installer.time, 'monotonic', side_effect=[0, 100]):
            with self.assertRaisesRegex(RuntimeError, 'No signals were sent'):
                installer.stop_application(app, timeout=1)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args[0][0][0], '/usr/bin/osascript')
        self.assertTrue(app.exists())

    def test_state_backup_preserves_preferences_without_text_rewriting(self):
        """Резервная копия содержит свежий defaults export без замены строк."""
        home = self.root / 'home'
        support = home / 'Library' / 'Application Support' / 'Previous'
        support.mkdir(parents=True)
        (support / 'data').write_bytes(b'data')
        backup = self.root / 'backup'
        backup.mkdir()
        values = {'text': 'Previous Name user text', 'number': 4}
        with patch.object(Path, 'home', return_value=home), patch.object(installer, 'preference_domains', return_value={'previous.example'}), patch.object(installer, 'export_preferences', return_value=values):
            installer.backup_state({'CFBundleExecutable': 'Previous', 'CFBundleIdentifier': 'previous.example'}, backup)
        self.assertEqual((backup / 'state' / 'Previous' / 'data').read_bytes(), b'data')
        preferences = backup / 'state' / 'preferences.plist'
        self.assertEqual(plistlib.loads(preferences.read_bytes()), values)
        self.assertEqual(preferences.stat().st_mode & 0o777, 0o600)

    def test_process_matching_requires_exact_bundle_prefix(self):
        """Ожидание остановки не захватывает приложения с похожим именем."""
        output = '12 /Applications/Speakey.app/Contents/MacOS/Previous\n13 /Applications/Speakey.app/Contents/Library/LoginItems/Helper\n14 /Applications/Speakey.app.other/Contents/MacOS/Speakey\n'
        self.assertEqual(installer.bundle_processes(Path('/Applications/Speakey.app'), output), [12, 13])


if __name__ == '__main__':
    unittest.main()
