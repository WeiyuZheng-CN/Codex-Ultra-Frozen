"""Add private Codex history to an existing profile, with Codex fully closed.

Only a private JSON plan supplies machine paths. Dialogue fields remain opaque
inside SQLite and copied rollout files; console output contains aggregate counts.
This is an inspected local migration procedure, not a vendor import API.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import uuid


DATABASES = ("state_5.sqlite", "thread_history_1.sqlite")
HISTORY_TABLES = (
    "thread_history_projection_state", "thread_items",
    "thread_realtime_items", "thread_turns",
)
STATE_CHILDREN = (
    "thread_read_receipts", "thread_attachments",
    "thread_dynamic_tools", "guardian_review_feedback",
)
PENDING_PHASES = {"COMMITTING", "ROLLING_BACK"}


class ImportFailure(RuntimeError):
    pass


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def contained(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def no_links(path: Path, root: Path) -> None:
    current = path
    while contained(current, root):
        if current.exists():
            stat = current.lstat()
            if current.is_symlink() or getattr(stat, "st_file_attributes", 0) & 0x400:
                raise ImportFailure("A migration path is a filesystem link.")
        if current == root:
            return
        current = current.parent
    raise ImportFailure("A migration path escaped its approved root.")


def read_plan(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    required = {"schemaVersion", "sourceHomes", "targetHome", "backupRoot", "receiptPath"}
    if not isinstance(value, dict) or set(value) != required or value["schemaVersion"] != 1:
        raise ImportFailure("The private history plan has an unsupported shape.")
    if not isinstance(value["sourceHomes"], list) or not value["sourceHomes"]:
        raise ImportFailure("The history plan needs at least one source home.")
    for name in ("targetHome", "backupRoot", "receiptPath"):
        if not isinstance(value[name], str) or not Path(value[name]).is_absolute():
            raise ImportFailure("History-plan paths must be absolute.")
    if any(not isinstance(p, str) or not Path(p).is_absolute() for p in value["sourceHomes"]):
        raise ImportFailure("Source-home paths must be absolute.")
    for raw in value["sourceHomes"] + [value["targetHome"], value["backupRoot"], value["receiptPath"]]:
        original = Path(raw)
        no_links(original, Path(original.anchor))
    target = Path(value["targetHome"]).resolve()
    sources = [Path(p).resolve() for p in value["sourceHomes"]]
    backup = Path(value["backupRoot"]).resolve()
    receipt = Path(value["receiptPath"]).resolve()
    if len(set(sources)) != len(sources):
        raise ImportFailure("The history plan repeats a source home.")
    homes = [target] + sources
    for index, home in enumerate(homes):
        if not home.is_dir():
            raise ImportFailure("A history profile does not exist.")
        no_links(home, home)
        for other in homes[index + 1:]:
            if contained(home, other) or contained(other, home):
                raise ImportFailure("Source and target profiles must be independent.")
        if contained(backup, home) or contained(receipt, home):
            raise ImportFailure("Backups and receipts must be outside every profile.")
    if contained(target, backup) or any(contained(p, backup) for p in sources):
        raise ImportFailure("The backup root must not contain a source or target profile.")
    for home in homes:
        for name in DATABASES:
            if not (home / name).is_file():
                raise ImportFailure("A required history database is missing.")
            no_links(home / name, home)
    return {
        "schemaVersion": 1, "sourceHomes": sources, "targetHome": target,
        "backupRoot": backup, "receiptPath": receipt,
    }


def assert_offline() -> None:
    if os.name != "nt":
        raise ImportFailure("The production migration command requires Windows.")
    command = (
        "$p=@(Get-Process -Name ChatGPT,codex,codex-code-mode-host "
        "-ErrorAction SilentlyContinue); if($p.Count){exit 23}; exit 0"
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode == 23:
        raise ImportFailure("Quit Codex completely before importing history. No process was stopped.")
    if result.returncode:
        raise ImportFailure("Windows could not verify that Codex is closed.")


def connect_readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=10)
    connection.execute("PRAGMA query_only=ON")
    connection.execute("BEGIN")
    return connection


def schema(connection: sqlite3.Connection) -> list:
    return list(connection.execute(
        "SELECT type,name,sql FROM sqlite_schema "
        "WHERE type IN ('table','index','view','trigger') ORDER BY type,name"
    ))


def verify_schema(source: sqlite3.Connection, target: sqlite3.Connection) -> None:
    if schema(source) != schema(target):
        raise ImportFailure("Source and target database schemas differ; no import was made.")
    if source.execute("PRAGMA user_version").fetchone() != target.execute("PRAGMA user_version").fetchone():
        raise ImportFailure("Source and target database versions differ.")
    migrations = "SELECT version,checksum,success FROM _sqlx_migrations ORDER BY version"
    if list(source.execute(migrations)) != list(target.execute(migrations)):
        raise ImportFailure("Database migration records differ; review compatibility first.")


def database_ids(connection: sqlite3.Connection, table: str, column: str) -> set[str]:
    return {row[0] for row in connection.execute(
        "SELECT DISTINCT " + quoted(column) + " FROM " + quoted(table)
    )}


def resolve_rollout(raw: str, home: Path, thread_id: str) -> tuple[Path, Path, Path]:
    if raw.startswith("\\\\?\\"):
        raw = raw[4:]
    original = Path(raw)
    if not original.is_absolute():
        raise ImportFailure("A source rollout path is not absolute.")
    logical_path = original.resolve()
    if not contained(logical_path, home):
        raise ImportFailure("A source rollout is outside its source home.")
    relative = logical_path.relative_to(home)
    if not relative.parts or relative.parts[0] not in ("sessions", "archived_sessions"):
        raise ImportFailure("Only sessions and archived_sessions rollout files may be imported.")
    if not (logical_path.name.endswith(".jsonl") or logical_path.name.endswith(".jsonl.zst")):
        raise ImportFailure("A source rollout has an unsupported file type.")
    if thread_id not in logical_path.name:
        raise ImportFailure("A rollout filename does not contain its database thread identity.")
    no_links(original, home)
    path = logical_path
    # Codex retains the logical .jsonl path after compressing the physical file.
    # Preserve that relationship and projection byte offsets; never decompress.
    if not path.exists() and path.name.endswith(".jsonl"):
        compressed = path.with_name(path.name + ".zst")
        no_links(compressed, home)
        if compressed.is_file():
            path = compressed
    if not path.is_file():
        raise ImportFailure("A source rollout file is missing; the import was stopped.")
    return path, relative, path.relative_to(home)


def inspect(plan: dict) -> dict:
    target = plan["targetHome"]
    connections = []
    try:
        target_state = connect_readonly(target / DATABASES[0])
        target_history = connect_readonly(target / DATABASES[1])
        connections += [target_state, target_history]
        protected = database_ids(target_state, "threads", "id")
        for table in HISTORY_TABLES:
            protected |= database_ids(target_history, table, "thread_id")
        initial_target_ids = database_ids(target_state, "threads", "id")
        seen = set(protected)
        sources = []
        files = {}
        skipped = 0
        orphan_history = 0
        provider_counts = {}
        for source_home in plan["sourceHomes"]:
            state = connect_readonly(source_home / DATABASES[0])
            history = connect_readonly(source_home / DATABASES[1])
            connections += [state, history]
            verify_schema(state, target_state)
            verify_schema(history, target_history)
            rows = list(state.execute(
                "SELECT id,rollout_path,archived,project_id,thread_section_id,model_provider "
                "FROM threads ORDER BY id"
            ))
            all_source_ids = {r[0] for r in rows}
            source_history_ids = database_ids(history, "thread_history_projection_state", "thread_id")
            orphan_history += len(source_history_ids - all_source_ids)
            selected = []
            for thread_id, raw_path, archived, project_id, section_id, provider in rows:
                if thread_id in seen:
                    skipped += 1
                    continue
                source_file, logical_relative, relative = resolve_rollout(raw_path, source_home, thread_id)
                destination = target / logical_relative
                no_links(destination, target)
                no_links(target / relative, target)
                if destination.exists() or (target / relative).exists():
                    raise ImportFailure("A rollout destination already exists without a protected thread.")
                key = str(relative).casefold()
                if key in files:
                    raise ImportFailure("Two imported threads claim the same rollout destination.")
                entry = {
                    "id": thread_id, "source": source_file, "relative": relative,
                    "destination": destination, "archived": archived,
                    "project_id": project_id, "section_id": section_id,
                }
                selected.append(entry)
                files[key] = entry
                seen.add(thread_id)
                provider_counts[provider] = provider_counts.get(provider, 0) + 1
            sources.append({"home": source_home, "threads": selected})
        return {
            "sources": sources, "files": list(files.values()),
            "target_ids": initial_target_ids,
            "summary": {
                "existingTargetThreads": len(initial_target_ids),
                "importThreads": len(files), "duplicateIdsSkipped": skipped,
                "orphanHistoryIdsSkipped": orphan_history,
                "archivedThreads": sum(bool(e["archived"]) for e in files.values()),
                "providerCounts": provider_counts, "schemaCompatible": True,
            },
        }
    finally:
        for connection in connections:
            connection.close()


def fingerprint(home: Path) -> dict:
    result = {}
    for name in DATABASES:
        for suffix in ("", "-wal"):
            path = home / (name + suffix)
            result[name + suffix] = digest(path) if path.exists() else None
    return result


def snapshot(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    reader = connect_readonly(source)
    writer = sqlite3.connect(destination)
    try:
        reader.backup(writer)
    finally:
        writer.close()
        reader.close()


def verify_database(path: Path) -> None:
    connection = connect_readonly(path)
    try:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ImportFailure("A staged or restored database failed integrity_check.")
        if connection.execute("PRAGMA foreign_key_check").fetchall():
            raise ImportFailure("A staged or restored database has broken foreign-key relationships.")
    finally:
        connection.close()


def columns(connection: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in connection.execute("PRAGMA table_info(" + quoted(table) + ")")]


def insert_selected(connection: sqlite3.Connection, table: str, predicate: str, ignore=False) -> None:
    names = ",".join(quoted(c) for c in columns(connection, table))
    connection.execute(
        "INSERT " + ("OR IGNORE " if ignore else "") +
        "INTO main." + quoted(table) + " (" + names + ") SELECT " + names +
        " FROM src." + quoted(table) + " WHERE " + predicate
    )


def merge_reference(connection: sqlite3.Connection, table: str, selected_column: str) -> None:
    names = columns(connection, table)
    differences = " OR ".join("a." + quoted(c) + " IS NOT b." + quoted(c) for c in names)
    selected = "a.id IN (SELECT " + selected_column + " FROM temp.import_ids WHERE " + selected_column + " IS NOT NULL)"
    conflict = connection.execute(
        "SELECT COUNT(*) FROM src." + quoted(table) + " a JOIN main." +
        quoted(table) + " b ON a.id=b.id WHERE " + selected + " AND (" + differences + ")"
    ).fetchone()[0]
    if conflict:
        raise ImportFailure("A project or section identity conflicts with existing target data.")
    insert_selected(connection, table,
                    "id IN (SELECT " + selected_column + " FROM temp.import_ids) "
                    "AND NOT EXISTS (SELECT 1 FROM main." + quoted(table) + " t WHERE t.id=src." +
                    quoted(table) + ".id)")


def stage_databases(plan: dict, inspected: dict, job: Path) -> None:
    for name in DATABASES:
        snapshot(plan["targetHome"] / name, job / "original" / name)
        shutil.copy2(job / "original" / name, job / "staged" / name)
    for source in inspected["sources"]:
        selected = source["threads"]
        if not selected:
            continue
        state = sqlite3.connect((job / "staged" / DATABASES[0]).as_uri() + "?mode=rw", uri=True)
        try:
            state.execute("PRAGMA foreign_keys=ON")
            state.execute("ATTACH DATABASE ? AS src",
                          ((source["home"] / DATABASES[0]).as_uri() + "?mode=ro",))
            state.execute("BEGIN")
            state.execute("CREATE TEMP TABLE import_ids(id TEXT PRIMARY KEY,project_id TEXT,section_id TEXT)")
            state.executemany("INSERT INTO temp.import_ids VALUES(?,?,?)",
                              [(e["id"], e["project_id"], e["section_id"]) for e in selected])
            merge_reference(state, "projects", "project_id")
            merge_reference(state, "thread_sections", "section_id")
            insert_selected(state, "project_roots",
                            "project_id IN (SELECT project_id FROM temp.import_ids)", ignore=True)
            insert_selected(state, "project_idempotency_keys",
                            "project_id IN (SELECT project_id FROM temp.import_ids)", ignore=True)
            cols = columns(state, "threads")
            names = ",".join(quoted(c) for c in cols)
            expressions = ",".join("?" if c == "rollout_path" else quoted(c) for c in cols)
            for entry in selected:
                state.execute(
                    "INSERT INTO main.threads (" + names + ") SELECT " + expressions +
                    " FROM src.threads WHERE id=?", (str(entry["destination"]), entry["id"]))
            for table in STATE_CHILDREN:
                insert_selected(state, table, "thread_id IN (SELECT id FROM temp.import_ids)")
            insert_selected(state, "thread_spawn_edges",
                            "child_thread_id IN (SELECT id FROM temp.import_ids) "
                            "AND parent_thread_id IN (SELECT id FROM main.threads)")
            state.commit()
        finally:
            state.close()
        history = sqlite3.connect((job / "staged" / DATABASES[1]).as_uri() + "?mode=rw", uri=True)
        try:
            history.execute("ATTACH DATABASE ? AS src",
                            ((source["home"] / DATABASES[1]).as_uri() + "?mode=ro",))
            history.execute("BEGIN")
            history.execute("CREATE TEMP TABLE import_ids(id TEXT PRIMARY KEY)")
            history.executemany("INSERT INTO temp.import_ids VALUES(?)", [(e["id"],) for e in selected])
            for table in HISTORY_TABLES:
                insert_selected(history, table, "thread_id IN (SELECT id FROM temp.import_ids)")
            history.commit()
        finally:
            history.close()
    for name in DATABASES:
        verify_database(job / "staged" / name)
    check = connect_readonly(job / "staged" / DATABASES[0])
    try:
        ids = database_ids(check, "threads", "id")
        expected = inspected["target_ids"] | {e["id"] for e in inspected["files"]}
        if ids != expected:
            raise ImportFailure("The staged thread identities failed preservation checks.")
    finally:
        check.close()


def prepare(plan: dict, inspected: dict) -> tuple[Path, dict]:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    job = plan["backupRoot"] / (stamp + "-" + uuid.uuid4().hex[:12])
    job.mkdir(parents=True)
    (job / "staged").mkdir()
    journal = {
        "schemaVersion": 1, "phase": "PREPARING", "targetHome": str(plan["targetHome"]),
        "job": str(job), "fingerprint": fingerprint(plan["targetHome"]),
        "files": [], "summary": inspected["summary"],
    }
    atomic_json(job / "journal.json", journal)
    try:
        stage_databases(plan, inspected, job)
        for name in ("session_index.jsonl", ".codex-global-state.json", ".codex-global-state.json.bak"):
            original = plan["targetHome"] / name
            if original.is_file():
                shutil.copy2(original, job / "original" / name)
        for entry in inspected["files"]:
            staged = job / "rollouts" / entry["relative"]
            staged.parent.mkdir(parents=True, exist_ok=True)
            before = digest(entry["source"])
            shutil.copy2(entry["source"], staged)
            if digest(staged) != before or digest(entry["source"]) != before:
                raise ImportFailure("A source rollout changed while it was being staged.")
            journal["files"].append({
                "relative": str(entry["relative"]), "sha256": before,
                "bytes": staged.stat().st_size,
            })
        if fingerprint(plan["targetHome"]) != journal["fingerprint"]:
            raise ImportFailure("Target history changed during preparation; no live files were replaced.")
        journal["backupHashes"] = {name: digest(job / "original" / name) for name in DATABASES}
        journal["stagedHashes"] = {name: digest(job / "staged" / name) for name in DATABASES}
        journal["phase"] = "PREPARED"
        atomic_json(job / "journal.json", journal)
        return job, journal
    except Exception:
        journal["phase"] = "FAILED"
        atomic_json(job / "journal.json", journal)
        raise


def remove_sidecars(home: Path, name: str) -> None:
    for suffix in ("-wal", "-shm"):
        path = home / (name + suffix)
        if path.exists():
            no_links(path, home)
            path.unlink()


def replace_from(source: Path, destination: Path) -> None:
    temporary = destination.with_name(destination.name + ".history-import-" + uuid.uuid4().hex)
    try:
        shutil.copy2(source, temporary)
        with temporary.open("r+b") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def rollback(plan: dict, job: Path, journal: dict) -> None:
    assert_offline()
    target = plan["targetHome"]
    if journal.get("targetHome") != str(target) or journal.get("job") != str(job):
        raise ImportFailure("A pending journal does not belong to this target and backup job.")
    for name in DATABASES:
        original = job / "original" / name
        if digest(original) != journal["backupHashes"][name]:
            raise ImportFailure("A rollback database backup has changed; repair is required.")
    journal["phase"] = "ROLLING_BACK"
    atomic_json(job / "journal.json", journal)
    for name in DATABASES:
        no_links(target / name, target)
        remove_sidecars(target, name)
        replace_from(job / "original" / name, target / name)
        verify_database(target / name)
    for entry in journal["files"]:
        path = target / entry["relative"]
        if not contained(path.resolve(), target):
            raise ImportFailure("A rollback rollout path escaped the target.")
        if path.exists():
            no_links(path, target)
            if digest(path) != entry["sha256"]:
                raise ImportFailure("An imported rollout changed; retain it for manual recovery.")
            path.unlink()
    journal["phase"] = "ROLLED_BACK"
    atomic_json(job / "journal.json", journal)


def recover_pending(plan: dict) -> int:
    count = 0
    if not plan["backupRoot"].exists():
        return count
    for journal_path in sorted(plan["backupRoot"].glob("*/journal.json")):
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        if journal.get("phase") in PENDING_PHASES and journal.get("targetHome") == str(plan["targetHome"]):
            rollback(plan, journal_path.parent, journal)
            count += 1
    return count


def commit(plan: dict, job: Path, journal: dict) -> None:
    assert_offline()
    target = plan["targetHome"]
    if fingerprint(target) != journal["fingerprint"]:
        raise ImportFailure("Target history changed after staging; the prepared import was not applied.")
    for name in DATABASES:
        if digest(job / "staged" / name) != journal["stagedHashes"][name]:
            raise ImportFailure("A staged database changed after verification.")
    for entry in journal["files"]:
        source = job / "rollouts" / entry["relative"]
        destination = target / entry["relative"]
        if destination.exists() or digest(source) != entry["sha256"]:
            raise ImportFailure("A rollout destination or staged file changed after verification.")
    journal["phase"] = "COMMITTING"
    atomic_json(job / "journal.json", journal)
    try:
        for entry in journal["files"]:
            destination = target / entry["relative"]
            no_links(destination, target)
            destination.parent.mkdir(parents=True, exist_ok=True)
            replace_from(job / "rollouts" / entry["relative"], destination)
        assert_offline()
        for name in DATABASES:
            no_links(target / name, target)
            remove_sidecars(target, name)
            replace_from(job / "staged" / name, target / name)
        for name in DATABASES:
            verify_database(target / name)
        for entry in journal["files"]:
            if digest(target / entry["relative"]) != entry["sha256"]:
                raise ImportFailure("An installed rollout failed its final hash check.")
        journal["phase"] = "COMPLETED"
        atomic_json(job / "journal.json", journal)
    except Exception:
        rollback(plan, job, journal)
        raise


def run(plan: dict, validate_only=False, prepare_only=False) -> dict:
    if validate_only:
        inspected = inspect(plan)
        return {"status": "VALIDATED", **inspected["summary"]}
    assert_offline()
    recover_pending(plan)
    inspected = inspect(plan)
    job, journal = prepare(plan, inspected)
    if not prepare_only:
        commit(plan, job, journal)
    result = {
        "schemaVersion": 1, "status": "PREPARED" if prepare_only else "COMPLETED",
        "job": str(job), "journalPath": str(job / "journal.json"),
        "completedUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
        **inspected["summary"],
    }
    atomic_json(plan["receiptPath"], result)
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True, type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--validate-only", action="store_true",
                       help="Compare schemas and metadata without creating or changing files.")
    modes.add_argument("--prepare", action="store_true",
                       help="Prepare private backups and staged artifacts without replacing target files.")
    args = parser.parse_args(argv)
    plan = None
    try:
        plan = read_plan(args.plan)
        result = run(plan, args.validate_only, args.prepare)
        public = {k: v for k, v in result.items() if k not in ("job", "journalPath")}
        print(json.dumps(public, ensure_ascii=True, sort_keys=True))
        return 0
    except Exception as exc:
        if plan is not None and not args.validate_only:
            atomic_json(plan["receiptPath"], {"schemaVersion": 1, "status": "FAILED",
                                            "errorType": type(exc).__name__})
        # Arbitrary SQLite/filesystem errors can contain private values or paths.
        message = str(exc) if isinstance(exc, ImportFailure) else type(exc).__name__
        print("History import stopped: " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
