"""Строгий разбор локального mono 16 kHz RIFF WAV без преобразования сэмплов.

Хеш включает формат, ширину, частоту, каналы и исходный payload. Он обнаруживает
точные дубли одного представления, но не эквивалентность PCM и Float32.
"""

import hashlib
import math
from pathlib import Path
import struct


class AudioError(ValueError):
    """Ошибка аудио без пути к записи и содержимого файла."""


def audio_info(path):
    """Возвращает метаданные и точные байты payload для integer PCM или Float32."""
    try:
        if Path(path).stat().st_size > 256 * 1024 * 1024:
            raise AudioError('WAV превышает ограничение 256 MiB')
        data = Path(path).read_bytes()
    except OSError:
        raise AudioError('Не удалось прочитать WAV') from None
    if (len(data) > 256 * 1024 * 1024 or len(data) < 12 or data[:4] != b'RIFF' or data[8:12] != b'WAVE'
            or struct.unpack_from('<I', data, 4)[0] != len(data) - 8):
        raise AudioError('Неверный размер или заголовок RIFF WAV')
    position = 12
    fmt = payload = None
    while position < len(data):
        if len(data) - position < 8:
            raise AudioError('Обрезан заголовок чанка WAV')
        kind, size = struct.unpack_from('<4sI', data, position)
        position += 8
        end = position + size
        padded_end = end + size % 2
        if padded_end > len(data):
            raise AudioError('Обрезан чанк WAV или отсутствует паддинг')
        if kind == b'fmt ':
            if fmt is not None or size < 16:
                raise AudioError('Неверный чанк fmt WAV')
            fmt = data[position:end]
        elif kind == b'data':
            if payload is not None:
                raise AudioError('Повтор чанка data WAV')
            payload = data[position:end]
        position = padded_end
    if fmt is None or payload is None:
        raise AudioError('Отсутствует fmt или data WAV')
    encoding, channels, rate, byte_rate, alignment, bits = struct.unpack_from('<HHIIHH', fmt)
    if len(fmt) != 16:
        if len(fmt) < 18 or struct.unpack_from('<H', fmt, 16)[0] != len(fmt) - 18:
            raise AudioError('Неверное расширение fmt WAV')
    if (channels != 1 or rate != 16000
            or not (encoding == 1 and bits in (8, 16, 24, 32) or encoding == 3 and bits == 32)):
        raise AudioError('Требуется mono WAV 16000 Hz: integer PCM или IEEE Float32')
    width = bits // 8
    if alignment != channels * width or byte_rate != rate * alignment:
        raise AudioError('Неверный blockAlign или byteRate WAV')
    if not payload:
        raise AudioError('Аудио пустое')
    if len(payload) % alignment:
        raise AudioError('Обрезан сэмпл WAV')
    if encoding == 3 and any(not math.isfinite(sample[0]) for sample in struct.iter_unpack('<f', payload)):
        raise AudioError('Float32 WAV содержит нечисловые сэмплы')
    digest = hashlib.sha256(struct.pack('<HHIH', encoding, channels, rate, bits) + payload).hexdigest()
    frames = len(payload) // alignment
    return dict(frame_count=frames, duration_seconds=frames / rate,
                format='pcm' if encoding == 1 else 'ieee_float', pcm_sha256=digest,
                input_wav_sha256=hashlib.sha256(data).hexdigest(),
                sample_rate=rate, channels=channels, sample_width=width, payload=payload)
