#!/usr/bin/env python3
"""Отдельная среда Whisper LoRA, загрузка весов только с --download-model."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from Tools.SpeechEvaluation.whisper_assets import ASSETS,MODEL_REPO,MODEL_REVISION,model_digest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download-model',action='store_true')
    parser.add_argument('--plan',action='store_true')
    args=parser.parse_args()
    destination=ROOT/'vendor/speech-evaluation'
    python=destination/'whisper-venv/bin/python'
    model=destination/'models/whisper-large-v3-turbo-hf'
    if args.plan:
        print(json.dumps(dict(model_repo=MODEL_REPO,revision=MODEL_REVISION,bytes=sum(x['size'] for x in ASSETS.values()),download_model=args.download_model)))
        return
    # Используем уже проверенный загрузчик публичных файлов и чистое окружение.
    spec=importlib.util.spec_from_file_location('speech_setup',ROOT/'scripts/setup-speech-qwen.py')
    setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)
    destination.mkdir(parents=True,exist_ok=True)
    if destination.is_symlink() or python.parent.parent.is_symlink():raise ValueError('Небезопасный каталог окружения')
    environment=setup.clean_environment(destination/'whisper-hf-provisioning')
    if not python.exists():subprocess.run(['/opt/homebrew/bin/python3.12','-m','venv',str(python.parent.parent)],check=True,env=environment)
    subprocess.run([str(python),'-m','pip','--isolated','install','--index-url','https://pypi.org/simple','-r',str(ROOT/'Tools/SpeechEvaluation/requirements-whisper-lora.lock')],check=True,env=environment)
    freeze=subprocess.check_output([str(python),'-m','pip','--isolated','freeze','--all'],text=True,env=environment)
    (destination/'whisper-requirements-installed.txt').write_text(freeze)
    if args.download_model:
        model.parent.mkdir(parents=True,exist_ok=True)
        if model.exists():model_digest(model)
        else:
            staged=Path(tempfile.mkdtemp(prefix='.whisper-provision-',dir=model.parent))
            try:
                for name,expected in ASSETS.items():
                    print('Downloading',name,flush=True)
                    setup.download_asset('https://huggingface.co/{}/resolve/{}/{}'.format(MODEL_REPO,MODEL_REVISION,name),staged/name,expected)
                model_digest(staged)
                staged.rename(model)
            finally:
                if staged.exists():shutil.rmtree(staged)
    print(json.dumps(dict(environment_ready=True,model_ready=model.exists(),model_revision=MODEL_REVISION)))


if __name__=='__main__':main()
