#!/usr/bin/env python3
"""Give Gameplane servers of port-routed games their public address.

Valheim and Factorio clients don't send the hostname they connect to, so the
OCI edge can only tell servers apart by port: each server needs public ports
of its own. The edge forwards a fixed range of ports per game to this app's
gateway (Traefik), and this controller hands them out. For each GameServer
of a configured game, it:

1. Gives the server a slot: the lowest one no other server of that game
   holds. Slot 0 is the game's default port, so the first server needs no
   port at all. A deleted server's slot is free again.
2. Sets spec.networking.portOverrides, so the server's Service listens on the
   slot's public ports. Gameplane still forwards them to the game's own ports.
   The overrides are also the record of the slot: a server holds the slot
   whose ports its overrides name, so nothing else has to be kept.
3. Writes the game's public hostname into the Service's load-balancer status.
   The Service's loadBalancerClass (set by a policy in the gameplane app)
   makes this controller its load balancer. Gameplane shows that hostname and
   the Service's port as the server's address: valheim.fultonhuffman.com:2459.
4. Routes each public port from the gateway to the Service, in the
   gateway's Traefik config: a ConfigMap this controller writes and Traefik
   watches, so Traefik itself needs no access to the cluster. Routes go to
   the Service's cluster name, not its pods, so they follow Gameplane's wake
   sentinel while the server sleeps.

This leans on how Gameplane behaves today: that it keeps a Service's class
and load-balancer status, shows the status hostname as the address, and
forwards an overridden port to the game's own. So every pass also checks
that it still does, end to end, on a canary: a UDP echo server of its own
game, which this controller creates and recreates daily so Gameplane's create
path is checked too. The canary's check sends a packet to its public address,
out to the internet and back in through the edge, the tailnet and the
gateway. When every check passes, the controller sets
game_ports_checks_last_success_timestamp_seconds, which a SigNoz alert
watches; each failure is logged.

The configuration (GAME_PORTS_CONFIG) is JSON:

  {"namespace": "gameplane-games", "routeNamespace": "game-ports",
   "routeConfigMap": "game-ports-routes",
   "loadBalancerClass": "homelab.io/game-ports", "metricsPort": 9100,
   "canary": {"name": "game-ports-canary", "game": "game-ports-canary",
              "maxAgeHours": 24, "settleSeconds": 180},
   "games": {"valheim": {"hostname": "valheim.fultonhuffman.com",
                         "basePort": 2456, "portsPerServer": 3, "servers": 4}}}

Games are keyed by GameTemplate name. basePort is the game's default port:
the template's first advertised port, so slot 0 changes nothing. Only UDP
ports are routed; the gateway has no TCP entrypoints.
"""

import json
import os
import signal
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from kubernetes import client, config
from kubernetes.client.rest import ApiException

ROUTES_KEY = "routes.yaml"
GAMEPLANE = ("gameplane.local", "v1alpha1")
POLL_INTERVAL = 10
CANARY_PAYLOAD = b"game-ports"
CANARY_REPLY = b"game-ports-canary:" + CANARY_PAYLOAD

core = None
custom = None
warned = set()
metrics = {"last_success": 0.0, "failing": 0}


def warn_once(key, message):
    """Log a problem once, not on every pass, until it clears."""
    if key not in warned:
        warned.add(key)
        print(f"WARNING: {message}")


def entrypoint(port):
    """The gateway's entrypoint for a public port (templates/gateway.yaml)."""
    return f"udp-{port}"


def advertised_ports(template):
    """The template's advertised ports, in order: (name, containerPort, protocol)."""
    return [
        (p["name"], p["containerPort"], p.get("protocol", "TCP"))
        for p in template.get("spec", {}).get("ports", [])
        if p.get("advertise")
    ]


def public_ports(ports, game, slot):
    """Each advertised port's public port in this slot: {name: port}."""
    first = game["basePort"] + slot * game["portsPerServer"]
    return {name: first + i for i, (name, _, _) in enumerate(ports)}


