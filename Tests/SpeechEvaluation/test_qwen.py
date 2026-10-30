"""Проверки локального Qwen без MLX, весов и сети."""
import array
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import wave

from Tools.SpeechEvaluation import qwen


class QwenTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.model = self.root / 'model'
        self.model.mkdir()
        for name in qwen.MODEL_FILES:
            (self.model/name).write_bytes(b'{}' if name.endswith('.json') else b'synthetic')
        (self.model/'config.json').write_text(json.dumps({'model_type':'qwen3_asr'}))
        trusted={}
        for name in qwen.MODEL_FILES:
            data=(self.model/name).read_bytes()
            trusted[name]=dict(size=len(data),sha256=hashlib.sha256(data).hexdigest())
        self.trust=mock.patch.object(qwen,'ASSETS',trusted)
        self.trust.start()
        self.addCleanup(self.trust.stop)
        qwen.write_model_manifest(self.model)
        self.audio = self.root/'clip.wav'
        with wave.open(str(self.audio),'wb') as stream:
            stream.setparams((1,2,16000,0,'NONE','not compressed'))
            stream.writeframes(struct.pack('<hhh',-32768,0,32767))
        self.output=self.root/'result.json'

    def test_хеш_локальной_модели_стабилен_и_не_загружает_библиотеки(self):
        with mock.patch('importlib.import_module',side_effect=AssertionError('Нельзя импортировать MLX')):
            self.assertEqual(qwen.model_digest(self.model),qwen.model_digest(str(self.model)))
        self.assertEqual(len(qwen.model_digest(self.model)),64)

    def test_переписанный_manifest_не_легализует_подмену_весов(self):
        manifest=self.model/qwen.MANIFEST
        document=json.loads(manifest.read_text())
        changed=b'changed!!'
        (self.model/'model.safetensors').write_bytes(changed)
        document['files']['model.safetensors']=hashlib.sha256(changed).hexdigest()
        manifest.write_text(json.dumps(document))
        with self.assertRaises(qwen.QwenError): qwen.model_digest(self.model)
        manifest.unlink()
        with self.assertRaises(qwen.QwenError): qwen.write_model_manifest(self.model)

    def test_отклоняет_remote_id_пропущенные_и_изменённые_файлы(self):
        with self.assertRaises(qwen.QwenError): qwen.model_digest('mlx-community/Qwen3-ASR-1.7B-8bit')
        (self.model/'merges.txt').unlink()
        with self.assertRaises(qwen.QwenError): qwen.model_digest(self.model)
        (self.model/'merges.txt').write_text('changed')
        with self.assertRaises(qwen.QwenError): qwen.model_digest(self.model)

    def test_отклоняет_ссылки_и_auto_map(self):
        alias=self.root/'alias'
        alias.symlink_to(self.model,target_is_directory=True)
        with self.assertRaises(qwen.QwenError): qwen.model_digest(alias)
        (self.model/'config.json').write_text(json.dumps({'model_type':'qwen3_asr','auto_map':{'AutoModel':'remote.code'}}))
        with self.assertRaises(qwen.QwenError): qwen.write_model_manifest(self.model)

    def test_декодирует_PCM_и_float32_с_отрицательным_нулём(self):
        for width,payload,expected in [(1,b'\0\x80\xff',[-1,0,127/128]),
                (2,struct.pack('<hhh',-32768,0,32767),[-1,0,32767/32768]),
                (3,b'\0\0\x80\0\0\0\xff\xff\x7f',[-1,0,8388607/8388608]),
                (4,struct.pack('<iii',-2147483648,0,2147483647),[-1,0,1])]:
            actual=qwen.decode_samples({'format':'pcm','sample_width':width,'payload':payload})
            self.assertEqual(list(actual),expected)
        payload=struct.pack('<ff',-0.0,0.25)
        self.assertEqual(qwen.decode_samples({'format':'ieee_float','sample_width':4,'payload':payload}).tobytes(),payload)

    def test_прогон_пишет_только_явный_приватный_JSON(self):
        seen={}
        class Backend:
            def generate(self,audio,**kwargs):
                seen.update(kwargs)
                self_audio=list(audio)
                if self_audio != [-1,0,32767/32768]: raise AssertionError('Сэмплы изменились')
                return SimpleNamespace(text='Привет, мир!')
        qwen.transcribe_file(self.audio,self.model,self.output,'ru',backend_loader=lambda path:Backend())
        result=json.loads(self.output.read_text())
        self.assertEqual(result['engine'],'qwen')
        self.assertEqual(result['raw_hypothesis'],result['hypothesis'])
        self.assertEqual(result['sample_count'],3)
        self.assertEqual(result['model_sha256'],qwen.model_digest(self.model))
        self.assertEqual(seen['language'],'Russian')
        self.assertEqual(seen['temperature'],0.0)
        self.assertIsNone(seen['hotwords'])
        self.assertEqual(self.output.stat().st_mode & 0o777,0o600)
        config_bytes=json.dumps(result['config'],sort_keys=True,ensure_ascii=False,separators=(',',':')).encode()
        self.assertEqual(result['config_sha256'],hashlib.sha256(config_bytes).hexdigest())
        with self.assertRaises(qwen.QwenError): qwen.transcribe_file(self.audio,self.model,self.output,'ru',backend_loader=lambda path:Backend())

    def test_ошибка_движка_не_оставляет_вывод(self):
        def fail(path): raise RuntimeError('Личный текст не должен попасть в ошибку')
        with self.assertRaises(qwen.QwenError) as caught:
            qwen.transcribe_file(self.audio,self.model,self.output,'auto',backend_loader=fail)
        self.assertNotIn('Личный',str(caught.exception))
        self.assertFalse(self.output.exists())

    def test_запрещает_сетевые_сокеты_и_восстанавливает_их(self):
        original=socket.socket
        with qwen.offline_runtime(self.root/'hf-empty'):
            self.assertEqual(__import__('os').environ['HF_HUB_OFFLINE'],'1')
            with self.assertRaises(qwen.QwenError): socket.create_connection(('example.com',443))
        self.assertIs(socket.socket,original)



