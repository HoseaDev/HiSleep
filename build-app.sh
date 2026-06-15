#!/usr/bin/env bash
# 把 ShutEye 打包成可分发的 .app(ad-hoc 签名,免费,无需 Apple 账号)。
# 产物在 dist/:ShutEye.app + install.sh,打成一个 zip 发给别人即可。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ShutEye"
BUNDLE_ID="com.hosea.shuteye"
VERSION="1.0.0"

echo "==> swift build -c release"
swift build -c release
BIN=".build/release/${APP_NAME}"
[ -f "$BIN" ] || { echo "构建产物不存在: $BIN" >&2; exit 1; }

APP="${APP_NAME}.app"
echo "==> 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"

# 应用图标:从 shuteye.png 生成多分辨率 .icns
ICON_SRC="shuteye.png"
HAS_ICON=0
if [ -f "$ICON_SRC" ]; then
    echo "==> 生成应用图标 ${APP_NAME}.icns"
    ICONSET="$(mktemp -d)/${APP_NAME}.iconset"
    mkdir -p "$ICONSET"
    for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                "512 512x512" "1024 512x512@2x"; do
        px="${spec%% *}"; name="${spec##* }"
        sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/icon_${name}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/${APP_NAME}.icns"
    rm -rf "$(dirname "$ICONSET")"
    HAS_ICON=1
else
    echo "==> 未找到 ${ICON_SRC},跳过图标(app 用默认图标)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>${APP_NAME}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名(Apple Silicon 必须签,否则会被系统直接杀掉)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> 组装分发包 dist/"
DIST="dist"
rm -rf "$DIST"; mkdir -p "$DIST"
cp -R "$APP" "$DIST/"
cp install.sh "$DIST/"
( cd "$DIST" && ditto -c -k --keepParent . "../${APP_NAME}-dist.zip" )

echo
echo "完成 ✅"
echo "  分发包: ${APP_NAME}-dist.zip(里面是 ${APP} + install.sh)"
echo "  发给对方,让对方解压后在终端里跑:  ./install.sh"
