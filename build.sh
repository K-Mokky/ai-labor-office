#!/bin/bash
# Build AI Usage.app (menu bar app + WidgetKit extension) without Xcode.
# Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

TARGET="arm64-apple-macos14.0"
BUILD=build
APP="$BUILD/AI Usage.app"
APPEX="$APP/Contents/Extensions/AIUsageWidget.appex"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

echo "==> Compiling app"
swiftc -O -parse-as-library -target "$TARGET" \
  Sources/Shared/*.swift Sources/App/*.swift \
  -o "$APP/Contents/MacOS/AIUsage"

echo "==> Compiling widget extension"
swiftc -O -parse-as-library -application-extension -target "$TARGET" \
  Sources/Shared/*.swift Sources/Widget/*.swift \
  -o "$APPEX/Contents/MacOS/AIUsageWidget"

cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Widget-Info.plist "$APPEX/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing"
codesign --force --sign - --entitlements Resources/widget.entitlements "$APPEX"
codesign --force --sign - "$APP"

echo "==> Built: $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="/Applications/AI Usage.app"
  pkill -x AIUsage 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  open "$DEST"
  echo "==> Installed and launched: $DEST"
  echo "==> Widget registration (WidgetKit):"
  sleep 3
  pluginkit -m -p com.apple.widgetkit-extension | grep -i "com.mokky.aiusage.widget" \
    || echo "(위젯이 아직 등록되지 않았습니다. 잠시 후 'pluginkit -m -p com.apple.widgetkit-extension'으로 확인하세요.)"
fi
