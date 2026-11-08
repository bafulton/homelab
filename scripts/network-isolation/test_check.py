"""Regression tests for false denial evidence and cleanup on infrastructure failures."""
import argparse
import subprocess
import unittest
from unittest.mock import patch
from check import Harness


class HarnessFailures(unittest.TestCase):
    def setUp(self):
        self.h = Harness(argparse.Namespace(context='test', targets=None, nodes=['node-a'],
                                             image='example', enforce=True))

    def test_exec_errors_are_not_policy_denials(self):
        for result in (subprocess.CompletedProcess([], 1, '', 'error: pod not found'),
                       subprocess.CompletedProcess([], 2, 'DNS lookup failed', ''),
                       subprocess.CompletedProcess([], 137, '', '')):
            with self.subTest(result=result), patch('check.subprocess.run', return_value=result):
                self.h.record('egress', 'deny-0', 'server', 'deny', ['code'])
                self.assertFalse(self.h.results[-1]['passed'])
                self.assertEqual(self.h.results[-1]['observed'], 'error')

    def test_failed_setup_removes_only_generated_namespace(self):
        def call(*args, **kwargs):
            if args[:2] == ('get', 'nodes'):
                return '{"items":[{"metadata":{"name":"node-a"}}]}'
            if args[:2] == ('get', 'service'):
                return '{"spec":{"clusterIP":"10.96.0.10"}}'
            return ''
        calls = []
        with patch.object(self.h, 'call', side_effect=call) as command, patch.object(self.h, 'apply') as apply:
            def fail_pod(obj):
                calls.append(obj)
                if obj['kind'] == 'Pod':
                    raise RuntimeError('image/setup failure')
            apply.side_effect = fail_pod
            with self.assertRaisesRegex(RuntimeError, 'setup failure'):
                self.h.execute()
            command.assert_any_call('delete', 'namespace', self.h.ns, '--wait=true', '--timeout=120s')
            self.assertTrue(self.h.ns.startswith('cat6-probe-'))
            self.assertEqual(calls[0]['kind'], 'Namespace')


if __name__ == '__main__':
    unittest.main()
