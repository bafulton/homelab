"""Exercise the host-rule reconciler without changing host networking."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "files/reconcile.sh"
FUNCTIONS = SCRIPT.read_text().split('log "enabled=', 1)[0]
IP_MOCK = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(os.environ["RULES_FILE"])
rules = json.loads(path.read_text())
args = sys.argv[1:]
if args == ["-4", "-j", "rule", "list"]:
    print(json.dumps(rules))
    sys.exit(0)
if len(args) < 3 or args[:2] != ["-4", "rule"] or args[2] not in ("add", "del"):
    sys.exit(2)
cidr = args[args.index("to") + 1]
address, bits = cidr.split("/")
rule = {"priority": int(args[args.index("priority") + 1]),
        "protocol": args[args.index("protocol") + 1],
        "table": args[args.index("table") + 1], "src": "all",
        "dst": address, "dstlen": int(bits)}
if args[2] == "add":
    if cidr == os.environ.get("FAIL_ADD_CIDR"):
        print("injected add failure", file=sys.stderr)
        sys.exit(1)
    rules.append(rule)
else:
    try:
        rules.remove(rule)
    except ValueError:
        sys.exit(1)
path.write_text(json.dumps(rules))
'''
KUBECTL_MOCK = '''#!/bin/sh
if [ "$DISCOVERY_FAIL" = true ]; then
  echo "API unavailable" >&2
  exit 1
fi
cat "$NODES_FILE"
'''


def rule(cidr, protocol="242", priority=5260):
    address, bits = cidr.split("/")
    return {"priority": priority, "protocol": protocol, "table": "main",
            "src": "all", "dst": address, "dstlen": int(bits)}


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        for name, content in (("ip", IP_MOCK), ("kubectl", KUBECTL_MOCK)):
            path = root / name
            path.write_text(content)
            path.chmod(0o755)
        self.rules_file = root / "rules.json"
        self.nodes_file = root / "nodes.json"
        self.env = {**os.environ, "PATH": f'{root}:{os.environ["PATH"]}',
                    "RULES_FILE": str(self.rules_file), "NODES_FILE": str(self.nodes_file),
                    "ENABLED": "true", "DISCOVERY_FAIL": "false", "NODE_NAME": "beelink",
                    "SELECTOR": "homelab.io/location=local", "LANCIDR": "192.168.1.0/24",
                    "PRIORITY": "5260"}
        self.set_rules([])
        self.set_nodes([("beelink", "10.244.0.0/24"), ("rpi5", "10.244.1.0/24")])

    def set_rules(self, rules):
        self.rules_file.write_text(json.dumps(rules))

    def set_nodes(self, nodes):
        self.nodes_file.write_text(json.dumps({"items": [
            {"metadata": {"name": name}, "spec": {"podCIDR": cidr}}
            for name, cidr in nodes]}))

    def run_reconcile(self):
        result = subprocess.run(["sh", "-c", FUNCTIONS + "\nreconcile"],
                                env=self.env, text=True, capture_output=True)
        return result, json.loads(self.rules_file.read_text())

    def test_cidr_change_and_removed_peer_prune_only_owned_rules(self):
        unrelated = rule("10.244.99.0/24", protocol="static")
        legacy = rule("10.244.1.0/24", protocol="boot")
        self.set_rules([rule("192.168.1.0/24"), rule("10.244.1.0/24"),
                        unrelated, legacy])
        self.set_nodes([("beelink", "10.244.0.0/24"), ("rpi5", "10.244.2.0/24")])
        result, rules = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertCountEqual(rules, [rule("192.168.1.0/24"),
                                      rule("10.244.2.0/24"), unrelated, legacy])
        self.set_nodes([("beelink", "10.244.0.0/24")])
        result, rules = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(rule("10.244.2.0/24"), rules)

    def test_failed_or_incomplete_discovery_preserves_rules(self):
        original = [rule("10.244.1.0/24")]
        self.set_rules(original)
        self.env["DISCOVERY_FAIL"] = "true"
        result, rules = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(rules, original)
        self.assertIn("node discovery failed", result.stderr)
        self.env["DISCOVERY_FAIL"] = "false"
        self.set_nodes([("beelink", "10.244.0.0/24"), ("rpi5", "")])
        result, rules = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(rules, original)

    def test_disable_removes_only_owned_rules(self):
        unrelated = rule("10.244.99.0/24", priority=5260, protocol="static")
        self.set_rules([rule("192.168.1.0/24"), rule("10.244.1.0/24"), unrelated])
        self.env["ENABLED"] = "false"
        self.env["DISCOVERY_FAIL"] = "true"
        result, rules = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rules, [unrelated])

    def test_add_failure_does_not_prune_previous_rules(self):
        original = [rule("10.244.1.0/24")]
        self.set_rules(original)
        self.set_nodes([("beelink", "10.244.0.0/24"), ("rpi5", "10.244.2.0/24")])
        self.env["FAIL_ADD_CIDR"] = "10.244.2.0/24"
        result, rules = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(rule("10.244.1.0/24"), rules)
        self.assertIn("failed to add rule", result.stderr)


if __name__ == "__main__":
    unittest.main()
