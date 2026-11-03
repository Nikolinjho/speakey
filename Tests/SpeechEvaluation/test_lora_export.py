"""Экспорт принимает только завершённый и целый адаптер пилота."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

class LoraExportTests(unittest.TestCase):
    def test_отклоняет_незавершённое_обучение_до_загрузки_модели(self):
        from Tools.SpeechEvaluation.whisper_lora_export import validate_training_run
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'run.json').write_text(json.dumps({'completed':False}))
            with self.assertRaises(ValueError):validate_training_run(root,'unused')
    def test_подмена_сохранённого_адаптера_отклоняется(self):
        from Tools.SpeechEvaluation import whisper_lora_export as export
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);adapter=root/'adapter';adapter.mkdir()
            weights=adapter/'adapter_model.safetensors';weights.write_bytes(b'original')
            protocol=dict(completed=True,status='complete',base_model_sha256='base',adapter_sha256={weights.name:hashlib.sha256(b'original').hexdigest()})
            (root/'run.json').write_text(json.dumps(protocol))
            with mock.patch.object(export,'model_digest',return_value='base'):
                export.validate_training_run(root,'base')
                weights.write_bytes(b'changed')
                with self.assertRaises(ValueError):export.validate_training_run(root,'base')
