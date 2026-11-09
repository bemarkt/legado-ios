import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('compare_reference', ROOT / 'scripts/compare-legado-reference.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        data = (ROOT / 'protocols/legado-compatibility/corpus.json').read_bytes()
        self.corpus = json.loads(data)
        self.digest = hashlib.sha256(data).hexdigest()
        rows = []
        for case in self.corpus['cases']:
            error = case['expectedOutcome'] == 'error'
            rows.append({'id': case['id'], 'outcome': 'error' if error else 'success',
                         'values': [] if error else case.get('sanityValues', ['synthetic']),
                         'variables': {key: 'synthetic' for key in case['inspectVariables']},
                         'errors': [{'code': 'synthetic', 'message': 'fixture error'}] if error else []})
        self.android = {'schemaVersion': 1, 'engine': 'android-legado-reference',
                        'referenceCommit': self.corpus['referenceCommit'], 'corpusSHA256': self.digest,
                        'results': rows}
        self.swift = copy.deepcopy(self.android)
        self.swift['engine'] = 'swift-legacy-rule-engine'

    def compare(self):
        return MODULE.compare(self.corpus, self.digest, self.android, self.swift)

    def test_complete_evidence_does_not_claim_provider_compatibility(self):
        result = self.compare()
        self.assertEqual(result['counts'], {'equal-values': 27, 'error-outcome-only': 2})
        self.assertEqual(result['providerCompatibility'], 'not-evaluated')

    def test_value_order_and_variables_are_not_normalized_away(self):
        self.swift['results'][0]['values'] = ['changed']
        variable = next(row for row in self.swift['results'] if row['variables'])
        variable['variables'][next(iter(variable['variables']))] = 'changed'
        result = self.compare()
        self.assertEqual(result['counts']['different'], 2)
        self.assertIn('values', result['results'][0]['changedFields'])

    def test_two_engines_failing_a_success_case_is_not_a_match(self):
        for report in (self.android, self.swift):
            report['results'][0].update(outcome='error', values=[], errors=[{'code': 'parse', 'message': 'failed'}])
        self.assertEqual(self.compare()['results'][0]['classification'], 'unexpected-outcome')

    def test_diagnostic_is_not_silently_equivalent(self):
        self.swift['results'][0]['errors'] = [{'code': 'warning', 'message': 'partial'}]
        self.assertEqual(self.compare()['results'][0]['classification'], 'diagnostic-review')

    def test_stale_reference_or_corpus_is_rejected(self):
        for key in ('referenceCommit', 'corpusSHA256', 'engine'):
            with self.subTest(key=key):
                original = self.swift[key]
                self.swift[key] = 'stale'
                with self.assertRaises(ValueError):
                    self.compare()
                self.swift[key] = original

    def test_missing_duplicate_and_unknown_cases_are_rejected(self):
        original = copy.deepcopy(self.swift['results'])
        for rows in (original[:-1], original + [original[0]], [dict(original[0], id='unknown')] + original[1:]):
            self.swift['results'] = rows
            with self.assertRaises(ValueError):
                self.compare()

    def test_missing_variables_and_coerced_values_are_rejected(self):
        self.swift['results'][0]['values'] = [3]
        with self.assertRaises(ValueError):
            self.compare()
        self.swift['results'][0]['values'] = ['synthetic']
        row = next(row for row in self.swift['results'] if row['variables'])
        row['variables'] = {}
        with self.assertRaises(ValueError):
            self.compare()

    def test_sanity_anchor_catches_empty_execution(self):
        row = next(row for row in self.swift['results'] if row['id'] == 'js-execution-anchor')
        row['values'] = []
        with self.assertRaises(ValueError):
            self.compare()


if __name__ == '__main__':
    unittest.main()
