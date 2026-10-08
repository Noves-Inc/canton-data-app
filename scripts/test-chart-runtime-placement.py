#!/usr/bin/env python3
"""Focused client-only Helm contracts; fixtures are synthetic, not install inputs."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'chart/noves-canton-data-app'
BASE = '71730eb4222806e2fa45eee0f7cd1fdc4e5a4672'
COMMON = {
    'oidc': {'provider': 'auth0', 'appUrl': 'https://data.example.invalid',
             'auth0': {'domain': 'tenant.example.invalid', 'clientId': 'test-only',
                       'audience': 'https://test.example.invalid'}},
    'installation': {'kek': {'existingSecret': 'test-only-existing-kek'},
                     'canary': {'existingSecret': 'test-only-existing-canary'}},
    'accounting': {'tokenEncryption': {'existingSecret': 'test-only-existing-accounting'}},
}
TOLERATION = {'key': 'r08.noves.fi/dedicated', 'operator': 'Equal',
              'value': 'services', 'effect': 'NoSchedule'}


def merge(left, right):
    result = copy.deepcopy(left)
    for key, value in right.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


class RuntimePlacement(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix='cda-placement-offline-')
        cls.tmp = Path(cls.scratch.name)
        cls.env = dict(os.environ, KUBECONFIG=str(cls.tmp / 'empty-kubeconfig'))
        (cls.tmp / 'empty-kubeconfig').write_text('')
        # Fresh base chart from immutable Git bytes, without altering any worktree.
        cls.baseline = cls.tmp / 'baseline'
        cls.baseline.mkdir()
        archive = subprocess.check_output(['git', '-C', str(ROOT), 'archive', BASE,
                                           'chart/noves-canton-data-app'])
        subprocess.run(['tar', '-x', '-C', str(cls.baseline)], input=archive, check=True)
        cls.oldchart = cls.baseline / 'chart/noves-canton-data-app'
        cls.reusechart = cls.tmp / 'reuse-chart-with-old-values'
        shutil.copytree(CHART, cls.reusechart)
        shutil.copyfile(cls.oldchart / 'values.yaml', cls.reusechart / 'values.yaml')

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def render(self, values=None, chart=CHART, expect_success=True):
        inputs = self.tmp / 'test-only-values.json'
        inputs.write_text(json.dumps(merge(COMMON, values or {})))
        result = subprocess.run(['helm', 'template', 'test-only', str(chart),
                                 '--namespace', 'test-only', '-f', str(inputs)],
                                env=self.env, capture_output=True, text=True)
        if not expect_success:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return list(yaml.safe_load_all(result.stdout))

    @staticmethod
    def workload(docs, component):
        return next(d for d in docs if d and d.get('kind') in ('Deployment', 'StatefulSet')
                    and d['metadata'].get('labels', {}).get('app.kubernetes.io/component') == component)

    def test_default_semantics_match_immutable_baseline(self):
        self.assertEqual(self.render(chart=self.oldchart), self.render())

    def test_inherited_global_semantics_match_baseline(self):
        values = {'nodeSelector': {'old-pool': 'true'}, 'tolerations': [TOLERATION]}
        self.assertEqual(self.render(values, chart=self.oldchart), self.render(values))

    def test_application_optin_keeps_entire_database_workload_unchanged(self):
        original = self.render()
        values = {c: {'nodeSelector': {'agentpool': 'r08apps'}, 'tolerations': [TOLERATION],
                      'serviceAccountName': 'test-only-' + c, 'automountServiceAccountToken': False}
                  for c in ('backend', 'frontend')}
        changed = self.render(values)
        self.assertEqual(self.workload(original, 'database'), self.workload(changed, 'database'))
        for c in ('backend', 'frontend'):
            pod = self.workload(changed, c)['spec']['template']['spec']
            self.assertEqual(pod['nodeSelector'], {'agentpool': 'r08apps'})
            self.assertEqual(pod['tolerations'], [TOLERATION])
            self.assertEqual(pod['serviceAccountName'], 'test-only-' + c)
            self.assertIs(pod['automountServiceAccountToken'], False)
        self.assertFalse(any(d and d['kind'] in ('ServiceAccount', 'Role', 'RoleBinding',
                                               'ClusterRole', 'ClusterRoleBinding') for d in changed))

    def test_each_component_identity_and_token_setting(self):
        for c in ('backend', 'frontend', 'database'):
            for mount in (False, True):
                with self.subTest(component=c, mount=mount):
                    docs = self.render({c: {'serviceAccountName': 'test-only-' + c,
                                            'automountServiceAccountToken': mount}})
                    for other in ('backend', 'frontend', 'database'):
                        pod = self.workload(docs, other)['spec']['template']['spec']
                        self.assertIs(pod['automountServiceAccountToken'], mount if other == c else False)
                        self.assertEqual(pod.get('serviceAccountName'), 'test-only-' + c if other == c else None)

    def test_explicit_empty_component_placement_clears_global(self):
        docs = self.render({'nodeSelector': {'old-pool': 'true'}, 'tolerations': [TOLERATION],
                            'backend': {'nodeSelector': {}, 'tolerations': []}})
        for c in ('backend', 'frontend', 'database'):
            pod = self.workload(docs, c)['spec']['template']['spec']
            if c == 'backend':
                self.assertNotIn('nodeSelector', pod)
                self.assertNotIn('tolerations', pod)
            else:
                self.assertEqual(pod['nodeSelector'], {'old-pool': 'true'})
                self.assertEqual(pod['tolerations'], [TOLERATION])

    def test_null_component_placement_inherits_global(self):
        global_values = {'nodeSelector': {'old-pool': 'true'}, 'tolerations': [TOLERATION]}
        values = merge(global_values, {'backend': {'nodeSelector': None, 'tolerations': None}})
        self.assertEqual(self.render(global_values, chart=self.oldchart), self.render(values))

    def test_component_wrong_types_names_and_tolerations_are_rejected(self):
        bad = [('serviceAccountName', True), ('serviceAccountName', 'Bad Name'),
               ('serviceAccountName', 'a' * 254), ('automountServiceAccountToken', 'false'),
               ('nodeSelector', ['wrong']), ('nodeSelector', {'agentpool': 3}),
               ('tolerations', {}), ('tolerations', [{'effect': 'Always'}]),
               ('tolerations', [{'tolerationSeconds': -1}])]
        for c in ('backend', 'frontend', 'database'):
            for field, value in bad:
                with self.subTest(component=c, field=field, value=value):
                    error = self.render({c: {field: value}}, expect_success=False)
                    self.assertIn(field, error)

    def test_old_values_without_new_properties_keep_token_and_sa_semantics(self):
        # New templates/schema with the old values.yaml actually omit all new properties.
        self.assertEqual(self.render(chart=self.oldchart), self.render(chart=self.reusechart))

    def test_native_lint(self):
        values = self.tmp / 'lint-test-only-values.json'
        values.write_text(json.dumps(COMMON))
        result = subprocess.run(['helm', 'lint', str(CHART), '-f', str(values)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
