# Conversation history and skills migration

## Current status

The frozen runtime retains the existing target profile and its current
conversations. A selective import from the normal-version profiles is being
prepared as a one-time operation on the first frozen launch after Codex has
fully closed. The import has not yet been executed or verified.

The additive skill import has completed: 9 user skill directories containing
172 files were copied, no existing skills were overwritten, and bundled
`.system` skills were unchanged. This is filesystem verification; discovery
inside the app remains to be checked.

Record actual import results only after the chosen workflow has been
implemented and checked. Do not interpret a successful file copy as proof
that the app can list, open, and continue imported conversations.

The source entry point is `tools/Import-CodexHistory.py`; the installed
launcher invokes the pinned copy with `--plan` and the private plan path.
Deployment wires it using `-HistoryMigrationPlanPath`,
`-HistoryMigrationReceiptPath`, and `-PythonPath`. These files and the
eventual receipt remain outside the repository.

`Start-FrozenCodex.ps1 -ValidateOnly` checks local prerequisites without
running the import. An ordinary launch while the frozen app is still running
only attempts to focus its existing window. The pending import runs only
before a fresh launch, after all Codex desktop processes have closed.
Startup stops if it fails; a completed receipt prevents it from running again.

## Prepared history procedure

This is a custom additive migration of local app state, rather than a
vendor-supported import API. It was prepared for the observed source and
target database schemas and must be reviewed again for a different build or
schema.

The read-only schema and planning check observed:

| Planning item | Observed result |
|---|---|
| Existing target conversations | 9 at planning time |
| Candidate conversations from normal ChatGPT profile | 192 |
| Candidate conversations from normal Transfer profile | 613 |
| Total candidate conversations | 805 |
| Archived candidates | 409 |
| Duplicate candidate identities | 0 |
| Orphan projected-history identities omitted | 120 |

An orphan projected-history identity has no corresponding thread in the
source state database. The prepared procedure omits those records instead
of creating incomplete conversations. These counts describe the planning
snapshot, not a completed import or the eventual sidebar count.

On the first fresh frozen launch, the prepared workflow takes consistent
backups of the target SQLite state and stages the additive changes. It
preserves current target records, copies session payloads as opaque bytes
including compressed variants, and preserves the logical session paths
expected by the database. It does not parse conversation text to rewrite its
contents or replace the target profile wholesale.

The private completion receipt must report `COMPLETED` before the launcher
continues. Partial-import recovery and rollback remain under review until the
fixture checks and actual offline execution establish their results. After
the import, opening the frozen app is still required to verify conversation
visibility and usability. No completed-history claim is made here.

## Identify the data before copying

The app executable, Codex home, and Electron data directory are separate
choices. First identify:

- the actual source profile used by the normal version;
- the actual target profile used by the frozen launcher;
- the app versions that last opened those profiles;
- the selected source skill folders;
- the private backup and migration-report destinations.

An official ChatGPT profile and a provider-specific profile can contain
different histories. Do not infer the source from the app's display name or
shortcut alone. Do not move credentials between providers while importing
history.

If the user intends to keep using an existing profile, verify whether it can
be reused safely before creating another copy. Reuse still requires version
compatibility checks when a newer app has migrated its data.

## Required boundaries for history import

1. Preserve the target's current conversations, active task, credentials,
   configuration, and installed skills.
2. Prepare the work while Codex is open, but perform database changes only
   after all processes using the source and target profiles have closed.
   Never terminate the process hosting the maintenance task.
3. Preserve recoverable, consistent backups before any database or index
   mutation. Keep them outside this repository.
4. Inspect the relevant schemas and relationships using read-only access.
   A newer profile may contain data an older frozen build cannot interpret.
5. Use a selective, collision-aware import. Do not replace the target's
   databases wholesale or overwrite a conversation with the same identity.
6. Keep original rollout/session records recoverable and preserve archive
   state where the verified import format supports it.
7. Check database integrity, imported-record counts, duplicate handling,
   and target-data preservation before opening the frozen app.
8. Verify imported conversation visibility and opening after restart.
   Record continuation behavior separately if a real provider request is
   authorized.

Copying `sessions/` alone may omit the metadata needed for the sidebar.
Replacing a state database alone may lose target records or point to missing
rollout files. Copying a SQLite file while its WAL is active can produce an
inconsistent snapshot. The eventual workflow must address these relationships
explicitly.

Authentication files, logs, caches, browser sessions, and unrelated Electron
state are not conversation-history import inputs. Keep them out of the
migration unless an inspected, authorized requirement establishes otherwise.

## Selected skill import

User skills can be copied independently of conversation databases. The
additive tool scans `skills/` under each selected source home, copies eligible
new directories, and skips existing target names. Preview its candidate list:

```powershell
& .\tools\Import-CodexSkills.ps1 `
  -SourceHomes "C:\Private\NormalCodexHome","C:\Private\NormalTransferHome" `
  -TargetHome "C:\Private\CodexUltra\codex-home" `
  -BackupRoot "C:\Private\CodexUltraBackups" `
  -ValidateOnly
```

Replace the example paths with the inspected profile roots. Remove
`-ValidateOnly` to perform the authorized additive import. The tool's
`-BackupRoot` stores the private import receipt; source skills remain intact.
It does not copy profile databases and may add complete new skill directories
while Codex is running.

The intended import behavior is:

- import eligible new user skill directories from selected source homes;
- keep the target's `.system` directory and bundled skills;
- skip generated marketplace and plugin caches;
- skip existing names and duplicate names from later source homes;
- preserve relative files, assets, scripts, and attribution required by each
  selected skill;
- verify that imported `SKILL.md` files and referenced local resources are
  present;
- stage and verify each new directory before publishing it in the target
  skills folder;
- report imported names, counts, and the private receipt without logging
  secrets.

Skill folders can contain local paths, reference documents, private assets,
or external-tool configuration. Keep imported skills local. Permission to
copy them for this profile does not authorize publishing them in the source
repository.

The target app may discover skills on a future turn or after restart. Report
filesystem import and in-app discovery as separate results.

## Rollback

Before changing state, record the exact private backup location and what it
contains. A rollback must use a consistent set of files with Codex closed.
Preserve the newly created target conversations separately before restoring
an older backup.

Do not delete source history after import. Keep the source and migration
backups until the user has accepted the result and explicitly authorizes any
cleanup.

## Verification record

The following fields must be completed from observed results. Keep the full
record private because it may expose profile paths and conversation metadata.
A sanitized source change may record only the procedure and aggregate
results.

| Item | Status |
|---|---|
| Source and target profiles identified | Recorded in the private plan; counts above are its planning snapshot |
| Consistent source and target backups | Pending |
| Schema/version compatibility reviewed | Read-only planning check passed for the observed profiles |
| Selective history import completed | Pending first fresh frozen launch after closing Codex |
| Target conversations preserved | Pending |
| Duplicate and archive behavior checked | Pending |
| Database and file consistency checks | Pending |
| Imported conversations visible/openable in frozen app | Pending restart verification |
| Selected skill import and collisions reviewed | Completed: 9 skills, 172 files, no existing skills overwritten, `.system` unchanged |
| Imported skills discovered by app | Pending in-app verification |
| Provider request for an imported conversation | Not required for local import; only if separately authorized |
