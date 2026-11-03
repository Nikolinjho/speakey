"""Локальный пилот LoRA декодера Whisper с отдельной оценкой до и после."""
import argparse
from datetime import datetime,timezone,timedelta
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import random
import sys
import time
import traceback
from .audio import audio_info
from .evaluate import evaluate_rows
from .lora_data import prepare_corpus,private_output,TrainingDataError
from .qwen import offline_runtime,decode_samples
from .whisper_assets import MODEL_REPO,MODEL_REVISION,model_digest


def add_decoder_lora(model,rank=8):
    if isinstance(rank,bool) or not isinstance(rank,int) or not 1<=rank<=64:
        raise ValueError('Rank должен быть целым числом от 1 до 64')
    from peft import LoraConfig,get_peft_model
    config=LoraConfig(r=rank,lora_alpha=rank*2,lora_dropout=0,bias='none',
        target_modules=r'model\.decoder\.layers\.\d+\.(self_attn|encoder_attn)\.(q_proj|v_proj)')
    adapted=get_peft_model(model,config)
    trainable=[name for name,p in adapted.named_parameters() if p.requires_grad]
    if not trainable or any('decoder' not in name or 'lora_' not in name for name in trainable):
        raise ValueError('Обучаемые параметры должны принадлежать только LoRA декодера')
    return adapted


