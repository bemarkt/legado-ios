#!/usr/bin/env python3
"""Kill the real Swift SourceArchive probe before/during/after a source update.

Uses synthetic data only. Requires the SwiftPM SourceRecoveryProbe executable.
The during-write case is accepted only when WAL growth was observed and reopening
proves the entire old state survived; a completed race is retried, never counted.
"""
import argparse
import json
from pathlib import Path
import queue
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time


def invoke(binary, operation, database):
    result = subprocess.run([str(binary), operation, str(database)], capture_output=True, text=True, timeout=45, check=True)
    return json.loads(result.stdout)


def start_update(binary, database):
    process = subprocess.Popen([str(binary), 'update', str(database)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    messages = queue.Queue()
    def read_output():
        for line in process.stdout:
            messages.put(json.loads(line))
    process.reader = threading.Thread(target=read_output, daemon=True)
    process.reader.start()
    return process, messages


def phase(process, messages, expected):
    try:
        value = messages.get(timeout=30)
    except queue.Empty:
        raise RuntimeError('Timed out waiting for ' + expected + '; process=' + str(process.poll()))
    if value.get('phase') != expected:
        raise RuntimeError('Unexpected probe phase: ' + repr(value))
    return value


def kill(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)
    process.reader.join(timeout=2)
    for stream in [process.stdin, process.stdout, process.stderr]:
        stream.close()


def equivalent_data(actual, original):
    for key in ['selected', 'websiteState', 'books']:
        if actual[key] != original[key]:
            raise AssertionError('Source update changed unrelated account data: ' + key)


def assert_committed(actual, original, candidate):
    equivalent_data(actual, original)
    assert actual['active'] == candidate and actual['version'] == '10', actual
    assert actual['history'] == ([original['active']] + original['history'])[:8]
    assert actual['configurations'] == {key: {} for key in original['configurations']}


def verify(binary, workspace):
    build = (workspace / 'build').resolve()
    build.mkdir(exist_ok=True)
    report = {'version': 1, 'probe': str(binary), 'cases': [], 'limitations': ['No physical power-loss or device-filesystem claim']}
    with tempfile.TemporaryDirectory(prefix='source-process-recovery-', dir=build) as directory:
        root = Path(directory).resolve()
        # Validate the exact cleanup root before TemporaryDirectory may recursively remove it.
        assert root.parent == build and root.name.startswith('source-process-recovery-')
        seed = root / 'seed' / 'native.sqlite3'
        original = invoke(binary, 'seed', seed)
        with sqlite3.connect(seed) as connection:
            assert connection.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0] == 0
        for checkpoint in ['before', 'during', 'after']:
            for attempt in range(1, 6):
                folder = root / (checkpoint + '-' + str(attempt))
                folder.mkdir()
                database = folder / 'native.sqlite3'
                shutil.copy2(seed, database)
                if checkpoint == 'during':
                    # Deterministic fault injection at the actual history write, without product test hooks.
                    # Force uncommitted dirty pages to WAL, then hold the writer in a bounded SQL calculation.
                    # The parent must observe WAL growth before killing; a completed race never counts.
                    with sqlite3.connect(database) as connection:
                        connection.executescript('''
                            CREATE TABLE recovery_fault_marker(payload BLOB);
                            CREATE TRIGGER recovery_pause AFTER UPDATE OF payload ON records
                            WHEN NEW.namespace='installation-history'
                            BEGIN
                                INSERT INTO recovery_fault_marker VALUES(zeroblob(16777216));
                                SELECT sum(value) FROM (
                                    WITH RECURSIVE delay(value) AS (
                                        VALUES(1) UNION ALL SELECT value+1 FROM delay WHERE value<100000000
                                    ) SELECT value FROM delay
                                );
                            END;
                        ''')
                        connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
                process, messages = start_update(binary, database)
                grown = False
                try:
                    ready = phase(process, messages, 'ready')
                    if checkpoint != 'before':
                        wal = Path(str(database) + '-wal')
                        baseline = wal.stat().st_size if wal.exists() else 0
                        process.stdin.write('go\n'); process.stdin.flush()
                        if checkpoint == 'after':
                            phase(process, messages, 'committed')
                        else:
                            deadline = time.monotonic() + 30
                            while time.monotonic() < deadline:
                                if wal.exists() and wal.stat().st_size > baseline + 131072:
                                    grown = True
                                    break
                                if process.poll() is not None:
                                    raise RuntimeError('Probe exited before the WAL checkpoint')
                                time.sleep(0.0005)
                            if not grown:
                                raise RuntimeError('No transaction WAL growth observed')
                    kill(process)
                finally:
                    if process.poll() is None:
                        kill(process)
                recovered = invoke(binary, 'inspect', database)
                if checkpoint == 'after':
                    assert_committed(recovered, original, ready['candidate'])
                elif recovered != original:
                    # The commit may win a scheduling race. Verify atomicity but do not count it as interruption.
                    assert_committed(recovered, original, ready['candidate'])
                    if checkpoint == 'during' and attempt < 5:
                        continue
                    raise AssertionError('Did not interrupt the transaction at ' + checkpoint)
                with sqlite3.connect(database) as connection:
                    assert connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
                report['cases'].append({'checkpoint': checkpoint, 'attempt': attempt, 'walGrowthObserved': grown,
                                        'recovered': 'new' if checkpoint == 'after' else 'old', 'integrity': 'ok'})
                if checkpoint != 'after':
                    # Remove only the fixture fault before explicitly retrying the same real Swift API.
                    if checkpoint == 'during':
                        with sqlite3.connect(database) as connection:
                            assert connection.execute('SELECT COUNT(*) FROM recovery_fault_marker').fetchone()[0] == 0
                            connection.executescript('DROP TRIGGER recovery_pause; DROP TABLE recovery_fault_marker;')
                    retry, retry_messages = start_update(binary, database)
                    try:
                        retry_ready = phase(retry, retry_messages, 'ready')
                        retry.stdin.write('go\n'); retry.stdin.flush()
                        phase(retry, retry_messages, 'committed')
                        kill(retry)
                    finally:
                        if retry.poll() is None:
                            kill(retry)
                    assert_committed(invoke(binary, 'inspect', database), original, retry_ready['candidate'])
                    report['cases'][-1]['explicitRetry'] = 'new'
                break
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = verify(args.probe.resolve(strict=True), Path(__file__).resolve().parents[1])
    text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding='utf-8', newline='\n')
    print(text, end='')


if __name__ == '__main__':
    main()
