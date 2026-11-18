#!/usr/bin/env python3
"""Import observed Codex rate-limit events, never conversation text or estimates."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--database", type=Path, default=Path.home() / ".cache/swiftbar-usage/history.sqlite")
    args = parser.parse_args()
    os.umask(0o077)
    now = int(time.time())
    cutoff = now - 90 * 86400
    args.database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.database, timeout=30) as db:
        db.execute("CREATE TABLE IF NOT EXISTS samples (at INTEGER, provider TEXT, id TEXT, remaining REAL, reset INTEGER, PRIMARY KEY(at,provider,id))")
        before = db.total_changes
        files = 0
        for folder in ("sessions", "archived_sessions"):
            for path in sorted((args.codex_home / folder).rglob("*.jsonl")):
                try:
                    day = dt.date.fromisoformat(path.name.removeprefix("rollout-")[:10])
                    if day < dt.datetime.fromtimestamp(cutoff, dt.timezone.utc).date() - dt.timedelta(days=1):
                        continue
                except ValueError:
                    pass
                files += 1
                with path.open(errors="replace") as stream:
                    for line in stream:
                        if '"rate_limits"' not in line:
                            continue
                        try:
                            event = json.loads(line)
                            payload = event.get("payload", {})
                            if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                                continue
                            limits = payload.get("rate_limits")
                            if not isinstance(limits, dict) or limits.get("limit_id") not in (None, "codex"):
                                continue
                            stamp = dt.datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
                            if stamp.tzinfo is None:
                                continue
                            at = int(stamp.timestamp())
                            if not cutoff <= at <= now:
                                continue
                            for key in ("primary", "secondary"):
                                window = limits.get(key)
                                if not isinstance(window, dict):
                                    continue
                                used, minutes, reset = window.get("used_percent"), window.get("window_minutes"), window.get("resets_at")
                                if type(used) not in (int, float) or not 0 <= used <= 100:
                                    continue
                                if type(minutes) is not int or minutes <= 0 or (reset is not None and type(reset) is not int):
                                    continue
                                db.execute("INSERT OR IGNORE INTO samples VALUES (?, 'codex', ?, ?, ?)",
                                           (at, f"codex_{minutes * 60}", 100 - used, reset))
                        except (ValueError, KeyError, TypeError, AttributeError):
                            continue
                db.commit()
        print(f"Imported {db.total_changes - before} observed readings from {files} local session files. Existing samples were preserved.")


if __name__ == "__main__":
    main()
