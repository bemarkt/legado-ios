import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('legado_regression', ROOT / 'scripts/verify-legado-regression.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RegressionEvidenceTests(unittest.TestCase):
    def setUp(self):
        data = (ROOT / 'protocols/legado-compatibility/corpus.json').read_bytes()
        self.corpus = json.loads(data)
        self.digest = hashlib.sha256(data).hexdigest()
        self.expected = json.loads((ROOT / 'protocols/legado-compatibility/expectations.json').read_text(encoding='utf-8'))
        rows = []
        for case in self.expected['cases']:
            row = {key: copy.deepcopy(case[key]) for key in ('id', 'outcome', 'values', 'variables')}
            row['errors'] = [dict(item, message='Synthetic diagnostic') for item in case['diagnostics']]
            rows.append(row)
        self.observed = {'schemaVersion': 1, 'engine': 'swift-legacy-rule-engine',
                         'referenceCommit': self.corpus['referenceCommit'], 'corpusSHA256': self.digest,
                         'results': rows}

    def verify(self):
        return MODULE.verify(self.corpus, self.digest, self.expected, self.observed)

    def test_reviewed_profile_does_not_claim_full_provider(self):
        report = self.verify()
        self.assertEqual(report['checked'], 29)
        self.assertFalse(report['failures'])
        self.assertEqual(report['providerCompatibility'], 'not-evaluated')

    def test_numeric_difference_remains_explicit(self):
        row = next(row for row in self.observed['results'] if row['id'] == 'js-arithmetic')
        row['values'] = ['3.0']
        failure = self.verify()['failures'][0]
        self.assertEqual(failure['field'], 'values')
        self.assertEqual(failure['expected'], ['3'])

    def test_errors_cannot_be_silently_accepted(self):
        row = next(row for row in self.observed['results'] if row['id'] == 'js-throw')
        row['errors'][0]['code'] = 'rule.resource_limit'
        self.assertEqual(self.verify()['failures'][0]['field'], 'diagnostics')

    def test_wrong_order_or_scope_is_a_failure(self):
        row = next(row for row in self.observed['results'] if row['id'] == 'json-list')
        row['values'].reverse()
        row = next(row for row in self.observed['results'] if row['id'] == 'js-put-get')
        row['variables']['token'] = 'other-account'
        self.assertEqual(len(self.verify()['failures']), 2)

    def test_stale_expectations_require_review(self):
        for key in ('referenceCommit', 'corpusSHA256'):
            previous = self.expected[key]
            self.expected[key] = 'stale'
            with self.assertRaises(ValueError): self.verify()
            self.expected[key] = previous
        self.expected['cases'].pop()
        with self.assertRaises(ValueError): self.verify()


if __name__ == '__main__':
    unittest.main()
