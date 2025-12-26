# Invoke

A macOS utility for real-time Git synchronization with AI pair programming support.

## ✨ New: Three-Mode System

Invoke now offers **three Git workflows** to match your needs:

- 🔒 **Local Only**: Commit locally without pushing (perfect for privacy/experiments)
- 🔀 **Safe**: Create PR branches for team review
- ⚡ **YOLO**: Direct push to main (fast prototyping)

See [Three-Mode System Guide](docs/THREE_MODE_SYSTEM.md) | [中文指南](docs/THREE_MODE_SYSTEM_CN.md)

## Features

- 🔄 Real-time Git change tracking and auto-commit
- 🤖 Gemini AI integration for pair programming
- 🎯 Three flexible Git modes (Local Only / Safe / YOLO)
- 🎬 Animated onboarding with workflow demo
- 📁 Project folder selection with full system permissions
- 🔗 Clickable commit links to GitHub
- ⚡️ Floating panel UI for quick access
- 🔐 Proper entitlements and code signing
- 📋 **Protocol v3** - Direct file editing via clipboard
- 🔌 **Aider Integration** - Use Fetch as a proxy for Aider

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

## Protocol v3 - Direct File Editing

Fetch supports **Protocol v3** for direct file editing through the clipboard. This allows AI assistants to modify your codebase by copying formatted instructions to the clipboard.

### Format

The protocol uses special markers to indicate file changes:

```
>>> INVOKE
!!!FILE_START!!!
path/to/file.ext
[Full file content here]
!!!FILE_END!!!
```

### How It Works

1. **AI generates code** in the Protocol v3 format
2. **Copy to clipboard** - The formatted text is copied
3. **Fetch detects** the `>>> INVOKE` trigger
4. **Files are written** automatically to your project

### Example

```
>>> INVOKE
!!!FILE_START!!!
Sources/Example.swift
import Foundation

class Example {
    func hello() {
        print("Hello, World!")
    }
}
!!!FILE_END!!!
```

### Usage Tips

- Ensure Fetch is running and has access to your project folder
- The protocol requires **complete file content** - partial updates are not supported
- Markdown code blocks (```) should be **outside** the `!!!FILE_START!!!` tags
- Each file must be complete and valid

## Aider Integration

Fetch can act as a proxy between Aider and Gemini, allowing you to use Gemini's web interface with Aider's code editing capabilities.

### Setup

1. **Start Fetch** and ensure you're logged into Gemini
2. **Configure Aider** to use Fetch's local API server:

```bash
export OPENAI_API_BASE=http://127.0.0.1:3000/v1
export OPENAI_API_KEY=any-key
aider --model openai/gemini-2.0-flash
```

3. **Use Aider normally** - Fetch will proxy requests to Gemini

### How It Works

- Fetch runs a local API server on port 3000
- Aider connects to this server instead of OpenAI
- Fetch translates Aider's requests to Gemini's web interface
- Responses are returned in OpenAI-compatible format

### Benefits

- ✅ Use Gemini's free web interface with Aider
- ✅ No API keys required
- ✅ Full code editing capabilities
- ✅ Real-time synchronization with Git
