import datetime as dt
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest


class ImportHistoryTest(unittest.TestCase):
    def test_observations_only_and_existing_samples_win(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = root / "sessions"
            sessions.mkdir()
            now = int(time.time())

            def event(at, used, limit="codex"):
                return {"type": "event_msg", "timestamp": dt.datetime.fromtimestamp(at, dt.timezone.utc).isoformat(),
                        "payload": {"type": "token_count", "rate_limits": {"limit_id": limit,
                            "primary": {"used_percent": used, "window_minutes": 10080, "resets_at": now + 86400}}}}

            events = [event(now - 600, 23), event(now - 300, 41), event(now - 300, 41),
                      event(now - 200, 44, "other-model"), event(now + 3600, 50),
                      event(now - 91 * 86400, 10), event(now - 100, 101)]
            (sessions / "fixture.jsonl").write_text("not-json\n" + "\n".join(map(json.dumps, events)))
            db_path = root / "history.sqlite"
            with sqlite3.connect(db_path) as db:
                db.execute("CREATE TABLE samples (at INTEGER, provider TEXT, id TEXT, remaining REAL, reset INTEGER, PRIMARY KEY(at,provider,id))")
                db.execute("INSERT INTO samples VALUES (?, 'codex', 'codex_604800', 82, ?)", (now - 600, now + 86400))
            command = [sys.executable, str(Path(__file__).resolve().parents[1] / "import_codex_history.py"),
                       "--codex-home", str(root), "--database", str(db_path)]
            subprocess.run(command, check=True, capture_output=True)
            subprocess.run(command, check=True, capture_output=True)
            with sqlite3.connect(db_path) as db:
                self.assertEqual(db.execute("SELECT at,remaining FROM samples ORDER BY at").fetchall(),
                                 [(now - 600, 82), (now - 300, 59)])


if __name__ == "__main__":
    unittest.main()
