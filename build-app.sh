#!/bin/bash
# Собирает Speakey.app напрямую через swiftc (SwiftPM в этой CLT сломан),
# кладёт Info.plist (LSUIElement) и подписывает постоянным сертификатом.
set -e
cd "$(dirname "$0")"
PROJECT_ROOT="$(pwd -P)"

# Проверяем сертификат до компиляции и изменения подготовленного бандла.
bash "$PROJECT_ROOT/scripts/sign-speakey-app.sh" --check-identity

# Ежедневная резервная копия, привязанная к работе, а не к календарю. Сборка — самый честный
# признак того, что сегодня в проекте что-то менялось: в дни без сборок и терять нечего.
# Режим `daily` сам выходит за миллисекунды, если свежий снимок уже есть, поэтому цена этой
# строки — двадцать секунд раз в сутки. Сборку не роняем никогда: недоступное хранилище копий
# не повод не собрать приложение.
# ⚠️ Проверка на существование обязательна: этот скрипт публикуется на GitHub, а Tools/ — нет.
# Без неё у постороннего человека сборка начиналась бы с жалобы на отсутствующий файл.
# Именно `if`, а не `[ … ] && { … }`: при set -e неудачная проверка вернула бы 1 всем выражением
# и оборвала бы сборку ровно у того, у кого Tools/ нет — то есть у любого стороннего человека.
if [ -f Tools/backup.sh ]; then
  bash Tools/backup.sh daily || echo "  ⚠️ ежедневный бэкап не сделан"
fi

SWIFTDIR="/Library/Developer/CommandLineTools/usr/include/swift"
if [ -f "$SWIFTDIR/module.modulemap" ] && [ -f "$SWIFTDIR/bridging.modulemap" ]; then
  echo "⚠️  Сломанный toolchain: два modulemap определяют SwiftBridging."
  echo "    Почини один раз (нужен пароль):"
  echo "    sudo mv \"$SWIFTDIR/module.modulemap\" \"$SWIFTDIR/module.modulemap.bak-2023\""
  echo "    Затем запусти этот скрипт снова."
  echo
fi

# Куда собирать. По умолчанию в рабочую папку, но агент собирает в /tmp: пока автор работает в
# своей копии по обычному пути, пересборка туда же означала бы гасить приложение у него под руками,
# а перенос копии в другое место ломает выданные доступы (TCC привязан к пути и подписи).
APP="${SPEAKEY_BUILD_APP:-Speakey.app}"

# Local admin tools share the exact process classifier. Source releases may omit Tools/, so keep a
# minimal equivalent fallback here: v3 wins over the legacy flag it also carries.
if [ -f Tools/speakey-process-safety.sh ]; then
  . Tools/speakey-process-safety.sh
