"""Подтверждение дословного эталона отдельно от ответа распознавания."""
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import wave
from Tools.SpeechEvaluation import corrections

class CorrectionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        with wave.open(str((self.root/'audio.wav').resolve()),'wb') as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
            audio.writeframes(b'\0\0'*1600)
        self.draft=self.root/'draft.jsonl'
        self.draft.write_text(json.dumps(dict(id='one',audio='audio.wav',reference='Модель придумала',reference_confirmed=False))+'\n')
        self.reference=self.root/'reference.txt'
        self.reference.write_text('Реально сказанное.')
        self.output=self.root/'confirmed.jsonl'
    def confirm(self,**kwargs):
        return corrections.confirm(self.draft,reference_file=self.reference,output=self.output,session_id='day-one',split='dev',**kwargs)
    def test_использует_явный_эталон_вместо_ответа_модели(self):
        self.confirm()
        row=json.loads(self.output.read_text())
        self.assertEqual(row['reference'],'Реально сказанное.')
        self.assertTrue(row['reference_confirmed'])
        self.assertEqual(row['reference_source'],'explicit_user_confirmation')
        self.assertEqual(row['session_id'],'day-one')
        self.assertEqual(row['split'],'dev')
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode),0o600)
        self.assertEqual(row['audio'],str((self.root/'audio.wav').resolve()))
        self.assertNotIn('Модель придумала',self.output.read_text())
    def test_пустой_эталон_требует_явного_подтверждения_тишины(self):
        self.reference.write_text('')
        with self.assertRaises(corrections.CorrectionError): self.confirm()
        self.confirm(silence=True)
        self.assertEqual(json.loads(self.output.read_text())['kind'],'silence')
    def test_отделяет_редактуру_от_дословного_эталона(self):
        edited=self.root/'edited.txt'; edited.write_text('Желаемое оформление')
        self.confirm(edited_file=edited)
        row=json.loads(self.output.read_text())
        self.assertEqual(row['edited_text'],'Желаемое оформление')
        self.assertEqual(row['reference'],'Реально сказанное.')
    def test_не_перезаписывает_существующий_эталон(self):
        self.output.write_text('keep')
        with self.assertRaises(corrections.CorrectionError): self.confirm()
        self.assertEqual(self.output.read_text(),'keep')
    def test_не_записывает_личный_эталон_в_репозиторий(self):
        self.output=Path(__file__).resolve().parents[2]/'.private-confirmed.jsonl'
        with self.assertRaises(corrections.CorrectionError): self.confirm()
        self.assertFalse(self.output.exists())
    def test_сбой_записи_не_оставляет_частичный_эталон(self):
        with mock.patch.object(corrections.os,'fsync',side_effect=OSError('disk full')):
            with self.assertRaises(corrections.CorrectionError): self.confirm()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob('.speech-confirm-*')))
        self.confirm()

    def test_ошибка_не_раскрывает_личный_текст(self):
        self.reference.write_bytes(b'\xff')
        with self.assertRaises(corrections.CorrectionError) as caught: self.confirm()
        self.assertNotIn(str(self.root),str(caught.exception))
        self.assertFalse(self.output.exists())

if __name__=='__main__': unittest.main()
