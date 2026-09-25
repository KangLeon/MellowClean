#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_PATH="${MELLOW_BUILD_PATH:-.build}"
swift build -c release --scratch-path "$BUILD_PATH" "$@"
BIN="$(swift build -c release --scratch-path "$BUILD_PATH" "$@" --show-bin-path)"
mkdir -p dist/MellowClean.app/Contents/MacOS dist/bin
cp "$BIN/MellowCleanApp" dist/MellowClean.app/Contents/MacOS/MellowClean
cp "$BIN/mellowclean" dist/bin/
cp Resources/Info.plist dist/MellowClean.app/Contents/
xattr -cr dist/MellowClean.app
codesign --force --sign - dist/MellowClean.app
echo 'Built dist/MellowClean.app and dist/bin/mellowclean'
