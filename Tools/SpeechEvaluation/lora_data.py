"""Подготовка подтверждённого корпуса без смешивания дней обучения и проверки."""
from datetime import datetime,timezone,timedelta
import hashlib
import os
from pathlib import Path
from .dataset import validate_manifest,ValidationError,_near_duplicate
from .metrics import normalize
from .audio import audio_info

class TrainingDataError(ValueError):
    pass


def prepare_corpus(manifest):
    try:
        rows=validate_manifest(manifest)
        if any(r['split']!='dev' for r in rows):
            raise TrainingDataError('Авторазбиение принимает только исходный корпус dev')
        if any(not r['reference'].strip() and r.get('kind')!='silence' for r in rows):
            raise TrainingDataError('Пустой эталон допустим только для явно подтверждённой тишины')
        days={}
        for row in rows:
            created=datetime.fromisoformat(row['created_at'].replace('Z','+00:00'))
            if created.tzinfo is None:raise ValueError()
            days[row['id']]=created.astimezone(timezone(timedelta(hours=3))).date().isoformat()
        unique=sorted(set(days.values()))
        if len(unique)<2:raise TrainingDataError('Для проверки нужен отдельный день записи')
        validation_day=unique[0]
        train=[];validation=[];excluded=[]
        for row in rows:
            if days[row['id']]==validation_day:validation.append(row)
            elif row['duration_seconds']>30:
                excluded.append(dict(id=row['id'],reason='longer_than_training_window',duration_seconds=row['duration_seconds']))
            else:train.append(row)
        if not train:raise TrainingDataError('Нет подходящих примеров обучения')
        # В исходном dev дубли допустимы. После разделения они становятся утечкой.
        audio_hashes={r['id']:audio_info(r['audio'])['pcm_sha256'] for r in train+validation}
        for a in train:
            for b in validation:
                left,right=normalize(a['reference']),normalize(b['reference'])
                if (audio_hashes[a['id']]==audio_hashes[b['id']]
                        or left and (left==right or _near_duplicate(left,right))):
                    raise TrainingDataError('Дубли между обучением и проверкой')
        return dict(train=train,validation=validation,all=rows,excluded_train=excluded,
                    train_days=unique[1:],validation_days=[validation_day],
                    manifest_sha256=hashlib.sha256(Path(manifest).read_bytes()).hexdigest())
    except (KeyError,ValueError,TypeError,ValidationError) as error:
        if isinstance(error,TrainingDataError):raise
        raise TrainingDataError('Неверный подтверждённый корпус или время создания') from None


def private_output(path):
    path=Path(path).absolute()
    if any(p.is_symlink() for p in [path,*path.parents]):
        raise TrainingDataError('Ссылки в пути результата запрещены')
    path=path.resolve()
    repository=Path(__file__).resolve().parents[2]
    if path==repository or repository in path.parents:
        raise TrainingDataError('Личные результаты должны находиться вне репозитория')
    try:os.mkdir(path,0o700)
    except OSError:raise TrainingDataError('Нужен новый каталог результата с доступным родителем') from None
    return path
