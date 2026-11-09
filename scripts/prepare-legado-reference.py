#!/usr/bin/env python3
"""Add only repository-authored instrumentation/fixtures to an exact, unmodified reference checkout."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    checkout = args.checkout.resolve(strict=True)
    spec = importlib.util.spec_from_file_location('reference_verifier', root / 'scripts/verify-legado-reference.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    baseline = json.loads((root / 'protocols/legado-compatibility/baseline.json').read_text(encoding='utf-8'))
    report = module.verify(checkout, baseline)
    subprocess.run(['git', '-C', str(checkout), 'diff', '--quiet', 'HEAD', '--'], check=True)
    mappings = [
        ('tools/legado-compatibility/android/LegadoDifferentialTest.kt',
         'app/src/androidTest/java/io/legado/app/compatibility/LegadoDifferentialTest.kt'),
        ('protocols/legado-compatibility/corpus.json',
         'app/src/androidTest/assets/legado-compatibility-corpus.json'),
    ]
    planned = []
    for source, relative in mappings:
        target = (checkout / relative).resolve()
        if not target.is_relative_to(checkout):
            raise ValueError('Overlay escapes checkout')
        tracked = subprocess.check_output(['git', '-C', str(checkout), 'ls-files', '--', relative])
        if tracked:
            raise ValueError('Refusing to overwrite reference source: ' + relative)
        data = (root / source).read_bytes()
        if target.exists() and target.read_bytes() != data:
            raise ValueError('Different overlay already exists: ' + relative)
        planned.append((source, relative, target, data))
    init_data = (root / 'tools/legado-compatibility/android/reference.init.gradle').read_bytes()
    report['buildOverlay'] = {'minSdk': 26, 'sourceAlgorithms': 'unchanged',
                              'initSHA256': hashlib.sha256(init_data).hexdigest()}
    report['overlay'] = []
    for source, relative, target, data in planned:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report['overlay'].append({'source': source, 'destination': relative,
                                  'sha256': hashlib.sha256(data).hexdigest()})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8', newline='\n')
    print('Verified pinned reference and added two isolated test files; no production code modified.')


if __name__ == '__main__':
    main()
