"""Закреплённые исходные веса Whisper Turbo для локального обучения."""
import hashlib
import json
from pathlib import Path
from .qwen_assets import verified_sha256

MODEL_REPO='openai/whisper-large-v3-turbo'
MODEL_REVISION='41f01f3fe87f28c78e2fbf8b568835947dd65ed9'
ASSETS={'added_tokens.json': {'size': 34648, 'git_sha1': '1b33526d33aaa60d79f78ae8651dae50b730185a'}, 'config.json': {'size': 1256, 'git_sha1': 'ad2f44ff1ed66e12765b2392dc041469db91a462'}, 'generation_config.json': {'size': 3772, 'git_sha1': 'cbe752958dc3e4671b0e0220aa1c545423a6d5f5'}, 'merges.txt': {'size': 493869, 'git_sha1': '6038932a2a1f09a66991b1c2adae0d14066fa29e'}, 'model.safetensors': {'size': 1617824864, 'sha256': '542566a422ae4f3fd23f1ba11add198fca01bbf82e66e6a2857b3f608b1eb9d1'}, 'normalizer.json': {'size': 52666, 'git_sha1': 'dd6ae819ad738ac1a546e9f9282ef325c33b9ea0'}, 'preprocessor_config.json': {'size': 340, 'git_sha1': '931c77a740890c46365c7ae0c9d350ba3cca908f'}, 'special_tokens_map.json': {'size': 2186, 'git_sha1': '312bc106291bb51bf2cc1648df070bef963a0639'}, 'tokenizer.json': {'size': 2710337, 'git_sha1': '17456db595adc78a973f97d69d8cb50bc87c0b1c'}, 'tokenizer_config.json': {'size': 282843, 'git_sha1': '06ffdc8308eae6bb7bd1fdd81e94b0a881a539ab'}, 'vocab.json': {'size': 1036558, 'git_sha1': '0f3456460629e21d559c6daa23ab6ce3644e8271'}}

def model_digest(model):
    root=Path(model)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Нужен локальный каталог Whisper')
    hashes={}
    for name,expected in ASSETS.items():
        path=root/name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Отсутствует обычный файл Whisper')
        hashes[name]=verified_sha256(path,expected)
    return hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest()
