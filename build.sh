#!/bin/bash
# Сборка PingDot.app без Xcode-проекта — нужен только swiftc из Command Line Tools.
#   ./build.sh                собрать build/PingDot.app
#   ./build.sh install        собрать, положить в /Applications и запустить
#   ARCHS=arm64 ./build.sh    только под Apple Silicon (по умолчанию — Apple Silicon + Intel)
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Не найден компилятор Swift. Установи Command Line Tools: xcode-select --install"
    exit 1
fi

APP="build/PingDot.app"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="13.0"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf build
mkdir -p "$APP/Contents/MacOS"

binaries=()
for arch in $ARCHS; do
    echo "→ компиляция ($arch)"
    xcrun --sdk macosx swiftc -O -parse-as-library -module-name PingDot \
        -target "$arch-apple-macos$MIN_MACOS" \
        Sources/*.swift -o "$WORK/PingDot-$arch"
    binaries+=("$WORK/PingDot-$arch")
done

lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/PingDot"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"    # ad-hoc подпись: нужна для Apple Silicon и автозапуска
echo "✓ Собрано: $APP"

if [[ "${1:-}" == "install" ]]; then
    if pgrep -x PingDot >/dev/null; then
        pkill -x PingDot || true
        for _ in {1..25}; do pgrep -x PingDot >/dev/null || break; sleep 0.2; done
    fi
    rm -rf /Applications/PingDot.app
    cp -R "$APP" /Applications/
    open /Applications/PingDot.app
    echo "✓ Установлено в /Applications и запущено"
else
    echo "  Запустить:   open $APP"
    echo "  Установить:  ./build.sh install"
fi
