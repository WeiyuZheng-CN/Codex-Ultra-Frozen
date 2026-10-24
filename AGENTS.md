# Instructions for maintaining Codex Ultra Frozen

Read `README.md`, `docs/ARCHITECTURE.md`, and `docs/MIGRATION.md` completely
before changing the installation or this source project.

## Intended behavior

- Use the reviewed modified Codex desktop build `26.1016.8120.0` as the
  default. The user's explicit frozen-runtime requirement takes precedence
  over advice from an older launcher project to prefer the current Store app.
- Preserve the two reviewed changes: Ultra inclusion in the picker query and
  disabled in-app update checks/downloads.
- Preserve the global `multiAgentMode` gate and its runtime/tool consumers.
  Do not force it, fabricate model capabilities, or claim that Ultra display
  proves server-side behavior.
- Never silently fall back to the Store executable. Missing or changed
  runtime assets, an incompatible package identity, or critical config drift
  must stop launch with a clear diagnostic.
- Keep the Microsoft Store package installed for Windows package identity.
  Its update lifecycle is separate from the frozen app copy.

## Inspect, back up, then adapt

Ordinary reversible work within the user's requested scope may proceed
without repeated permission questions. Inspect actual paths and behavior
first. Preserve recoverable copies before replacing working user files and
record local changes, checks, and rollback paths in a private
`LOCAL-CHANGES.md`.

Never stop the Codex process hosting the maintenance task. Prepare work while
it is open; perform operations that require exclusive profile access after
the user has closed Codex.

Treat installed app files and their approved manifest as immutable assets.
Treat the machine-private `freeze-plan.json` as the approved local baseline,
not a cache to regenerate whenever validation fails. Validation must not
silently restore or rewrite configuration, refresh models, repatch app files,
replace hashes, or redirect launch to another runtime.

Configuration maintenance is an explicit operation: inspect the difference,
explain its effect, preserve a backup, make the authorized change, verify it,
and deliberately update the approved baseline where required. Keep history,
skills, projects, and ordinary application state writable.

## Data migration

- Identify the source and target profiles independently of the app executable.
  Changing runtime does not by itself move history.
- Preserve the target's existing conversations, credentials, and configuration.
- Follow the prepared procedure and its current verification status in
  `docs/MIGRATION.md`. A pinned pending import runs once on the first frozen
  launch with Codex fully closed. A validation result does not mean it ran.
  Do not claim success or replace active SQLite files.
- Perform database changes only with exclusive access and a recoverable
  backup. An older app opening data from a newer version requires explicit
  compatibility verification.
- Import new user skill directories from the selected source profiles.
  Preserve the target's bundled `.system` skills. The additive import tool
  skips existing names and never replaces those directories.
- Keep all imported data and migration reports outside the Git repository.

## Source and GitHub boundary

The target repository is `WeiyuZheng-CN/Codex-Ultra-Frozen`, with private
visibility. Keep its history separate from the broader provider-launcher
repository and review the complete staged file list before each push.

The GitHub repository remains source-only in Git history. The owner has explicitly authorized one private GitHub Release asset containing the sanitized offline bundle built for personal transfer to the owner's own computer. Keep that ZIP outside the repository and never add it to a Git commit. This authorization is limited to that artifact and does not establish rights for public or broader redistribution.

Never commit to Git or include in the personal bundle:

- Codex app-package installers, signing material, or any machine-specific freeze plan;
- `auth.json`, generated profile configs, private keys, credentials, tokens,
  or encrypted credential stores;
- sessions, conversation exports, databases and sidecars, Electron data,
  logs, caches, backups, recovery snapshots, or machine-private
  `freeze-plan.json`;
- local manifests, migration reports, or notes containing private profile
  details or user-specific filesystem paths.

The offline bundle may contain only the reviewed modified app tree, its sanitized portable manifest, launcher/deployment source and documentation, tests, and the optional user-supplied shortcut icon. Verify the full archive inventory before attaching it to the private release. Never change repository visibility or make the release public.

Do not read or print credential contents. Copy secret files opaquely only
when that is explicitly necessary and authorized for a local operation. Do
not collect credentials for unused provider modes.

This repository does not establish a project-wide license for code whose
rights have not been determined. Preserve existing attribution and the
ownership boundaries in `NOTICE.md`. Do not add an open-source license by
assumption, expand the existing patch anchors into copied bundle source, or
publicly/broadly redistribute the desktop app. The single private personal-use
release authorized for this task does not grant other distribution rights.

Ask before destructive cleanup, an unrequested account change, a download
from an unverified source, or publication beyond the user's authorization.
Do not change repository visibility without explicit authorization.

## Validation and reporting

Use Windows PowerShell 5.1 for the PowerShell tools. After a relevant change,
parse the edited scripts and run focused fixture checks. Verify deployed
paths and hash checks without launching a second Codex process.

Deployment uses `tools/Protect-FrozenCodex.ps1` with `-InstallRoot`,
`-CodexHome`, `-ElectronData`, and `-BackupRoot`. Keep writable data and ACL
backups outside the protected installation. Save the returned backup path.
Rollback uses `tools/Restore-FrozenCodex.ps1 -BackupPath` while Codex is
closed; it must not delete imported user data.

Report separately:

- source/fixture validation;
- deployed runtime and configuration verification;
- actual graphical startup and observed UI behavior;
- a real provider request, only when explicitly authorized.

Local validation does not prove provider acceptance or future package
compatibility. Do not make a network request merely to open the app or verify
the local installation.
