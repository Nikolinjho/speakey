import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Tools' / 'SpeechEvaluation'))
from audio import AudioError, audio_info


def chunk(kind, payload):
    return kind + struct.pack('<I', len(payload)) + payload + (b'\0' if len(payload) % 2 else b'')


def wav(payload, encoding=1, width=2, channels=1, rate=16000, alignment=None, byte_rate=None):
    alignment = channels * width if alignment is None else alignment
    byte_rate = rate * alignment if byte_rate is None else byte_rate
    fmt = struct.pack('<HHIIHH', encoding, channels, rate, byte_rate, alignment, width * 8)
    body = b'WAVE' + chunk(b'fmt ', fmt) + chunk(b'data', payload)
    return b'RIFF' + struct.pack('<I', len(body)) + body


class AudioTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'private-audio.wav'

    def info(self, data):
        self.path.write_bytes(data)
        return audio_info(self.path)

    def test_отклоняет_слишком_большой_wav_до_чтения(self):
        with self.path.open('wb') as target:
            target.truncate(256 * 1024 * 1024 + 1)
        with mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('Большой файл прочитан')):
            with self.assertRaises(AudioError): audio_info(self.path)

    def test_читает_целочисленные_форматы_без_изменения_байтов(self):
        for width in (1, 2, 3, 4):
            payload = bytes(range(width * 3))
            with self.subTest(width=width):
                info = self.info(wav(payload, width=width))
                self.assertEqual(info['payload'], payload)
                self.assertEqual(info['frame_count'], 3)
                self.assertEqual(info['sample_width'], width)
                self.assertEqual(info['format'], 'pcm')
                self.assertEqual(info['duration_seconds'], 3 / 16000)

    def test_float32_сохраняет_биты_включая_отрицательный_ноль(self):
        payload = struct.pack('<ffff', -0.0, 0.0, 0.25, -1.5)
        info = self.info(wav(payload, encoding=3, width=4))
        self.assertEqual(info['payload'], payload)
        self.assertEqual(info['format'], 'ieee_float')
        self.assertEqual(info['frame_count'], 4)

    def test_отклоняет_нечисловые_float32(self):
        for value in (math.nan, math.inf, -math.inf):
            with self.subTest(value=value), self.assertRaises(AudioError):
                self.info(wav(struct.pack('<f', value), encoding=3, width=4))

    def test_хеш_учитывает_представление_и_игнорирует_метаданные(self):
        payload = b'\0' * 4
        pcm = self.info(wav(payload, width=4))
        floating = self.info(wav(payload, encoding=3, width=4))
        narrow = self.info(wav(payload, width=2))
        self.assertNotEqual(pcm['pcm_sha256'], floating['pcm_sha256'])
        self.assertNotEqual(pcm['pcm_sha256'], narrow['pcm_sha256'])
        original = wav(payload, width=4)
        extra = chunk(b'JUNK', b'x')
        altered = original[:12] + extra + original[12:]
        altered = altered[:4] + struct.pack('<I', len(altered) - 8) + altered[8:]
        self.assertEqual(self.info(altered)['pcm_sha256'], pcm['pcm_sha256'])

    def test_отклоняет_поврежденные_заголовки_и_пустое_аудио(self):
        valid = wav(b'\0\0')
        cases = [b'', valid[:-1], valid + b'x', valid[:4] + struct.pack('<I', 1) + valid[8:],
                 wav(b''), wav(b'x'), wav(b'\0\0', alignment=1),
                 wav(b'\0\0', byte_rate=1), wav(b'\0\0', channels=2),
                 wav(b'\0\0', rate=8000), wav(b'\0\0', encoding=3),
                 wav(b'\0\0', encoding=0xFFFE)]
        for index, data in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(AudioError):
                self.info(data)

    def test_отклоняет_пропущенный_паддинг_и_дубли_чанков(self):
        original = wav(b'\0\0')
        additions = [b'JUNK' + struct.pack('<I', 1) + b'x', chunk(b'data', b'\0\0'),
                     chunk(b'fmt ', struct.pack('<HHIIHH', 1, 1, 16000, 32000, 2, 16)), b'abc']
        for extra in additions:
            changed = original[:12] + extra + original[12:]
            changed = changed[:4] + struct.pack('<I', len(changed) - 8) + changed[8:]
            with self.subTest(extra=extra[:4]), self.assertRaises(AudioError):
                self.info(changed)

    def test_поддерживает_fact_и_пустое_расширение_fmt(self):
        payload = struct.pack('<f', -0.0)
        fmt = struct.pack('<HHIIHHH', 3, 1, 16000, 64000, 4, 32, 0)
        body = b'WAVE' + chunk(b'fmt ', fmt) + chunk(b'fact', struct.pack('<I', 1))
        body += chunk(b'data', payload)
        info = self.info(b'RIFF' + struct.pack('<I', len(body)) + body)
        self.assertEqual(info['payload'], payload)

    def test_отклоняет_неверное_расширение_fmt_и_отсутствующие_чанки(self):
        fmt = struct.pack('<HHIIHH', 1, 1, 16000, 32000, 2, 16)
        bodies = [b'WAVE' + chunk(b'data', b'xx'), b'WAVE' + chunk(b'fmt ', fmt),
                  b'WAVE' + chunk(b'fmt ', fmt + b'x') + chunk(b'data', b'xx'),
                  b'WAVE' + chunk(b'fmt ', fmt + b'\x01\0') + chunk(b'data', b'xx')]
        for body in bodies:
            with self.subTest(body=body[:8]), self.assertRaises(AudioError):
                self.info(b'RIFF' + struct.pack('<I', len(body)) + body)

    def test_ошибки_не_раскрывают_путь(self):
        with self.assertRaises(AudioError) as caught:
            audio_info(self.path)
        self.assertNotIn(str(self.path), str(caught.exception))