def held_slot(gs, ports, game):
    """The slot whose ports the server's overrides name, or None.

    Every advertised port must be overridden to that slot's port. A server
    without overrides holds no slot yet, even though its ports are the
    defaults: a new server must not claim slot 0 from the server holding it.
    """
    overrides = {
        o.get("name"): o.get("servicePort")
        for o in gs.get("spec", {}).get("networking", {}).get("portOverrides") or []
    }
    if not ports:
        return None
    first = overrides.get(ports[0][0])
    if not isinstance(first, int):
        return None
    offset = first - game["basePort"]
    if offset < 0 or offset % game["portsPerServer"]:
        return None
    slot = offset // game["portsPerServer"]
    if slot >= game["servers"]:
        return None
    if all(overrides.get(name) == port for name, port in public_ports(ports, game, slot).items()):
        return slot
    return None


def assign_slots(servers, ports, game):
    """Map each server name to its slot, keeping the slots servers already hold.

    servers is a list of GameServer objects of one game. A slot a second
    server also holds (say, after a restore) stays with the server created
    first; the other is reassigned. A server gets None when every slot is
    taken.
    """
    taken = {}
    slots = {}
    by_age = sorted(servers, key=lambda s: (s["metadata"].get("creationTimestamp", ""), s["metadata"]["name"]))
    for gs in by_age:
        slot = held_slot(gs, ports, game)
        if slot is not None and slot not in taken:
            taken[slot] = gs["metadata"]["name"]
            slots[gs["metadata"]["name"]] = slot
    for gs in by_age:
        name = gs["metadata"]["name"]
        if name in slots:
            continue
        free = [s for s in range(game["servers"]) if s not in taken]
        slots[name] = free[0] if free else None
        if free:
            taken[free[0]] = name
    return slots


def merged_overrides(existing, public):
    """portOverrides with our servicePorts set, keeping everything else.

    Returns None when nothing needs to change.
    """
    out = [dict(o) for o in existing or []]
    changed = False
    for name, port in public.items():
        entry = next((o for o in out if o.get("name") == name), None)
        if entry is None:
            out.append({"name": name, "servicePort": port})
            changed = True
        elif entry.get("servicePort") != port:
            entry["servicePort"] = port
            changed = True
    return out if changed else None


def desired_routes(server, namespace, ports, public):
    """Traefik UDP routers and services for a server's UDP ports.

    Returns ({router: spec}, {service: spec}), one of each per port, named
    <server>-<port name>.
    """
    routers, services = {}, {}
    for name, _, protocol in ports:
        if protocol != "UDP":
            continue
        port = public[name]
        route = f"{server}-{name}"
        routers[route] = {"entryPoints": [entrypoint(port)], "service": route}
        services[route] = {"loadBalancer": {"servers": [
            {"address": f"{server}.{namespace}.svc.cluster.local:{port}"}]}}
    return routers, services


def render_routes(routers, services):
    """The gateway's dynamic config. JSON is YAML, so Traefik reads it as is."""
    if not routers:
        return "{}\n"
    return json.dumps({"udp": {"routers": routers, "services": services}}, indent=2, sort_keys=True) + "\n"


def plan_game(game_name, game, servers, template):
    """Everything one game's servers need: [(server, slot, public ports)].

    Servers without a free slot, or a template with more advertised ports
    than a slot holds, get no ports and are reported.
    """
    ports = advertised_ports(template)
    if len(ports) > game["portsPerServer"]:
        warn_once(f"ports:{game_name}", f"{game_name} advertises {len(ports)} ports, more than portsPerServer ({game['portsPerServer']}); its servers get no public ports")
        return [], ports
    plan = []
    for name, slot in assign_slots(servers, ports, game).items():
        if slot is None:
            warn_once(f"full:{name}", f"no free {game_name} slot for {name}: all {game['servers']} are taken")
            continue
        warned.discard(f"full:{name}")
        plan.append((name, slot, public_ports(ports, game, slot)))
    return plan, ports


