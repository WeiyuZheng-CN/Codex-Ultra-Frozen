# Frozen desktop runtime architecture

## Purpose

Codex Ultra Frozen keeps an approved local Windows desktop runtime stable
while retaining a writable private Codex profile. The default runtime is the
modified Codex build `26.1016.8120.0`. Selection is explicit and verified;
launch failure must not silently select the installed Store executable.

The repository contains the local integration and verification source. The
installed desktop app and all private profile data live outside the source
tree.

## Components and data flow

```text
Graphical shortcut
  -> Start-FrozenCodex-WindowRestore.ps1
     -> Start-FrozenCodex.ps1
        -> FrozenCodex.Helpers.ps1
        -> machine-private freeze-plan.json
     -> pinned app and critical-config validation
     -> pending history import, once and only while Codex is closed
     -> Windows package activation
        -> approved copied ChatGPT.exe
           -> private CODEX_HOME
           -> private Electron data directory
           -> configured provider
```

The local plan identifies approved physical paths and verification
expectations. It is created during reviewed deployment and kept beside the
deployed launcher. It is excluded from the repository because it describes a
particular installation.

The profile and Electron directories are separate from the immutable app
assets. They remain writable for conversation history, project state,
skills, and ordinary application preferences. Neither Git nor the source
directory acts as a profile backup.

## Reviewed app modifications

The version-specific recipe makes two changes in an independent copy of the
inspected app:

| Change | Scope |
|---|---|
| Ultra inclusion | The picker query can request Ultra without its rollout-gate conjunction. Existing capabilities, explicit opt-outs, access checks, hidden-model policy, effort filtering, and Copilot policy remain in effect. |
| In-app updater disabled | The copied app's in-app update checks and automatic downloads are disabled. |

The global `multiAgentMode` gate and its runtime/tool consumers remain
unchanged. The recipe does not synthesize support for an effort a model does
not advertise. A working multi-agent session is observed behavior; it does
not establish that the picker patch enabled that behavior.

The copied executable and app archive differ from the vendor distribution,
so their original vendor signature no longer validates. The approved local
manifest and hashes identify the reviewed copy; they do not turn it into an
official vendor release. Windows security must not be bypassed to run it.

## Freeze contract

The installation has two classes of state.

| State | Expected treatment |
|---|---|
| Reviewed app files and manifest | Preserved as immutable installation assets and verified against the approved baseline. |
| Critical configuration | Checked for drift against the approved local plan; changed values cause an actionable stop. |
| Conversation, project, skill, and ordinary UI state | Writable in the private profile, subject to normal backup and migration rules. |
| Git source | Reviewable maintenance code, tests, templates, and documentation only. |

Validation is observational. It must not automatically restore a profile,
refresh the model catalog, adopt new hashes, repatch a newer app, or change
the selected runtime. It must report enough information to locate a
difference without disclosing credentials.

The current configuration guard records the provider name, its endpoint,
wire API and auth-mode flag, desktop effort choices and Ultra preference,
and the existing feature settings. The selected model catalog and its path
are also pinned. Ordinary model selection and unrelated UI state are not a
reason to replace the profile. The source helper takes
`Get-FrozenCodexConfigBaseline -ConfigPath` when deliberately preparing the
baseline.

An intentional change to a pinned asset or critical setting requires a
maintenance operation: inspect the difference, preserve a recoverable copy,
make the authorized change, verify it, and deliberately approve the new
baseline. A file changing while the app is open is not authorization to
accept that change.

This contract protects the approved local behavior through preservation and
change detection. It does not claim that an administrator cannot alter files
or that a remote provider cannot change its behavior.

## Package identity and updates

The app copy still uses Windows package activation. The Microsoft Store
Codex package remains installed to supply package identity, while activation
starts the approved copied executable with the selected private paths.

The modified `26.1016.8120.0` runtime was successfully used in the user's
active session with Store package `26.1016.8622.0`. This is an observed
compatible combination. Future package versions, Windows changes, and
activation contracts require fresh verification.

Store/MSIX updates are independent of the app copy's disabled in-app
updater. They do not authorize replacing the copied runtime. If the package
identity or activation contract no longer works, stop and report the
incompatibility. Never launch the Store executable as an automatic fallback.

The user may explicitly choose another runtime or authorize a reviewed
upgrade later. Such a choice belongs in a separate maintenance action,
with a preserved rollback path.

## Multi-agent and provider boundary

Pinning the app preserves its local implementation and checking critical
configuration detects unintended local changes. The patch leaves the
global feature gate intact, so remote feature decisions and provider
support remain external dependencies.

An available picker choice, local validation, and a completed provider
request are different evidence:

- Local validation establishes that the selected installation matches its
  approved local expectations.
- Graphical startup establishes that Windows activation and the copied app
  work in the tested environment.
- Visible Ultra and available multi-agent tools establish observed client
  behavior for that session.
- A real provider request establishes the tested endpoint's response at that
  time.

None guarantees future server behavior. Startup and validation must not send
an unnecessary provider request.

## History and skills

Profiles own history and skills. An app-copy change does not require a
different profile, and reusing a profile is distinct from importing data
between profiles. Existing private target data must be preserved.

SQLite state and session files can have version-dependent relationships.
A separately prepared, pinned selective-import plan is pending execution.
When present, the launcher invokes it only after confirming there are no
Codex desktop processes and before dispatching the frozen app. A completion
receipt prevents repetition. Existing-app focus and `-ValidateOnly` do not run
the import. A failed import stops startup. Follow `MIGRATION.md` and its
recorded verification status; do not replace live databases with a raw copy.

Skill imports should copy deliberately selected user-authored directories
without replacing the target's bundled `.system` skills or blindly copying
plugin caches. The additive importer stages and verifies each new directory
before publishing it in the target's skills folder, skips existing names,
and does not touch databases. Import results stay local.

## Deployment and rollback

`tools/Protect-FrozenCodex.ps1` accepts existing `-InstallRoot`, `-CodexHome`,
`-ElectronData`, and an external `-BackupRoot`. It saves ACL recovery data
before applying the user's deny-write/delete permissions to the installation,
deploys static launcher files, creates the private plan, and updates the
desktop shortcut. Profiles remain outside the protected installation.
`-ValidateOnly` previews the deployment inputs without changing files.

Optional `-HistoryMigrationPlanPath`, `-HistoryMigrationReceiptPath`, and
`-PythonPath` pin the pending importer and its private inputs. The local plan
also pins the launch wrapper so ordinary startup never recreates it.

`tools/Restore-FrozenCodex.ps1 -BackupPath` uses the exact recovery directory
returned by deployment. Run it after closing Codex. It restores recorded
permissions and the previous launcher/README/desktop shortcut, and moves the
active plan into the recovery directory. It keeps user history and imported
skills. Any intentional re-deployment must review the restored state and
deliberately approve a new local plan.

## Source and deployment layout

```text
Repository
  scripts/       launcher and shared helpers
  tools/         deployment, selected skill import, local build recipe
  tests/         focused local fixture checks
  docs/          architecture and migration instructions
  README.md
  AGENTS.md
  NOTICE.md

Private local deployment, outside Git
  deployed launcher and helpers
  freeze-plan.json
  reviewed copied app and approved manifest
  private CODEX_HOME
  private Electron data directory
  local backups and migration reports
```

The exact private physical paths are deployment inputs, not hard-coded
source defaults to publish. Repository checks must reject app binaries,
credentials, private state, or oversized runtime assets before pushing to the
private GitHub destination.
