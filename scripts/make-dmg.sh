#!/usr/bin/env bash
#
# dist/Markit.app 을 배포용 DMG로 만든다.
#
# 사용법:
#   scripts/make-dmg.sh [버전]
#
# create-dmg가 있으면 드래그 설치 창(앱 아이콘 + Applications 별칭)을 만들고,
# 없으면 hdiutil로 단순 DMG를 만든다. 둘 다 설치는 되므로 create-dmg를 강제하지 않는다.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-0.0.0-dev}"
APP_NAME="Markit"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME-$VERSION.dmg"

[ -d "$APP" ] || { echo "번들이 없다: $APP  (scripts/make-app.sh 를 먼저 실행)" >&2; exit 1; }

rm -f "$DMG"

if command -v create-dmg > /dev/null; then
    echo "==> create-dmg로 DMG 생성"
    ARGS=(
        --volname "$APP_NAME $VERSION"
        --window-pos 200 120
        --window-size 600 400
        --icon-size 100
        --icon "$APP_NAME.app" 150 185
        --app-drop-link 450 185
        --no-internet-enable
    )
    # 아이콘이 있을 때만 볼륨 아이콘을 지정한다. 없는 파일을 주면 create-dmg가 실패한다.
    [ -f "$APP/Contents/Resources/AppIcon.icns" ] && \
        ARGS+=(--volicon "$APP/Contents/Resources/AppIcon.icns")

    # create-dmg는 성공해도 0이 아닌 값을 내는 경우가 있다. 종료 코드를 무시하는 대신
    # 산출물 존재로 판정한다 — `|| true`로 덮으면 실패를 조용히 넘긴다.
    create-dmg "${ARGS[@]}" "$DMG" "$APP" || true
else
    echo "==> create-dmg 없음 — hdiutil로 단순 DMG 생성"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG" > /dev/null
    rm -rf "$STAGE"
fi

[ -f "$DMG" ] || { echo "DMG가 만들어지지 않았다" >&2; exit 1; }

# 마운트해서 앱이 실제로 들어 있는지 확인한다. 빈 DMG를 릴리스에 올리는 것을 막는다.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" > /dev/null
if [ -d "$MOUNT/$APP_NAME.app" ]; then
    echo "    내용 확인: $APP_NAME.app 있음"
    RESULT=0
else
    echo "    DMG 안에 $APP_NAME.app 이 없다" >&2
    RESULT=1
fi
hdiutil detach "$MOUNT" > /dev/null
rmdir "$MOUNT"
[ "$RESULT" -eq 0 ] || exit 1

echo
echo "완성: $DMG  ($(du -h "$DMG" | cut -f1))"
