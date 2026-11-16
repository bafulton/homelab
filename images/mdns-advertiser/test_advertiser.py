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
        if any(active.name == info.name for active in self.active):
            raise RuntimeError(f"{info.name} is already registered")
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
        self.services = []
        self.routes = []
        self.gateways = {}
        self.advertiser.v1 = types.SimpleNamespace(
            list_service_for_all_namespaces=lambda **kwargs: types.SimpleNamespace(items=self.services),
        )
        self.advertiser.custom = types.SimpleNamespace(
            list_cluster_custom_object=lambda *args, **kwargs: {"items": self.routes},
            get_namespaced_custom_object=lambda group, version, ns, plural, name: self.gateways[(ns, name)],
        )

    def service(self, annotations, ip="192.168.1.201", port=445, name="time-machine"):
        ingress = [types.SimpleNamespace(ip=ip)] if ip else []
        return types.SimpleNamespace(
            metadata=types.SimpleNamespace(namespace="test", name=name, annotations=annotations),
            spec=types.SimpleNamespace(ports=[types.SimpleNamespace(port=port)]),
            status=types.SimpleNamespace(load_balancer=types.SimpleNamespace(ingress=ingress)),
        )

    def route(self, annotations, hostnames, section="local"):
        return {
            "metadata": {"namespace": "app", "name": "app-local", "annotations": annotations},
            "spec": {
                "hostnames": hostnames,
                "parentRefs": [{"name": "traefik-apps", "namespace": "traefik-apps", "sectionName": section}],
            },
        }

    def published(self):
        return {(i.type, i.name, i.server, i.port, i.addresses[0]) for i in self.advertiser.zc.active}

    def set_config(self, value):
        """Publish a record config as an annotated Service, test/example."""
        annotations = {
            "mdns.homelab.io/hostname": value["hostname"],
            "mdns.homelab.io/name": value["name"],
            "mdns.homelab.io/ip": value["ip"],
            "mdns.homelab.io/port": str(value["port"]),
            "mdns.homelab.io/types": json.dumps(value["types"]),
        }
        annotations.update(value.get("extra", {}))
        self.services = [self.service(annotations, name="example")]

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
        self.config["extra"] = {"other.example.com/unrelated": "no change to published records"}
        self.set_config(self.config)
        self.assertFalse(self.advertiser.sync_services())
        self.assertEqual(self.advertiser.zc.calls, [])

    def test_deleted_service_removes_all_records(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        self.services = []
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

        self.advertiser.custom.list_cluster_custom_object = (
            lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("API unavailable"))
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
            self.advertiser.registered_services["service:test/example"].port, 80
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

    def test_service_annotations_publish_at_the_load_balancer_address(self):
        self.services = [self.service({
            "mdns.homelab.io/hostname": "timemachine",
            "mdns.homelab.io/name": "Time Machine",
            "mdns.homelab.io/types": json.dumps([
                {"type": "_smb._tcp"},
                {"type": "_adisk._tcp", "txtRecords": ["sys=adVF=0x100", "dk0=adVN=Family,adVF=0x82"]},
            ]),
        })]
        self.assertTrue(self.advertiser.sync_services())
        address = self.advertiser.socket.inet_aton("192.168.1.201")
        self.assertEqual(self.published(), {
            ("_smb._tcp.local.", "Time Machine._smb._tcp.local.", "timemachine.local.", 445, address),
            ("_adisk._tcp.local.", "Time Machine._adisk._tcp.local.", "timemachine.local.", 445, address),
        })
        adisk = [i for i in self.advertiser.zc.active if i.type == "_adisk._tcp.local."][0]
        self.assertEqual(adisk.properties, {"sys": "adVF=0x100", "dk0": "adVN=Family,adVF=0x82"})

    def test_malformed_json_types_keep_the_published_records(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        original = set(self.advertiser.zc.active)
        self.services[0].metadata.annotations["mdns.homelab.io/types"] = '[{"type": '
        self.assertFalse(self.advertiser.sync_services())
        self.assertEqual(self.advertiser.zc.active, original)

    def test_service_without_an_address_waits_and_ip_annotation_overrides(self):
        self.services = [self.service({"mdns.homelab.io/hostname": "pending"}, ip=None)]
        self.assertFalse(self.advertiser.sync_services())
        self.assertFalse(self.advertiser.zc.active)

        self.services = [self.service({
            "mdns.homelab.io/hostname": "fulton-fun-minecraft",
            "mdns.homelab.io/ip": "192.168.1.210",
            "mdns.homelab.io/port": "25565",
        }, ip=None, name="fulton-fun")]
        self.assertTrue(self.advertiser.sync_services())
        info = next(iter(self.advertiser.zc.active))
        self.assertEqual((info.type, info.server, info.port, info.addresses[0]), (
            "_http._tcp.local.", "fulton-fun-minecraft.local.", 25565,
            self.advertiser.socket.inet_aton("192.168.1.210")))

    def test_unannotated_services_and_routes_are_ignored(self):
        self.services = [self.service({"other": "annotation"})]
        self.routes = [self.route({}, ["app.local"])]
        self.assertFalse(self.advertiser.sync_services())
        self.assertFalse(self.advertiser.zc.active)

    def test_route_local_hostnames_publish_at_the_gateway_address(self):
        self.gateways[("traefik-apps", "traefik-apps")] = {
            "spec": {"listeners": [{"name": "web", "port": 80}, {"name": "local", "port": 443}]},
            "status": {"addresses": [{"type": "IPAddress", "value": "192.168.1.200"}]},
        }
        self.routes = [self.route({
            "mdns.homelab.io/advertise": "true",
            "mdns.homelab.io/name": "BottleShip",
            "mdns.homelab.io/types": "_https._tcp",
        }, ["games.fultonhuffman.com", "games.local"])]
        self.assertTrue(self.advertiser.sync_services())
        self.assertEqual(self.published(), {(
            "_https._tcp.local.", "BottleShip._https._tcp.local.", "games.local.", 443,
            self.advertiser.socket.inet_aton("192.168.1.200"))})

        # The port annotation wins over the listener's.
        self.routes[0]["metadata"]["annotations"]["mdns.homelab.io/port"] = "80"
        self.assertTrue(self.advertiser.sync_services())
        self.assertEqual({i.port for i in self.advertiser.zc.active}, {80})

    def test_moving_a_name_between_services_hands_it_over(self):
        records = {
            "mdns.homelab.io/hostname": "timemachine",
            "mdns.homelab.io/name": "Time Machine",
            "mdns.homelab.io/types": "_smb._tcp",
        }
        self.services = [self.service(dict(records), name="old")]
        self.advertiser.sync_services()

        # Both exist for a moment: the new Service's records wait for the name.
        self.services.append(self.service(dict(records), name="new"))
        self.advertiser.sync_services()
        self.assertEqual(set(self.advertiser.registered_services), {"service:test/old"})

        # Once the old one is gone, the new one takes the name in the same sync.
        self.services = self.services[1:]
        self.assertTrue(self.advertiser.sync_services())
        self.assertEqual(set(self.advertiser.registered_services), {"service:test/new"})
        self.assertEqual(len(self.advertiser.zc.active), 1)

    def test_a_failed_service_or_route_list_changes_nothing(self):
        self.set_config(self.config)
        self.advertiser.sync_services()
        original = set(self.advertiser.zc.active)
        self.advertiser.v1.list_service_for_all_namespaces = (
            lambda **kwargs: (_ for _ in ()).throw(RuntimeError("API unavailable")))
        with self.assertRaisesRegex(RuntimeError, "API unavailable"):
            self.advertiser.sync_services()
        self.assertEqual(self.advertiser.zc.active, original)


if __name__ == "__main__":
    unittest.main()
