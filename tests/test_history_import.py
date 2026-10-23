import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock


TOOL = Path(__file__).resolve().parents[1] / "tools" / "Import-CodexHistory.py"
SPEC = importlib.util.spec_from_file_location("history_import", TOOL)
IMPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORT)


STATE_SQL = """
CREATE TABLE _sqlx_migrations(version INTEGER PRIMARY KEY,checksum BLOB,success INTEGER);
INSERT INTO _sqlx_migrations VALUES(1,X'01',1);
CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT,metadata TEXT,position INTEGER,created_at_ms INTEGER,updated_at_ms INTEGER);
CREATE TABLE project_roots(project_id TEXT REFERENCES projects(id),position INTEGER,path TEXT,PRIMARY KEY(project_id,position));
CREATE TABLE project_idempotency_keys(key TEXT PRIMARY KEY,project_id TEXT,created_at_ms INTEGER);
CREATE TABLE thread_sections(id TEXT PRIMARY KEY,name TEXT,appearance TEXT);
CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,archived INTEGER,project_id TEXT REFERENCES projects(id),thread_section_id TEXT REFERENCES thread_sections(id),model_provider TEXT,title TEXT);
CREATE TABLE thread_read_receipts(thread_id TEXT PRIMARY KEY,revision TEXT);
CREATE TABLE thread_attachments(id TEXT PRIMARY KEY,thread_id TEXT REFERENCES threads(id));
CREATE TABLE thread_dynamic_tools(thread_id TEXT,position INTEGER,PRIMARY KEY(thread_id,position));
CREATE TABLE guardian_review_feedback(id TEXT PRIMARY KEY,thread_id TEXT REFERENCES threads(id));
CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT PRIMARY KEY,status TEXT);
INSERT INTO thread_sections VALUES('default','Default',NULL);
"""
HISTORY_SQL = """
CREATE TABLE _sqlx_migrations(version INTEGER PRIMARY KEY,checksum BLOB,success INTEGER);
INSERT INTO _sqlx_migrations VALUES(1,X'01',1);
CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_json TEXT,PRIMARY KEY(thread_id,turn_id,item_id),UNIQUE(thread_id,rollout_ordinal));
CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,PRIMARY KEY(thread_id,turn_id),UNIQUE(thread_id,rollout_ordinal));
CREATE TABLE thread_realtime_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,PRIMARY KEY(thread_id,item_id),UNIQUE(thread_id,rollout_ordinal));
"""


class HistoryImportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.source = self.make_home("source")
        self.target = self.make_home("target")
        self.plan_path = self.root / "private-plan.json"
        self.plan_path.write_text(json.dumps({
            "schemaVersion": 1, "sourceHomes": [str(self.source)],
            "targetHome": str(self.target), "backupRoot": str(self.root / "backups"),
            "receiptPath": str(self.root / "receipt.json"),
        }))
        self.plan = IMPORT.read_plan(self.plan_path)
        self.guard = mock.patch.object(IMPORT, "assert_offline")
        self.guard.start()
        self.addCleanup(self.guard.stop)
        self.addCleanup(self.temp.cleanup)

    def make_home(self, name):
        home = self.root / name
        home.mkdir()
        for filename, sql in zip(IMPORT.DATABASES, (STATE_SQL, HISTORY_SQL)):
            c = sqlite3.connect(home / filename)
            c.executescript(sql)
            c.close()
        return home

    def add_thread(self, home, thread_id, archived=0, project=False, compressed=False):
        folder = "archived_sessions" if archived else "sessions"
        suffix = ".jsonl.zst" if compressed else ".jsonl"
        rollout = home / folder / ("rollout-" + thread_id + suffix)
        rollout.parent.mkdir(exist_ok=True)
        rollout.write_bytes(b"opaque-session-fixture-" + thread_id.encode())
        state = sqlite3.connect(home / IMPORT.DATABASES[0])
        if project:
            state.execute("INSERT INTO projects VALUES(?,?,?,?,?,?)",
                          ("project-" + thread_id, "Project", "{}", 0, 1, 1))
            state.execute("INSERT INTO project_roots VALUES(?,?,?)",
                          ("project-" + thread_id, 0, "/fixture/project"))
        state.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?)",
                      (thread_id, str(rollout), archived, "project-" + thread_id if project else None,
                       "default", "OpenAI", "opaque title " + thread_id))
        state.execute("INSERT INTO thread_read_receipts VALUES(?,?)", (thread_id, "fixture-revision"))
        state.commit()
        state.close()
        hist = sqlite3.connect(home / IMPORT.DATABASES[1])
        hist.execute("INSERT INTO thread_history_projection_state VALUES(?,?,?)", (thread_id, 0, 1))
        hist.execute("INSERT INTO thread_items VALUES(?,?,?,?,?)", (thread_id, "turn", "item", 1, "{}"))
        hist.execute("INSERT INTO thread_turns VALUES(?,?,?)", (thread_id, "turn", 1))
        hist.commit()
        hist.close()
        return rollout

    def rows(self, home, database, sql):
        c = sqlite3.connect(home / database)
        try:
            return c.execute(sql).fetchall()
        finally:
            c.close()

    def test_additive_import_preserves_target_projects_and_archival(self):
        self.add_thread(self.target, "existing", project=True)
        source_file = self.add_thread(self.source, "new", archived=1, project=True, compressed=True)
        for name in ("auth.json", "config.toml", "models.json", "session_index.jsonl", ".codex-global-state.json"):
            (self.target / name).write_bytes(b"unchanged")
        result = IMPORT.run(self.plan)
        self.assertEqual(result["status"], "COMPLETED")
        self.assertEqual(result["importThreads"], 1)
        rows = self.rows(self.target, IMPORT.DATABASES[0], "SELECT id,archived,rollout_path FROM threads ORDER BY id")
        self.assertEqual([r[0] for r in rows], ["existing", "new"])
        self.assertEqual(rows[1][1], 1)
        imported = Path(rows[1][2])
        self.assertTrue(imported.is_relative_to(self.target))
        self.assertEqual(imported.read_bytes(), source_file.read_bytes())
        self.assertEqual(len(self.rows(self.target, IMPORT.DATABASES[0], "SELECT * FROM projects")), 2)
        self.assertEqual(len(self.rows(self.target, IMPORT.DATABASES[1], "SELECT * FROM thread_items")), 2)
        for name in ("auth.json", "config.toml", "models.json", "session_index.jsonl", ".codex-global-state.json"):
            self.assertEqual((self.target / name).read_bytes(), b"unchanged")

    def test_duplicates_are_preserved_and_reimport_is_additive(self):
        self.add_thread(self.target, "same")
        self.add_thread(self.source, "same", archived=1)
        self.add_thread(self.source, "new")
        first = IMPORT.run(self.plan)
        second = IMPORT.run(self.plan)
        self.assertEqual(first["duplicateIdsSkipped"], 1)
        self.assertEqual(second["importThreads"], 0)
        self.assertEqual(self.rows(self.target, IMPORT.DATABASES[0],
                                  "SELECT archived FROM threads WHERE id='same'"), [(0,)])

    def test_validate_only_is_readonly_and_missing_rollout_rejected(self):
        source_file = self.add_thread(self.source, "missing")
        before = IMPORT.fingerprint(self.target)
        result = IMPORT.run(self.plan, validate_only=True)
        self.assertEqual(result["status"], "VALIDATED")
        self.assertFalse(self.plan["backupRoot"].exists())
        self.assertFalse(self.plan["receiptPath"].exists())
        self.assertEqual(IMPORT.fingerprint(self.target), before)
        source_file.unlink()
        with self.assertRaises(IMPORT.ImportFailure):
            IMPORT.run(self.plan, validate_only=True)
        self.assertEqual(IMPORT.fingerprint(self.target), before)

    def test_schema_mismatch_stops_before_any_mutation(self):
        c = sqlite3.connect(self.source / IMPORT.DATABASES[0])
        c.execute("ALTER TABLE threads ADD COLUMN unexpected TEXT")
        c.close()
        with self.assertRaises(IMPORT.ImportFailure):
            IMPORT.run(self.plan)
        self.assertFalse(self.plan["backupRoot"].exists())

    def test_failure_after_first_database_replacement_rolls_back(self):
        self.add_thread(self.target, "existing")
        self.add_thread(self.source, "new")
        expected_state = self.rows(self.target, IMPORT.DATABASES[0], "SELECT * FROM threads")
        expected_history = self.rows(self.target, IMPORT.DATABASES[1], "SELECT * FROM thread_items")
        inspected = IMPORT.inspect(self.plan)
        job, journal = IMPORT.prepare(self.plan, inspected)
        actual_replace = IMPORT.replace_from
        failed = False

        def fail_once(source, destination):
            nonlocal failed
            if destination == self.target / IMPORT.DATABASES[1] and not failed:
                failed = True
                raise OSError("injected second-database failure")
            return actual_replace(source, destination)

        with mock.patch.object(IMPORT, "replace_from", side_effect=fail_once):
            with self.assertRaises(OSError):
                IMPORT.commit(self.plan, job, journal)
        self.assertEqual(journal["phase"], "ROLLED_BACK")
        self.assertEqual(self.rows(self.target, IMPORT.DATABASES[0], "SELECT * FROM threads"), expected_state)
        self.assertEqual(self.rows(self.target, IMPORT.DATABASES[1], "SELECT * FROM thread_items"), expected_history)
        self.assertFalse((self.target / "sessions" / "rollout-new.jsonl").exists())

    def test_pending_commit_journal_is_recovered_before_next_import(self):
        self.add_thread(self.target, "existing")
        self.add_thread(self.source, "new")
        job, journal = IMPORT.prepare(self.plan, IMPORT.inspect(self.plan))
        journal["phase"] = "COMMITTING"
        IMPORT.atomic_json(job / "journal.json", journal)
        IMPORT.replace_from(job / "staged" / IMPORT.DATABASES[0], self.target / IMPORT.DATABASES[0])
        self.assertEqual(IMPORT.recover_pending(self.plan), 1)
        self.assertEqual(self.rows(self.target, IMPORT.DATABASES[0], "SELECT id FROM threads"), [("existing",)])

    def test_project_identity_conflict_never_overwrites_target(self):
        self.add_thread(self.source, "new", project=True)
        c = sqlite3.connect(self.target / IMPORT.DATABASES[0])
        c.execute("INSERT INTO projects VALUES(?,?,?,?,?,?)",
                  ("project-new", "Different existing project", "{}", 0, 1, 1))
        c.commit()
        c.close()
        with self.assertRaises(IMPORT.ImportFailure):
            IMPORT.run(self.plan)
        self.assertEqual(self.rows(self.target, IMPORT.DATABASES[0], "SELECT COUNT(*) FROM threads"), [(0,)])

    def test_compressed_rollout_retains_logical_database_path(self):
        physical = self.add_thread(self.source, "compressed", compressed=True)
        logical = Path(str(physical)[:-4])
        c = sqlite3.connect(self.source / IMPORT.DATABASES[0])
        c.execute("UPDATE threads SET rollout_path=? WHERE id='compressed'", (str(logical),))
        c.commit()
        c.close()
        IMPORT.run(self.plan)
        stored = self.rows(self.target, IMPORT.DATABASES[0], "SELECT rollout_path FROM threads")[0][0]
        self.assertTrue(stored.endswith(".jsonl"))
        self.assertFalse(Path(stored).exists())
        self.assertEqual(Path(stored + ".zst").read_bytes(), physical.read_bytes())


if __name__ == "__main__":
    unittest.main()
