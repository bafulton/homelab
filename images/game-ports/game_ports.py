#!/usr/bin/env python3
"""Give Gameplane servers of port-routed games their public address.

Valheim and Factorio clients don't send the hostname they connect to, so the
OCI edge can only tell servers apart by port: each server needs public ports
of its own. The edge forwards a fixed range of ports per game to this app's
gateway (Traefik), and this controller hands them out. For each GameServer
of a configured game, it:

1. Gives the server a slot: the lowest one no other server of that game
   holds, recorded in the game-ports.homelab.io/slot annotation. Slot 0 is the
   game's default port, so the first server needs no port at all. A deleted
   server's slot is free again.
2. Sets spec.networking.portOverrides, so the server's Service listens on the
   slot's public ports. Gameplane still forwards them to the game's own ports.
3. Writes the game's public hostname into the Service's load-balancer status.
   The Service's loadBalancerClass (set by a policy in the gameplane app)
   makes this controller its load balancer. Gameplane shows that hostname and
   the Service's port as the server's address: valheim.fultonhuffman.com:2459.
4. Routes each public port from the gateway to the Service, in the
   gateway's Traefik config: a ConfigMap this controller writes and Traefik
   watches, so Traefik itself needs no access to the cluster. Routes go to
   the Service's cluster name, not its pods, so they follow Gameplane's wake
   sentinel while the server sleeps.

The configuration (GAME_PORTS_CONFIG) is JSON:

  {"namespace": "gameplane-games", "routeNamespace": "game-ports",
   "routeConfigMap": "game-ports-routes",
   "loadBalancerClass": "homelab.io/game-ports",
   "games": {"valheim": {"hostname": "valheim.fultonhuffman.com",
                         "basePort": 2456, "portsPerServer": 3, "servers": 4}}}

Games are keyed by GameTemplate name. basePort is the game's default port:
the template's first advertised port, so slot 0 changes nothing. Only UDP
ports are routed; the gateway has no TCP entrypoints.
"""

import json
import os
import signal
import sys
import time

from kubernetes import client, config
from kubernetes.client.rest import ApiException

SLOT_ANNOTATION = "game-ports.homelab.io/slot"
ROUTES_KEY = "routes.yaml"
GAMEPLANE = ("gameplane.local", "v1alpha1")
POLL_INTERVAL = 10

core = None
custom = None
warned = set()


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


def assign_slots(servers, game):
    """Map each server name to its slot, keeping the slots servers already hold.

    servers is a list of GameServer objects of one game. A slot outside the
    game's range, or one a second server also claims (say, after a restore),
    is reassigned: the server created first keeps it. A server gets None when
    every slot is taken.
    """
    taken = {}
    slots = {}
    by_age = sorted(servers, key=lambda s: (s["metadata"].get("creationTimestamp", ""), s["metadata"]["name"]))
    for gs in by_age:
        raw = gs["metadata"].get("annotations", {}).get(SLOT_ANNOTATION)
        if raw is None:
            continue
        try:
            slot = int(raw)
        except ValueError:
            continue
        if 0 <= slot < game["servers"] and slot not in taken:
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


def public_ports(ports, game, slot):
    """Each advertised port's public port in this slot: {name: port}."""
    first = game["basePort"] + slot * game["portsPerServer"]
    return {name: first + i for i, (name, _, _) in enumerate(ports)}


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
    for name, slot in assign_slots(servers, game).items():
        if slot is None:
            warn_once(f"full:{name}", f"no free {game_name} slot for {name}: all {game['servers']} are taken")
            continue
        warned.discard(f"full:{name}")
        plan.append((name, slot, public_ports(ports, game, slot)))
    return plan, ports


def reconcile(cfg):
    ns = cfg["namespace"]
    route_ns = cfg["routeNamespace"]
    lb_class = cfg["loadBalancerClass"]
    servers = custom.list_namespaced_custom_object(*GAMEPLANE, ns, "gameservers")["items"]
    routers, services = {}, {}

    for game_name, game in cfg["games"].items():
        game_servers = [s for s in servers if s.get("spec", {}).get("templateRef", {}).get("name") == game_name]
        if not game_servers:
            continue
        try:
            template = custom.get_cluster_custom_object(*GAMEPLANE, "gametemplates", game_name)
        except ApiException as e:
            warn_once(f"template:{game_name}", f"can't read GameTemplate {game_name}: {e.status}")
            continue
        warned.discard(f"template:{game_name}")
        plan, ports = plan_game(game_name, game, game_servers, template)
        by_name = {s["metadata"]["name"]: s for s in game_servers}

        for name, slot, public in plan:
            gs = by_name[name]
            if gs["metadata"].get("annotations", {}).get(SLOT_ANNOTATION) != str(slot):
                custom.patch_namespaced_custom_object(
                    *GAMEPLANE, ns, "gameservers", name,
                    {"metadata": {"annotations": {SLOT_ANNOTATION: str(slot)}}})
                print(f"{name}: {game_name} slot {slot}, ports {sorted(public.values())}")
            overrides = merged_overrides(gs["spec"].get("networking", {}).get("portOverrides"), public)
            if overrides is not None:
                custom.patch_namespaced_custom_object(
                    *GAMEPLANE, ns, "gameservers", name,
                    {"spec": {"networking": {"portOverrides": overrides}}})

            # Route only once the Service exists: Traefik resolves its name.
            if set_address(ns, name, lb_class, game["hostname"]):
                server_routers, server_services = desired_routes(name, ns, ports, public)
                routers.update(server_routers)
                services.update(server_services)

    write_routes(route_ns, cfg["routeConfigMap"], render_routes(routers, services))


def set_address(ns, name, lb_class, hostname):
    """Publish the hostname as the load-balancer address of the server's Service.

    Returns whether the Service exists.
    """
    try:
        svc = core.read_namespaced_service(name, ns)
    except ApiException as e:
        if e.status == 404:
            return False  # Gameplane hasn't created it yet.
        raise
    if svc.spec.load_balancer_class != lb_class:
        # Created before the policy, or by a server that isn't a
        # LoadBalancer: the route still works, but the dashboard shows the
        # Service's own address.
        warn_once(f"class:{name}", f"Service {name} isn't of class {lb_class}; the dashboard won't show its public address")
        return True
    ingress = (svc.status.load_balancer.ingress or []) if svc.status and svc.status.load_balancer else []
    if [i.hostname for i in ingress] == [hostname] and not any(i.ip for i in ingress):
        return True
    core.patch_namespaced_service_status(
        name, ns, {"status": {"loadBalancer": {"ingress": [{"hostname": hostname}]}}})
    print(f"{name}: address {hostname}")
    return True


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


def main():
    global core, custom
    cfg = json.loads(os.environ["GAME_PORTS_CONFIG"])
    config.load_incluster_config()
    core = client.CoreV1Api()
    custom = client.CustomObjectsApi()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print(f"game-ports: {', '.join(cfg['games'])} in {cfg['namespace']}")
    while True:
        try:
            reconcile(cfg)
        except Exception as e:  # Keep serving; the next pass retries.
            print(f"ERROR: reconcile failed: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
