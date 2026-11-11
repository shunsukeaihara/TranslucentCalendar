#!/bin/bash
# リリースビルドして build/TranslucentCalendar.app を作る
#   ./build.sh           ビルドのみ
#   ./build.sh install   ビルドして /Applications に入れ、起動し直す
#                        （INSTALL_DIR=... で入れる先を変えられる）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TranslucentCalendar.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TranslucentCalendar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TranslucentCalendar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 固定の署名 ID で署名すると、再ビルドしてもカレンダーの許可が引き継がれる。
# scripts/make_signing_cert.sh で作った自己署名証明書があればそれを使い、
# なければアドホック署名（再ビルドのたびに許可を聞かれる）にする。
LOCAL_IDENTITY="TranslucentCalendar Local Signing"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
        CODESIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        CODESIGN_IDENTITY="-"
    fi
fi
codesign --force --sign "$CODESIGN_IDENTITY" "$APP"

echo "Built: $APP (signed with: $CODESIGN_IDENTITY)"

if [[ "${1:-}" == "install" ]]; then
    # パスに末尾スペースなどがあるとメニューバーのアイコンが出ないことがあるため、
    # 実際に使うアプリは /Applications に置く（Launchpad や Spotlight にも出る）
    # 終了しきる前に開くと起動に失敗するので、少し待つ
    pkill -x TranslucentCalendar && sleep 1 || true
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/TranslucentCalendar.app"
    cp -R "$APP" "$INSTALL_DIR/"
    open "$INSTALL_DIR/TranslucentCalendar.app"
    echo "Installed: $INSTALL_DIR/TranslucentCalendar.app"
fi
