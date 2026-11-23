"""Route, canary and metrics tests, without a Kubernetes cluster."""

import importlib.util
import json
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest


def load_module():
    """Import game_ports.py with stand-ins for the kubernetes client."""
    kubernetes = ModuleType("kubernetes")
    kubernetes.client = ModuleType("kubernetes.client")
    kubernetes.config = ModuleType("kubernetes.config")
    rest = ModuleType("kubernetes.client.rest")
    rest.ApiException = type("ApiException", (Exception,), {})
    sys.modules.update({
        "kubernetes": kubernetes,
        "kubernetes.client": kubernetes.client,
        "kubernetes.config": kubernetes.config,
        "kubernetes.client.rest": rest,
    })
    spec = importlib.util.spec_from_file_location("game_ports", Path(__file__).with_name("game_ports.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gp = load_module()


def service(name, namespace="gameplane-games", ports=((2459, "UDP"), (2460, "UDP")), labels=None):
    return SimpleNamespace(
        metadata=SimpleNamespace(name=name, namespace=namespace, labels=labels),
        spec=SimpleNamespace(ports=[SimpleNamespace(port=p, protocol=proto) for p, proto in ports],
                              load_balancer_class="homelab.io/game-ports"),
        status=SimpleNamespace(load_balancer=SimpleNamespace(ingress=[])))


class PoolRoutesTest(unittest.TestCase):
    def test_one_route_per_udp_port_through_the_service_name(self):
        routers, backends = gp.pool_routes([service("frosty")])
        self.assertEqual(sorted(routers), ["frosty-2459", "frosty-2460"])
        self.assertEqual(routers["frosty-2459"], {"entryPoints": ["udp-2459"], "service": "frosty-2459"})
        self.assertEqual(backends["frosty-2459"], {"loadBalancer": {"servers": [
            {"address": "frosty.gameplane-games.svc.cluster.local:2459"}]}})

    def test_tcp_ports_get_no_route(self):
        routers, backends = gp.pool_routes([service("t", ports=((7777, "TCP"),))])
        self.assertEqual((routers, backends), ({}, {}))

    def test_two_services_each_get_their_own_routes(self):
        routers, _ = gp.pool_routes([service("a", ports=((2456, "UDP"),)), service("b", ports=((34197, "UDP"),))])
        self.assertEqual(sorted(routers), ["a-2456", "b-34197"])


class FakeCore:
    """Stands in for gp.core, recording status patches."""

    def __init__(self):
        self.patches = []

    def patch_namespaced_service_status(self, name, ns, body):
        self.patches.append((name, ns, body))


class PublishAddressTest(unittest.TestCase):
    def setUp(self):
        gp.core = FakeCore()

    def test_publishes_the_hostname_for_our_class(self):
        gp.publish_address(service("frosty"), "gameplane-games", "homelab.io/game-ports", "valheim.fultonhuffman.com")
        self.assertEqual(gp.core.patches, [("frosty", "gameplane-games", {"status": {"loadBalancer": {
            "ingress": [{"hostname": "valheim.fultonhuffman.com"}]}}})])

    def test_skips_a_service_of_another_class(self):
        svc = service("frosty")
        svc.spec.load_balancer_class = "example.com/other"
        gp.publish_address(svc, "gameplane-games", "homelab.io/game-ports", "valheim.fultonhuffman.com")
        self.assertEqual(gp.core.patches, [])

    def test_skips_once_already_published(self):
        svc = service("frosty")
        svc.status.load_balancer.ingress = [SimpleNamespace(hostname="valheim.fultonhuffman.com", ip=None)]
        gp.publish_address(svc, "gameplane-games", "homelab.io/game-ports", "valheim.fultonhuffman.com")
        self.assertEqual(gp.core.patches, [])


class CanaryRouteTest(unittest.TestCase):
    def test_targets_the_canary_service_in_the_route_namespace(self):
        routers, backends = gp.canary_route("game-ports", 39999)
        self.assertEqual(routers, {"canary-39999": {"entryPoints": ["udp-39999"], "service": "canary-39999"}})
        self.assertEqual(backends["canary-39999"], {"loadBalancer": {"servers": [
            {"address": "game-ports-canary.game-ports.svc.cluster.local:39999"}]}})


class RenderRoutesTest(unittest.TestCase):
    def test_render_is_stable_and_empty_without_routes(self):
        self.assertEqual(gp.render_routes({}, {}), "{}\n")
        a = gp.render_routes(*gp.pool_routes([service("frosty")]))
        b = gp.render_routes(*gp.pool_routes([service("frosty")]))
        self.assertEqual(a, b)
        self.assertEqual(json.loads(a)["udp"]["routers"]["frosty-2459"]["entryPoints"], ["udp-2459"])


class EchoTest(unittest.TestCase):
    def test_no_reply_within_the_timeout_fails(self):
        # 192.0.2.0/24 is reserved for documentation; nothing answers there.
        self.assertFalse(gp.echo("192.0.2.1", 39999, timeout=0.2, attempts=1))


class MetricsTest(unittest.TestCase):
    def test_render_reflects_the_last_update(self):
        gp.metrics.update(last_success=200.0, failing=0)
        self.assertIn("game_ports_checks_last_success_timestamp_seconds 200.0", gp.render_metrics())
        self.assertIn("game_ports_checks_failing 0", gp.render_metrics())


if __name__ == "__main__":
    unittest.main()
