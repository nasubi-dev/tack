#!/bin/zsh
# Tack.app をビルドして ~/Applications に置く。
# 署名を Apple Development 証明書で固定しているので、作り直しても権限（画面収録・アクセシビリティ）が外れない。
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Tack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/main.swift -o "$APP/Contents/MacOS/Tack"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/Tack.app
cp -R "$APP" ~/Applications/
echo "installed: ~/Applications/Tack.app"
