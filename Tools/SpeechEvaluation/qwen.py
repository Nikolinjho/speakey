"""Опциональный Qwen3-ASR из проверенной локальной MLX-модели. Без загрузки весов."""
import argparse
import array
import contextlib
import hashlib
import importlib.metadata
import io
import json
import os
from pathlib import Path
import platform
import socket
import stat
import struct
import sys
import tempfile
import time

from .audio import AudioError, audio_info

from .qwen_assets import ASSETS, MODEL_FILES, MODEL_REPO, MODEL_REVISION, verified_sha256
MANIFEST='speakey-model-manifest.json'
AUDIO_VERSION='0.6.3'
MLX_VERSION='0.32.4'
LANGUAGES={'auto':None,'ru':'Russian','en':'English'}


class QwenError(ValueError):
    """Ошибка без личного текста и путей."""


def _canonical(value):
    return json.dumps(value,sort_keys=True,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode('utf8')


def _hash_file(path):
    digest=hashlib.sha256()
    with path.open('rb') as source:
        for part in iter(lambda:source.read(1024*1024),b''): digest.update(part)
    return digest.hexdigest()


def _tree(model):
    root=Path(model).expanduser()
    if not root.is_absolute() or root.is_symlink() or not root.is_dir(): raise QwenError('Нужен существующий локальный каталог Qwen')
    root=root.resolve()
    names=set()
    for path in root.rglob('*'):
        relative=path.relative_to(root)
        if path.is_symlink(): raise QwenError('Ссылки в модели запрещены')
        if '.cache' in relative.parts: continue
        if not path.is_file() or not stat.S_ISREG(path.stat().st_mode): raise QwenError('Неверный состав модели')
        if str(relative)!=MANIFEST: names.add(str(relative))
    if names!=set(MODEL_FILES): raise QwenError('Неполный или неизвестный состав модели')
    files={}
    for name in MODEL_FILES:
        try: files[name]=verified_sha256(root/name,ASSETS[name])
        except (OSError,ValueError): raise QwenError('Байты модели не совпадают с закреплённым upstream snapshot') from None
        if name.endswith('.json'):
            try: document=json.loads((root/name).read_text(encoding='utf8'))
            except (OSError,ValueError,UnicodeError): raise QwenError('Неверный JSON модели') from None
            def has_remote(value):
                if isinstance(value,dict): return 'auto_map' in value or any(has_remote(item) for item in value.values())
                return isinstance(value,list) and any(has_remote(item) for item in value)
            if has_remote(document): raise QwenError('Модель требует непроверенный remote code')
            if name=='config.json' and (not isinstance(document,dict) or document.get('model_type')!='qwen3_asr'):
                raise QwenError('Требуется Qwen3-ASR')
    return root,files


def write_model_manifest(model):
    """Вызывается только после явного получения закреплённого публичного snapshot."""
    root,files=_tree(model)
    document=dict(schema=1,repo=MODEL_REPO,revision=MODEL_REVISION,files=files)
    target=root/MANIFEST
    with os.fdopen(os.open(str(target),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'wb') as output:
        output.write(_canonical(document))
    return hashlib.sha256(_canonical(files)).hexdigest()


def model_digest(model):
    """SHA-256 canonical sorted compact UTF-8 {relative-path: file-sha256}."""
    try:
        root,files=_tree(model)
        if (root/MANIFEST).is_symlink(): raise QwenError('Ссылки в модели запрещены')
        document=json.loads((root/MANIFEST).read_text(encoding='utf8'))
        if (not isinstance(document,dict) or document.get('schema')!=1
                or document.get('repo')!=MODEL_REPO or document.get('revision')!=MODEL_REVISION
                or document.get('files')!=files): raise QwenError('Модель не совпадает с закреплённым manifest')
        return hashlib.sha256(_canonical(files)).hexdigest()
    except (OSError,ValueError,UnicodeError) as error:
        if isinstance(error,QwenError): raise
        raise QwenError('Не удалось проверить локальную модель') from None


def decode_samples(info):
    """IEEE Float32 mono: PCM8 unsigned, остальные PCM signed little endian."""
    samples=array.array('f')
    payload=info['payload']
    width=info['sample_width']
    if info['format']=='ieee_float':
        samples.frombytes(payload)
        if sys.byteorder!='little': samples.byteswap()
        return samples
    denominator=float(1<<(width*8-1))
    for position in range(0,len(payload),width):
        raw=payload[position:position+width]
        value=raw[0]-128 if width==1 else int.from_bytes(raw,'little',signed=True)
        samples.append(value/denominator)
    return samples


@contextlib.contextmanager
def offline_runtime(home):
    """Отключает Hub и сетевые Python-сокеты до импорта опциональных библиотек."""
    values=dict(HF_HOME=str(home),HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',
                HF_HUB_DISABLE_IMPLICIT_TOKEN='1',HF_HUB_DISABLE_TELEMETRY='1',
                HF_HUB_DISABLE_UPDATE_CHECK='1',DO_NOT_TRACK='1',TOKENIZERS_PARALLELISM='false')
    values.update({name:None for name in ('HF_TOKEN','HUGGING_FACE_HUB_TOKEN','HF_TOKEN_PATH','HF_HUB_CACHE','HUGGINGFACE_HUB_CACHE')})
    previous={name:os.environ.get(name) for name in values}
    for name,value in values.items():
        if value is None: os.environ.pop(name,None)
        else: os.environ[name]=value
    names=('socket','create_connection','getaddrinfo','gethostbyname','gethostbyname_ex','gethostbyaddr')
    originals={name:getattr(socket,name) for name in names}
    def denied(*args,**kwargs): raise QwenError('Сеть отключена для локального распознавания')
    original_socket=socket.socket
    class LocalSocket(original_socket):
        def __init__(self,family=socket.AF_INET,*args,**kwargs):
            if family in (socket.AF_INET,socket.AF_INET6): denied()
            super().__init__(family,*args,**kwargs)
    socket.socket=LocalSocket
    for name in names[1:]: setattr(socket,name,denied)
    try: yield
    finally:
        for name,value in originals.items(): setattr(socket,name,value)
        for name,value in previous.items():
            if value is None: os.environ.pop(name,None)
            else: os.environ[name]=value


def dependency_versions():
    result={}
    for name in ('mlx-audio','mlx','numpy','transformers','huggingface-hub'):
        try: result[name]=importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError: result[name]='unavailable'
    return result


def _load_backend(model_path):
    if sys.version_info<(3,10) or platform.machine()!='arm64': raise QwenError('Нужен Python 3.10+ на Apple Silicon')
    versions=dependency_versions()
    if versions['mlx-audio']!=AUDIO_VERSION or versions['mlx']!=MLX_VERSION: raise QwenError('Версии Qwen окружения не совпадают')
    import numpy as np
    from mlx_audio.stt import load
    from mlx_audio.stt.models.qwen3_asr import Qwen3ASRModel
    from transformers import AutoTokenizer,WhisperFeatureExtractor
    # Upstream hook использует trust_remote_code=True. Здесь разрешены только встроенные классы.
    original_hook=Qwen3ASRModel.__dict__['post_load_hook']
    def local_hook(cls,model,path):
        model._tokenizer=AutoTokenizer.from_pretrained(str(path),local_files_only=True,trust_remote_code=False)
        model._feature_extractor=WhisperFeatureExtractor.from_pretrained(str(path),local_files_only=True)
        return model
    Qwen3ASRModel.post_load_hook=classmethod(local_hook)
    try: model=load(Path(model_path),lazy=False,strict=True)
    finally: Qwen3ASRModel.post_load_hook=original_hook
    class Backend:
        def generate(self,samples,**kwargs):
            return model.generate(np.frombuffer(samples,dtype=np.float32),**kwargs)
    return Backend()


def transcribe_file(audio,model,output,language,*,backend_loader=None,max_tokens=8192):
    if language not in LANGUAGES or isinstance(max_tokens,bool) or not isinstance(max_tokens,int) or not 1<=max_tokens<=8192:
        raise QwenError('Неверные параметры Qwen')
    output=Path(output)
    if output.exists() or output.is_symlink(): raise QwenError('Выходной файл уже существует')
    try:
        digest=model_digest(model)
        info=audio_info(audio)
        samples=decode_samples(info)
        with tempfile.TemporaryDirectory(prefix='speakey-qwen-offline-') as home, offline_runtime(home):
            # Даже библиотечные предупреждения не должны выводить личный текст.
            with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
                started=time.monotonic()
                backend=(backend_loader or _load_backend)(Path(model).resolve())
                load_seconds=time.monotonic()-started
                started=time.monotonic()
                result=backend.generate(samples,language=LANGUAGES[language],temperature=0.0,max_tokens=max_tokens,
                    batch_size=1,verbose=False,stream=False,system_prompt=None,hotwords=None,
                    chunk_duration=1200.0,min_chunk_duration=1.0)
                decode_seconds=time.monotonic()-started
        if not isinstance(result.text,str): raise QwenError('Неверный результат Qwen')
        if model_digest(model)!=digest or _hash_file(Path(audio))!=info['input_wav_sha256']:
            raise QwenError('Модель или аудио изменились во время прогона')
        config=dict(engine='qwen',model_repo=MODEL_REPO,model_revision=MODEL_REVISION,
            language=language,decodeLanguage=LANGUAGES[language] or 'auto',temperature='0.0',
            max_tokens=str(max_tokens),batch_size='1',chunk_duration='1200.0',min_chunk_duration='1.0',
            recognition_hint='disabled_explicitly',system_prompt='disabled_explicitly',hotwords='disabled_explicitly',
            prompt_sha256=hashlib.sha256(b'').hexdigest(),network='hub_offline_and_python_socket_guard',
            tokenizer_remote_code='false',hypothesis_boundary='vendor_normalized_text',
            production_configuration_equivalent='false_qwen_experiment')
        config.update({'version_'+name:version for name,version in dependency_versions().items()})
        document=dict(schema=1,engine='qwen',hypothesis=result.text,raw_hypothesis=result.text,
            model_sha256=digest,model_sha256_format='sorted-relative-file-sha256-utf8-v1',
            language=language,sample_count=info['frame_count'],sample_rate=16000,
            input_wav_sha256=info['input_wav_sha256'],elapsed_seconds=decode_seconds,model_load_seconds=load_seconds,
            scope='qwen_vendor_normalized_no_dictionary_no_output_options',config=config,
            config_sha256=hashlib.sha256(_canonical(config)).hexdigest(),config_sha256_format='sorted-compact-utf8-v1')
        payload=_canonical(document)
        created=False
        try:
            descriptor=os.open(str(output),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            created=True
            with os.fdopen(descriptor,'wb') as destination: destination.write(payload)
        except BaseException:
            if created: output.unlink()
            raise
        return document
    except Exception as error:
        if isinstance(error,QwenError): raise
        raise QwenError('Локальное распознавание Qwen не удалось') from None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=('transcribe','preflight'))
    parser.add_argument('--model',required=True)
    parser.add_argument('--input')
    parser.add_argument('--output')
    parser.add_argument('--language',choices=tuple(LANGUAGES),default='auto')
    parser.add_argument('--max-tokens',type=int,default=8192)
    args=parser.parse_args(argv)
    try:
        if args.command=='preflight':
            digest=model_digest(args.model)
            versions=dependency_versions()
            if versions['mlx-audio']!=AUDIO_VERSION or versions['mlx']!=MLX_VERSION: raise QwenError('Сначала подготовьте изолированное окружение Qwen')
            print(json.dumps(dict(model_sha256=digest,versions=versions),sort_keys=True))
        else:
            if args.input is None or args.output is None: raise QwenError('Нужны явные вход и выход')
            transcribe_file(args.input,args.model,args.output,args.language,max_tokens=args.max_tokens)
        return 0
    except QwenError:
        print('Qwen speech CLI failed (invalid local input, unavailable dependency, or existing output).',file=sys.stderr)
        return 1


if __name__=='__main__': sys.exit(main())
