"""Проверки сборки контекста из манифеста на синтетических данных."""

import contextlib
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest

from Tools.SpeechEvaluation import context


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = self.root / 'manifest.jsonl'
        self.output = self.root / 'context'

    def write(self, rows):
        self.manifest.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))

    def row(self, ident, session, reference, **extra):
        return dict(id=ident, audio=ident + '.wav', reference=reference, reference_confirmed=True,
                    session_id=session, split='train', **extra)

    def load(self, ident):
        return json.loads(context.context_path(self.output, ident).read_text())

    def screen(self, ident):
        sources = self.load(ident)['sources']
        return [source['words'] for source in sources if source['kind'] == 'screen']

    def test_соседи_не_включают_саму_запись_и_их_не_больше_трёх(self):
        self.write([self.row('r{}'.format(i), 's', 'слово{} общее'.format(i)) for i in range(6)])
        context.build(self.manifest, self.output)
        words = self.screen('r5')[0]
        self.assertNotIn('слово5', words)
        self.assertEqual({'слово2', 'слово3', 'слово4'}, {w for w in words if w.startswith('слово')})
        self.assertEqual(words['общее'], 3)
        self.assertEqual(self.screen('r0'), [])

    def test_не_пересекает_сессии(self):
        self.write([self.row('a1', 'one', 'первая'), self.row('b1', 'two', 'вторая'),
                    self.row('a2', 'one', 'третья')])
        context.build(self.manifest, self.output)
        self.assertEqual(self.screen('a2'), [{'первая': 1}])
        self.assertEqual(self.screen('b1'), [])

    def test_порядок_берётся_из_времени_если_оно_есть(self):
        self.write([self.row('late', 's', 'поздняя', created_at='2026-11-02T10:00:00+03:00'),
                    self.row('early', 's', 'ранняя', created_at='2026-11-01T10:00:00+03:00'),
                    self.row('mid', 's', 'средняя', created_at='2026-11-01T12:00:00+03:00')])
        context.build(self.manifest, self.output)
        self.assertEqual(self.screen('early'), [])
        self.assertEqual(set(self.screen('late')[0]), {'ранняя', 'средняя'})
        self.assertEqual(self.screen('mid'), [{'ранняя': 1}])

    def test_словарь_корпуса_добавляется_как_corpus(self):
        vocabulary = self.root / 'vocabulary.json'
        vocabulary.write_text(json.dumps({'DPR': 3, 'Nuxt': 5}))
        self.write([self.row('one', 's', 'текст')])
        context.build(self.manifest, self.output, corpus_vocabulary=vocabulary)
        sources = self.load('one')['sources']
        self.assertEqual(sources, [dict(kind='corpus', words={'DPR': 3, 'Nuxt': 5})])

    def test_права_и_отказ_писать_в_репозиторий(self):
        self.write([self.row('one', 's', 'текст')])
        context.build(self.manifest, self.output)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        for path in self.output.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with self.assertRaises(context.ContextError):
            context.build(self.manifest, self.output)
        repository = Path(context.__file__).resolve().parents[2]
        with self.assertRaises(context.ContextError):
            context.build(self.manifest, repository / '.speech-private-context')

    def test_cli_не_печатает_тексты(self):
        self.write([self.row('one', 's', 'секретный текст'), self.row('two', 's', 'другой')])
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = context.main(['build', str(self.manifest), '--output-dir', str(self.output)])
        self.assertEqual(code, 0)
        self.assertNotIn('секретный', out.getvalue() + err.getvalue())


if __name__ == '__main__':
    unittest.main()
