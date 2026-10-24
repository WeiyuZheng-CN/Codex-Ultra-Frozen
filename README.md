# Codex Ultra Frozen

This repository maintains the launcher, verification tools, and local build
recipe for a frozen Windows Codex desktop copy based on build
`26.1016.8120.0`. The modified copy is the intended default runtime. Ordinary
launch must never silently switch to the Microsoft Store version.

The GitHub destination for this project is the private repository
`WeiyuZheng-CN/Codex-Ultra-Frozen`. This source tree contains no installed
Codex app, account credentials, conversation history, or other private profile
data.

## What is frozen

The reviewed app copy has two narrow changes:

1. The model-picker query can include the Ultra reasoning choice without its
   usual rollout-gate conjunction. Existing model capabilities, caller
   opt-outs, access checks, and effort filtering still apply.
2. The copy disables Codex's in-app update checks and automatic downloads.

The patch does not force the global `multiAgentMode` feature gate or change
its runtime and tool consumers. An Ultra choice in the picker is not proof of
provider support or a particular server-side reasoning implementation.

App files and their approved manifest are treated as immutable installation
assets. A local verification plan pins the expected runtime and the critical
configuration selected during deployment. Validation detects drift and
reports it; it does not silently rewrite the profile, repatch the app, adopt
new hashes, or select the Store app.

Profiles remain writable so Codex can save conversations, projects, skills,
and ordinary UI state. Freezing the app is separate from making the entire
profile read-only. See [the architecture](docs/ARCHITECTURE.md) for the trust
and update boundaries.

## Local installation and launch

An installation agent should first read `AGENTS.md` and
`docs/ARCHITECTURE.md` completely, inspect the existing local installation,
and preserve recoverable copies before replacing working launcher or
configuration files.

The main source components are:

| Path | Purpose |
|---|---|
| `scripts/Start-FrozenCodex.ps1` | Validate and launch the approved frozen copy. |
| `scripts/FrozenCodex.Helpers.ps1` | Shared validation and launch helpers. |
| `scripts/Start-FrozenCodex-WindowRestore.ps1` | Start the pinned launcher and restore the Electron window if activation leaves it hidden. |
| `tools/Protect-FrozenCodex.ps1` | Prepare the local deployment and its verification plan. |
| `tools/Restore-FrozenCodex.ps1` | Restore the saved installation permissions and previous launcher/shortcut. |
| `tools/Import-CodexSkills.ps1` | Add new user skill directories from selected source profiles. |
| `tools/Import-CodexHistory.py` | Run the separately prepared selective history-import plan while Codex is closed. |
| `tools/build_display_copy.py` | Version-specific recipe for the two reviewed app changes. |
| `tools/Build-FrozenCodexOfflineBundle.ps1` | Build a private offline ZIP from the verified frozen app without bundling machine profile state. |
| `tests/Test-FrozenCodex.ps1` | Local fixture checks for the frozen launcher contract. |
| `tests/Test-FrozenCodexRecovery.ps1` | Isolated checks of actual write protection, rollback, and deliberate redeployment. |
| `docs/MIGRATION.md` | History and skills migration boundaries and verification status. |

The source package does not contain Codex binaries. For personal offline transfer, `tools/Build-FrozenCodexOfflineBundle.ps1` can assemble the verified local app payload with launcher/deployment source into a private archive outside Git. It removes the machine-specific source path from the bundle manifest and excludes profiles, credentials, history, Electron data, freeze plans, and backups. See [the offline bundle guide](docs/OFFLINE-BUNDLE.md). The ZIP must never be committed to Git history; this task authorizes attaching this sanitized artifact only to a private personal-use release, not a public release or general redistribution.

Use Windows PowerShell 5.1 for the launcher and deployment tools. Deployment
creates or updates the graphical shortcut after validating its target. Finish
the current maintenance task, completely quit Codex, then use the installed
frozen shortcut. Maintenance must never terminate the Codex process hosting
the task.

