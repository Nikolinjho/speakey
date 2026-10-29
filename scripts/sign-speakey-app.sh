#!/bin/bash
# Подписывает подготовленный бандл постоянным сертификатом, без ad-hoc fallback.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SIGN_ID="${SPEAKEY_SIGN_ID:-749281C2A0E19FC82DA85918A28F5BCC195C5597}"
if [ "$SIGN_ID" = "-" ]; then
  echo "✗ ad-hoc подпись запрещена. Нужен постоянный SPEAKEY_SIGN_ID." >&2
  exit 2
fi
if [ "$#" -ne 1 ]; then
  echo "Использование: bash scripts/sign-speakey-app.sh --check-identity | /path/to/Staged.app" >&2
  exit 2
fi

# -v возвращает только валидные identities. Точное имя должно определять один сертификат.
IDENTITIES="$(security find-identity -v -p codesigning)"
SIGN_SHA="$(printf '%s\n' "$IDENTITIES" | python3 -c '
import re, sys
requested = sys.argv[1]
identities = re.findall(r"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+\"([^\"]+)\"", sys.stdin.read(), re.M)
is_hash = re.fullmatch(r"[0-9A-Fa-f]{40}", requested) is not None
matches = {sha.upper() for sha, name in identities if (sha.upper() == requested.upper() if is_hash else name == requested)}
if len(matches) != 1:
    print("✗ Сертификат подписи отсутствует или имя неоднозначно: " + requested, file=sys.stderr)
    sys.exit(1)
print(next(iter(matches)))
' "$SIGN_ID")"
if [ "$1" = "--check-identity" ]; then
  echo "Подпись доступна: $SIGN_ID ($SIGN_SHA)"
  exit 0
fi

APP="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")"
case "$APP" in
  /Applications|/Applications/*|/System/Applications|/System/Applications/*)
    echo "✗ Установленный бандл не переподписывается: $APP" >&2
    exit 2 ;;
esac
case "$APP" in *.app) ;; *) echo "✗ Нужен подготовленный *.app" >&2; exit 2 ;; esac
for path in "$APP/Contents/Info.plist" "$APP/Contents/MacOS/Speakey"; do
  if [ ! -f "$path" ]; then
    echo "✗ Неполный подготовленный бандл: $path" >&2
    exit 2
  fi
done

if [ "${SPEAKEY_RELEASE:-}" = "1" ]; then
  ENT="$PROJECT_ROOT/Speakey.entitlements"
  CS_OPTS=(--options runtime --timestamp)
else
  ENT="$PROJECT_ROOT/Speakey-dev.entitlements"
  CS_OPTS=(--timestamp=none)
fi
codesign --force --sign "$SIGN_SHA" --entitlements "$ENT" "${CS_OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Подпись и строгая проверка готовы: $SIGN_ID ($SIGN_SHA)"
