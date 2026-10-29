#!/usr/bin/env python3
"""Замораживает публичный пилот, не меняя основной оценочный корпус."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "rightlayout-opportunity-pilot-v1:"
QUALITY = ROOT / "Tests/NeuralLayout/quality-source.jsonl"
existing = {json.loads(line)["family"] for line in QUALITY.read_text().splitlines()}
paths = {language: ROOT / f"Sources/Speakey/Resources/words_{language}.json" for language in ("en", "ru")}
words = {language: set(json.loads(path.read_text())) for language, path in paths.items()}
en = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
ru = "ёйцукенгшщзхъфывапролджэячсмитьбю."
tables = {"en": str.maketrans(en, ru), "ru": str.maketrans(ru, en)}
rows = []
for language in ("en", "ru"):
    alphabet = set("abcdefghijklmnopqrstuvwxyz" if language == "en" else "абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
    candidates = []
    for word in words[language]:
        if not 4 <= len(word) <= 16 or not set(word) <= alphabet or word in existing:
            continue
        wrong = word.translate(tables[language])
        reverse = "ru" if language == "en" else "en"
        if wrong == word or wrong in words["en"] or wrong in words["ru"] or wrong.translate(tables[reverse]) != word:
            continue
        candidates.append(word)
    candidates.sort(key=lambda word: hashlib.sha256((PREFIX + word).encode()).hexdigest())
    for index, word in enumerate(candidates[:20], 1):
        rows.append(dict(id=f"{language}-{index:02d}", family=word, text=word, language=language,
                         source=f"keyswitcher:Resources/words_{language}.json", license="MIT"))
assert len(rows) == 40
output = ROOT / "Tests/NeuralLayout/opportunity-pilot.jsonl"
output.write_text("".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows))
manifest = dict(version=1, selection=f"SHA256({PREFIX}+family), ascending, first 20 eligible/language",
                pilotSHA256=hashlib.sha256(output.read_bytes()).hexdigest(),
                qualitySHA256=hashlib.sha256(QUALITY.read_bytes()).hexdigest(),
                sources={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths.values()},
                labels="Dictionary-derived layout roundtrip labels; not independently human-labelled; not known unseen to the model",
                attribution="keyswitcher, MIT; see THIRD_PARTY.md. No personal journal data.")
output.with_suffix(".provenance.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
print(f"40 public families frozen; SHA256 {manifest['pilotSHA256']}")
