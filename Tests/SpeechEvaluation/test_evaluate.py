import contextlib
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools' / 'SpeechEvaluation'))
import evaluate


class EvaluateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        with wave.open(str(self.root / 'sample.wav'), 'wb') as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b'\0\0' * 1600)
        self.manifest = self.root / 'manifest.jsonl'
        self.predictions = self.root / 'hypotheses.jsonl'
        self.output = self.root / 'report.json'
        self.manifest.write_text(json.dumps(dict(id='one', audio='sample.wav', reference='Личный текст',
            reference_confirmed=True, session_id='session', split='test')) + '\n')
        self.predictions.write_text(json.dumps(dict(id='one', hypothesis='Личный текст')) + '\n')

    def run_cli(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = evaluate.main(list(args))
        return code, stdout.getvalue(), stderr.getvalue()

    def test_валидация_не_показывает_расшифровку(self):
        code, out, err = self.run_cli('validate', str(self.manifest))
        self.assertEqual(code, 0, err)
        self.assertNotIn('Личный', out + err)
        self.assertIn('test', out)

    def test_оценка_сохраняет_приватный_отчет_без_текстов(self):
        code, out, err = self.run_cli('evaluate', str(self.manifest), str(self.predictions),
                                       '--output', str(self.output))
        self.assertEqual(code, 0, err)
        report = json.loads(self.output.read_text())
        self.assertEqual(report['aggregate']['wer'], 0)
        self.assertEqual(report['aggregate']['cer'], 0)
        self.assertEqual(report['source'], 'precomputed_hypotheses')
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertNotIn('Личный', self.output.read_text() + out + err)

    def test_отклоняет_отсутствующие_и_повторные_гипотезы(self):
        for rows in ([dict(id='other', hypothesis='секрет')],
                     [dict(id='one', hypothesis='x'), dict(id='one', hypothesis='y')]):
            self.predictions.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            code, _, _ = self.run_cli('evaluate', str(self.manifest), str(self.predictions),
                                         '--output', str(self.output))
            self.assertEqual(code, 1)
            self.assertFalse(self.output.exists())

    def test_критические_термины_проверяются_отдельно_и_без_текста(self):
        row = json.loads(self.manifest.read_text())
        row.update(reference='Ёлка 15', critical_terms=['Ёлка', '15'])
        self.manifest.write_text(json.dumps(row) + '\n')
        self.predictions.write_text(json.dumps(dict(id='one', hypothesis='Елка 15')) + '\n')
        code, _, err = self.run_cli('evaluate', str(self.manifest), str(self.predictions), '--output', str(self.output))
        self.assertEqual(code, 0, err)
        report = json.loads(self.output.read_text())
        self.assertEqual(report['aggregate']['wer'], 0)
        self.assertEqual(report['aggregate']['critical_terms']['missed_occurrences'], 1)
        self.assertNotIn('Ёлка', self.output.read_text())

    def test_числовой_термин_не_совпадает_с_частью_числа_или_даты(self):
        for hypothesis in ['-15.5', '+15', '15.5', '15,5', '15/10/2026',
                           '2026-10-15', '10:15', '15%', '115', '15а']:
            with self.subTest(hypothesis=hypothesis):
                counts = evaluate._critical_counts('15', hypothesis, ['15'])
                self.assertEqual(counts['matched_occurrences'], 0)

    def test_полный_числовой_термин_совпадает_рядом_с_пунктуацией(self):
        for reference, hypothesis, term in [
            ('15', 'Ровно 15.', '15'), ('15', '(15), пожалуйста', '15'),
            ('-15.5', 'Температура -15.5.', '-15.5'),
            ('15/10/2026', 'Дата: 15/10/2026.', '15/10/2026'),
            ('15%', 'Всего 15%.', '15%'),
        ]:
            with self.subTest(hypothesis=hypothesis):
                counts = evaluate._critical_counts(reference, hypothesis, [term])
                self.assertEqual(counts['matched_occurrences'], 1)

    def test_не_перезаписывает_файлы(self):
        self.output.write_text('existing')
        code, _, _ = self.run_cli('evaluate', str(self.manifest), str(self.predictions),
                                     '--output', str(self.output))
        self.assertEqual(code, 1)
        self.assertEqual(self.output.read_text(), 'existing')

    def test_не_пишет_личные_отчеты_в_репозиторий(self):
        output = Path(__file__).resolve().parents[2] / 'private-report.json'
        code, _, _ = self.run_cli('evaluate', str(self.manifest), str(self.predictions), '--output', str(output))
        self.assertEqual(code, 1)
        self.assertFalse(output.exists())

    def test_тишина_считает_ложные_вставки(self):
        row = json.loads(self.manifest.read_text())
        row.update(reference='', kind='silence')
        self.manifest.write_text(json.dumps(row) + '\n')
        code, _, err = self.run_cli('evaluate', str(self.manifest), str(self.predictions), '--output', str(self.output))
        self.assertEqual(code, 0, err)
        aggregate = json.loads(self.output.read_text())['aggregate']
        self.assertIsNone(aggregate['wer'])
        self.assertEqual(aggregate['silence_false_positives'], 1)

    def compare_fixture(self):
        rows = [('a', 'проверь DPR сейчас', 'проверь тпр сейчас', 'проверь DPR сейчас'),
                ('b', 'открой Nuxt', 'открой Nuxt', 'открой Next'),
                ('c', 'привет мир', 'привет мир', 'привет мир')]
        manifest = self.root / 'compare-manifest.jsonl'
        manifest.write_text(''.join(json.dumps(dict(id=ident, audio='sample.wav', reference=reference,
            reference_confirmed=True, session_id='session-' + ident, split='test'), ensure_ascii=False) + '\n'
            for ident, reference, _, _ in rows))
        paths = {}
        for name, column in (('baseline', 2), ('variant', 3)):
            hypotheses = self.root / (name + '.jsonl')
            hypotheses.write_text(''.join(json.dumps(dict(id=row[0], hypothesis=row[column]), ensure_ascii=False) + '\n'
                                          for row in rows))
            report = self.root / (name + '-report.json')
            code, _, err = self.run_cli('evaluate', str(manifest), str(hypotheses), '--output', str(report))
            self.assertEqual(code, 0, err)
            paths[name] = (hypotheses, report)
        common = self.root / 'common.json'
        common.write_text(json.dumps(['проверь', 'сейчас', 'открой', 'привет', 'мир']))
        return manifest, paths, common

    def test_compare_считает_лучше_хуже_и_редкие_слова_без_текста(self):
        manifest, paths, common = self.compare_fixture()
        output = self.root / 'compare.json'
        code, out, err = self.run_cli('compare', str(paths['baseline'][1]), str(paths['variant'][1]),
            '--manifest', str(manifest), '--baseline-hypotheses', str(paths['baseline'][0]),
            '--variant-hypotheses', str(paths['variant'][0]), '--common-words', str(common),
            '--output', str(output))
        self.assertEqual(code, 0, err)
        report = json.loads(output.read_text())
        self.assertEqual((report['better'], report['worse'], report['same']), (1, 1, 1))
        self.assertEqual(report['worse_ids'], ['b'])
        self.assertEqual(report['word_errors'], dict(baseline=1, variant=1))
        self.assertEqual(report['rare_word_errors'], dict(reference_occurrences=2,
            baseline_missed=1, variant_missed=1))
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        text = output.read_text() + out + err
        for secret in ('DPR', 'Nuxt', 'тпр', 'проверь'):
            self.assertNotIn(secret, text)

    def test_compare_без_текстов_не_считает_редкие_слова(self):
        _, paths, _ = self.compare_fixture()
        output = self.root / 'compare-no-rare.json'
        code, _, err = self.run_cli('compare', str(paths['baseline'][1]), str(paths['variant'][1]),
                                    '--output', str(output))
        self.assertEqual(code, 0, err)
        report = json.loads(output.read_text())
        self.assertEqual(report['better'], 1)
        self.assertIsNone(report['rare_word_errors'])

    def test_compare_отклоняет_разные_наборы_записей(self):
        _, paths, _ = self.compare_fixture()
        other = json.loads(paths['variant'][1].read_text())
        other['samples'] = other['samples'][:2]
        broken = self.root / 'broken-report.json'
        broken.write_text(json.dumps(other))
        output = self.root / 'compare-bad.json'
        code, _, _ = self.run_cli('compare', str(paths['baseline'][1]), str(broken), '--output', str(output))
        self.assertEqual(code, 1)
        self.assertFalse(output.exists())


if __name__ == '__main__': unittest.main()
