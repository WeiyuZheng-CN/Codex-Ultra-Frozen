# Private offline bundle

`tools/Build-FrozenCodexOfflineBundle.ps1` creates a local ZIP containing the reviewed modified app payload and the launcher/deployment source. It reads only `app/` and `manifest.json` from the current frozen install. The source manifest is sanitized so the archive does not disclose the original WindowsApps path.

The builder refuses unreviewed app hashes, non-reviewed patch metadata, output inside the repository/install, and an existing output archive. It writes an inventory with SHA-256 hashes, rechecks the copied app, validates ZIP paths and contents, and removes only its own uniquely named temporary staging directory after verification.

Build a personal-use archive outside the Git checkout and frozen install:

```powershell
& .\tools\Build-FrozenCodexOfflineBundle.ps1 `
  -InstallRoot "C:\LocalApps\Codex-Ultra-Transfer-Test-26.1016.8120.0" `
  -OutputArchive "D:\Offline\Codex-Ultra-Frozen-26.1016.8120.0.zip" `
  -ShortcutIconPath "D:\Offline\shortcut-icon.ico"
```

The example paths are inputs only. Keep the resulting ZIP outside Git. It contains the app payload but no machine-specific `freeze-plan.json`, profiles, authentication, conversations, databases, Electron data, logs, backups, or local change notes. The optional icon is copied as `assets/shortcut-icon.ico`.

## Destination setup

The destination's local agent must select fresh paths and prepare the destination Codex profile and Electron-data directories. The app and sanitized `manifest.json` should be placed under a new installation root. Run `tools/Protect-FrozenCodex.ps1` from the extracted bundle with the destination's `InstallRoot`, `CodexHome`, `ElectronData`, and external `BackupRoot`. Pass `-ShortcutIconPath` with the extracted `assets/shortcut-icon.ico` when present. Do not copy a freeze plan, profile, credentials, history, or backups from the source computer.

Windows package activation still requires package family `OpenAI.Codex_2p2nqsd0c76g0`. The ZIP does not contain a Store/MSIX/AppX package or its signing material. The destination agent must verify that package identity is installed and compatible; do not bypass Windows package or signature security. This local app copy is modified and its vendor signature does not validate.

The installed UI and files are local, but account sign-in and Pixel Transfer provider requests need network access. The bundle does not provide local model inference. Personal use on another device remains subject to the relevant software terms. This task authorizes attaching this sanitized artifact to the private GitHub Release for the owner's own transfer; do not commit it to Git history, publish it publicly, or treat this as general redistribution permission.

## Bundle contents

- `app/`: the 3,627-file modified Codex build.
- `manifest.json`: machine-neutral reviewed build/patch metadata.
- `bundle-manifest.json`: app inventory and bundle file hashes.
- `scripts/`, `tools/`, `tests/`, and `docs/`: launcher, deployment, and verification source.
- `OFFLINE-SETUP.md`: package-specific limitations and destination notes.
- `assets/shortcut-icon.ico`: optional custom shortcut icon.
