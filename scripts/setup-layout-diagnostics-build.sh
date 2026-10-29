#!/bin/bash
# Готовит зависимости внутри vendor, не запускает и не устанавливает приложение.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--check-only) ;; *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;; esac
mkdir -p vendor
checkout() {
    local path="$1" url="$2" tag="$3" revision="$4"
    if [ ! -d "$path" ]; then git clone --depth 1 --branch "$tag" "$url" "$path"; fi
    if [ "$(git -C "$path" rev-parse HEAD)" != "$revision" ]; then
        echo "Несовместимая версия $path, ожидается $revision. Существующую копию не меняю." >&2
        exit 1
    fi
    if [ -n "$(git -C "$path" ls-files --others -- . ':(exclude).build' ':(exclude)build-macos14' ':(exclude).DS_Store' ':(exclude)**/.DS_Store')" ]; then
        echo "В $path есть неизвестные файлы. Сборка остановлена." >&2
        exit 1
    fi
    if [ "$path" != vendor/FluidAudio ] && [ -n "$(git -C "$path" status --porcelain)" ]; then
        echo "В $path есть локальные изменения. Сборка остановлена." >&2
        exit 1
    fi
}
checkout vendor/whisper.cpp https://github.com/ggml-org/whisper.cpp.git v1.8.3 2eeeba56e9edd762b4b38467bab96c2517163158
checkout vendor/FluidAudio https://github.com/FluidInference/FluidAudio.git v0.14.8 56607d90b97de7d95a731200563bf49aa5beef20
patch="$PWD/vendor-patches/fluidaudio-offline.patch"
actual="$(git -C vendor/FluidAudio diff --no-ext-diff --no-color --no-renames --src-prefix=a/ --dst-prefix=b/ --unified=3 HEAD --)"
expected="$(cat "$patch")"
if [ -z "$actual" ]; then
    git -C vendor/FluidAudio apply --check "$patch"
    git -C vendor/FluidAudio apply "$patch"
elif [ "$actual" != "$expected" ]; then
    echo "FluidAudio содержит изменения за пределами точного офлайн-патча." >&2
    exit 1
fi
[ "${1:-}" != --check-only ] || exit 0
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build-macos14 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build vendor/whisper.cpp/build-macos14 -j "$(sysctl -n hw.logicalcpu)"
# Явный backend сохраняет одинаковое расположение артефактов SwiftPM.
swift build --disable-sandbox --build-system swiftbuild --package-path vendor/FluidAudio \
    -c release --target FluidAudio --triple arm64-apple-macosx14.0
products=vendor/FluidAudio/.build/out/Products/Release
fa=vendor/fluidaudio-prebuilt
mkdir -p "$fa/Modules" "$fa/include/FastClusterWrapper" "$fa/include/MachTaskSelfWrapper"
libtool -static -o "$fa/libFluidAudio.a" "$products/FluidAudio.o" \
    "$products/FastClusterWrapper.o" "$products/MachTaskSelfWrapper.o"
cp -R "$products/FluidAudio.swiftmodule" "$fa/Modules/"
cp -R vendor/FluidAudio/Sources/FastClusterWrapper/include/ "$fa/include/FastClusterWrapper/"
cp -R vendor/FluidAudio/Sources/MachTaskSelfWrapper/include/ "$fa/include/MachTaskSelfWrapper/"
