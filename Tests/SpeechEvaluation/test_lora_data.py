"""Разделение личного корпуса для пилота обучения."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import wave

class LoraDataTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.manifest=self.root/'manifest.jsonl'
    def row(self,id,day,text,seconds=.1):
        path=self.root/(id+'.wav')
        with wave.open(str(path),'wb') as audio:
            audio.setparams((1,2,16000,0,'NONE','not compressed'))
            audio.writeframes(struct.pack('<h',100+len(id))*round(seconds*16000))
        return dict(id=id,audio=path.name,reference=text,reference_confirmed=True,session_id=day,split='dev',created_at=day+'T12:00:00+03:00')
    def prepare(self,rows):
        self.manifest.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
        from Tools.SpeechEvaluation.lora_data import prepare_corpus
        return prepare_corpus(self.manifest)
    def test_откладывает_старый_день_целиком(self):
        rows=[self.row('one','2026-10-30','Первый эталон'),self.row('two-new','2026-11-02','Другие слова')]
        split=self.prepare(rows)
        self.assertEqual([r['id'] for r in split['validation']],['one'])
        self.assertEqual([r['id'] for r in split['train']],['two-new'])
    def test_один_день_не_создаёт_фиктивную_валидацию(self):
        from Tools.SpeechEvaluation.lora_data import TrainingDataError
        with self.assertRaises(TrainingDataError):self.prepare([self.row('one','2026-11-02','Первый эталон')])
    def test_отклоняет_дубли_эталона_между_днями(self):
        from Tools.SpeechEvaluation.lora_data import TrainingDataError
        with self.assertRaises(TrainingDataError):self.prepare([self.row('one','2026-10-30','Одинаковая фраза'),self.row('long-id','2026-11-02','Одинаковая фраза!')])
    def test_длинная_запись_явно_исключена_из_обучения_и_сохранена_для_оценки(self):
        rows=[self.row('one','2026-10-30','Первый эталон'),self.row('two-new','2026-11-02','Другие слова'),self.row('long-clip','2026-11-02','Длинная речь',30.01)]
        split=self.prepare(rows)
        self.assertEqual(len(split['train']),1)
        self.assertEqual(split['excluded_train'][0]['id'],'long-clip')
        self.assertEqual(len(split['all']),3)
    def test_не_использует_зарезервированную_итоговую_выборку(self):
        from Tools.SpeechEvaluation.lora_data import TrainingDataError
        rows=[self.row('one','2026-10-30','Первый эталон'),self.row('two-new','2026-11-02','Другие слова')];rows[0]['split']='test'
        with self.assertRaises(TrainingDataError):self.prepare(rows)
    def test_запрещает_результат_в_репозитории_и_перезапись(self):
        from Tools.SpeechEvaluation.lora_data import private_output,TrainingDataError
        with self.assertRaises(TrainingDataError):private_output(Path(__file__).resolve().parents[2]/'private-lora-test')
        with self.assertRaises(TrainingDataError):private_output(self.root)
        output=private_output(self.root/'new')
        self.assertEqual(output.stat().st_mode&0o777,0o700)
    def test_учитывает_календарный_день_в_MSK(self):
        rows=[self.row('one','2026-10-30','Первый эталон'),self.row('two-new','2026-11-01','Другие слова')]
        rows[1]['created_at']='2026-11-01T22:00:00+00:00'
        self.assertEqual(self.prepare(rows)['train_days'],['2026-11-02'])

    def test_одинаковое_аудио_между_днями_не_скрывается_за_другим_эталоном(self):
        from Tools.SpeechEvaluation.lora_data import TrainingDataError
        rows=[self.row('one','2026-10-30','Первый эталон'),self.row('two','2026-11-02','Другие слова')]
        with self.assertRaises(TrainingDataError):self.prepare(rows)

    def test_пустой_эталон_речи_не_становится_примером_тишины(self):
        from Tools.SpeechEvaluation.lora_data import TrainingDataError
        for text in ['', '   ']:
            with self.subTest(text=text),self.assertRaises(TrainingDataError):
                self.prepare([self.row('one','2026-10-30','Первый эталон'),self.row('two-new','2026-11-02',text)])
    def test_явно_подтверждённая_тишина_допустима(self):
        row=self.row('two-new','2026-11-02','');row['kind']='silence'
        split=self.prepare([self.row('one','2026-10-30','Первый эталон'),row])
        self.assertEqual(len(split['train']),1)
