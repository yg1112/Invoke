#!/bin/bash

set -e

# 🔥 品牌重塑：App Name 改为 Fetch
APP_NAME="Fetch"
APP_BUNDLE="$APP_NAME.app"

echo "🔨 Building $APP_NAME..."
echo "=============================="

# 1. Build the executable
echo ""
echo "📦 Step 1: Building executable..."
swift build -c release

# 注意：Swift Package 里的可执行文件名字可能还是 Invoke (取决于 Package.swift)，这里我们重命名
if [ -f .build/release/Invoke ]; then
    echo "✅ Found binary"
else
    echo "❌ Build failed - executable not found"
    exit 1
fi

# 2. Create .app bundle structure
echo ""
echo "📦 Step 2: Creating .app bundle structure..."
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

# Remove old bundle if exists
rm -rf "$APP_BUNDLE"

# Create directories
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"
mkdir -p "$FRAMEWORKS"

# 3. Copy executable & Rename to Fetch
echo "📦 Step 3: Copying executable..."
cp .build/release/Invoke "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# 4. Copy Info.plist
echo "📦 Step 4: Copying Info.plist..."
cp Info.plist "$CONTENTS/"

# 5. Copy icon if exists
if [ -f "AppIcon.icns" ]; then
    echo "📦 Step 5: Copying icon..."
    cp AppIcon.icns "$RESOURCES/"
fi

# 6. Copy Sparkle framework
echo "📦 Step 6: Copying Sparkle framework..."
if [ -d ".build/release/Sparkle.framework" ]; then
    cp -R .build/release/Sparkle.framework "$FRAMEWORKS/"
    echo "✓ Sparkle framework copied"
else
    echo "⚠️  Warning: Sparkle.framework not found in .build/release/"
    if [ -d ".build/debug/Sparkle.framework" ]; then
        cp -R .build/debug/Sparkle.framework "$FRAMEWORKS/"
        echo "✓ Sparkle framework copied from debug build"
    fi
fi

# 6.5. Fix rpath
echo "📦 Step 6.5: Fixing runtime search paths..."
if [ -f "$MACOS/$APP_NAME" ]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$APP_NAME" 2>/dev/null || true
fi

# 7. Sign the app
echo ""
echo "🔐 Step 7: Signing application..."
if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
    codesign --force --deep --sign - "$FRAMEWORKS/Sparkle.framework"
fi
codesign --force --deep --sign - --entitlements Entitlements.plist "$APP_BUNDLE"

echo ""
echo "🎉 Build complete!"
echo "📍 Location: $(pwd)/$APP_BUNDLE"
echo ""
echo "🚀 To run the app:"
echo "   open $APP_BUNDLE"