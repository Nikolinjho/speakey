import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/sign-keyboop-app.sh"
SHA = "749281C2A0E19FC82DA85918A28F5BCC195C5597"
OTHER = "A" * 40


class SigningPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keyboop-signing-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = pathlib.Path(self.temp.name).resolve()
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.log = self.work / "codesign.jsonl"
        self.app = self.work / "Staged app.app"
        self.framework = self.app / "Contents/Frameworks/Sparkle.framework"
        self.version = self.framework / "Versions/B"
        for name in ["XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Updater.app"]:
            (self.version / name).mkdir(parents=True)
        (self.version / "Autoupdate").touch()
        (self.app / "Contents/MacOS").mkdir()
        (self.app / "Contents/MacOS/Keyboop").touch()
        (self.app / "Contents/Info.plist").touch()
        self.make_command("security", '''import os, sys
if os.environ.get("SIGN_TEST_SECURITY_FAIL"): sys.exit(31)
print(os.environ.get("SIGN_TEST_IDENTITIES", ""))
''')
        self.make_command("codesign", '''import json, os, sys
args = sys.argv[1:]
with open(os.environ["SIGN_TEST_LOG"], "a") as stream: stream.write(json.dumps(args) + "\\n")
fail = os.environ.get("SIGN_TEST_FAIL")
if fail == "nested" and args[-1].endswith("Downloader.xpc"): sys.exit(42)
if fail == "outer" and args[-1] == os.environ["SIGN_TEST_APP"] and "--verify" not in args: sys.exit(43)
if fail == "verify" and "--verify" in args: sys.exit(44)
''')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        SIGN_TEST_LOG=str(self.log), SIGN_TEST_APP=str(self.app),
                        SIGN_TEST_IDENTITIES=f'  1) {SHA} "Keyboop Local Dev"\n     1 valid identities found')
        self.env.pop("KEYBOOP_SIGN_ID", None)
        self.env.pop("KEYBOOP_RELEASE", None)

    def make_command(self, name, text):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + text)
        path.chmod(0o755)

    def run_helper(self, *args, **env):
        return subprocess.run(["bash", str(HELPER), *(args or [str(self.app)])], cwd=self.work,
                              env=dict(self.env, **env), text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_default_identity_signs_inside_out(self):
        """Постоянная подпись применяется изнутри наружу, затем строго проверяется."""
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        expected = [self.version / "XPCServices/Downloader.xpc", self.version / "XPCServices/Installer.xpc",
                    self.version / "Updater.app", self.version / "Autoupdate", self.framework, self.app]
        self.assertEqual([call[-1] for call in calls[:-1]], list(map(str, expected)))
        for call in calls[:-1]:
            self.assertIn(SHA, call)
            self.assertIn("--timestamp=none", call)
            self.assertNotIn("--deep", call)
        for call in calls[:2]:
            self.assertIn("--preserve-metadata=entitlements", call)
        self.assertIn(str(ROOT / "Keyboop-dev.entitlements"), calls[-2])
        self.assertEqual(calls[-1], ["--verify", "--deep", "--strict", str(self.app)])

    def test_missing_identity_never_signs(self):
        """Отсутствующий сертификат не заменяется ad-hoc подписью."""
        result = self.run_helper(SIGN_TEST_IDENTITIES="0 valid identities found")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_security_error_never_signs(self):
        """Ошибка чтения связки ключей останавливает подпись."""
        self.assertNotEqual(self.run_helper(SIGN_TEST_SECURITY_FAIL="1").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_adhoc_rejected(self):
        """Явная ad-hoc подпись запрещена."""
        self.assertNotEqual(self.run_helper(KEYBOOP_SIGN_ID="-").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_nested_failure_stops_before_outer(self):
        """Ошибка вложенного XPC останавливает все последующие подписи."""
        self.assertNotEqual(self.run_helper(SIGN_TEST_FAIL="nested").returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_outer_failure_stops_before_verification(self):
        """Ошибка внешней подписи возвращается вызывающему скрипту."""
        self.assertNotEqual(self.run_helper(SIGN_TEST_FAIL="outer").returncode, 0)
        self.assertEqual(len(self.calls()), 6)
        self.assertTrue(all("--verify" not in call for call in self.calls()))

    def test_verify_failure_is_fatal(self):
        """Невалидная итоговая подпись не считается готовой сборкой."""
        self.assertNotEqual(self.run_helper(SIGN_TEST_FAIL="verify").returncode, 0)
        self.assertEqual(len(self.calls()), 7)

    def test_identity_check_uses_exact_name_or_hash(self):
        """Проверка принимает точное имя или полный хеш без подписи бандла."""
        for identity in ["Keyboop Local Dev", SHA, SHA.lower()]:
            result = self.run_helper("--check-identity", KEYBOOP_SIGN_ID=identity)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(SHA, result.stdout)
        self.assertNotEqual(self.run_helper("--check-identity", KEYBOOP_SIGN_ID="Keyboop").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_ambiguous_name_rejected(self):
        """Одноимённые сертификаты требуют точного хеша."""
        identities = f'1) {SHA} "Keyboop Local Dev"\n2) {OTHER} "Keyboop Local Dev"'
        self.assertNotEqual(self.run_helper("--check-identity", SIGN_TEST_IDENTITIES=identities).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_release_keeps_runtime_timestamp_and_entitlements(self):
        """Релиз сохраняет hardened runtime, timestamp и релизные entitlements."""
        identities = f'1) {OTHER} "Developer ID Application: Example (TEAM)"'
        result = self.run_helper(KEYBOOP_RELEASE="1", KEYBOOP_SIGN_ID=OTHER, SIGN_TEST_IDENTITIES=identities)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for call in self.calls()[:-1]:
            self.assertIn("--options", call)
            self.assertIn("runtime", call)
            self.assertIn("--timestamp", call)
            self.assertNotIn("--timestamp=none", call)
        self.assertIn(str(ROOT / "Keyboop.entitlements"), self.calls()[-2])

    def test_live_app_and_symlink_rejected(self):
        """Установленный бандл и ссылка на него не переподписываются."""
        alias = self.work / "Alias.app"
        alias.symlink_to("/Applications/Keyboop_local.app")
        for target in ["/Applications/Keyboop_local.app", str(alias)]:
            self.assertNotEqual(self.run_helper(target).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_missing_nested_code_rejected_before_signing(self):
        """Неполный Sparkle отклоняется до изменения подписей."""
        (self.version / "Autoupdate").unlink()
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_build_stops_at_identity_preflight(self):
        """Сборка без сертификата останавливается до копирования и компиляции."""
        self.make_command("swift", "import sys\nsys.exit(98)\n")
        self.make_command("swiftc", "import sys\nsys.exit(98)\n")
        env = dict(self.env, SIGN_TEST_IDENTITIES="0 valid identities found", KEYBOOP_BUILD_APP=str(self.app))
        result = subprocess.run(["bash", str(ROOT / "build-app.sh")], cwd=self.work, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Сертификат подписи отсутствует", result.stderr)
        self.assertNotIn("swiftc compile", result.stdout)
        self.assertTrue((self.app / "Contents/MacOS/Keyboop").exists())
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
