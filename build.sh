#!/bin/bash
# Сборка + установка LayoutSwitcher со СТАБИЛЬНОЙ подписью.
# Ключевое: подпись постоянным сертификатом "LayoutSwitcher Self-Signed" →
# designated requirement привязан к сертификату, а не к cdhash →
# права (Accessibility, Screen Recording) НЕ слетают при пересборке.
set -e

CERT="LayoutSwitcher Self-Signed"
APP="/Applications/LayoutSwitcher.app"
SRC=~/LayoutSwitcher/src
UID_=$(id -u)

echo "→ Компиляция (Swift + C-жесты + MultitouchSupport + CoreAudio)..."
cd ~/LayoutSwitcher
swiftc "$SRC/main.swift" "$SRC/away.swift" "$SRC/away_ui.swift" "$SRC/mtswipe.c" \
  -import-objc-header "$SRC/bridge.h" \
  -framework Carbon -framework AppKit -framework Foundation -framework ApplicationServices -framework IOKit -framework CoreAudio -framework AudioToolbox \
  -F /System/Library/PrivateFrameworks -framework MultitouchSupport \
  -O -o LayoutSwitcherBin

echo "→ Установка бинарника..."
pkill -9 -x LayoutSwitcher 2>/dev/null || true
launchctl bootout gui/$UID_/com.nikita.layoutswitcher 2>/dev/null || true
sleep 1
cp LayoutSwitcherBin "$APP/Contents/MacOS/LayoutSwitcher"

echo "→ Подпись стабильным сертификатом (права сохранятся)..."
codesign --force --deep -s "$CERT" "$APP"
codesign -d --requirements - "$APP" 2>&1 | grep -i designated || true

echo "→ Запуск через launchd..."
launchctl bootstrap gui/$UID_ ~/Library/LaunchAgents/com.nikita.layoutswitcher.plist
sleep 2
PID=$(pgrep -x LayoutSwitcher | head -1)
echo "✅ Готово. PID=$PID. Права НЕ сбрасывались (стабильная подпись)."
