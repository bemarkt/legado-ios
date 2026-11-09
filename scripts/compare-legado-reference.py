#!/usr/bin/env python3
"""Compare exact offline observations. Discovery success is not a compatibility verdict."""
import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path


def read_json(path):
    data = Path(path).read_bytes()
    if len(data) > 4 * 1024 * 1024:
        raise ValueError('Oversized evidence')
    return json.loads(data), hashlib.sha256(data).hexdigest()


def validate_report(report, corpus, digest, engine):
    if report.get('schemaVersion') != 1 or report.get('engine') != engine:
        raise ValueError('Unexpected report schema or engine')
    if report.get('corpusSHA256') != digest or report.get('referenceCommit') != corpus['referenceCommit']:
        raise ValueError('Evidence does not describe this corpus/reference')
    results = report.get('results', [])
    ids = [item['id'] for item in results]
    if len(ids) != len(set(ids)) or set(ids) != {item['id'] for item in corpus['cases']}:
        raise ValueError('Missing, duplicate or unknown case results')
    by_id = {item['id']: item for item in results}
    for fixture in corpus['cases']:
        item = by_id[fixture['id']]
        if item.get('outcome') not in ('success', 'error'):
            raise ValueError('Missing explicit outcome')
        values = item.get('values')
        variables = item.get('variables')
        errors = item.get('errors')
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise ValueError('Values must preserve the actual string array')
        if not isinstance(variables, dict) or set(variables) != set(fixture['inspectVariables']):
            raise ValueError('Variable observations are incomplete')
        if not all(isinstance(value, str) for value in variables.values()):
            raise ValueError('Variables must be strings')
        if not isinstance(errors, list) or (item['outcome'] == 'error' and not errors):
            raise ValueError('Errors must retain diagnostic evidence')
        for error in errors:
            if not isinstance(error, dict) or not isinstance(error.get('code'), str) or not isinstance(error.get('message'), str):
                raise ValueError('Invalid error evidence')
        if 'sanityValues' in fixture and (item['outcome'] != 'success' or values != fixture['sanityValues']):
            raise ValueError('Runner failed independent sanity anchor')
    return by_id


def compare(corpus, digest, android, swift):
    if corpus.get('schemaVersion') != 1 or not corpus.get('cases'):
        raise ValueError('Invalid corpus')
    ids = [item['id'] for item in corpus['cases']]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate corpus ids')
    left = validate_report(android, corpus, digest, 'android-legado-reference')
    right = validate_report(swift, corpus, digest, 'swift-legacy-rule-engine')
    records = []
    for fixture in corpus['cases']:
        a, b = left[fixture['id']], right[fixture['id']]
        expected = fixture.get('expectedOutcome', 'success')
        changed = [key for key in ('outcome', 'values', 'variables') if a[key] != b[key]]
        if a['outcome'] != expected or b['outcome'] != expected:
            classification = 'unexpected-outcome'
        elif changed:
            classification = 'different'
        elif expected == 'error':
            classification = 'error-outcome-only'
        elif a['errors'] or b['errors']:
            classification = 'diagnostic-review'
        else:
            classification = 'equal-values'
        records.append({'id': fixture['id'], 'family': fixture['family'],
                        'classification': classification, 'changedFields': changed,
                        'android': a, 'swift': b})
    counts = dict(Counter(item['classification'] for item in records))
    return {'schemaVersion': 1, 'referenceCommit': corpus['referenceCommit'],
            'corpusSHA256': digest, 'mode': 'discovery', 'counts': counts,
            'scope': corpus['scope'], 'providerCompatibility': 'not-evaluated',
            'errorSemantics': 'raw diagnostics retained; matching error outcomes do not establish equivalent errors',
            'results': records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus', type=Path)
    parser.add_argument('android', type=Path)
    parser.add_argument('swift', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--strict', action='store_true', help='Fail on differences, unexpected outcomes or diagnostic review')
    args = parser.parse_args()
    corpus, digest = read_json(args.corpus)
    android, android_digest = read_json(args.android)
    swift, swift_digest = read_json(args.swift)
    report = compare(corpus, digest, android, swift)
    report['mode'] = 'strict' if args.strict else 'discovery'
    report['evidenceSHA256'] = {'android': android_digest, 'swift': swift_digest}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps({'counts': report['counts'], 'mode': report['mode'], 'providerCompatibility': 'not-evaluated'}))
    if args.strict and any(report['counts'].get(key, 0) for key in ('different', 'unexpected-outcome', 'diagnostic-review')):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
