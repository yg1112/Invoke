#!/bin/bash
# scripts/full_release.sh
# 核心构建脚本 - 被 deploy.sh 调用

set -e
APP_NAME="Invoke"
SCHEME="Invoke"
BUILD_DIR=".build/release"
OUTPUT_DMG="Invoke.dmg"
IDENTITY_NAME="Developer ID Application: DZG Studio LLC (DRV5ZMT5U8)" # 请确认这是你的证书名

echo "🚀 Building $APP_NAME..."

# 1. Clean & Build
swift build -c release --arch arm64 --arch x86_64

# 2. Create Bundle Structure
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# 3. Copy Binary & Assets
cp "$BUILD_DIR/$APP_NAME" "$APP_NAME.app/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_NAME.app/Contents/Info.plist"
# 如果有图标，复制图标 (假设你稍后会生成 AppIcon.icns)
# cp "Resources/AppIcon.icns" "$APP_NAME.app/Contents/Resources/AppIcon.icns" || true

# 4. Sign (Ad-hoc signature for local testing, or proper ID for release)
echo "🔐 Signing..."
codesign --force --deep --sign - "$APP_NAME.app"

# 5. Create DMG (Simple version)
echo "📦 Packaging DMG..."
if command -v create-dmg &> /dev/null; then
    create-dmg \
      --volname "$APP_NAME" \
      --window-pos 200 120 \
      --window-size 800 400 \
      "$OUTPUT_DMG" \
      "$APP_NAME.app"
else
    # Fallback to hdiutil if create-dmg is missing
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_NAME.app" -ov -format UDZO "$OUTPUT_DMG"
fi

echo "✅ Done! $OUTPUT_DMG is ready."
