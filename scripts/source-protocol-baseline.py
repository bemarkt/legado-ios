"""Record a reproducible P0 baseline and verify synthetic v7 SQLite fixtures.

Uses only repository source and generated public samples. Never reads an App's
user database. Generated databases live in a temporary directory by default.
This checks extracted SQL, not Swift migration/decoding or new-schema migration.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import platform
import re
import shutil
import sqlite3
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB_SOURCE = ROOT / "Sources/LegadoCore/Persistence/LegadoDatabase.swift"
SEED = ROOT / "protocols/source-v1/fixtures/migration/legacy-v7-seed.json"


def command(*args: str) -> str | None:
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=20)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def migration_blocks() -> list[tuple[int, str]]:
    text = DB_SOURCE.read_text(encoding="utf-8")
    # Only the checked-in static CREATE/ALTER blocks are read. This is a fixture
    # extractor, never a general Swift interpreter or production migration tool.
    blocks = [(int(version), sql) for version, sql in re.findall(
        r'if version < (\d+) \{\s*try execute\(database, "BEGIN IMMEDIATE"\)\s*do \{\s*try execute\(database, """(.*?)"""\)',
        text, re.S)]
    if [version for version, _ in blocks] != list(range(1, 8)):
        raise RuntimeError("Expected schema v1..v7 static blocks; review extractor for changed Swift source")
    if any('\\(' in sql for _, sql in blocks):
        raise RuntimeError("Swift interpolation is not supported by this fixture extractor")
    return blocks


def create_fixture(target: Path, seed: dict, version: int = 7) -> dict:
    if target.exists():
        raise FileExistsError(f"Refusing to overwrite {target}")
    connection = sqlite3.connect(target)
    try:
        connection.execute("PRAGMA foreign_keys=ON")
        for number, sql in migration_blocks():
            if number > version:
                break
            connection.executescript(sql)
        if version == 7:
            payload = lambda value: json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            source, book = seed["source"], seed["book"]
            connection.execute("INSERT INTO book_sources(book_source_url,position,payload) VALUES(?,?,?)", (source["bookSourceUrl"], 0, payload(source)))
            connection.execute("INSERT INTO books(book_url,name,author,position,payload) VALUES(?,?,?,?,?)", (book["bookUrl"], book["name"], book["author"], 0, payload(book)))
            for chapter in seed["chapters"]:
                connection.execute("INSERT INTO chapters(url,book_url,chapter_index,payload) VALUES(?,?,?,?)", (chapter["url"], book["bookUrl"], chapter["index"], payload(chapter)))
            bookmark = seed["bookmark"]
            connection.execute("INSERT INTO bookmarks(time,payload) VALUES(?,?)", (bookmark["time"], payload(bookmark)))
            record = seed["record"]
            connection.execute("INSERT INTO read_records(device_id,book_name,last_read,payload) VALUES(?,?,?,?)", (record["deviceId"], record["bookName"], record["lastRead"], payload(record)))
            for key, value in seed["cacheEntries"].items():
                connection.execute("INSERT INTO caches(`key`,value,deadline) VALUES(?,?,0)", (key, value))
            connection.execute("INSERT INTO cookies(url,cookie) VALUES(?,?)", (seed["cookie"]["url"], seed["cookie"]["cookie"]))
            connection.execute("INSERT INTO legacy_imports(key) VALUES('chapters')")
            connection.commit()
            assert json.loads(connection.execute("SELECT payload FROM book_sources").fetchone()[0])["customFixtureField"] == {"preserve": True}
            loaded = [json.loads(row[0]) for row in connection.execute("SELECT payload FROM chapters ORDER BY chapter_index")]
            assert loaded[0]["title"] == loaded[1]["title"] and loaded[0]["url"] != loaded[1]["url"]
            assert json.loads(connection.execute("SELECT payload FROM books").fetchone()[0])["durChapterIndex"] == 1
        assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert not connection.execute("PRAGMA foreign_key_check").fetchall()
        tables = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        return {"schemaVersion": connection.execute("PRAGMA user_version").fetchone()[0], "tables": tables,
                "counts": {name: connection.execute('SELECT COUNT(*) FROM "' + name + '"').fetchone()[0] for name in tables},
                "integrity": "ok", "foreignKeys": "ok"}
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Write JSON baseline report; does not contain user data")
    parser.add_argument("--fixture-output", type=Path, help="Optional new file for synthetic v7 database; never overwrites")
    args = parser.parse_args()
    seed = json.loads(SEED.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="legado-source-p0-") as temporary:
        migrations = [create_fixture(Path(temporary) / f"v{version}.sqlite3", seed, version) for version in range(1, 8)]
    if args.fixture_output:
        create_fixture(args.fixture_output.resolve(), seed)
    files = ["Package.swift", "Package.resolved", "Legado.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
             "Sources/LegadoCore/Persistence/LegadoDatabase.swift", "protocols/source-v1/schema.json",
             "protocols/source-v1/profile.json", "protocols/source-v1/fixtures/migration/legacy-v7-seed.json",
             "tools/source-protocol/package-lock.json", "tools/source-protocol/lib/static-parser.mjs",
             "tools/source-protocol/lib/contracts.mjs", "tools/source-protocol/lib/inspect.mjs",
             "tools/source-protocol/fixture-server.mjs", "tools/source-protocol/generate-types.mjs",
             "tools/source-protocol/test/static-parser.test.mjs", "tools/source-protocol/test/contracts.test.mjs",
             "tools/source-protocol/test/fixture-flow.test.mjs", "protocols/source-v1/context.d.ts",
             "protocols/source-v1/types.generated.d.ts", "protocols/source-v1/fixtures/static-cases.json",
             "protocols/source-v1/fixtures/html.source.js", "protocols/source-v1/fixtures/json.source.js",
             "scripts/source-protocol-baseline.py", ".github/workflows/source-protocol-ci.yml", ".gitattributes"]
    report = {"date": datetime.now(timezone(timedelta(hours=8))).date().isoformat(), "phase": "P0", "gitHEAD": command("git", "rev-parse", "HEAD"),
              "platform": platform.system(), "python": platform.python_version(), "sqlite": sqlite3.sqlite_version,
              "tools": {"node": command("node", "--version"), "swiftAvailable": bool(shutil.which("swift")),
                        "xcodebuildAvailable": bool(shutil.which("xcodebuild")), "adbAvailable": bool(shutil.which("adb"))},
              "filesSHA256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files},
              "syntheticSQLChecks": migrations,
              "unverified": ["Swift build and tests", "Swift decoding of synthetic payloads", "new-schema migration", "iOS WebKit/device behavior", "Android differential baseline", "real user database"]}
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding="utf-8")
    print(json.dumps({"gitHEAD": report["gitHEAD"], "schemaVersionsChecked": [item["schemaVersion"] for item in migrations],
                      "v7Tables": len(migrations[-1]["tables"]), "v7Counts": migrations[-1]["counts"], "unverified": report["unverified"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
