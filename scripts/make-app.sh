#!/usr/bin/env bash
#
# SPM 실행 파일로 Markit.app 번들을 조립한다.
#
# Xcode 프로젝트를 쓰지 않는 이유: 이 저장소는 Package.swift 하나가 진실이고 모든 것이
# `swift build`/`swift test`로 돌아간다. 앱 번들은 폴더 구조 + Info.plist일 뿐이므로
# 프로젝트 파일을 하나 더 유지할 이유가 없다.
#
# 사용법:
#   scripts/make-app.sh [버전]
#
# 환경 변수:
#   CODESIGN_IDENTITY   서명 식별자. 없으면 서명하지 않는다.
#                       (예: "Developer ID Application: NAME (TEAMID)")
#   BUILD_NUMBER        CFBundleVersion. 기본 1.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="Markit"
BUNDLE_ID="com.jinto.markit"
DIST_DIR="$ROOT_DIR/dist"
APP="$DIST_DIR/$APP_NAME.app"

echo "==> 유니버설 릴리스 빌드 (arm64 + x86_64)"
# 인텔 맥에서도 돌아야 하므로 유니버설로 만든다. 한쪽만 만들면 그 사용자는 아예 실행할 수 없다.
swift build -c release --product MarkitApp --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/MarkitApp"
[ -f "$BINARY" ] || { echo "빌드 산출물이 없다: $BINARY" >&2; exit 1; }

ARCHS="$(lipo -archs "$BINARY")"
echo "    아키텍처: $ARCHS"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "유니버설이 아니다: $ARCHS" >&2; exit 1 ;;
esac

echo "==> 번들 조립: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 프로세스 이름이 Markit으로 보이도록 실행 파일 이름을 바꿔 넣는다.
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
ICON_KEY=""
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="	<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
    echo "    아이콘 포함"
else
    echo "    아이콘 없음 — Resources/AppIcon.icns를 두면 포함된다"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ko</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
$ICON_KEY
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 JAE KWON PARK. Apache-2.0.</string>
</dict>
</plist>
PLIST

# 번들 구조가 실제로 유효한지 확인한다. Info.plist 오타는 런타임에야 드러난다.
plutil -lint "$APP/Contents/Info.plist" > /dev/null
[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" = "$BUNDLE_ID" ]

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "==> 서명: $CODESIGN_IDENTITY"
    # 번들 한 번만 서명한다. 중첩 코드(프레임워크·헬퍼·XPC)가 없으므로 안쪽부터
    # 서명할 대상이 없다 — 안쪽 실행 파일은 번들 서명에 포함된다.
    #
    # --options=runtime (하드닝된 런타임)과 --timestamp는 공증의 전제 조건이다.
    # entitlements를 주지 않는다: 샌드박스를 쓰지 않으므로 예외로 열어야 할 권한이 없다.
    TIMESTAMP_FLAG="--timestamp"
    [ "$CODESIGN_IDENTITY" = "-" ] && TIMESTAMP_FLAG=""  # 애드혹은 타임스탬프를 못 받는다

    codesign --force --sign "$CODESIGN_IDENTITY" \
        --options=runtime $TIMESTAMP_FLAG \
        "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "    서명 확인:"
    codesign --display --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|flags)' | sed 's/^/      /'
else
    echo "==> 서명 생략 (CODESIGN_IDENTITY 없음)"
fi

echo
echo "완성: $APP"
echo "  버전 $VERSION (빌드 $BUILD_NUMBER), $ARCHS"
