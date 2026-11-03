"""Экспорт завершённого локального пилота в отдельный кандидат GGML."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from .lora_data import private_output
from .qwen import offline_runtime
from .whisper_assets import ASSETS,model_digest
from .whisper_lora import write_json


def validate_training_run(directory,model):
    directory=Path(directory)
    protocol=json.loads((directory/'run.json').read_text())
    if protocol.get('completed') is not True or protocol.get('status')!='complete':
        raise ValueError('Пилот не завершён')
    if model_digest(model)!=protocol['base_model_sha256']:
        raise ValueError('Исходные веса не совпали с обучением')
    hashes=protocol.get('adapter_sha256')
    if not hashes:raise ValueError('В протоколе нет файлов адаптера')
    for name,digest in hashes.items():
        path=directory/'adapter'/name
        if Path(name).name!=name or path.is_symlink() or not path.is_file():
            raise ValueError('Неверный файл адаптера')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise ValueError('Адаптер изменился после обучения')
    return protocol


def export(training_run,model,output,whisper_source):
    training_run,model,whisper_source=map(Path,(training_run,model,whisper_source))
    protocol=validate_training_run(training_run,model)
    root=Path(__file__).resolve().parents[2]
    converter=root/'vendor/whisper.cpp/models/convert-h5-to-ggml.py'
    if not converter.is_file() or not (whisper_source/'whisper/assets/mel_filters.npz').is_file():
        raise ValueError('Нужны локальные whisper.cpp и исходники Whisper с mel-фильтрами')
    output=private_output(output);os.umask(0o077)
    intermediate=output/'huggingface';intermediate.mkdir(mode=0o700)
    try:
        with offline_runtime(output/'offline-hf'):
            import torch
            from peft import PeftModel
            from transformers import WhisperForConditionalGeneration
            base=WhisperForConditionalGeneration.from_pretrained(str(model),local_files_only=True,
                trust_remote_code=False,use_safetensors=True,dtype=torch.float32)
            adapted=PeftModel.from_pretrained(base,str(training_run/'adapter'),local_files_only=True)
            merged=adapted.merge_and_unload().to(dtype=torch.float16)
            merged.save_pretrained(intermediate,safe_serialization=True)
            for name in ASSETS:
                if name!='model.safetensors':shutil.copy2(model/name,intermediate/name)
            # Конвертер запускается без сети и работает только с локальными файлами.
            command=[sys.executable,str(converter),str(intermediate),str(whisper_source),str(output)]
            environment=dict(os.environ,HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1')
            with (output/'conversion.log').open('x') as log:
                subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT,env=environment)
        validate_training_run(training_run,model)
        candidate=output/'ggml-model.bin'
        with candidate.open('rb') as stream:
            if stream.read(4)!=b'lmgg':raise ValueError('Неверный заголовок GGML')
        result=dict(completed=True,training_run_sha256=hashlib.sha256((training_run/'run.json').read_bytes()).hexdigest(),
            base_model_sha256=protocol['base_model_sha256'],adapter_sha256=protocol['adapter_sha256'],
            converter_sha256=hashlib.sha256(converter.read_bytes()).hexdigest(),
            mel_filters_sha256=hashlib.sha256((whisper_source/'whisper/assets/mel_filters.npz').read_bytes()).hexdigest(),
            ggml_sha256=hashlib.sha256(candidate.read_bytes()).hexdigest(),bytes=candidate.stat().st_size,
            precision='float16',preferences_changed=False)
        write_json(output/'export.json',result)
        shutil.rmtree(intermediate)
        for path in output.rglob('*'):path.chmod(0o700 if path.is_dir() else 0o600)
        print(json.dumps(result,allow_nan=False))
        return candidate
    except BaseException:
        write_json(output/'failure.json',dict(completed=False))
        raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('training_run');parser.add_argument('--model',required=True)
    parser.add_argument('--output',required=True);parser.add_argument('--whisper-source',required=True)
    args=parser.parse_args()
    try:export(args.training_run,args.model,args.output,args.whisper_source)
    except Exception:
        print('Экспорт Whisper остановлен. Если каталог создан, подробности в приватном conversion.log.',file=sys.stderr)
        return 1
    return 0


if __name__=='__main__':sys.exit(main())