class QwenSetupTests(unittest.TestCase):
    def test_план_не_ставит_пакеты_и_не_скачивает_модель(self):
        import subprocess
        result=subprocess.run([__import__('sys').executable,'scripts/setup-speech-qwen.py','--plan'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        plan=json.loads(result.stdout)
        self.assertFalse(plan['download_model'])
        self.assertEqual(plan['mlx_audio'],'0.6.3')
        self.assertEqual(plan['model_revision'],qwen.MODEL_REVISION)

class QwenDownloadTests(unittest.TestCase):
    def test_проверяет_размер_и_ожидаемый_хеш_до_manifest(self):
        spec=importlib.util.spec_from_file_location('setup_qwen','scripts/setup-speech-qwen.py')
        setup=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(setup)
        payload=b'synthetic weights'
        expected=dict(size=len(payload),sha256=hashlib.sha256(payload).hexdigest())
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'weights'
            with mock.patch.object(setup.urllib.request,'urlopen',return_value=__import__('io').BytesIO(payload)):
                setup.download_asset('https://huggingface.co/pinned',target,expected)
            self.assertEqual(target.read_bytes(),payload)
            target.unlink()
            with mock.patch.object(setup.urllib.request,'urlopen',return_value=__import__('io').BytesIO(payload+b'x')):
                with self.assertRaises(ValueError):setup.download_asset('https://huggingface.co/pinned',target,expected)
            self.assertFalse(target.exists())
            git_expected=dict(size=len(payload),git_sha1=hashlib.sha1(('blob '+str(len(payload))+'\0').encode()+payload).hexdigest())
            with mock.patch.object(setup.urllib.request,'urlopen',return_value=__import__('io').BytesIO(payload)):
                setup.download_asset('https://huggingface.co/pinned',target,git_expected)
            target.unlink()
            expected['sha256']='0'*64
            with mock.patch.object(setup.urllib.request,'urlopen',return_value=__import__('io').BytesIO(payload)):
                with self.assertRaises(ValueError):setup.download_asset('https://huggingface.co/pinned',target,expected)


class QwenFailureTests(unittest.TestCase):
    setUp=QwenTests.setUp

    def test_изменение_аудио_или_модели_во_время_прогона_не_публикует_JSON(self):
        for mutate in ('audio','model'):
            with self.subTest(mutate=mutate):
                target=self.audio if mutate=='audio' else self.model/'merges.txt'
                original=target.read_bytes()
                class Backend:
                    def generate(self,samples,**kwargs):
                        target.write_bytes(original+b'changed')
                        return SimpleNamespace(text='Синтетический текст')
                with self.assertRaises(qwen.QwenError):
                    qwen.transcribe_file(self.audio,self.model,self.output,'auto',backend_loader=lambda path:Backend())
                self.assertFalse(self.output.exists())
                target.write_bytes(original)

    def test_неверные_параметры_отклоняются_до_загрузки(self):
        for language,tokens in [('bad',8192),('ru',0),('ru',True),('ru',8193),('ru',1.5)]:
            with self.subTest(language=language,tokens=tokens),self.assertRaises(qwen.QwenError):
                qwen.transcribe_file(self.audio,self.model,self.output,language,max_tokens=tokens,
                    backend_loader=lambda path:self.fail('Движок не должен запускаться'))

    def test_отклоняет_вложенную_ссылку_специальный_файл_и_неизвестный_код(self):
        source=self.model/'merges.txt'
        source.unlink()
        source.symlink_to(self.audio)
        with self.assertRaises(qwen.QwenError):qwen.model_digest(self.model)
        source.unlink()
        __import__('os').mkfifo(str(source))
        with self.assertRaises(qwen.QwenError):qwen.model_digest(self.model)
        source.unlink()
        source.write_bytes(b'synthetic')
        (self.model/'remote.py').write_text('raise RuntimeError()')
        with self.assertRaises(qwen.QwenError):qwen.model_digest(self.model)

    def test_ошибка_записи_не_создаёт_частичного_результата(self):
        class Backend:
            def generate(self,*args,**kwargs):return SimpleNamespace(text='Синтетический текст')
        with mock.patch.object(qwen.os,'open',side_effect=OSError('disk unavailable')):
            with self.assertRaises(qwen.QwenError):
                qwen.transcribe_file(self.audio,self.model,self.output,'auto',backend_loader=lambda path:Backend())
        self.assertFalse(self.output.exists())


if __name__=='__main__': unittest.main()
