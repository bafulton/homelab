"""Focused reconciliation tests without a Kubernetes cluster or multicast socket."""

import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch


class FakeServiceInfo:
    def __init__(self, type_, name, *, addresses, port, properties, server):
        self.type = type_
        self.name = name
        self.addresses = addresses
        self.port = port
        self.properties = properties
        self.server = server


class FakeZeroconf:
    def __init__(self):
        self.active = set()
        self.calls = []
        self.fail_on = None
        self.fail_always_on = None

    def register_service(self, info, **kwargs):
        self.calls.append(("register", info))
        if self.fail_always_on == info.type:
            raise RuntimeError("registration failed")
        if self.fail_on == info.type:
            self.fail_on = None
            raise RuntimeError("registration failed")
        self.active.add(info)

    def unregister_service(self, info):
        self.calls.append(("unregister", info))
        self.active.remove(info)


def load_advertiser():
    kubernetes = types.ModuleType("kubernetes")
    kubernetes.client = types.SimpleNamespace()
    kubernetes.config = types.SimpleNamespace()
    zeroconf = types.ModuleType("zeroconf")
    zeroconf.ServiceInfo = FakeServiceInfo
    zeroconf.Zeroconf = FakeZeroconf
    path = Path(__file__).with_name("advertiser.py")
    spec = importlib.util.spec_from_file_location("advertiser", path)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {
        "kubernetes": kubernetes, "zeroconf": zeroconf, "advertiser": module
    }):
        spec.loader.exec_module(module)
    return module


class AdvertiserTests(unittest.TestCase):
    def setUp(self):
        self.advertiser = load_advertiser()
        self.advertiser.zc = FakeZeroconf()
        self.config = {
            "name": "Example",
            "hostname": "example",
            "ip": "192.168.1.20",
            "port": 80,
            "types": [
                {"type": "_http._tcp", "txtRecords": ["path=/"]},
                {"type": "_demo._tcp", "txtRecords": ["key=value"]},
            ],
        }
        self.items = []
        self.advertiser.v1 = types.SimpleNamespace(
            list_config_map_for_all_namespaces=self.list_configmaps
        )

    def list_configmaps(self, **kwargs):
        return types.SimpleNamespace(items=self.items)

    def set_config(self, value):
        self.items = [types.SimpleNamespace(
            metadata=types.SimpleNamespace(namespace="test", name="example"),
            data={"config.json": json.dumps(value)},
        )]

    def test_each_published_field_updates_and_unchanged_config_does_not_churn(self):
        self.set_config(self.config)
        self.assertTrue(self.advertiser.sync_services())
        self.assertEqual(len(self.advertiser.zc.active), 2)
        self.advertiser.zc.calls.clear()
        self.assertFalse(self.advertiser.sync_services())
        self.assertEqual(self.advertiser.zc.calls, [])

        changes = [
            ("name", "Renamed"),
            ("hostname", "new-host"),
            ("ip", "192.168.1.21"),
            ("port", 8080),
        ]
        for field, value in changes:
            self.config[field] = value
            self.set_config(self.config)
            self.assertTrue(self.advertiser.sync_services(), field)
            self.assertEqual(len(self.advertiser.zc.active), 2)

        self.config["types"][0]["type"] = "_web._tcp"
        self.set_config(self.config)
        self.assertTrue(self.advertiser.sync_services())
        self.assertIn("_web._tcp.local.", {i.type for i in self.advertiser.zc.active})

        self.config["types"][0]["txtRecords"] = ["path=/new"]
        self.set_config(self.config)
        self.assertTrue(self.advertiser.sync_services())
        self.assertIn({"path": "/new"}, [i.properties for i in self.advertiser.zc.active])

        self.advertiser.zc.calls.clear()
        self.config["ignored"] = "no change to published records"
        self.set_config(self.config)
        self.assertFalse(self.advertiser.sync_services())
        self.assertEqual(self.advertiser.zc.calls, [])

    def test_deleted_configmap_removes_all_records(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        self.items = []
        self.assertTrue(self.advertiser.sync_services())
        self.assertFalse(self.advertiser.zc.active)
        self.assertFalse(self.advertiser.registered_services)

    def test_invalid_edit_and_failed_list_preserve_existing_records(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        original = set(self.advertiser.zc.active)
        self.config["ip"] = "invalid"
        self.set_config(self.config)
        self.assertFalse(self.advertiser.sync_services())
        self.assertEqual(self.advertiser.zc.active, original)

        self.advertiser.v1.list_config_map_for_all_namespaces = (
            lambda **kwargs: (_ for _ in ()).throw(RuntimeError("API unavailable"))
        )
        with self.assertRaisesRegex(RuntimeError, "API unavailable"):
            self.advertiser.sync_services()
        self.assertEqual(self.advertiser.zc.active, original)

    def test_partial_registration_failure_cleans_new_and_restores_old(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        original = set(self.advertiser.zc.active)
        self.config["port"] = 8080
        self.set_config(self.config)
        self.advertiser.zc.fail_on = "_demo._tcp.local."
        self.assertFalse(self.advertiser.sync_services())
        self.assertEqual(self.advertiser.zc.active, original)
        self.assertEqual(
            self.advertiser.registered_services["test/example"].port, 80
        )

    def test_partial_initial_registration_failure_leaves_no_records(self):
        self.set_config(self.config)
        self.advertiser.zc.fail_on = "_demo._tcp.local."
        self.assertFalse(self.advertiser.sync_services())
        self.assertFalse(self.advertiser.zc.active)
        self.assertFalse(self.advertiser.registered_services)

    def test_failed_rollback_does_not_leave_stale_tracking(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        self.config["port"] = 8080
        self.set_config(self.config)
        self.advertiser.zc.fail_always_on = "_demo._tcp.local."
        self.assertFalse(self.advertiser.sync_services())
        self.assertFalse(self.advertiser.zc.active)
        self.assertFalse(self.advertiser.registered_services)
        self.advertiser.zc.fail_always_on = None
        self.assertTrue(self.advertiser.sync_services())
        self.assertEqual(len(self.advertiser.zc.active), 2)


if __name__ == "__main__":
    unittest.main()
