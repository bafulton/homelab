#!/usr/bin/env python3
"""Behavioral tests for safe-reboot-node.sh; every external command is mocked."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "safe-reboot-node.sh"
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
case = os.environ.get("CASE", "success")
log = pathlib.Path(os.environ["MOCK_LOG"])
with log.open("a") as f:
    f.write(name + " " + " ".join(args) + "\n")
def out(value):
    print(json.dumps(value) if not isinstance(value, str) else value)
def fail():
    sys.exit(1)
if name == "sleep":
    sys.exit(0)
if name == "yq":
    out({"endpoint":"https://beelink.catfish-mountain.ts.net:6443",
         "nodes":[{"name":"beelink","lanIP":"192.168.1.86"}]})
    sys.exit(0)
if name == "talosctl":
    if args[:2] != ["--context", "homelab"]: fail()
    if "info" in args:
        out({"context":"homelab", "endpoints": ["wrong.example"] if case == "talos_target" else ["beelink.catfish-mountain.ts.net"]})
    elif "reboot" in args:
        if case == "reboot_error": fail()
    else: fail()
    sys.exit(0)
if name != "kubectl" or args[:2] != ["--context", "homelab"]: fail()
a = args[2:]
if a[:2] == ["config", "view"]:
    out({"contexts":[{"name":"homelab"}], "clusters":[{"cluster":{"server": "https://wrong.example:6443" if case == "kube_target" else "https://beelink.catfish-mountain.ts.net:6443"}}]})
elif a[:2] == ["get", "node"]:
    if "-o" in a and "jsonpath" in a[a.index("-o")+1]:
        if case == "boot_timeout": fail()
        out("new-boot")
    else:
        out({"metadata":{"name":"beelink"},"status":{"nodeInfo":{"bootID":"old-boot"}}})
elif a[0] in ("cordon", "drain", "uncordon"):
    if a[0] == "drain" and case == "drain_error": fail()
elif a[:2] == ["get", "volumes.longhorn.io"]:
    if case == "volume_api": fail()
    if case == "volume_parse":
        out("not-json")
        sys.exit(0)
    if case == "volume_incomplete":
        out({"items":[{"metadata":{"name":"v"},"spec":{"nodeID":""},"status":{"currentNodeID":"beelink"}}]})
        sys.exit(0)
    attached = case in ("detach_pending", "detach_timeout")
    count = sum(1 for line in log.read_text().splitlines() if "get volumes.longhorn.io" in line)
    out({"items":[{"metadata":{"name":"v"},"spec":{"nodeID":""},"status":{"currentNodeID":"beelink" if attached and (case == "detach_timeout" or count == 1) else "", "state":"detaching" if attached and (case == "detach_timeout" or count == 1) else "detached"}}]})
elif a[:2] == ["get", "pods"]:
    if case == "pod_api": fail()
    if case == "pod_parse": out("not-json"); sys.exit(0)
    pod = {"metadata":{"name":"app","namespace":"default"},"spec":{"nodeName":"beelink","volumes":[{"persistentVolumeClaim":{"claimName":"data"}}]}}
    out({"items":[pod] if case == "pvc_pod" else []})
elif a[0] == "wait":
    if case == "ready_error": fail()
else: fail()
'''

class SafeRebootTests(unittest.TestCase):
    def run_case(self, case, expected_reboot, expected_uncordon=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for name in ("kubectl", "talosctl", "yq", "sleep"):
                path = root / name
                path.write_text(MOCK)
                path.chmod(0o755)
            log = root / "calls"
            log.touch()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", CASE=case, MOCK_LOG=str(log),
                       SAFE_REBOOT_DETACH_TIMEOUT="0" if case == "detach_timeout" else "180",
                       SAFE_REBOOT_RECOVERY_TIMEOUT="0" if case == "boot_timeout" else "600")
            result = subprocess.run(["bash", str(SCRIPT), "beelink"], env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            calls = log.read_text()
            self.assertEqual("talosctl --context homelab -n 192.168.1.86 -e 192.168.1.86 reboot --wait=false" in calls,
                             expected_reboot, (case, result.stdout, result.stderr, calls))
            self.assertEqual("kubectl --context homelab uncordon beelink" in calls, expected_uncordon, case)
            self.assertEqual(result.returncode == 0, case in ("success", "detach_pending"),
                             (case, result.stdout, result.stderr))
            self.assertNotIn("kubectl --context other", calls)

    def test_success_ignores_current_context(self):
        self.run_case("success", True, True)

    def test_failures_before_reboot_leave_cordon(self):
        for case in ("drain_error", "volume_api", "volume_parse", "volume_incomplete",
                     "detach_timeout", "pod_api", "pod_parse", "pvc_pod"):
            with self.subTest(case=case):
                self.run_case(case, False)

    def test_pending_detach_eventually_completes(self):
        self.run_case("detach_pending", True, True)

    def test_wrong_targets_abort_before_cordon(self):
        for case in ("kube_target", "talos_target"):
            with self.subTest(case=case):
                self.run_case(case, False)

    def test_recovery_failures_remain_cordoned(self):
        for case in ("reboot_error", "boot_timeout", "ready_error"):
            with self.subTest(case=case):
                self.run_case(case, True)

if __name__ == "__main__":
    unittest.main()
