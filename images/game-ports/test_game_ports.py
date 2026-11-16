"""Slot, port and route planning tests, without a Kubernetes cluster."""

import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest


def load_module():
    """Import game_ports.py with stand-ins for the kubernetes client."""
    kubernetes = types.ModuleType("kubernetes")
    kubernetes.client = types.ModuleType("kubernetes.client")
    kubernetes.config = types.ModuleType("kubernetes.config")
    rest = types.ModuleType("kubernetes.client.rest")
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


def server(name, created, slot=None):
    annotations = {} if slot is None else {gp.SLOT_ANNOTATION: str(slot)}
    return {"metadata": {"name": name, "creationTimestamp": created, "annotations": annotations}}


class AssignSlotsTest(unittest.TestCase):
    def test_new_servers_get_the_lowest_free_slots_in_age_order(self):
        slots = gp.assign_slots([server("b", "2026-01-02"), server("a", "2026-01-01")], VALHEIM)
        self.assertEqual(slots, {"a": 0, "b": 1})

    def test_held_slots_are_kept_and_gaps_reused(self):
        slots = gp.assign_slots([server("a", "2026-01-01", 2), server("b", "2026-01-02")], VALHEIM)
        self.assertEqual(slots, {"a": 2, "b": 0})

    def test_a_duplicate_slot_stays_with_the_older_server(self):
        slots = gp.assign_slots([server("new", "2026-01-02", 0), server("old", "2026-01-01", 0)], VALHEIM)
        self.assertEqual(slots, {"old": 0, "new": 1})

    def test_out_of_range_and_garbage_slots_are_reassigned(self):
        slots = gp.assign_slots([server("a", "2026-01-01", 7), server("b", "2026-01-02", "x")], VALHEIM)
        self.assertEqual(slots, {"a": 0, "b": 1})

    def test_no_slot_when_all_are_taken(self):
        servers = [server(n, f"2026-01-0{i}") for i, n in enumerate("abcd", 1)]
        self.assertEqual(gp.assign_slots(servers, VALHEIM)["d"], None)


class PortsTest(unittest.TestCase):
    def test_slot_zero_is_the_default_ports(self):
        ports = gp.advertised_ports(VALHEIM_TEMPLATE)
        self.assertEqual(gp.public_ports(ports, VALHEIM, 0), {"game": 2456, "game2": 2457, "game3": 2458})

    def test_later_slots_follow_in_blocks(self):
        ports = gp.advertised_ports(VALHEIM_TEMPLATE)
        self.assertEqual(gp.public_ports(ports, VALHEIM, 1), {"game": 2459, "game2": 2460, "game3": 2461})

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
        ports = gp.advertised_ports(VALHEIM_TEMPLATE)
        routers, services = gp.desired_routes("frosty", "gameplane-games", ports, gp.public_ports(ports, VALHEIM, 1))
        self.assertEqual(sorted(routers), ["frosty-game", "frosty-game2", "frosty-game3"])
        self.assertEqual(routers["frosty-game"], {"entryPoints": ["udp-2459"], "service": "frosty-game"})
        self.assertEqual(services["frosty-game"], {"loadBalancer": {"servers": [
            {"address": "frosty.gameplane-games.svc.cluster.local:2459"}]}})

    def test_tcp_ports_get_no_route(self):
        self.assertEqual(gp.desired_routes("t", "ns", [("game", 7777, "TCP")], {"game": 7777}), ({}, {}))

    def test_render_is_stable_and_empty_without_routes(self):
        self.assertEqual(gp.render_routes({}, {}), "{}\n")
        ports = gp.advertised_ports(VALHEIM_TEMPLATE)
        a = gp.render_routes(*gp.desired_routes("frosty", "ns", ports, gp.public_ports(ports, VALHEIM, 0)))
        b = gp.render_routes(*gp.desired_routes("frosty", "ns", ports, gp.public_ports(ports, VALHEIM, 0)))
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


if __name__ == "__main__":
    unittest.main()
