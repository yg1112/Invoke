# Invoke

A macOS utility for real-time Git synchronization with AI pair programming support.

## Features

- 🔄 Real-time Git change tracking and auto-commit
- 🤖 Gemini AI integration for pair programming
- 📁 Project folder selection with full system permissions
- ⚡️ Floating panel UI for quick access
- 🔐 Proper entitlements and code signing

## Building

**Important**: Use the provided build script to create a proper .app bundle with all permissions:

```bash
./build_app.sh
```

This will:
- Build the release version
- Create a complete .app bundle structure
- Copy Info.plist and Entitlements
- Sign the application with proper permissions
- Configure runtime paths for frameworks

**Do NOT use `swift build` or `swift run`** - they don't include the necessary permissions and will fail when accessing system features like file pickers.

## Running

### Quick Test (Recommended)
```bash
./quick_test.sh
```

### Manual Launch
```bash
# Open normally
open Invoke.app

# Or run with debug logging
./Invoke.app/Contents/MacOS/Invoke 2>&1 | tee invoke_debug.log
```

### Verify Build
```bash
./verify_fix.sh
```

## Development Workflow

1. Make code changes in `Sources/Invoke/`
2. Build: `./build_app.sh`
3. Test: `open Invoke.app` or `./quick_test.sh`
4. Check logs if needed: `cat invoke_debug.log`

## Architecture

See `docs/STRUCTURE.md` for detailed architecture documentation.

### Key Components

- **GeminiLinkLogic** - Core Git synchronization and AI protocol logic
- **ContentView** - Main floating panel UI
- **PermissionsManager** - System permission handling
- **GitService** - Git operations wrapper

## Requirements

- macOS 14.0+
- Swift 5.9+
- Xcode Command Line Tools

## Troubleshooting

### File Picker Issues
If you see grayed-out folders or crashes when selecting files:
- ✅ Use `./build_app.sh` to create a proper .app bundle
- ❌ Don't use `swift run` - it lacks necessary permissions

### Framework Not Found
If you see "Library not loaded: Sparkle.framework":
- Run `./build_app.sh` again - it fixes the rpath automatically

### Permission Denied
- Check System Settings > Privacy & Security
- Grant "Full Disk Access" if needed for certain folders
