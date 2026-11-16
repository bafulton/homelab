"""Slot, port, route and check tests, without a Kubernetes cluster."""

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

VALHEIM = {"hostname": "valheim.fultonhuffman.com", "basePort": 2456, "portsPerServer": 3, "servers": 3}
VALHEIM_TEMPLATE = {"spec": {"ports": [
    {"name": "game", "containerPort": 2456, "protocol": "UDP", "advertise": True},
    {"name": "game2", "containerPort": 2457, "protocol": "UDP", "advertise": True},
    {"name": "game3", "containerPort": 2458, "protocol": "UDP", "advertise": True},
    {"name": "status", "containerPort": 80, "protocol": "TCP", "advertise": False},
]}}
PORTS = gp.advertised_ports(VALHEIM_TEMPLATE)


def server(name, created, slot=None, overrides=None):
    """A GameServer, holding slot (by its port overrides) when given."""
    if slot is not None:
        overrides = [{"name": n, "servicePort": p} for n, p in gp.public_ports(PORTS, VALHEIM, slot).items()]
    networking = {} if overrides is None else {"portOverrides": overrides}
    return {"metadata": {"name": name, "creationTimestamp": created}, "spec": {"networking": networking}}


class HeldSlotTest(unittest.TestCase):
    def test_overrides_name_the_slot(self):
        self.assertEqual(gp.held_slot(server("a", "t", slot=2), PORTS, VALHEIM), 2)

    def test_no_overrides_is_no_slot_not_slot_zero(self):
        self.assertIsNone(gp.held_slot(server("a", "t"), PORTS, VALHEIM))

    def test_partial_or_mismatched_overrides_are_no_slot(self):
        partial = server("a", "t", overrides=[{"name": "game", "servicePort": 2459}])
        mixed = server("b", "t", overrides=[
            {"name": "game", "servicePort": 2459}, {"name": "game2", "servicePort": 2457}, {"name": "game3", "servicePort": 2461}])
        off_grid = server("c", "t", overrides=[{"name": "game", "servicePort": 2457}])
        out_of_range = server("d", "t", overrides=[{"name": "game", "servicePort": 2456 + 3 * 9}])
        for gs in (partial, mixed, off_grid, out_of_range):
            self.assertIsNone(gp.held_slot(gs, PORTS, VALHEIM), gs["metadata"]["name"])


class AssignSlotsTest(unittest.TestCase):
    def test_new_servers_get_the_lowest_free_slots_in_age_order(self):
        slots = gp.assign_slots([server("b", "2026-01-02"), server("a", "2026-01-01")], PORTS, VALHEIM)
        self.assertEqual(slots, {"a": 0, "b": 1})

    def test_held_slots_are_kept_and_gaps_reused(self):
        slots = gp.assign_slots([server("a", "2026-01-01", slot=2), server("b", "2026-01-02")], PORTS, VALHEIM)
        self.assertEqual(slots, {"a": 2, "b": 0})

    def test_a_new_server_never_takes_slot_zero_from_its_holder(self):
        slots = gp.assign_slots([server("old", "2026-01-02", slot=0), server("new", "2026-01-01")], PORTS, VALHEIM)
        self.assertEqual(slots, {"old": 0, "new": 1})

    def test_a_duplicate_slot_stays_with_the_older_server(self):
        slots = gp.assign_slots([server("new", "2026-01-02", slot=0), server("old", "2026-01-01", slot=0)], PORTS, VALHEIM)
        self.assertEqual(slots, {"old": 0, "new": 1})

    def test_no_slot_when_all_are_taken(self):
        servers = [server(n, f"2026-01-0{i}") for i, n in enumerate("abcd", 1)]
        self.assertEqual(gp.assign_slots(servers, PORTS, VALHEIM)["d"], None)


class PortsTest(unittest.TestCase):
    def test_slot_zero_is_the_default_ports(self):
        self.assertEqual(gp.public_ports(PORTS, VALHEIM, 0), {"game": 2456, "game2": 2457, "game3": 2458})

    def test_later_slots_follow_in_blocks(self):
        self.assertEqual(gp.public_ports(PORTS, VALHEIM, 1), {"game": 2459, "game2": 2460, "game3": 2461})

    def test_overrides_keep_other_entries(self):
        existing = [{"name": "game", "servicePort": 1}, {"name": "rcon", "nodePort": 30001}]
        merged = gp.merged_overrides(existing, {"game": 2459})
        self.assertEqual(merged, [{"name": "game", "servicePort": 2459}, {"name": "rcon", "nodePort": 30001}])

    def test_overrides_unchanged_is_none(self):
        self.assertIsNone(gp.merged_overrides([{"name": "game", "servicePort": 2459}], {"game": 2459}))

    def test_overrides_are_added_when_missing(self):
        self.assertEqual(gp.merged_overrides(None, {"game": 2456}), [{"name": "game", "servicePort": 2456}])


