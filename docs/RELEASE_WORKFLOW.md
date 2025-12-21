# Release Workflow

> **🤖 AI Instruction:**
> To release a new version of Invoke, DO NOT run build commands manually.
> ALWAYS use the master script: `scripts/deploy.sh`

## How to Release
1. Run: `./scripts/deploy.sh [VersionNumber]` (e.g., `./scripts/deploy.sh 1.0.1`)
2. This will:
   - Update `Info.plist` version.
   - Run `scripts/full_release.sh` to build and sign.
   - Commit and Tag in Git.
   - Upload `Invoke.dmg` to GitHub Releases.
