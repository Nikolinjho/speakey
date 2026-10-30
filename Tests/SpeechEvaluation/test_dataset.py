import json
from pathlib import Path
import sys
import struct
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools' / 'SpeechEvaluation'))
import dataset


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def audio(self, name='one.wav', channels=1, rate=16000, sample=1):
        path = self.root / name
        with wave.open(str(path), 'wb') as out:
            out.setnchannels(channels)
            out.setsampwidth(2)
            out.setframerate(rate)
            out.writeframes(sample.to_bytes(2, 'little', signed=True) * 1600 * channels)
        return name

    def row(self, **changes):
        row = dict(id='one', audio=self.audio(), reference='Привет, мир!',
                   reference_confirmed=True, session_id='session-one', split='train')
        row.update(changes)
        return row

    def validate(self, rows):
        path = self.root / 'manifest.jsonl'
        path.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))
        return dataset.validate_manifest(path)

    def test_принимает_подтвержденную_запись(self):
        result = self.validate([self.row(edited_text='Отредактированный текст')])
        self.assertEqual(len(result), 1)
        self.assertAlmostEqual(result[0]['duration_seconds'], .1)
        self.assertEqual(result[0]['reference'], 'Привет, мир!')

    def test_принимает_подтвержденную_тишину(self):
        self.assertEqual(len(self.validate([self.row(reference='', kind='silence')])), 1)

    def test_принимает_float32_экспорт_и_находит_его_дубли(self):
        row = self.row()
        payload = struct.pack('<ff', -0.0, 0.5)
        fmt = struct.pack('<HHIIHH', 3, 1, 16000, 64000, 4, 32)
        body = b'WAVEfmt ' + struct.pack('<I', len(fmt)) + fmt
        body += b'data' + struct.pack('<I', len(payload)) + payload
        (self.root / row['audio']).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
        result = self.validate([row])
        self.assertEqual(result[0]['duration_seconds'], 2 / 16000)
        second = dict(row, id='two', reference='Другой текст', session_id='second', split='test')
        with self.assertRaisesRegex(dataset.ValidationError, 'Утечка audio'):
            self.validate([row, second])

    def test_ошибка_аудио_не_раскрывает_путь(self):
        row = self.row(audio='private-secret-name.wav')
        with self.assertRaises(dataset.ValidationError) as caught:
            self.validate([row])
        self.assertNotIn(row['audio'], str(caught.exception))
        self.assertNotIn(str(self.root), str(caught.exception))

    def test_отклоняет_неподтвержденную_расшифровку(self):
        with self.assertRaisesRegex(dataset.ValidationError, 'reference_confirmed'):
            self.validate([self.row(reference_confirmed=False)])

    def test_отклоняет_неверный_формат_аудио(self):
        for channels, rate in [(2, 16000), (1, 44100)]:
            with self.subTest(channels=channels, rate=rate):
                row = self.row(audio=self.audio('wrong.wav', channels, rate))
                with self.assertRaises(dataset.ValidationError):
                    self.validate([row])

    def test_отклоняет_утечки_между_выборками(self):
        for leak in ('session', 'text', 'audio'):
            with self.subTest(leak=leak):
                first = self.row()
                second = self.row(id='two', audio=self.audio('two.wav', sample=2),
                                  reference='Другой текст', session_id='session-two', split='test')
                if leak == 'session': second['session_id'] = first['session_id']
                if leak == 'text': second['reference'] = 'ПРИВЕТ мир'
                if leak == 'audio': second['audio'] = first['audio']
                with self.assertRaises(dataset.ValidationError):
                    self.validate([first, second])

    def test_утечка_учитывает_ё_и_сохраняет_числовые_разделители(self):
        first = self.row(reference='Ёлка 1.5')
        second = self.row(id='two', audio=self.audio('two.wav', sample=2),
                          reference='елка 1.5', session_id='second', split='test')
        with self.assertRaises(dataset.ValidationError): self.validate([first, second])

    def test_отклоняет_почти_одинаковые_длинные_расшифровки_между_выборками(self):
        first = self.row(reference='Сегодня мы вместе подробно расскажем нашему гостю про старый город')
        second = self.row(id='two', audio=self.audio('two.wav', sample=2),
                          reference='Сегодня мы вместе подробно расскажем вашему гостю про старый город',
                          session_id='second', split='test')
        with self.assertRaisesRegex(dataset.ValidationError, 'near_duplicate'):
            self.validate([first, second])

    def test_разрешает_различные_длинные_тексты_и_короткие_похожие(self):
        for references in [
            ('Сегодня мы вместе подробно расскажем нашему гостю про старый город',
             'Завтра гид покажет новой группе туристов центральную площадь возле реки'),
            ('Нашему гостю нравится город', 'Вашему гостю нравится город'),
            ('', ''),
        ]:
            with self.subTest(references=references):
                first = self.row(reference=references[0])
                second = self.row(id='two', audio=self.audio('two.wav', sample=2),
                                  reference=references[1], session_id='second', split='test')
                self.assertEqual(len(self.validate([first, second])), 2)

    def test_отклоняет_повтор_идентификатора(self):
        row = self.row()
        with self.assertRaises(dataset.ValidationError): self.validate([row, row])

    def test_ошибка_не_раскрывает_текст(self):
        secret = 'Личный секретный текст'
        with self.assertRaises(dataset.ValidationError) as error:
            self.validate([self.row(reference=secret, split=secret)])
        self.assertNotIn(secret, str(error.exception))

    def test_отклоняет_пустой_корпус_и_несовпадение_длительности(self):
        for rows in ([], [self.row(duration_seconds=10)]):
            with self.assertRaises(dataset.ValidationError): self.validate(rows)

    def test_отклоняет_обрезанный_wav(self):
        row = self.row()
        path = self.root / row['audio']
        path.write_bytes(path.read_bytes()[:60])
        with self.assertRaises(dataset.ValidationError): self.validate([row])

    def test_отклоняет_неверные_типы(self):
        for field, value in [('id', 1), ('reference', None), ('session_id', ''),
                             ('reference_confirmed', 1), ('duration_seconds', True),
                             ('critical_terms', ['']), ('kind', 'other')]:
            with self.subTest(field=field):
                with self.assertRaises(dataset.ValidationError): self.validate([self.row(**{field: value})])


if __name__ == '__main__': unittest.main()
