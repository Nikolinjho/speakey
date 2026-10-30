"""Проверки запуска изолированного распознавания без настоящей модели."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import stat
import sys
import subprocess
import tempfile
import unittest
from unittest import mock
import wave

from Tools.SpeechEvaluation import runners


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / 'synthetic-model.bin'
        self.model.write_bytes(b'synthetic-model-not-whisper')
        self.digest = hashlib.sha256(self.model.read_bytes()).hexdigest()
        self.audio = self.root / 'clip.wav'
        with wave.open(str(self.audio), 'wb') as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b'\0\0' * 1600)
        self.manifest = self.root / 'manifest.jsonl'
        self.manifest.write_text(json.dumps(dict(id='clip-1', audio='clip.wav',
            reference='Верный текст', reference_confirmed=True, session_id='one', split='test'))+'\n')
        self.executable = self.root / 'fake-speakey'
        self.output = self.root / 'run'
        self.fake('success')

    def fake(self, mode):
        script = '''#!{python}
import hashlib,json,os,pathlib,sys,time
words=sys.argv[1:]
is_qwen=words[:2]==['-m','Tools.SpeechEvaluation.qwen']
if is_qwen: words=words[2:]
sys.path.insert(0,os.getcwd())
args=dict(zip(words[1::2],words[2::2]))
assert words[0]=='transcribe'
assert os.environ['SPEAKEY_SPEECH_CLI']=='1'
assert os.environ.get('SPEAKEY_SPEECH_DIAGNOSTICS')!='1'
mode={mode!r}
if mode=='timeout': time.sleep(10)
if mode=='fail':
    print('СЕКРЕТНЫЙ текст',file=sys.stderr)
    sys.exit(7)
model=pathlib.Path(args['--model'])
audio=pathlib.Path(args['--input'])
result=dict(hypothesis='Верный текст',raw_hypothesis='Сырой текст',
    model_sha256=hashlib.sha256(model.read_bytes()).hexdigest() if model.is_file() else '{digest}',
    engine='qwen' if is_qwen else 'whisper',
    elapsed_seconds=0.1,model_load_seconds=0.02,language=args['--language'],
    input_wav_sha256=hashlib.sha256(audio.read_bytes()).hexdigest(),sample_count=1600,sample_rate=16000,
    config=dict(prompt_sha256='a'*64,recognition_hint='disabled_explicitly',strategy='greedy',entropyThreshold='2.4',decodeLanguage='ru'))
result['config_sha256']=hashlib.sha256(json.dumps(result['config'],sort_keys=True,ensure_ascii=False,separators=(',',':')).encode('utf8')).hexdigest()
result['config_sha256_format']='sorted-compact-utf8-v1'
if mode=='bad_config': result['config']['strategy']='changed'
if mode=='bad_hash': result['model_sha256']='0'*64
if mode=='missing_raw': del result['raw_hypothesis']
if mode=='nan': result['elapsed_seconds']=float('nan')
if mode=='bad_audio': result['input_wav_sha256']='0'*64
if mode=='changed_audio': audio.write_bytes(audio.read_bytes()+b'changed')
if mode=='missing_config': del result['config']
pathlib.Path(args['--output']).write_text(json.dumps(result))
print('СЕКРЕТНЫЙ текст')
'''.format(python=sys.executable,mode=mode,digest=self.digest)
        self.executable.write_text(script)
        self.executable.chmod(0o700)

    def run_batch(self, **kwargs):
        return runners.run_corpus(self.manifest, executable=self.executable, model=self.model,
                                  output=self.output, language='ru', **kwargs)

    def test_записывает_сырые_гипотезы_и_протокол_без_текста(self):
        result = self.run_batch()
        hypotheses = [json.loads(line) for line in (self.output/'hypotheses.jsonl').read_text().splitlines()]
        self.assertEqual(hypotheses, [dict(id='clip-1',hypothesis='Сырой текст')])
        protocol = json.loads((self.output/'run.json').read_text())
        self.assertEqual(protocol['model_sha256'],self.digest)
        self.assertEqual(protocol['process_mode'],'fresh-process-per-record')
        self.assertEqual(protocol['stage'],'raw')
        self.assertEqual(protocol['samples'][0]['id'],'clip-1')
        self.assertGreaterEqual(protocol['samples'][0]['wall_seconds'],0)
        self.assertEqual(protocol['samples'][0]['config']['prompt_sha256'],'a'*64)
        config=protocol['samples'][0]['config']
        self.assertEqual(protocol['samples'][0]['config_sha256'],hashlib.sha256(
            json.dumps(config,sort_keys=True,ensure_ascii=False,separators=(',',':')).encode('utf8')).hexdigest())
        self.assertNotIn('Сырой текст',(self.output/'run.json').read_text())
        self.assertEqual(result['samples'],1)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode),0o700)
        for path in self.output.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)

    def test_позволяет_явно_выбрать_результат_без_эха(self):
        self.run_batch(stage='echo-cleaned')
        self.assertEqual(json.loads((self.output/'hypotheses.jsonl').read_text())['hypothesis'],'Верный текст')

    def test_не_перезаписывает_существующий_каталог(self):
        self.output.mkdir()
        marker=self.output/'keep'
        marker.write_text('keep')
        with self.assertRaises(runners.RunError): self.run_batch()
        self.assertEqual(marker.read_text(),'keep')

    def test_ошибка_движка_не_раскрывает_текст_и_удаляет_частичный_прогон(self):
        self.fake('fail')
        with self.assertRaises(runners.RunError) as caught: self.run_batch()
        self.assertNotIn('СЕКРЕТНЫЙ',str(caught.exception))
        self.assertFalse(self.output.exists())

    def test_таймаут_завершает_дочерний_процесс(self):
        self.fake('timeout')
        with self.assertRaises(runners.RunError): self.run_batch(timeout=0.05)
        self.assertFalse(self.output.exists())

    def test_отклоняет_подмену_модели_и_неполный_ответ(self):
        for mode in ['bad_hash','missing_raw','nan','bad_audio','missing_config','bad_config']:
            self.fake(mode)
            with self.subTest(mode=mode), self.assertRaises(runners.RunError): self.run_batch()
            self.assertFalse(self.output.exists())

    def test_отклоняет_неподтверждённый_эталон_до_старта(self):
        row=json.loads(self.manifest.read_text())
        row['reference_confirmed']=False
        self.manifest.write_text(json.dumps(row)+'\n')
        with self.assertRaises(runners.RunError): self.run_batch()
        self.assertFalse(self.output.exists())

    def test_не_пишет_прогон_в_репозиторий(self):
        self.output=Path(__file__).resolve().parents[2]/'.speech-private-run'
        with self.assertRaises(runners.RunError): self.run_batch()
        self.assertFalse(self.output.exists())

    def test_отклоняет_изменение_аудио_во_время_распознавания(self):
        self.fake('changed_audio')
        with self.assertRaises(runners.RunError): self.run_batch()
        self.assertFalse(self.output.exists())

    def test_метаданные_и_хеш_берутся_из_одного_снимка_wav(self):
        original=runners.audio_info
        def read_then_change(path):
            info=original(path)
            data=Path(path).read_bytes()
            Path(path).write_bytes(data[:-2]+b'\x01\x00')
            return info
        with mock.patch.object(runners,'audio_info',side_effect=read_then_change):
            with self.assertRaises(runners.RunError): self.run_batch()
        self.assertFalse(self.output.exists())

    def test_хеш_parakeet_соответствует_каноническому_списку_загруженных_файлов(self):
        model=self.root/'parakeet-tdt-0.6b-v3'
        model.mkdir()
        pairs=[]
        for name in ['Preprocessor.mlmodelc','Encoder.mlmodelc','Decoder.mlmodelc','JointDecisionv3.mlmodelc']:
            (model/name).mkdir()
            (model/name/'model.bin').write_bytes(name.encode())
            pairs.append([name+'/model.bin',hashlib.sha256(name.encode()).hexdigest()])
        (model/'parakeet_vocab.json').write_bytes(b'{}')
        pairs.append(['parakeet_vocab.json',hashlib.sha256(b'{}').hexdigest()])
        expected=hashlib.sha256(json.dumps(sorted(pairs),ensure_ascii=False,separators=(',',':')).encode()).hexdigest()
        self.assertEqual(runners.model_digest(model,'parakeet'),expected)
        (model/'unused.txt').write_text('ignored')
        self.assertEqual(runners.model_digest(model,'parakeet'),expected)
        (model/'link').symlink_to(model/'unused.txt')
        with self.assertRaises(runners.RunError): runners.model_digest(model,'parakeet')

    def test_вызывает_qwen_отдельным_локальным_python_модулем(self):
        from Tools.SpeechEvaluation import qwen
        model=self.root/'qwen'
        model.mkdir()
        self.model=model
        with mock.patch.object(runners,'model_digest',return_value=self.digest):
            self.run_batch(engine='qwen')
        protocol=json.loads((self.output/'run.json').read_text())
        self.assertEqual(protocol['backend'],'speakey-qwen-cli')
        self.assertEqual(protocol['backend_code_sha256'],hashlib.sha256(Path(qwen.__file__).read_bytes()).hexdigest())

    def test_прямой_cli_qwen_ошибка_не_содержит_traceback(self):
        result=subprocess.run([sys.executable,str(Path(runners.__file__).resolve()),str(self.manifest),
            '--executable',str(self.executable),'--model',str(self.model),'--engine','qwen',
            '--output',str(self.output)],capture_output=True,text=True)
        self.assertEqual(result.returncode,1)
        self.assertNotIn('Traceback',result.stderr)
        self.assertFalse(self.output.exists())

    def test_не_выдаёт_пустую_выборку_за_успех(self):
        with self.assertRaises(runners.RunError): self.run_batch(split='dev')
        self.assertFalse(self.output.exists())


if __name__=='__main__': unittest.main()