`Protect-FrozenCodex.ps1` requires an existing reviewed installation containing
`app/` and `manifest.json`, plus existing private Codex and Electron data
directories. It does not download the app or invent another provider profile.
Preview with the same paths that will be used for deployment:

```powershell
& .\tools\Protect-FrozenCodex.ps1 `
  -InstallRoot "C:\LocalApps\CodexUltraFrozen" `
  -CodexHome "C:\Private\CodexUltra\codex-home" `
  -ElectronData "C:\Private\CodexUltra\electron-data" `
  -BackupRoot "C:\Private\CodexUltraBackups" `
  -ValidateOnly
```

Replace the example paths with inspected local paths. Keep both writable
profile directories and the backup root outside the protected installation.
Remove `-ValidateOnly` only for the authorized deployment. `-DesktopPath`
optionally selects the shortcut directory.

The deployed launcher reads `freeze-plan.json` beside itself. Use
`Start-FrozenCodex.ps1 -ValidateOnly` for a local check; `-PlanPath` accepts an
explicit private plan. Validation does not launch the app or run a pending
history import.

For rollback, close Codex normally and use the exact backup directory returned
by deployment:

```powershell
& .\tools\Restore-FrozenCodex.ps1 -BackupPath "C:\Private\CodexUltraBackups\freeze-<deployment-stamp>"
```

Rollback restores recorded permissions and the previous launcher/desktop
shortcut, and moves the active local plan into the recovery directory so it
cannot remain active accidentally. It does not remove imported conversations
or skills.

The isolated recovery fixture passes 32 checks under Windows PowerShell 5.1,
including deployment using a portable manifest, optional shortcut icon
installation, the window-restoring launcher target, actual write protection,
rollback, and deliberate redeployment using dummy app files. It did not activate
the real desktop app or send a provider request.

## Microsoft Store boundary

The Store Codex package stays installed because Windows package identity is
still needed for activation. This does not make the Store executable the
default runtime.

The modified `26.1016.8120.0` app was used successfully in the user's active
session while Store package `26.1016.8622.0` was installed. That is evidence
for this observed combination; future Windows or Store package compatibility
is not guaranteed.

Disabling the copy's in-app updater does not disable independent Microsoft
Store/MSIX updates. If package activation becomes incompatible or any pinned
asset changes, the frozen launcher must stop with an actionable diagnostic.
It must not hide the problem by opening another Codex version.

Freezing local files cannot freeze provider availability, account access,
remote feature decisions, or server behavior. It also cannot prevent an
administrator or an explicitly authorized maintenance action from replacing
files. The local design combines a preserved runtime with change detection
and an explicit maintenance boundary.

## History and skills

History and skills belong in the private profile, not in this repository.
The target profile must keep its current conversations and credentials.
Imports require source/target identification, recoverable backups, and
verification appropriate to the data being moved.

A separately prepared history plan can be pinned during deployment with
`-HistoryMigrationPlanPath`, `-HistoryMigrationReceiptPath`, and `-PythonPath`.
The first launch after Codex has fully closed runs that import once before
opening the frozen app. A completed private receipt prevents repeated import.
If Codex is already running, the launcher does not import into its live
profile.

The import is still pending execution and verification. Do not infer that
copying session files or replacing SQLite databases is a supported migration.
See [migration status and procedure](docs/MIGRATION.md).

The additive skill import has completed locally: 9 user skill directories
containing 172 files were copied, with no existing skills overwritten and no
change to bundled `.system` skills. In-app discovery remains a separate
restart/turn check.

## Source and privacy boundaries

The repository holds wrapper scripts, tests, documentation, and the narrow
existing patch recipe. It excludes app executables and archives, MSIX
packages, profile configuration, authentication files, session data,
databases, Electron data, logs, caches, credentials, and backups.

Review the exact staged files before any push. `.gitignore` reduces accidental
inclusion; it does not prove that a repository is free of private data.
Publication remains private unless the user explicitly requests a visibility
change. See [NOTICE.md](NOTICE.md) for ownership and licensing boundaries.
