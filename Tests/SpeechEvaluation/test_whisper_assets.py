"""Целостность исходного Whisper без загрузки весов."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

class WhisperAssetsTests(unittest.TestCase):
    def test_подмена_весов_не_проходит_по_локальному_manifest(self):
        from Tools.SpeechEvaluation import whisper_assets as assets
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'weights').write_bytes(b'original')
            expected={'weights':{'size':8,'sha256':hashlib.sha256(b'original').hexdigest()}}
            with mock.patch.object(assets,'ASSETS',expected):
                self.assertEqual(len(assets.model_digest(root)),64)
                (root/'weights').write_bytes(b'changed!')
                with self.assertRaises(ValueError):assets.model_digest(root)
    def test_отклоняет_симлинк_вместо_весов(self):
        from Tools.SpeechEvaluation import whisper_assets as assets
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'actual').write_bytes(b'original');(root/'weights').symlink_to(root/'actual')
            expected={'weights':{'size':8,'sha256':hashlib.sha256(b'original').hexdigest()}}
            with mock.patch.object(assets,'ASSETS',expected),self.assertRaises(ValueError):assets.model_digest(root)
