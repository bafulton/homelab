#!/usr/bin/env python3
"""Route the OCI edge's forwarded game ports to Gameplane's port-pool servers.

Valheim and Factorio clients send no hostname, so behind the OCI edge's one
public address each server needs ports of its own. Gameplane's own operator
hands those out (operator.portPools in the gameplane app, GameplanePanel/
Gameplane#1001) and labels each pool server's Service
gameplane.local/port-pool. This controller:

1. Mirrors those Services' ports into the gateway's Traefik config: a
   ConfigMap this controller writes and Traefik watches
   (templates/gateway.yaml), so Traefik itself needs no access to the
   cluster. Routes go to the Service's cluster name, not its pods, so they
   follow Gameplane's wake sentinel while a server sleeps.
2. Writes each pool's public hostname into its Services' load-balancer
   status. The gameplane app gives a pool server its own loadBalancerClass
   (GameplanePanel/Gameplane#1000), which makes this controller its load
   balancer; Gameplane then shows that hostname and the Service's port as
   the server's address (GameplanePanel/Gameplane#999): without this, the
   dashboard would show the Service's cluster address instead, and the
   owner would have to combine a separate hostname label with the port by
   hand.

Because routing and addressing both follow whichever Service actually holds
a port, adding a pool-routed game needs no change to the control flow here:
just its range and hostname in values.yaml, its loadBalancerClass and
hostname in the gameplane app's operator.portPools/gamePorts, var.games
(opentofu/oci-forwarder) and the tag:edge grant (tailscale/policy.hujson).

It also runs the canary check: every pass it sends a UDP packet to the
canary's public address (templates/canary.yaml, a static echo Service of
this app's own, not a GameServer), out to the internet and back in through
the edge, the tailnet and the gateway, so the check covers DNS, the edge,
the tailnet grant and the gateway together. When it answers, the controller
sets game_ports_checks_last_success_timestamp_seconds, which a SigNoz alert
watches; a miss is logged.

The configuration (GAME_PORTS_CONFIG) is JSON:

  {"namespace": "gameplane-games", "poolLabel": "gameplane.local/port-pool",
   "loadBalancerClass": "homelab.io/game-ports",
   "poolHostnames": {"valheim": "valheim.fultonhuffman.com"},
   "routeNamespace": "game-ports", "routeConfigMap": "game-ports-routes",
   "metricsPort": 9100,
   "canary": {"hostname": "game-ports-canary.fultonhuffman.com", "port": 39999}}

Only UDP ports are routed; the gateway has no TCP entrypoints.
"""

import json
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from kubernetes import client, config
from kubernetes.client.rest import ApiException

ROUTES_KEY = "routes.yaml"
POLL_INTERVAL = 10
CANARY_PAYLOAD = b"game-ports"
CANARY_REPLY = b"game-ports-canary:" + CANARY_PAYLOAD

core = None
warned = set()
metrics = {"last_success": 0.0, "failing": 0}


def warn_once(key, message):
    """Log a problem once, not on every pass, until it clears."""
    if key not in warned:
        warned.add(key)
        print(f"WARNING: {message}")


def clear_warning(key, cleared_message):
    if key in warned:
        warned.discard(key)
        print(cleared_message)


def entrypoint(port):
    """The gateway's entrypoint for a public port (templates/gateway.yaml)."""
    return f"udp-{port}"


def pool_routes(services):
    """Traefik UDP routers and services for every pool Service's UDP ports.

    services is a list of V1Service. Returns ({router: spec}, {service:
    spec}), one of each per port, named <service>-<port>.
    """
    routers, backends = {}, {}
    for svc in services:
        for p in svc.spec.ports or []:
            if p.protocol != "UDP":
                continue
            route = f"{svc.metadata.name}-{p.port}"
            routers[route] = {"entryPoints": [entrypoint(p.port)], "service": route}
            backends[route] = {"loadBalancer": {"servers": [
                {"address": f"{svc.metadata.name}.{svc.metadata.namespace}.svc.cluster.local:{p.port}"}]}}
    return routers, backends


def canary_route(route_ns, port):
    """The static route to this app's own canary Service (templates/canary.yaml)."""
    route = f"canary-{port}"
    return (
        {route: {"entryPoints": [entrypoint(port)], "service": route}},
        {route: {"loadBalancer": {"servers": [
            {"address": f"game-ports-canary.{route_ns}.svc.cluster.local:{port}"}]}}},
    )


def render_routes(routers, backends):
    """The gateway's dynamic config. JSON is YAML, so Traefik reads it as is."""
    if not routers:
        return "{}\n"
    return json.dumps({"udp": {"routers": routers, "services": backends}}, indent=2, sort_keys=True) + "\n"


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


def publish_address(svc, ns, lb_class, hostname):
    """Publish hostname as the load-balancer address of a pool Service.

    Only a Service of our class is ours to publish for: one created before
    the gameplane app's policy, or with the policy not run, keeps working
    through its route, but the dashboard shows its own cluster address
    instead.
    """
    if svc.spec.load_balancer_class != lb_class:
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


def reconcile(cfg):
    services = core.list_namespaced_service(cfg["namespace"], label_selector=cfg["poolLabel"]).items
    routers, backends = pool_routes(services)
    canary_routers, canary_backends = canary_route(cfg["routeNamespace"], cfg["canary"]["port"])
    routers.update(canary_routers)
    backends.update(canary_backends)
    write_routes(cfg["routeNamespace"], cfg["routeConfigMap"], render_routes(routers, backends))

    for svc in services:
        pool = (svc.metadata.labels or {}).get(cfg["poolLabel"])
        hostname = cfg["poolHostnames"].get(pool)
        if hostname:
            publish_address(svc, cfg["namespace"], cfg["loadBalancerClass"], hostname)

    canary = cfg["canary"]
    if echo(canary["hostname"], canary["port"]):
        metrics["failing"] = 0
        metrics["last_success"] = time.time()
        clear_warning("canary", "canary: echo restored")
    else:
        metrics["failing"] = 1
        warn_once("canary", f"canary: no echo from {canary['hostname']}:{canary['port']}")


def render_metrics():
    return (
        "# HELP game_ports_checks_last_success_timestamp_seconds When the canary last echoed.\n"
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
    global core
    cfg = json.loads(os.environ["GAME_PORTS_CONFIG"])
    config.load_incluster_config()
    core = client.CoreV1Api()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer(("", cfg["metricsPort"]), MetricsHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"game-ports: routing {cfg['poolLabel']} Services in {cfg['namespace']}")
    while True:
        try:
            reconcile(cfg)
        except Exception as e:  # Keep serving; the next pass retries.
            metrics["failing"] = max(metrics["failing"], 1)
            print(f"ERROR: reconcile failed: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
