#!/bin/bash
# Build AI 노동청 (bundle folder: AI Labor Office.app) — menu bar app + WidgetKit
# extension without Xcode.
# Usage: ./build.sh [install|dmg]
#   install  /Applications 에 설치 후 실행
#   dmg      assets/AI-노동청-<버전>.dmg 생성 (버전은 Resources/App-Info.plist 기준)
#
# 번들 폴더명은 반드시 ASCII(AI Labor Office.app)여야 한다: 한글 이름이면
# ExtensionKit이 위젯 appex를 NFD로 분해된 URL로 LaunchServices에서 조회하다
# 실패해 ("not found in LS database") 위젯이 갤러리에 뜨지 않는다. Finder에
# 보이는 한글 이름(AI 노동청)은 ko.lproj/InfoPlist.strings가 담당한다.
set -euo pipefail
cd "$(dirname "$0")"

TARGET="arm64-apple-macos14.0"
BUILD=build
APP="$BUILD/AI Labor Office.app"
APPEX="$APP/Contents/Extensions/AI Labor Office Widget.appex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 두 plist의 버전이 어긋난 채 빌드되는 사고 방지 — rm -rf 전에 검사해서
# 불일치면 기존 build/를 건드리지 않고 바로 실패한다.
APP_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/App-Info.plist)
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/App-Info.plist)
WIDGET_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Widget-Info.plist)
WIDGET_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Widget-Info.plist)
if [[ "$APP_VER" != "$WIDGET_VER" || "$APP_BUILD" != "$WIDGET_BUILD" ]]; then
  echo "error: App-Info.plist ($APP_VER/$APP_BUILD)와 Widget-Info.plist ($WIDGET_VER/$WIDGET_BUILD) 버전이 다릅니다" >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ko.lproj" \
         "$APP/Contents/Resources/en.lproj" \
         "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources/ko.lproj" \
         "$APPEX/Contents/Resources/en.lproj"

echo "==> Compiling app"
# 실행 파일명(CFBundleExecutable)은 ASCII 프로그램 이름이다
# (Activity Monitor의 프로세스명). 한글 표시 이름은 ko.lproj의
# CFBundleDisplayName/CFBundleName = "AI 노동청"이 담당하고, 루트 Info.plist는
# ASCII("AI Labor Office")로 둔다. 번들 폴더(AI Labor Office.app)는
# 위젯 LaunchServices 등록 안정성을 위해 ASCII로 유지한다.
swiftc -O -parse-as-library -target "$TARGET" \
  Sources/Shared/*.swift Sources/App/*.swift \
  -o "$APP/Contents/MacOS/AI Labor Office"

echo "==> Compiling widget extension"
swiftc -O -parse-as-library -application-extension -target "$TARGET" \
  Sources/Shared/*.swift Sources/Widget/*.swift \
  -o "$APPEX/Contents/MacOS/AI Labor Office Widget"

cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Widget-Info.plist "$APPEX/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Finder·위젯 갤러리에 보이는 이름 (번들 폴더명은 ASCII 유지).
# Launch Services는 UTF-16 InfoPlist.strings만 안정적으로 읽는다.
write_strings() {
  local dest="$1"
  shift
  printf '%s\n' "$@" | iconv -f UTF-8 -t UTF-16 > "$dest"
}
write_strings "$APP/Contents/Resources/ko.lproj/InfoPlist.strings" \
  'CFBundleDisplayName = "AI 노동청";' \
  'CFBundleName = "AI 노동청";'
write_strings "$APP/Contents/Resources/en.lproj/InfoPlist.strings" \
  'CFBundleDisplayName = "AI Labor Office";' \
  'CFBundleName = "AI Labor Office";'
write_strings "$APPEX/Contents/Resources/ko.lproj/InfoPlist.strings" \
  'CFBundleDisplayName = "AI 노동청 위젯";' \
  'CFBundleName = "AI 노동청 위젯";'
write_strings "$APPEX/Contents/Resources/en.lproj/InfoPlist.strings" \
  'CFBundleDisplayName = "AI Labor Office Widget";' \
  'CFBundleName = "AI Labor Office Widget";'

echo "==> Signing"
codesign --force --sign - --entitlements Resources/widget.entitlements "$APPEX"
codesign --force --sign - "$APP"

echo "==> Built: $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="/Applications/AI Labor Office.app"
  # 실행 중 인스턴스 종료 — 실행 파일명과 무관하게 번들 경로로 매칭.
  pkill -f "/Applications/AIUsage.app/Contents/MacOS" 2>/dev/null || true
  pkill -f "/Applications/AI Labor Office.app/Contents/MacOS" 2>/dev/null || true
  pkill -x "AIUsage" 2>/dev/null || true
  pkill -x "AI NoDongChung" 2>/dev/null || true
  # 구버전 번들 정리 — 한글 이름 번들은 위젯 등록이 깨지므로 LS 기록까지 지운다.
  for old in "/Applications/AI 노동청.app" "/Applications/AI Usage.app" \
             "/Applications/AIUsage.app" "/Applications/AI NoDongChung.app"; do
    if [[ -d "$old" ]]; then
      "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true
      rm -rf "$old"
    fi
  done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST"
  # appex 단독 등록은 -10811(앱 아님)로 거부될 수 있다 — 부모 앱 등록이 플러그인을 포함한다.
  "$LSREGISTER" -f "$DEST/Contents/Extensions/AI Labor Office Widget.appex" 2>/dev/null || true
  open "$DEST"
  echo "==> Installed and launched: $DEST"
  echo "==> Widget registration (WidgetKit):"
  sleep 3
  pluginkit -m -p com.apple.widgetkit-extension | grep -i "com.mokky.aiusage.widget" \
    || echo "(위젯이 아직 등록되지 않았습니다. 잠시 후 'pluginkit -m -p com.apple.widgetkit-extension'으로 확인하세요.)"
fi

if [[ "${1:-}" == "dmg" ]]; then
  VERSION="$APP_VER"
  ASSETS=assets
  DMG="$ASSETS/AI-노동청-$VERSION.dmg"
  DMG_ASCII="$ASSETS/AI-Labor-Office-$VERSION.dmg"   # GitHub 릴리스 에셋용(한글 파일명은 GitHub이 지움)
  mkdir -p "$ASSETS"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG" "$DMG_ASCII"
  hdiutil create -volname "AI 노동청 $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  cp "$DMG" "$DMG_ASCII"
  echo "==> DMG: $DMG"
  echo "==> DMG (릴리스 업로드용): $DMG_ASCII"
fi
