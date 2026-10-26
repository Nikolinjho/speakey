#!/bin/bash
# Готовит зависимости внутри vendor, не запускает и не устанавливает приложение.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor
checkout() {
    local path="$1" url="$2" tag="$3" revision="$4"
    if [ ! -d "$path" ]; then git clone --depth 1 --branch "$tag" "$url" "$path"; fi
    if [ "$(git -C "$path" rev-parse HEAD)" != "$revision" ]; then
        echo "Несовместимая версия $path, ожидается $revision. Существующую копию не меняю." >&2
        exit 1
    fi
    if [ "$path" != vendor/FluidAudio ] && [ -n "$(git -C "$path" status --porcelain)" ]; then
        echo "В $path есть локальные изменения. Сборка остановлена." >&2
        exit 1
    fi
}
checkout vendor/whisper.cpp https://github.com/ggml-org/whisper.cpp.git v1.8.3 2eeeba56e9edd762b4b38467bab96c2517163158
checkout vendor/FluidAudio https://github.com/FluidInference/FluidAudio.git v0.14.8 56607d90b97de7d95a731200563bf49aa5beef20
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build-macos14 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build vendor/whisper.cpp/build-macos14 -j "$(sysctl -n hw.logicalcpu)"
patch="$PWD/vendor-patches/fluidaudio-offline.patch"
if git -C vendor/FluidAudio apply --check "$patch" 2>/dev/null; then
    git -C vendor/FluidAudio apply "$patch"
elif ! git -C vendor/FluidAudio apply --reverse --check "$patch" 2>/dev/null; then
    echo "FluidAudio не соответствует исходнику или офлайн-патчу." >&2
    exit 1
fi
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
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-vendor.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl -fL https://github.com/sparkle-project/Sparkle/releases/download/2.9.3/Sparkle-2.9.3.tar.xz -o "$work/Sparkle.tar.xz"
printf '%s  %s\n' 74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6 "$work/Sparkle.tar.xz" | shasum -a 256 -c -
if [ -d vendor/sparkle ]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' vendor/sparkle/Sparkle.framework/Resources/Info.plist)"
    [ "$version" = 2.9.3 ] || { echo "Ожидался Sparkle 2.9.3, получен $version" >&2; exit 1; }
else
    mkdir -p vendor/sparkle
    tar -xf "$work/Sparkle.tar.xz" -C vendor/sparkle
fi
