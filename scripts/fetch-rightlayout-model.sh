#!/bin/bash
set -euo pipefail
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --check-only ]; }; then
  echo "Использование: $0 [--check-only]" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel"
SOURCE_COMMIT=58658d8d4c3b71ed4cfd6b20627196a8145f17f9
EXPECTED_SHA=5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704
EXPECTED_BYTES=13880886
URL="https://raw.githubusercontent.com/chernistry/RightLayout/$SOURCE_COMMIT/RightLayout/Sources/Resources/LayoutClassifier.mlmodel"

verify_model() {
  local bytes sha
  bytes="$(wc -c < "$1" | tr -d '[:space:]')"
  sha="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [ "$bytes" != "$EXPECTED_BYTES" ] || [ "$sha" != "$EXPECTED_SHA" ]; then
    echo "Ошибка RightLayout: размер или SHA256 не совпадает: $1" >&2
    return 1
  fi
}

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  if [ ! -f "$TARGET" ] || ! verify_model "$TARGET"; then
    echo "Существующий ресурс несовместим. Удали его явно перед повторным скачиванием." >&2
    exit 1
  fi
  echo "RightLayout: SHA256 и размер проверены"
  exit 0
fi
if [ "${1:-}" = --check-only ]; then
  echo "Ресурс RightLayout отсутствует. Выполни bash scripts/fetch-rightlayout-model.sh" >&2
  exit 1
fi
mkdir -p "$(dirname "$TARGET")"
TEMPORARY="$(mktemp "$(dirname "$TARGET")/.LayoutClassifier.XXXXXX")"
trap 'rm -f "$TEMPORARY"' EXIT
curl --fail --location --silent --show-error --output "$TEMPORARY" "$URL"
verify_model "$TEMPORARY"
# Параллельная загрузка не должна перезаписать появившийся несовместимый ресурс.
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  verify_model "$TARGET"
else
  mv -n "$TEMPORARY" "$TARGET"
  verify_model "$TARGET"
fi
echo "RightLayout: скачан и проверен $SOURCE_COMMIT"
