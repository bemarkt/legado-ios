#!/usr/bin/env python3
"""Verify an existing Android reference checkout against the pinned Legado baseline.

Read-only: does not clone, download, install, execute Gradle/APKs, or alter the checkout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def verify(checkout, baseline):
    head = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if head != baseline['reference']['commit']:
        raise ValueError('Reference checkout is not at the pinned commit')
    results = []
    for item in baseline['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Unexpected reference path')
        target = (checkout / relative).resolve(strict=True)
        if not target.is_relative_to(checkout):
            raise ValueError('Reference file escapes the checkout')
        data = target.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != item['bytes'] or digest != item['sha256']:
            raise ValueError('Reference bytes changed: ' + item['path'])
        results.append({'path': item['path'], 'bytes': len(data), 'sha256': digest})
    return {'commit': head, 'verifiedFiles': results, 'androidExecution': 'not-verified-by-this-tool'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    baseline = json.loads((root / 'protocols/legado-compatibility/baseline.json').read_text(encoding='utf-8'))
    report = verify(args.checkout.resolve(strict=True), baseline)
    text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text, encoding='utf-8', newline='\n')
    print(text, end='')


if __name__ == '__main__':
    main()
