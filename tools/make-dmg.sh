#!/bin/bash
# Собирает установщик build/Rondo-<версия>.dmg: приложение + ярлык «Программы» + оформленное окно.
# Запуск: make dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Rondo.app
VOL=Rondo
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
OUT=build/Rondo-$VER.dmg
STAGE=build/dmg-stage
RW=build/rondo-rw.dmg

[ -d "$APP" ] || { echo "нет $APP — сначала make"; exit 1; }
# если уже смонтирован старый образ с тем же именем — отключаем
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
rm -rf "$STAGE" "$RW" "$OUT"

# 1. содержимое образа
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Rondo.app"
ln -s /Applications "$STAGE/Applications"
swiftc -O tools/dmg-bg.swift -o build/dmg-bg 2>&1 | grep -E "error" || true
build/dmg-bg build/bg1.png 1; build/dmg-bg build/bg2.png 2
tiffutil -cathidpicheck build/bg1.png build/bg2.png -out "$STAGE/.background/background.tiff" 2>/dev/null

# 2. записываемый образ → оформление окна
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size 40m "$RW" >/dev/null
hdiutil attach "$RW" -noautoopen -nobrowse >/dev/null
sleep 1
# расположение иконок и размер окна задаёт Finder; если доступ к Finder не дан — образ всё равно рабочий
if ! perl -e 'alarm 40; exec @ARGV' osascript <<OSA >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Rondo.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
then echo "⚠ Finder не разрешил оформить окно — образ будет с обычной раскладкой иконок"; fi

# значок тома: копируем уже в смонтированный образ (hdiutil не переносит скрытые файлы из папки) и ставим флаг «свой значок»
cp res/AppIcon.icns "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL" 2>/dev/null || echo "⚠ нет SetFile (Command Line Tools) — у тома будет обычный значок"


sync; sleep 1
hdiutil detach "/Volumes/$VOL" >/dev/null || { sleep 2; hdiutil detach "/Volumes/$VOL" -force >/dev/null; }

# 3. сжатый образ только для чтения
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$RW" "$STAGE" build/bg1.png build/bg2.png
echo "готово: $OUT ($(du -h "$OUT" | cut -f1))"
