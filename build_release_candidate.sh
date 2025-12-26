#!/bin/bash

set -e

# Release Candidate Build Script
# Creates a production-ready build with version tagging

APP_NAME="Fetch"
APP_BUNDLE="$APP_NAME.app"
VERSION=$(date +"%Y.%m.%d")
BUILD_DIR="release_candidates"
RC_NAME="${APP_NAME}_RC_${VERSION}"

echo "🚀 Building Release Candidate: $RC_NAME"
echo "=========================================="

# Create release candidates directory
mkdir -p "$BUILD_DIR"

# Run standard build
echo ""
echo "📦 Step 1: Running standard build..."
./build_app.sh

# Verify build succeeded
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Build failed - $APP_BUNDLE not found"
    exit 1
fi

# Create release candidate package
echo ""
echo "📦 Step 2: Creating release candidate package..."
RC_DIR="$BUILD_DIR/$RC_NAME"
rm -rf "$RC_DIR"
mkdir -p "$RC_DIR"

# Copy app bundle
cp -R "$APP_BUNDLE" "$RC_DIR/"

# Create release notes
cat > "$RC_DIR/RELEASE_NOTES.md" << EOF
# Fetch Release Candidate $VERSION

## Build Date
$(date)

## Changes
- Fixed Swift 6 concurrency warnings (@MainActor on GeminiWebManager)
- Removed unused variable warnings
- Production-ready build with Protocol v3 support
- Aider integration documentation

## Protocol v3
This release includes full support for Protocol v3 file editing:
- Format: \`>>> INVOKE\` followed by \`!!!FILE_START!!!\` blocks
- Direct clipboard-based file editing
- Complete file content required

## Aider Integration
Use Fetch as a proxy for Aider:
\`\`\`bash
export OPENAI_API_BASE=http://127.0.0.1:3000/v1
export OPENAI_API_KEY=any-key
aider --model openai/gemini-2.0-flash
\`\`\`

## Installation
1. Copy \`$APP_BUNDLE\` to your Applications folder
2. Grant necessary permissions when prompted
3. Launch and follow onboarding

## Testing
Run verification script:
\`\`\`bash
./verify_system_integrity.sh
\`\`\`
EOF

# Create checksum
echo ""
echo "📦 Step 3: Generating checksums..."
cd "$RC_DIR"
shasum -a 256 "$APP_BUNDLE/Contents/MacOS/$APP_NAME" > "checksum.txt"
cd - > /dev/null

# Create archive (optional)
echo ""
echo "📦 Step 4: Creating archive..."
cd "$BUILD_DIR"
zip -r "${RC_NAME}.zip" "$RC_NAME" > /dev/null
cd - > /dev/null

echo ""
echo "✅ Release Candidate created successfully!"
echo "📍 Location: $(pwd)/$RC_DIR"
echo "📦 Archive: $(pwd)/$BUILD_DIR/${RC_NAME}.zip"
echo ""
echo "📋 Contents:"
echo "   - $APP_BUNDLE"
echo "   - RELEASE_NOTES.md"
echo "   - checksum.txt"
echo ""
echo "🚀 Next steps:"
echo "   1. Test the build: open $RC_DIR/$APP_BUNDLE"
echo "   2. Review RELEASE_NOTES.md"
echo "   3. Distribute ${RC_NAME}.zip if ready"

