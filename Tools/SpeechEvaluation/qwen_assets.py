"""Ожидаемые публичные байты Qwen3-ASR-1.7B-8bit, независимо от локального manifest."""
import hashlib
from types import MappingProxyType

MODEL_REPO='mlx-community/Qwen3-ASR-1.7B-8bit'
MODEL_REVISION='a8379a2e2f9e313c9292cdf1af4055ab56d50d55'
# Публичный API закреплённого HF commit: .../revision/a8379a2...?blobs=true.
# Обычные файлы проверяются как Git blob SHA-1, LFS-веса – по SHA-256 содержимого.
ASSETS={
    'chat_template.json':dict(size=1161,git_sha1='c44736493efd71ec96218cc626904698cdb13235'),
    'config.json':dict(size=7188,git_sha1='888cc7fae19ea9ede543b1ae82e9c78aa06104ca'),
    'generation_config.json':dict(size=142,git_sha1='7382a4d347c0a865b76bb1b8277f66a5ac312854'),
    'merges.txt':dict(size=1671853,git_sha1='31349551d90c7606f325fe0f11bbb8bd5fa0d7c7'),
    'model.safetensors':dict(size=2463307541,sha256='bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c'),
    'model.safetensors.index.json':dict(size=78968,git_sha1='f0191caac2794d5b6fba0ab3eeb70f8eff90319e'),
    'preprocessor_config.json':dict(size=330,git_sha1='8f7f07346466d5d494ec0d4969d1c3d0190eed72'),
    'tokenizer_config.json':dict(size=12487,git_sha1='b93109843922a40c6654c5449d3bf95372267c66'),
    'vocab.json':dict(size=2776833,git_sha1='4783fe10ac3adce15ac8f358ef5462739852c569'),
}

ASSETS=MappingProxyType({name:MappingProxyType(value) for name,value in ASSETS.items()})
MODEL_FILES=tuple(ASSETS)


def verified_sha256(path,expected):
    size=expected['size']
    if path.stat().st_size!=size: raise ValueError('Размер модели не совпадает')
    sha256=hashlib.sha256()
    git=hashlib.sha1(('blob '+str(size)+'\0').encode('ascii')) if 'git_sha1' in expected else None
    written=0
    with path.open('rb') as source:
        for part in iter(lambda:source.read(1024*1024),b''):
            written+=len(part)
            if written>size: raise ValueError('Размер модели не совпадает')
            sha256.update(part)
            if git is not None: git.update(part)
    if (written!=size or ('sha256' in expected and sha256.hexdigest()!=expected['sha256'])
            or (git is not None and git.hexdigest()!=expected['git_sha1'])):
        raise ValueError('Хеш модели не совпадает')
    return sha256.hexdigest()
