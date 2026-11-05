"""Exercise the cleanup script with a fake kubectl; no cluster is needed."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "files/replicaset-cleanup.sh"


def deployment(namespace, uid, replicas=1, complete=True):
    return {
        "kind": "Deployment",
        "metadata": {"namespace": namespace, "name": "shared", "uid": uid, "generation": 1},
        "spec": {"replicas": replicas},
        "status": {
            "observedGeneration": 1,
            "replicas": replicas,
            "updatedReplicas": replicas if complete else 0,
            "availableReplicas": replicas,
        },
    }


def replicaset(namespace, owner_uid, index, replicas=0, owner_name="shared"):
    name = f"{namespace}-{owner_uid}-{index}"
    return {
        "kind": "ReplicaSet",
        "metadata": {
            "namespace": namespace,
            "name": name,
            "uid": name,
            "resourceVersion": "1",
            "creationTimestamp": f"2026-01-01T00:00:{index:02d}Z",
            "ownerReferences": [{
                "kind": "Deployment", "name": owner_name,
                "uid": owner_uid, "controller": True,
            }],
        },
        "spec": {"replicas": replicas},
        "status": {"replicas": replicas},
    }


class CleanupTest(unittest.TestCase):
    def run_cleanup(self, objects, changed=None, keep="3"):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "snapshot.json").write_text(json.dumps({"items": objects}))
            (root / "changed.json").write_text(json.dumps(changed or {}))
            fake = root / "kubectl"
            fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FAKE_ROOT"])
args = sys.argv[1:]
items = json.loads((root / "snapshot.json").read_text())["items"]
if args[:2] == ["get", "deployments,replicasets"]:
    print(json.dumps({"items": items}))
elif args[0] == "get":
    kind = "Deployment" if args[1] == "deployment" else "ReplicaSet"
    ns = args[args.index("-n") + 1]
    name = args[args.index("-n") + 2]
    obj = next(x for x in items if x["kind"] == kind and
               x["metadata"]["namespace"] == ns and x["metadata"]["name"] == name)
    changed = json.loads((root / "changed.json").read_text())
    obj = changed.get(f"{kind}/{ns}/{name}", obj)
    print(json.dumps(obj))
elif args[0] == "delete":
    with (root / "deleted.txt").open("a") as output:
        output.write(f"{args[args.index('-n') + 1]}/{args[args.index('-n') + 2]}\\n")
else:
    raise SystemExit(f"unexpected kubectl call: {args}")
''')
            fake.chmod(0o755)
            env = os.environ | {
                "PATH": f"{root}:{os.environ['PATH']}",
                "FAKE_ROOT": directory,
                "KEEP_PER_DEPLOYMENT": keep,
            }
            result = subprocess.run(["sh", str(SCRIPT)], env=env, text=True,
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            deleted = root / "deleted.txt"
            return set(deleted.read_text().splitlines()) if deleted.exists() else set()

    def test_namespace_uid_and_scaled_down_protection(self):
        objects = []
        for namespace, uid, replicas in [
            ("alpha", "uid-a", 1), ("beta", "uid-b", 1),
            ("zero", "uid-z", 0),
        ]:
            objects.append(deployment(namespace, uid, replicas))
            objects += [replicaset(namespace, uid, i) for i in range(1, 6)]
            objects.append(replicaset(namespace, uid, 6, replicas))
        # A ReplicaSet left by a deleted Deployment must not count toward the
        # new Deployment's history, even when the name is reused.
        objects.append(replicaset("alpha", "old-uid", 0))
        self.assertEqual(self.run_cleanup(objects), {
            "alpha/alpha-uid-a-1", "alpha/alpha-uid-a-2",
            "beta/beta-uid-b-1", "beta/beta-uid-b-2",
        })

    def test_incomplete_rollout_and_changed_candidate_are_skipped(self):
        objects = [deployment("alpha", "uid-a"), deployment("beta", "uid-b", complete=False)]
        for namespace, uid in [("alpha", "uid-a"), ("beta", "uid-b")]:
            objects += [replicaset(namespace, uid, i) for i in range(1, 6)]
            objects.append(replicaset(namespace, uid, 6, 1))
        changed = replicaset("alpha", "uid-a", 1, 1)
        self.assertEqual(self.run_cleanup(objects, {
            "ReplicaSet/alpha/alpha-uid-a-1": changed,
        }), {"alpha/alpha-uid-a-2"})

    def test_scale_down_after_snapshot_skips_deletion(self):
        objects = [deployment("alpha", "uid-a")]
        objects += [replicaset("alpha", "uid-a", i) for i in range(1, 6)]
        objects.append(replicaset("alpha", "uid-a", 6, 1))
        self.assertEqual(self.run_cleanup(objects, {
            "Deployment/alpha/shared": deployment("alpha", "uid-a", replicas=0),
        }), set())


if __name__ == "__main__":
    unittest.main()