def service_problems(svc, gs, lb_class, hostname, ports, public):
    """What's wrong with a server's Service and address, as a list of strings.

    These are the Gameplane behaviors game-ports depends on: the Service has
    our class, publishes the public ports, forwards them to the game's own,
    and Gameplane shows our hostname and the first public port as the
    server's address.
    """
    name = gs["metadata"]["name"]
    if svc is None:
        return [f"{name}: no Service"]
    problems = []
    if svc.spec.load_balancer_class != lb_class:
        problems.append(f"{name}: Service class is {svc.spec.load_balancer_class!r}, not {lb_class!r}")
    want = {public[n]: c for n, c, _ in ports}
    have = {p.port: p.target_port for p in svc.spec.ports or []}
    for port, target in want.items():
        if port not in have:
            problems.append(f"{name}: Service has no port {port}")
        elif str(have[port]) != str(target):
            problems.append(f"{name}: Service port {port} goes to {have[port]}, not the game's {target}")
    endpoints = gs.get("status", {}).get("endpoints") or []
    first = public[ports[0][0]] if ports else None
    if not endpoints:
        problems.append(f"{name}: Gameplane shows no address")
    elif (endpoints[0].get("host"), endpoints[0].get("port")) != (hostname, first):
        problems.append(f"{name}: Gameplane shows {endpoints[0].get('host')}:{endpoints[0].get('port')}, not {hostname}:{first}")
    return problems


def age_seconds(obj, now):
    created = obj["metadata"].get("creationTimestamp")
    if not created:
        return 0
    return now - datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp()


def echo(hostname, port, timeout=5, attempts=3):
    """Whether the canary answers at its public address."""
    for _ in range(attempts):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.settimeout(timeout)
                s.sendto(CANARY_PAYLOAD, (hostname, port))
                if s.recvfrom(2048)[0] == CANARY_REPLY:
                    return True
        except OSError:
            pass
    return False


def reconcile(cfg):
    ns = cfg["namespace"]
    lb_class = cfg["loadBalancerClass"]
    canary = cfg["canary"]
    now = time.time()
    servers = custom.list_namespaced_custom_object(*GAMEPLANE, ns, "gameservers")["items"]
    routers, services = {}, {}
    problems = []

    canary_gs = manage_canary(ns, canary, servers, now)
    if canary_gs is None:
        problems.append("canary: not running yet")

    for game_name, game in cfg["games"].items():
        game_servers = [s for s in servers if s.get("spec", {}).get("templateRef", {}).get("name") == game_name]
        if not game_servers:
            continue
        try:
            template = custom.get_cluster_custom_object(*GAMEPLANE, "gametemplates", game_name)
        except ApiException as e:
            problems.append(f"can't read GameTemplate {game_name}: {e.status}")
            continue
        plan, ports = plan_game(game_name, game, game_servers, template)
        by_name = {s["metadata"]["name"]: s for s in game_servers}
        for name in by_name.keys() - {n for n, _, _ in plan}:
            problems.append(f"{name}: no public ports")

        for name, slot, public in plan:
            gs = by_name[name]
            overrides = merged_overrides(gs["spec"].get("networking", {}).get("portOverrides"), public)
            if overrides is not None:
                custom.patch_namespaced_custom_object(
                    *GAMEPLANE, ns, "gameservers", name,
                    {"spec": {"networking": {"portOverrides": overrides}}})
                print(f"{name}: {game_name} slot {slot}, ports {sorted(public.values())}")

            svc = read_service(ns, name)
            if svc is None:
                continue  # Gameplane hasn't created it yet.
            publish_address(svc, ns, lb_class, game["hostname"])
            # Route as soon as the Service exists: Traefik resolves its name.
            server_routers, server_services = desired_routes(name, ns, ports, public)
            routers.update(server_routers)
            services.update(server_services)

            # Check a server once it has had time to settle: Gameplane fills in
            # its address on its own schedule after the ports change.
            if age_seconds(gs, now) >= canary["settleSeconds"] and overrides is None:
                problems.extend(service_problems(svc, gs, lb_class, game["hostname"], ports, public))

            if canary_gs is not None and name == canary_gs["metadata"]["name"]:
                port = public[ports[0][0]]
                if not echo(game["hostname"], port):
                    problems.append(f"canary: no echo from {game['hostname']}:{port}")

    write_routes(cfg["routeNamespace"], cfg["routeConfigMap"], render_routes(routers, services))
    report(problems, now)


def report(problems, now):
    """Log each failed check, and record a pass for the alert."""
    metrics["failing"] = len(problems)
    if problems:
        for problem in sorted(set(problems)):
            warn_once(f"check:{problem}", f"check failed: {problem}")
        return
    if any(k.startswith("check:") for k in warned):
        print("checks: all passing again")
    for key in [k for k in warned if k.startswith("check:")]:
        warned.discard(key)
    metrics["last_success"] = now


