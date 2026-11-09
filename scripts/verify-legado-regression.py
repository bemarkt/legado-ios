#!/usr/bin/env python3
"""Verify reviewed iOS legacy-rule expectations; no Android environment is required."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('legado_compare', ROOT / 'scripts/compare-legado-reference.py')
COMPARISON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARISON)


def verify(corpus, digest, expected, observed):
    if expected.get('schemaVersion') != 1 or expected.get('corpusSHA256') != digest:
        raise ValueError('Reviewed expectations do not describe this corpus')
    if expected.get('referenceCommit') != corpus.get('referenceCommit'):
        raise ValueError('Reference revision changed without review')
    cases = expected.get('cases', [])
    ids = [item['id'] for item in cases]
    if len(ids) != len(set(ids)) or set(ids) != {item['id'] for item in corpus['cases']}:
        raise ValueError('Reviewed expectations are missing, duplicate or stale')
    actual = COMPARISON.validate_report(observed, corpus, digest, 'swift-legacy-rule-engine')
    failures = []
    for case in cases:
        if not case.get('basis'):
            raise ValueError('Expected case has no review basis')
        row = actual[case['id']]
        diagnostics = [{'code': item['code'], 'severity': item.get('severity')} for item in row['errors']]
        for key in ('outcome', 'values', 'variables', 'diagnostics'):
            value = diagnostics if key == 'diagnostics' else row[key]
            if value != case[key]:
                failures.append({'id': case['id'], 'field': key, 'expected': case[key], 'actual': value})
    return {'schemaVersion': 1, 'profile': expected['profile'], 'corpusSHA256': digest,
            'checked': len(cases), 'failures': failures,
            'providerCompatibility': 'not-evaluated', 'scope': expected['scope']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('observations', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    corpus, digest = COMPARISON.read_json(ROOT / 'protocols/legado-compatibility/corpus.json')
    expected, expected_digest = COMPARISON.read_json(ROOT / 'protocols/legado-compatibility/expectations.json')
    observed, observed_digest = COMPARISON.read_json(args.observations)
    report = verify(corpus, digest, expected, observed)
    report['evidenceSHA256'] = {'expected': expected_digest, 'observed': observed_digest}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(report, ensure_ascii=False))
    if report['failures']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
