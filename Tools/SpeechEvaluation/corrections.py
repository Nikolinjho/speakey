"""Явное подтверждение дословного эталона для одной экспортированной записи."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

try:
    from .audio import AudioError, audio_info
    from .dataset import ValidationError, read_jsonl
except ImportError:
    from audio import AudioError, audio_info
    from dataset import ValidationError, read_jsonl

class CorrectionError(ValueError):
    pass


def confirm(draft, *, reference_file, output, session_id, split, silence=False, edited_file=None):
    output=Path(output)
    if output.is_symlink():
        raise CorrectionError('Выходной файл не должен быть ссылкой')
    output=output.resolve()
    repository=Path(__file__).resolve().parents[2]
    if repository==output or repository in output.parents:
        raise CorrectionError('Личные эталоны нужно сохранять вне репозитория')
    if not isinstance(session_id,str) or not session_id.strip() or split not in ('train','dev','test'):
        raise CorrectionError('Нужны сессия записи и выборка')
    try:
        draft=Path(draft)
        original=draft.read_bytes()
        rows=read_jsonl(draft)
        if len(rows)!=1:
            raise CorrectionError('Нужен черновик одной записи')
        source=rows[0]
        if (not isinstance(source.get('id'),str) or not source['id'].strip()
                or not isinstance(source.get('audio'),str) or not source['audio'].strip()):
            raise CorrectionError('В черновике отсутствуют id или audio')
        reference=Path(reference_file).read_text(encoding='utf-8').strip()
        if bool(reference)==bool(silence):
            raise CorrectionError('Пустой эталон требует --silence, непустой несовместим с тишиной')
        audio=(draft.parent/source['audio']).resolve()
        info=audio_info(audio)
        row=dict(id=source['id'],audio=str(audio),reference=reference,reference_confirmed=True,
            reference_source='explicit_user_confirmation',session_id=session_id,split=split,
            kind='silence' if silence else 'speech',duration_seconds=info['duration_seconds'],
            input_wav_sha256=info['input_wav_sha256'],source_draft_sha256=hashlib.sha256(original).hexdigest())
        if edited_file is not None:
            row['edited_text']=Path(edited_file).read_text(encoding='utf-8').strip()
        content=json.dumps(row,ensure_ascii=False,allow_nan=False)+'\n'
        staged=output.parent/('.speech-confirm-'+str(uuid.uuid4()))
        descriptor=None
        try:
            descriptor=os.open(str(staged),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
            with os.fdopen(descriptor,'w',encoding='utf-8') as target:
                descriptor=None
                target.write(content)
                target.flush()
                os.fsync(target.fileno())
            os.link(str(staged),str(output))
        finally:
            if descriptor is not None: os.close(descriptor)
            if staged.exists(): staged.unlink()
        return dict(confirmed=1,split=split)
    except (OSError,UnicodeError,AudioError,ValidationError):
        raise CorrectionError('Не удалось подтвердить запись') from None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('draft')
    parser.add_argument('--reference-file',required=True)
    parser.add_argument('--session-id',required=True)
    parser.add_argument('--split',required=True,choices=('train','dev','test'))
    parser.add_argument('--output',required=True)
    parser.add_argument('--silence',action='store_true')
    parser.add_argument('--edited-file')
    args=parser.parse_args(argv)
    try:
        result=confirm(args.draft,reference_file=args.reference_file,session_id=args.session_id,
            split=args.split,output=args.output,silence=args.silence,edited_file=args.edited_file)
        print(json.dumps(result))
        return 0
    except CorrectionError as error:
        print(str(error),file=sys.stderr)
        return 1

if __name__=='__main__': sys.exit(main())