def manage_canary(ns, canary, servers, now):
    """Keep the canary GameServer: create it, recreate it daily.

    Returns the canary once it has run long enough to check, else None.
    """
    name = canary["name"]
    gs = next((s for s in servers if s["metadata"]["name"] == name), None)
    if gs is None:
        custom.create_namespaced_custom_object(*GAMEPLANE, ns, "gameservers", {
            "apiVersion": "/".join(GAMEPLANE),
            "kind": "GameServer",
            "metadata": {"name": name},
            "spec": {
                "templateRef": {"name": canary["game"]},
                "networking": {"expose": "LoadBalancer"},
            },
        })
        print(f"canary: created {name}")
        return None
    if gs["metadata"].get("deletionTimestamp"):
        return None
    age = age_seconds(gs, now)
    if age >= canary["maxAgeHours"] * 3600:
        # Recreated so that Gameplane's create path, where the policies set
        # the Service's class, is checked too, not just one old Service.
        custom.delete_namespaced_custom_object(*GAMEPLANE, ns, "gameservers", name)
        print(f"canary: recreating {name}")
        return None
    if age < canary["settleSeconds"] or gs.get("status", {}).get("phase") != "Running":
        return None
    return gs


def read_service(ns, name):
    try:
        return core.read_namespaced_service(name, ns)
    except ApiException as e:
        if e.status == 404:
            return None
        raise


def publish_address(svc, ns, lb_class, hostname):
    """Publish the hostname as the load-balancer address of the server's Service."""
    if svc.spec.load_balancer_class != lb_class:
        # Created before the policy, or the policy didn't run: the route
        # still works, but the dashboard shows the Service's own address.
        # The checks report it.
        return
    ingress = (svc.status.load_balancer.ingress or []) if svc.status and svc.status.load_balancer else []
    if [i.hostname for i in ingress] == [hostname] and not any(i.ip for i in ingress):
        return
    core.patch_namespaced_service_status(
        svc.metadata.name, ns, {"status": {"loadBalancer": {"ingress": [{"hostname": hostname}]}}})
    print(f"{svc.metadata.name}: address {hostname}")


def write_routes(route_ns, name, content):
    """Write the gateway's routes into its ConfigMap, when they changed."""
    try:
        current = core.read_namespaced_config_map(name, route_ns)
    except ApiException as e:
        if e.status != 404:
            raise
        core.create_namespaced_config_map(route_ns, client.V1ConfigMap(
            metadata=client.V1ObjectMeta(name=name), data={ROUTES_KEY: content}))
        print("routes: created")
        return
    if (current.data or {}).get(ROUTES_KEY) == content:
        return
    core.patch_namespaced_config_map(name, route_ns, {"data": {ROUTES_KEY: content}})
    routers = json.loads(content).get("udp", {}).get("routers", {})
    print(f"routes: {', '.join(f'{r} on {v['entryPoints'][0]}' for r, v in sorted(routers.items())) or 'none'}")


def render_metrics():
    return (
        "# HELP game_ports_checks_last_success_timestamp_seconds When every check last passed.\n"
        "# TYPE game_ports_checks_last_success_timestamp_seconds gauge\n"
        f"game_ports_checks_last_success_timestamp_seconds {metrics['last_success']}\n"
        "# HELP game_ports_checks_failing Checks failing on the last pass.\n"
        "# TYPE game_ports_checks_failing gauge\n"
        f"game_ports_checks_failing {metrics['failing']}\n"
    )


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = render_metrics().encode()
        self.send_response(200 if self.path == "/metrics" else 404)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        if self.path == "/metrics":
            self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    global core, custom
    cfg = json.loads(os.environ["GAME_PORTS_CONFIG"])
    config.load_incluster_config()
    core = client.CoreV1Api()
    custom = client.CustomObjectsApi()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer(("", cfg["metricsPort"]), MetricsHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"game-ports: {', '.join(cfg['games'])} in {cfg['namespace']}")
    while True:
        try:
            reconcile(cfg)
        except Exception as e:  # Keep serving; the next pass retries.
            metrics["failing"] = max(metrics["failing"], 1)
            print(f"ERROR: reconcile failed: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
