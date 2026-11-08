"""Ensure API defaults do not obscure meaningful policy differences."""
import unittest
from audit import normalized


class PolicyComparison(unittest.TestCase):
    def test_protocol_default_is_equivalent_but_udp_is_not(self):
        spec = {'podSelector': {}, 'ingress': [{'ports': [{'port': 53}]}]}
        tcp = {'podSelector': {}, 'policyTypes': ['Ingress'],
               'ingress': [{'ports': [{'port': 53, 'protocol': 'TCP'}]}]}
        self.assertEqual(normalized(spec), normalized(tcp))
        tcp['ingress'][0]['ports'][0]['protocol'] = 'UDP'
        self.assertNotEqual(normalized(spec), normalized(tcp))
        self.assertNotIn('policyTypes', spec)

    def test_missing_policy_is_not_empty_policy(self):
        self.assertNotEqual(normalized(None), normalized({'podSelector': {}}))


if __name__ == '__main__':
    unittest.main()