def write_json(path,value):
    with os.fdopen(os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as stream:
        json.dump(value,stream,ensure_ascii=False,allow_nan=False,indent=2)
        stream.write('\n')


def features_for(row,processor,device,longform=False):
    import numpy as np
    info=audio_info(row['audio'])
    samples=np.asarray(decode_samples(info),dtype=np.float32)
    features=processor.feature_extractor(samples,sampling_rate=16000,return_tensors='pt',
        return_attention_mask=True,truncation=not longform)
    return {key:value.to(device) for key,value in features.items()}


def evaluate_model(model,processor,rows,device,output,stage):
    import torch
    model.eval()
    predictions=[];measurements=[]
    for index,row in enumerate(rows,1):
        longform=row['duration_seconds']>30
        features=features_for(row,processor,device,longform=longform)
        started=time.monotonic()
        with torch.no_grad():
            tokens=model.generate(**features,language=None,task='transcribe',do_sample=False,num_beams=1,
                return_timestamps=longform,condition_on_prev_tokens=False,max_new_tokens=256,use_cache=True)
        text=processor.batch_decode(tokens,skip_special_tokens=True)[0]
        predictions.append(dict(id=row['id'],hypothesis=text))
        measurements.append(dict(id=row['id'],seconds=time.monotonic()-started,longform=longform,
                                 sample_count=audio_info(row['audio'])['frame_count']))
        print(stage,index,'/',len(rows),flush=True)
    with os.fdopen(os.open(output/(stage+'-hypotheses.jsonl'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as stream:
        for row in predictions:stream.write(json.dumps(row,ensure_ascii=False)+'\n')
    return predictions,measurements


def partition_reports(corpus,predictions):
    result={}
    for label,rows in [('train',corpus['train']),('validation',corpus['validation']),('all',corpus['all'])]:
        ids={r['id'] for r in rows}
        result[label]=evaluate_rows([dict(r,split='train' if label=='train' else 'dev') for r in rows],
                                   [p for p in predictions if p['id'] in ids])
    return result


def run(manifest,model_path,output,*,steps=60,rank=8,learning_rate=.0001,seed=42,device='mps'):
    if (isinstance(steps,bool) or not isinstance(steps,int) or not 1<=steps<=10000
            or isinstance(learning_rate,bool) or not math.isfinite(learning_rate) or not 0<learning_rate<=.01
            or isinstance(rank,bool) or not isinstance(rank,int) or not 1<=rank<=64
            or device not in ('mps','cpu')):
        raise ValueError('Неверные параметры пилота')
    corpus=prepare_corpus(manifest)
    base_hash=model_digest(model_path)
    inputs={row['id']:audio_info(row['audio'])['input_wav_sha256'] for row in corpus['all']}
    output=private_output(output)
    os.umask(0o077)
    configuration=dict(steps=steps,rank=rank,alpha=rank*2,learning_rate=learning_rate,seed=seed,
        device=device,batch_size=1,precision='float32',language='auto',training_label_language='ru',
        attention='sdpa',max_new_tokens=256,encoder_frozen=True)
    protocol=dict(status='running',completed=False,created_at_msk=datetime.now(timezone(timedelta(hours=3))).isoformat(),
        model_repo=MODEL_REPO,model_revision=MODEL_REVISION,base_model_sha256=base_hash,
        manifest_sha256=corpus['manifest_sha256'],input_wav_sha256=inputs,configuration=configuration,
        train_ids=[r['id'] for r in corpus['train']],validation_ids=[r['id'] for r in corpus['validation']],
        train_days=corpus['train_days'],validation_days=corpus['validation_days'],excluded_train=corpus['excluded_train'],
        independent_test=False,preferences_changed=False,source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    write_json(output/'started.json',protocol)
    try:
        with offline_runtime(output/'offline-hf'):
            import numpy as np
            import torch
            from transformers import WhisperForConditionalGeneration,WhisperProcessor
            from transformers.modeling_outputs import BaseModelOutput
            if device=='mps' and not torch.backends.mps.is_available():
                raise ValueError('GPU MPS недоступен в текущем процессе')
            random.seed(seed);np.random.seed(seed);torch.manual_seed(seed)
            torch.set_num_threads(4)
            protocol['versions']={name:importlib.metadata.version(name) for name in ('torch','transformers','peft','numpy','accelerate')}
            processor=WhisperProcessor.from_pretrained(str(model_path),local_files_only=True,trust_remote_code=False)
            base=WhisperForConditionalGeneration.from_pretrained(str(model_path),local_files_only=True,
                trust_remote_code=False,use_safetensors=True,dtype=torch.float32,attn_implementation='sdpa').to(device)
            base.generation_config.language=None
            base.generation_config.forced_decoder_ids=None
            before,before_times=evaluate_model(base,processor,corpus['all'],device,output,'before')
            before_reports=partition_reports(corpus,before)
            write_json(output/'before-metrics.json',before_reports)
            model=add_decoder_lora(base,rank=rank)
            parameters=[p for p in model.parameters() if p.requires_grad]
            original=[p.detach().cpu().clone() for p in parameters]
            protocol['trainable_parameters']=sum(p.numel() for p in parameters)
            processor.tokenizer.set_prefix_tokens(language='russian',task='transcribe',predict_timestamps=False)
            # Замороженный энкодер вычисляется один раз. Кеш существует только в памяти.
            examples=[]
            model.eval()
            for index,row in enumerate(corpus['train'],1):
                features=features_for(row,processor,device)
                with torch.no_grad():encoded=base.model.encoder(features['input_features']).last_hidden_state.detach().cpu()
                labels=processor.tokenizer(row['reference'],return_tensors='pt').input_ids
                if labels[0,0].item()==base.config.decoder_start_token_id:labels=labels[:,1:]
                if labels.shape[1]>base.config.max_target_positions:
                    raise ValueError('Эталон длиннее контекста обучения, усечение запрещено')
                examples.append((encoded,labels))
                print('encoder',index,'/',len(corpus['train']),flush=True)
            optimizer=torch.optim.AdamW(parameters,lr=learning_rate,weight_decay=.01)
            losses=[];order=[];rng=random.Random(seed)
            model.train();base.model.encoder.eval()
            started=time.monotonic()
            for step in range(steps):
                if not order:order=list(range(len(examples)));rng.shuffle(order)
                encoded,labels=examples[order.pop()]
                optimizer.zero_grad(set_to_none=True)
                loss=model(encoder_outputs=BaseModelOutput(last_hidden_state=encoded.to(device)),
                    labels=labels.to(device),use_cache=False).loss
                if not torch.isfinite(loss).item():raise ValueError('Нечисловая функция потерь')
                loss.backward()
                norm=torch.nn.utils.clip_grad_norm_(parameters,1.0,error_if_nonfinite=True)
                optimizer.step()
                losses.append(dict(step=step+1,loss=loss.item(),gradient_norm=norm.item()))
                if step==0 or (step+1)%5==0:print('train',step+1,'/',steps,'loss',round(loss.item(),5),flush=True)
            protocol['training_seconds']=time.monotonic()-started
            changed=sum(not torch.equal(old,new.detach().cpu()) for old,new in zip(original,parameters))
            if not changed:raise ValueError('Обучение не изменило адаптер')
            protocol['changed_adapter_tensors']=changed
            write_json(output/'losses.json',losses)
            adapter=output/'adapter'
            model.save_pretrained(adapter,safe_serialization=True)
            # Оценивается адаптер, заново прочитанный с диска.
            model.load_adapter(str(adapter),adapter_name='verified',is_trainable=False,local_files_only=True)
            model.set_adapter('verified')
            after,after_times=evaluate_model(model,processor,corpus['all'],device,output,'after')
            after_reports=partition_reports(corpus,after)
            write_json(output/'after-metrics.json',after_reports)
            protocol['measurements']=dict(before=before_times,after=after_times)
            protocol['metrics']={stage:{part:report['aggregate'] for part,report in reports.items()}
                                 for stage,reports in [('before',before_reports),('after',after_reports)]}
        if model_digest(model_path)!=base_hash or hashlib.sha256(Path(manifest).read_bytes()).hexdigest()!=corpus['manifest_sha256']:
            raise ValueError('Веса или корпус изменились во время пилота')
        if any(audio_info(row['audio'])['input_wav_sha256']!=inputs[row['id']] for row in corpus['all']):
            raise ValueError('Входное аудио изменилось во время пилота')
        protocol.update(status='complete',completed=True,steps_completed=steps)
        protocol['adapter_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in adapter.iterdir() if p.is_file()}
        write_json(output/'run.json',protocol)
        for path in output.rglob('*'):path.chmod(0o700 if path.is_dir() else 0o600)
        print(json.dumps(dict(completed=True,steps=steps,train_samples=len(corpus['train']),validation_samples=len(corpus['validation']),
            validation_wer_before=protocol['metrics']['before']['validation']['wer'],
            validation_wer_after=protocol['metrics']['after']['validation']['wer']),allow_nan=False),flush=True)
        return protocol
    except BaseException as error:
        write_json(output/'failure.json',dict(completed=False,error_type=type(error).__name__))
        with os.fdopen(os.open(output/'failure.txt',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as stream:traceback.print_exc(file=stream)
        raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest');parser.add_argument('--model',required=True);parser.add_argument('--output',required=True)
    parser.add_argument('--steps',type=int,default=60);parser.add_argument('--rank',type=int,default=8)
    parser.add_argument('--learning-rate',type=float,default=.0001);parser.add_argument('--seed',type=int,default=42)
    parser.add_argument('--device',choices=['mps','cpu'],default='mps')
    args=parser.parse_args()
    try:run(args.manifest,args.model,args.output,steps=args.steps,rank=args.rank,learning_rate=args.learning_rate,seed=args.seed,device=args.device)
    except Exception:
        print('Пилот Whisper остановлен. Если каталог создан, подробности в приватном failure.txt.',file=sys.stderr)
        return 1
    return 0


if __name__=='__main__':sys.exit(main())
