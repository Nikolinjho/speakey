#!/usr/bin/env python3
"""Изолированная среда Qwen. Веса загружаются только с --download-model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
AUDIO_VERSION='0.6.3'
MLX_VERSION='0.32.4'
PYTHON='/opt/homebrew/bin/python3.12'
DESTINATION=ROOT/'vendor/speech-evaluation'
from Tools.SpeechEvaluation.qwen_assets import ASSETS
REQUIREMENTS=ROOT/'Tools/SpeechEvaluation/requirements-qwen.lock'


def download_asset(url,target,expected):
    size=expected['size']
    digest=hashlib.sha256() if 'sha256' in expected else hashlib.sha1()
    if 'git_sha1' in expected: digest.update(('blob '+str(size)+'\0').encode('ascii'))
    written=0
    created=False
    try:
        with urllib.request.urlopen(url,timeout=120) as response, target.open('xb') as output:
            created=True
            while True:
                part=response.read(1024*1024)
                if not part: break
                written+=len(part)
                if written>size: raise ValueError('Размер модели не совпадает')
                digest.update(part)
                output.write(part)
        if written!=size or digest.hexdigest()!=expected.get('sha256',expected.get('git_sha1')):
            raise ValueError('Хеш модели не совпадает')
    except BaseException:
        if created: target.unlink()
        raise


def clean_environment(home):
    # Allowlist не передаёт HF_TOKEN, pip-конфигурацию или другие личные переменные.
    environment={name:os.environ[name] for name in ('PATH','TMPDIR','LANG','LC_ALL') if name in os.environ}
    environment.update(HF_HOME=str(home),HF_HUB_DISABLE_IMPLICIT_TOKEN='1',
                       HF_HUB_DISABLE_TELEMETRY='1',HF_HUB_DISABLE_UPDATE_CHECK='1',
                       PIP_DISABLE_PIP_VERSION_CHECK='1',PYTHONNOUSERSITE='1')
    return environment


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan',action='store_true')
    parser.add_argument('--download-model',action='store_true')
    args=parser.parse_args(argv)
    from Tools.SpeechEvaluation.qwen import MODEL_REPO,MODEL_REVISION,MODEL_FILES,write_model_manifest,model_digest
    target=DESTINATION/'models/qwen3-asr-1.7b-8bit'
    plan=dict(python=PYTHON,venv=str(DESTINATION/'venv'),mlx_audio=AUDIO_VERSION,mlx=MLX_VERSION,
              model_repo=MODEL_REPO,model_revision=MODEL_REVISION,model=str(target),
              download_model=args.download_model,requirements=str(REQUIREMENTS))
    if args.plan:
        print(json.dumps(plan,sort_keys=True)); return 0
    try:
        DESTINATION.mkdir(parents=True,exist_ok=True)
        if DESTINATION.is_symlink() or (DESTINATION/'venv').is_symlink(): raise ValueError()
        environment=clean_environment(DESTINATION/'hf-provisioning')
        python=DESTINATION/'venv/bin/python'
        if not python.exists():
            subprocess.run([PYTHON,'-m','venv',str(DESTINATION/'venv')],check=True,env=environment)
        subprocess.run([str(python),'-m','pip','--isolated','install','--index-url','https://pypi.org/simple',
                        '-r',str(REQUIREMENTS)],check=True,env=environment)
        completed=subprocess.run([str(python),'-m','pip','--isolated','freeze','--all'],
                                 check=True,env=environment,capture_output=True,text=True)
        (DESTINATION/'requirements-installed.txt').write_text(completed.stdout)
        if args.download_model:
            target.parent.mkdir(parents=True,exist_ok=True)
            if target.exists():
                model_digest(target)
            else:
                staged=Path(tempfile.mkdtemp(prefix='.qwen-provision-',dir=str(target.parent)))
                try:
                    for name in MODEL_FILES:
                        url='https://huggingface.co/{}/resolve/{}/{}'.format(MODEL_REPO,MODEL_REVISION,name)
                        # urllib не читает netrc или Hugging Face token. Только публичные HTTPS URL.
                        download_asset(url,staged/name,ASSETS[name])
                    write_model_manifest(staged)
                    staged.rename(target)
                finally:
                    if staged.exists(): shutil.rmtree(str(staged))
        print(json.dumps(dict(environment_ready=True,model_ready=target.exists(),model_revision=MODEL_REVISION)))
        return 0
    except (OSError,ValueError,subprocess.SubprocessError):
        print('Не удалось подготовить изолированный Qwen. Модель и личные записи не изменены.',file=sys.stderr)
        return 1


if __name__=='__main__': sys.exit(main())