class RoutesTest(unittest.TestCase):
    def test_one_route_per_udp_port_through_the_service_name(self):
        routers, services = gp.desired_routes("frosty", "gameplane-games", PORTS, gp.public_ports(PORTS, VALHEIM, 1))
        self.assertEqual(sorted(routers), ["frosty-game", "frosty-game2", "frosty-game3"])
        self.assertEqual(routers["frosty-game"], {"entryPoints": ["udp-2459"], "service": "frosty-game"})
        self.assertEqual(services["frosty-game"], {"loadBalancer": {"servers": [
            {"address": "frosty.gameplane-games.svc.cluster.local:2459"}]}})

    def test_tcp_ports_get_no_route(self):
        self.assertEqual(gp.desired_routes("t", "ns", [("game", 7777, "TCP")], {"game": 7777}), ({}, {}))

    def test_render_is_stable_and_empty_without_routes(self):
        self.assertEqual(gp.render_routes({}, {}), "{}\n")
        a = gp.render_routes(*gp.desired_routes("frosty", "ns", PORTS, gp.public_ports(PORTS, VALHEIM, 0)))
        b = gp.render_routes(*gp.desired_routes("frosty", "ns", PORTS, gp.public_ports(PORTS, VALHEIM, 0)))
        self.assertEqual(a, b)
        self.assertEqual(json.loads(a)["udp"]["routers"]["frosty-game"]["entryPoints"], ["udp-2456"])


class PlanGameTest(unittest.TestCase):
    def test_too_many_ports_for_a_slot_plans_nothing(self):
        game = dict(VALHEIM, portsPerServer=2)
        plan, _ = gp.plan_game("valheim", game, [server("a", "2026-01-01")], VALHEIM_TEMPLATE)
        self.assertEqual(plan, [])

    def test_full_game_skips_the_extra_server(self):
        game = dict(VALHEIM, servers=1)
        plan, _ = gp.plan_game("valheim", game, [server("a", "2026-01-01"), server("b", "2026-01-02")], VALHEIM_TEMPLATE)
        self.assertEqual([(name, slot) for name, slot, _ in plan], [("a", 0)])


def service(lb_class="homelab.io/game-ports", ports=((2459, 2456), (2460, 2457), (2461, 2458))):
    return SimpleNamespace(spec=SimpleNamespace(
        load_balancer_class=lb_class,
        ports=[SimpleNamespace(port=p, target_port=t) for p, t in ports]))


def with_address(gs, host, port):
    gs["status"] = {"endpoints": [{"host": host, "port": port}]}
    return gs


class ServiceProblemsTest(unittest.TestCase):
    public = gp.public_ports(PORTS, VALHEIM, 1)

    def problems(self, svc, gs):
        return gp.service_problems(svc, gs, "homelab.io/game-ports", VALHEIM["hostname"], PORTS, self.public)

    def test_a_healthy_server_has_none(self):
        gs = with_address(server("a", "t", slot=1), "valheim.fultonhuffman.com", 2459)
        self.assertEqual(self.problems(service(), gs), [])

    def test_each_gameplane_behavior_is_checked(self):
        gs = server("a", "t", slot=1)
        self.assertIn("a: Gameplane shows no address", self.problems(service(), gs))
        lan = with_address(server("a", "t", slot=1), "192.168.1.204", 2459)
        self.assertTrue(any("shows 192.168.1.204:2459" in p for p in self.problems(service(), lan)))
        healthy = with_address(server("a", "t", slot=1), "valheim.fultonhuffman.com", 2459)
        self.assertTrue(any("class is None" in p for p in self.problems(service(lb_class=None), healthy)))
        moved = service(ports=((2459, 2459), (2460, 2457), (2461, 2458)))
        self.assertTrue(any("port 2459 goes to 2459" in p for p in self.problems(moved, healthy)))
        missing = service(ports=((2459, 2456),))
        self.assertTrue(any("no port 2460" in p for p in self.problems(missing, healthy)))
        self.assertEqual(self.problems(None, healthy), ["a: no Service"])


class ReportTest(unittest.TestCase):
    def test_success_only_when_every_check_passes(self):
        gp.metrics.update(last_success=0.0, failing=0)
        gp.report(["canary: no echo"], 100.0)
        self.assertEqual((gp.metrics["last_success"], gp.metrics["failing"]), (0.0, 1))
        gp.report([], 200.0)
        self.assertEqual((gp.metrics["last_success"], gp.metrics["failing"]), (200.0, 0))
        self.assertIn("game_ports_checks_last_success_timestamp_seconds 200.0", gp.render_metrics())


if __name__ == "__main__":
    unittest.main()