else
  speakey_canonical_path() {
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
  }
  speakey_build_target_allowed() {
    local target project base
    target="$(speakey_canonical_path "$1")" || return 1
    project="$(speakey_canonical_path "$2")" || return 1
    base="$(basename "$target")"
    [ "$base" != ".app" ] || return 1
    case "$base" in *.app) ;; *) return 1 ;; esac
    case "$target" in
      "$project/"*.app|/private/tmp/*.app|/private/var/folders/*/T/*.app) return 0 ;;
      *) return 1 ;;
    esac
  }
  speakey_process_executable() {
    python3 -c '
import ctypes, os, sys
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
buf = ctypes.create_string_buffer(4096)
size = lib.proc_pidpath(ctypes.c_int(int(sys.argv[1])), buf, ctypes.c_uint32(len(buf)))
if size <= 0:
    raise SystemExit(1)
print(os.path.realpath(os.fsdecode(buf.value)))
' "$1" 2>/dev/null
  }
  speakey_candidate_pids() {
    local candidates status
    if candidates="$(pgrep -x Speakey 2>/dev/null)"; then
      printf '%s\n' "$candidates"
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] || echo "?"
  }
  speakey_process_pids() {
    local executable selector="${2:-any}" pid args kind physical
    executable="$(speakey_canonical_path "$1")" || return 1
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      physical="$(speakey_process_executable "$pid" || true)"
      if [ -z "$physical" ]; then
        [ "$selector" = any ] || [ "$selector" = blocking ] || continue
        echo "$pid"
        continue
      fi
      [ "$physical" = "$executable" ] || continue
      args="$(ps -ww -o args= -p "$pid" 2>/dev/null || true)"
      if [ -z "$args" ]; then
        [ "$selector" = any ] || [ "$selector" = blocking ] || continue
        echo "$pid"
        continue
      fi
      case " $args " in
        *" --resource-guard-v3 "*) kind=persistent ;;
        *" --globe-guard "*) kind=legacy ;;
        *) kind=application ;;
      esac
      case "$selector:$kind" in
        application:application|persistent:persistent|blocking:application|blocking:persistent|any:*)
          echo "$pid" ;;
      esac
    done < <(speakey_candidate_pids)
  }
fi
APP_ABSOLUTE="$(speakey_canonical_path "$APP")"
if ! speakey_build_target_allowed "$APP_ABSOLUTE" "$PROJECT_ROOT"; then
  echo "✗ небезопасный SPEAKEY_BUILD_APP: $APP_ABSOLUTE"
  echo "  Разрешён только *.app внутри проекта или системной временной папки."
  exit 2
fi
# From this point the checked path and the mutated path are identical. Never return to the raw
# alias supplied through SPEAKEY_BUILD_APP.
APP="$APP_ABSOLUTE"
EXECUTABLE="$APP_ABSOLUTE/Contents/MacOS/Speakey"

# ⚠️ Пересборка бандла под РАБОТАЮЩИМ из него процессом запрещена: macOS перестаёт доверять
# клиенту, чей бандл изменился на диске, и coreaudiod МОЛЧА глушит ему микрофон — TCC отвечает
# authorized, буферы идут, но в них битовый ноль (инцидент 23.07.2026).
# Узкий legacy crash-scanner без `--resource-guard-v3` можно отличить по argv и не учитывать. Новый
# persistent helper принципиально другой: он может жить после GUI, удерживая global lock/receipt и
# повторяя OFF/restore. Перезаписывать его executable bundle до завершения cleanup нельзя.
main_pids="$(speakey_process_pids "$EXECUTABLE" application)"
if [ -n "$main_pids" ]; then
  echo "✗ Speakey сейчас запущен из $APP_ABSOLUTE — собирать под ним нельзя."
  # ⚠️ ГАСИМ ПО ПУТИ, А НЕ ПО ИМЕНИ. Здесь стояло `pkill -x Speakey`, и эта подсказка обошлась
  # дорого: она гасит ЛЮБОЙ процесс с именем Speakey, то есть заодно и боевую копию из
  # /Applications, которой человек в этот момент пользуется. У сборочной и у боевой копии общее
  # имя процесса и разные пути — значит и различать их надо путём.
  # И `-f`, а не `-9`: SIGKILL перехватить нельзя, а на выходе мы возвращаем системе роль клавиши
  # 🌐, иначе она остаётся сломанной до перезапуска (задача 96).
  echo "  Сначала:  pkill -f \"$EXECUTABLE\"        затем собери и:  open \"$APP\""
  exit 1
fi
persistent_pids="$(speakey_process_pids "$EXECUTABLE" persistent)"
if [ -n "$persistent_pids" ]; then
  echo "⏳ persistent resource helper завершает cleanup: $persistent_pids"
  for _ in $(seq 1 40); do
    persistent_pids="$(speakey_process_pids "$EXECUTABLE" persistent)"
    [ -z "$persistent_pids" ] && break
    sleep 0.25
  done
  if [ -n "$persistent_pids" ]; then
    echo "✗ resource helper всё ещё держит незавершённую сессию: $persistent_pids"
    echo "  Bundle не перезаписываю; helper не посылаю сигналов. Проверь cleanup log/receipt."
    exit 1
  fi
fi
# ПРОВЕРКА ДУБЛЕЙ В L10n (25.07): Swift-словарь-литерал с повторяющимся ключом компилируется молча,
# но падает SIGTRAP при ПЕРВОМ обращении — то есть приложение не запускается вообще (Dictionary.init →
# one-time initialization function for strings). Ловим на сборке, а не по краш-репорту.
DUPES=$(python3 - <<'PYEOF'
import re, collections
src = open('Sources/Speakey/L10n.swift', encoding='utf-8').read()
keys = re.findall(r'^\s*"([^"]+)":\s*\[', src, re.M)
print(",".join(k for k, c in collections.Counter(keys).items() if c > 1))
PYEOF
)
if [ -n "$DUPES" ]; then
  echo "✗ Дубликаты ключей в L10n.swift: $DUPES"
  echo "  Swift упадёт при запуске (SIGTRAP в Dictionary.init). Переименуй ключ и собери снова."
  exit 1
fi

# Проверяем и компилируем модель до изменения существующего приложения.
bash scripts/fetch-rightlayout-model.sh --check-only
RIGHTLAYOUT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/speakey-rightlayout-build.XXXXXX")"
trap 'rm -rf "$RIGHTLAYOUT_STAGE"' EXIT
swift scripts/compile-rightlayout-model.swift \
  Sources/Speakey/Resources/RightLayout/LayoutClassifier.mlmodel \
  "$RIGHTLAYOUT_STAGE/LayoutClassifier.mlmodelc"
cp Resources/RightLayout/model.json "$RIGHTLAYOUT_STAGE/model.json"
cp Resources/RightLayout/LICENSE "$RIGHTLAYOUT_STAGE/LICENSE"
cp Resources/RightLayout/profile.json "$RIGHTLAYOUT_STAGE/profile.json"

echo "▸ swiftc compile…"
# Close the bounded-wait race: a GUI may have launched while the old helper was finishing. Perform
# one final exact-path check immediately before replacing any bundle contents.
blocking_pids="$(speakey_process_pids "$EXECUTABLE" blocking)"
if [ -n "$blocking_pids" ]; then
  echo "✗ перед записью bundle снова появился GUI/persistent helper: $blocking_pids"
  echo "  Bundle оставляю без изменений."
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/RightLayout"
cp -R "$RIGHTLAYOUT_STAGE/LayoutClassifier.mlmodelc" "$APP/Contents/Resources/RightLayout/"
cp "$RIGHTLAYOUT_STAGE/model.json" "$RIGHTLAYOUT_STAGE/LICENSE" "$RIGHTLAYOUT_STAGE/profile.json" "$APP/Contents/Resources/RightLayout/"

# ⚠️ КРИТИЧНО (24.07): arm64-сборка whisper.cpp ДОЛЖНА быть с CMAKE_OSX_DEPLOYMENT_TARGET=14.0.
# Без него cmake берёт таргет текущей системы (собирали на macOS 26) → ggml-metal делает STRONG-ссылку
# на MTLResidencySetDescriptor (класс есть только с macOS 15) → на Sonoma/14 dyld убивает процесс ДО
# main() с "Symbol not found", приложение молча не запускается (репорт M1/Sonoma, 0.2.66). С таргетом
# 14.0 ссылка становится weak (@available(macOS 15) в ggml отрабатывает как задумано).
WHISPER="vendor/whisper.cpp/build-macos14/.."
WHISPER_BUILD="vendor/whisper.cpp/build-macos14"
if [ ! -f "$WHISPER_BUILD/src/libwhisper.a" ]; then
  echo "⚠️  whisper.cpp не собран. Собери один раз:"
  echo "    cd $WHISPER && cmake -B build-macos14 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \\"
  echo "      -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF && cmake --build build-macos14 -j"
  exit 1
fi

# FluidAudio (Parakeet/CoreML/ANE) — предсобранная статика, предсобранная статика.
# Требует macOS 14 (поэтому таргет подняли 13→14).
FA="vendor/fluidaudio-prebuilt"
swiftc -O Sources/Speakey/*.swift \
  -o "$APP/Contents/MacOS/Speakey" \
  -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Speakey/whisper-bridging.h \
  -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
  -I "$FA/Modules" -I "$FA/include/FastClusterWrapper" -I "$FA/include/MachTaskSelfWrapper" \
  -L "$WHISPER_BUILD/src" -L "$WHISPER_BUILD/ggml/src" \
  -L "$WHISPER_BUILD/ggml/src/ggml-metal" -L "$WHISPER_BUILD/ggml/src/ggml-blas" \
  -L "$FA" -lFluidAudio \
  -lwhisper -lggml -lggml-cpu -lggml-metal -lggml-blas -lggml-base -lc++ \
  -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework IOKit \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Metal -framework MetalKit -framework Accelerate -framework CoreML \
  -framework SwiftUI -Xlinker -weak_framework -Xlinker Translation

# ── Universal (Intel): второй проход под x86_64 + lipo. Включается SPEAKEY_UNIVERSAL=1
#    (release.sh включает всегда; dev-сборки по умолчанию arm64-only — вдвое быстрее).
#    x86-срез: whisper из build-x86 (GGML_NATIVE=OFF + AVX2-бейзлайн, БЕЗ Metal — CPU/Accelerate),
#    БЕЗ FluidAudio (arm64-only статика; Swift-код компилирует Intel-заглушки по #if arch).
if [ "${SPEAKEY_UNIVERSAL:-}" = "1" ]; then
  WX="$WHISPER/build-x86"
  if [ ! -f "$WX/src/libwhisper.a" ]; then
    echo "✗ Нет x86-сборки whisper. Один раз собери:"
    echo "  cd $WHISPER && cmake -B build-x86 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \\"
    echo "    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON \\"
    echo "    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF && cmake --build build-x86 -j"
    exit 1
  fi
  echo "▸ swiftc compile (x86_64 для universal)…"
  mv "$APP/Contents/MacOS/Speakey" "$APP/Contents/MacOS/.Speakey-arm64"
  swiftc -O Sources/Speakey/*.swift \
    -o "$APP/Contents/MacOS/.Speakey-x86" \
    -swift-version 5 -target x86_64-apple-macos13.0 \
    -import-objc-header Sources/Speakey/whisper-bridging.h \
    -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
    -L "$WX/src" -L "$WX/ggml/src" -L "$WX/ggml/src/ggml-blas" \
    -lwhisper -lggml -lggml-cpu -lggml-blas -lggml-base -lc++ \
    -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework IOKit \
    -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework CoreML \
    -framework SwiftUI -Xlinker -weak_framework -Xlinker Translation
  lipo -create "$APP/Contents/MacOS/.Speakey-arm64" "$APP/Contents/MacOS/.Speakey-x86" \
       -output "$APP/Contents/MacOS/Speakey"
  rm -f "$APP/Contents/MacOS/.Speakey-arm64" "$APP/Contents/MacOS/.Speakey-x86"
  echo "  universal: $(lipo -archs "$APP/Contents/MacOS/Speakey")"
fi

# Языковые данные (триграммы/словари) в bundle Resources
cp Sources/Speakey/Resources/*.json "$APP/Contents/Resources/" 2>/dev/null || echo "  (нет Resources/*.json — детектор будет без данных)"
# Asset Catalog → coral как системный accent (чекбоксы/тумблеры/popup станут оранжевыми).
if [ -d Resources/Assets.xcassets ]; then
  actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 13.0 \
    --output-partial-info-plist /tmp/speakey-assets-plist.plist >/dev/null 2>&1 \
    && echo "  ассеты: AccentColor (coral) скомпилирован" \
    || echo "  ассеты: actool не справился (accent останется системным)"
fi

# Иконка приложения (Finder/Dock/About/DMG).
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null \
  && echo "  иконка: AppIcon.icns" \
  || echo "  (нет Resources/AppIcon.icns — иконка дефолтная)"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Speakey</string>
    <key>CFBundleDisplayName</key>     <string>Speakey</string>
    <key>CFBundleIdentifier</key>      <string>dev.speakey.app</string>
    <key>CFBundleVersion</key>         <string>0.4.10</string>
    <key>CFBundleShortVersionString</key> <string>0.4.10</string>
    <!-- Штамп сборки: подставляется ниже (sed по __BUILD_STAMP__). Логируется при запуске, чтобы по
         логу было ВИДНО, какую именно сборку гоняем. Прецедент 21.07: диагностировали баг по логу
         процесса, стартовавшего на 11 минут РАНЬШЕ пересборки, — то есть по коду без свежих правок. -->
    <key>SpeakeyBuildStamp</key>       <string>__BUILD_STAMP__</string>
    <key>CFBundleExecutable</key>      <string>Speakey</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleAllowMixedLocalizations</key> <true/>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Пер-архитектурные минимумы (задача «старые системы», 23.07.2026): arm64 требует 14
         (FluidAudio/ANE статически влинкован), x86_64 живёт с 13 — в этом срезе FluidAudio нет,
         а интелы 2017 года выше Ventura не обновляются. Ключ подтверждён в актуальной
         документации Apple (bundleresources → LSMinimumSystemVersionByArchitecture). -->
    <key>LSMinimumSystemVersionByArchitecture</key>
    <dict>
        <key>arm64</key>  <string>14.0</string>
        <key>x86_64</key> <string>13.0</string>
    </dict>
    <key>LSUIElement</key>             <true/>
    <key>NSAccentColorName</key>       <string>AccentColor</string>
    <key>NSAudioCaptureUsageDescription</key> <string>Speakey записывает системный звук и микрофон только по вашему ⌥-клику по значку, расшифровывает запись на этом Mac и никуда не отправляет.</string>
    <key>NSMicrophoneUsageDescription</key> <string>Speakey распознаёт надиктованный текст локально, на вашем Mac. Аудио никуда не отправляется.</string>
    <!-- ⚠️ ЯВНЫЙ ОТКАЗ ОТ РЕЖИМА СОВМЕСТИМОСТИ С КОРПУСОМ КАМЕРЫ (13.08.2026).
         На маках с чёлкой система умеет менять активную область экрана так, чтобы она обходила
         корпус камеры: тогда вырез исчезает, сверху появляется ровная полоса, а safeAreaInsets
         обнуляется. Включается это НЕ настройкой человека, а автоматически, как только приложение,
         которому режим нужен, положит окно за корпусом камеры на текущем рабочем столе. Мы кладём
         туда остров НАМЕРЕННО и умеем это делать правильно, поэтому говорим системе false: тогда
         Finder не показывает у нас галочку «Подогнать под встроенную камеру» в «Свойствах», и
         включить её случайно нельзя. Ключ документирован:
         developer.apple.com/documentation/bundleresources/information-property-list/nsprefersdisplaysafeareacompatibilitymode -->
    <key>NSPrefersDisplaySafeAreaCompatibilityMode</key> <false/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Speakey – free &amp; open source</string>
    <key>MDItemKeywords</key><string>Speakey, раскладка, диктовка, switcher</string>
</dict>
</plist>
PLIST

# Штамп сборки — реальные дата+время сборки в Info.plist (heredoc single-quoted, переменные там не
# раскрываются, поэтому подставляем sed'ом после). Логируется при запуске: по логу сразу видно,
# какую сборку гоняем (прецедент 21.07 — диагностика шла по процессу старше пересборки на 11 минут).
BUILD_STAMP="$(date '+%Y-%m-%d %H:%M')"
sed -i '' "s/__BUILD_STAMP__/$BUILD_STAMP/" "$APP/Contents/Info.plist"

# Сборки для разработки изолированы собственным доменом настроек.
if [ "${SPEAKEY_RELEASE:-}" != "1" ]; then
  /usr/libexec/PlistBuddy -c "Add :SpeakeyLocalBuild bool true" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.speakey.app.dev" "$APP/Contents/Info.plist"
fi

# Уведомления об авторстве и лицензии распространяются вместе с приложением.
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"
bash "$PROJECT_ROOT/scripts/sign-speakey-app.sh" "$APP"

echo "✓ Готово: $APP"
echo "  Запуск: open \"$APP\""
