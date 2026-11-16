#!/usr/bin/env python3
"""Advertise LAN services over mDNS from annotated Kubernetes objects.

Records come from two sources:

- Services annotated with mdns.homelab.io/hostname. The address is the
  Service's load balancer IP, so it is never copied by hand.
- HTTPRoutes annotated with mdns.homelab.io/advertise: "true". Each of the
  route's .local hostnames is published at its Gateway's address.

On Services and HTTPRoutes, these annotations describe the records:

  mdns.homelab.io/name           display name (default: the hostname)
  mdns.homelab.io/types          service types: comma-separated, or for types
                                 with TXT records a JSON list of
                                 {"type": ..., "txtRecords": [...]}
                                 (default: _http._tcp)
  mdns.homelab.io/port           port (default: the Service's first port,
                                 or the route's Gateway listener)
  mdns.homelab.io/ip             address override, eg to publish a name at
                                 another Service's address
"""

import json
import signal
import socket
import sys
import time
from dataclasses import dataclass

from kubernetes import client, config
from zeroconf import ServiceInfo, Zeroconf

PREFIX = "mdns.homelab.io/"
GATEWAY_GROUP = "gateway.networking.k8s.io"
GATEWAY_VERSION = "v1"
POLL_INTERVAL = 30

v1 = None
custom = None
zc = None
registered_services = {}  # source key -> Registration


@dataclass
class Registration:
    configuration: tuple
    name: str
    ip: str
    port: int
    infos: list


def shutdown(signum, frame):
    print("Shutting down mDNS advertiser...")
    for registration in registered_services.values():
        unregister_service(registration)
    zc.close()
    sys.exit(0)


def parse_txt_records(txt_records):
    """Parse TXT records from a list of 'key=value' strings."""
    props = {}
    for record in txt_records:
        if '=' in record:
            key, value = record.split('=', 1)
            props[key] = value
    return props


def prepare_service(svc_config):
    """Validate and build every record before replacing a live registration."""
    name = svc_config['name']
    hostname = svc_config['hostname']
    ip = svc_config['ip']
    port = svc_config['port']
    types = svc_config['types']
    if not types:
        raise ValueError("at least one service type is required")

    address = socket.inet_aton(ip)
    infos = []
    effective_types = []
    for svc_type in types:
        type_str = svc_type['type']
        properties = parse_txt_records(svc_type.get('txtRecords', []))
        infos.append(ServiceInfo(
            f"{type_str}.local.",
            f"{name}.{type_str}.local.",
            addresses=[address],
            port=port,
            properties=properties,
            server=f"{hostname}.local.",
        ))
        effective_types.append((type_str, tuple(sorted(properties.items()))))

    configuration = (name, hostname, ip, port, tuple(effective_types))
    return Registration(configuration, name, ip, port, infos)


def parse_types(annotations):
    """Service types, comma-separated or, for types with TXT records, JSON."""
    raw = annotations.get(PREFIX + "types", "_http._tcp").strip()
    if raw.startswith("["):
        return [{"type": t["type"], "txtRecords": t.get("txtRecords", [])}
                for t in json.loads(raw)]
    return [{"type": t.strip(), "txtRecords": []} for t in raw.split(",") if t.strip()]


def config_from_annotations(annotations, hostname, ip, port):
    """Build a record config from mdns.homelab.io/* annotations."""
    return {
        "name": annotations.get(PREFIX + "name", hostname),
        "hostname": hostname,
        "ip": annotations.get(PREFIX + "ip", ip),
        "port": int(annotations.get(PREFIX + "port", port)),
        "types": parse_types(annotations),
    }


def service_configs():
    """Services annotated with mdns.homelab.io/hostname."""
    configs = {}
    for svc in v1.list_service_for_all_namespaces().items:
        annotations = svc.metadata.annotations or {}
        hostname = annotations.get(PREFIX + "hostname")
        if not hostname:
            continue
        key = f"service:{svc.metadata.namespace}/{svc.metadata.name}"
        ingress = (svc.status.load_balancer.ingress or []) if svc.status.load_balancer else []
        ip = next((i.ip for i in ingress if i.ip), None)
        if not ip and PREFIX + "ip" not in annotations:
            # Not published until the load balancer has an address.
            continue
        port = svc.spec.ports[0].port if svc.spec.ports else 0
        configs[key] = lambda a=annotations, h=hostname, ip=ip, p=port: (
            config_from_annotations(a, h, ip, p))
    return configs


def route_configs():
    """HTTPRoutes annotated mdns.homelab.io/advertise, at their Gateway's address."""
    configs = {}
    gateways = {}
    routes = custom.list_cluster_custom_object(GATEWAY_GROUP, GATEWAY_VERSION, "httproutes")
    for route in routes.get("items", []):
        meta = route["metadata"]
        annotations = meta.get("annotations") or {}
        if annotations.get(PREFIX + "advertise") != "true":
            continue
        hostnames = [h for h in route["spec"].get("hostnames", []) if h.endswith(".local")]
        parents = route["spec"].get("parentRefs", [])
        if not hostnames or not parents:
            continue
        parent = parents[0]
        gw_ns = parent.get("namespace", meta["namespace"])
        gw_key = (gw_ns, parent["name"])
        if gw_key not in gateways:
            gateways[gw_key] = custom.get_namespaced_custom_object(
                GATEWAY_GROUP, GATEWAY_VERSION, gw_ns, "gateways", parent["name"])
        gateway = gateways[gw_key]
        ip = next((a["value"] for a in gateway.get("status", {}).get("addresses", [])
                   if a.get("type", "IPAddress") == "IPAddress"), None)
        listeners = gateway["spec"].get("listeners", [])
        listener = next((l for l in listeners if l["name"] == parent.get("sectionName")),
                        listeners[0] if listeners else {})
        if not ip and PREFIX + "ip" not in annotations:
            continue
        for host in hostnames:
            hostname = host[:-len(".local")]
            key = f"route:{meta['namespace']}/{meta['name']}/{hostname}"
            configs[key] = lambda a=annotations, h=hostname, ip=ip, p=listener.get("port", 80): (
                config_from_annotations(a, h, ip, p))
    return configs


def register_service(registration):
    """Register all records, cleaning up those already added on failure."""
    added = []
    try:
        for info in registration.infos:
            zc.register_service(info, cooperating_responders=True)
            added.append(info)
    except Exception:
        for info in reversed(added):
            zc.unregister_service(info)
        raise
    print(f"Publishing {registration.name} ({registration.ip}:{registration.port})")


def unregister_service(registration):
    print(f"Unpublishing {registration.name} ({registration.ip}:{registration.port})")
    for info in registration.infos:
        zc.unregister_service(info)


def sync_services():
    """Sync records with every source; return whether anything changed."""
    # A failed list must not be interpreted as an empty list (and delete
    # records), so every source is listed before anything changes.
    desired = {}
    desired.update(service_configs())
    desired.update(route_configs())
    changed = False

    # Remove first, so a record moving from one object to another frees its
    # name before it's published again.
    for key in set(registered_services) - set(desired):
        registration = registered_services[key]
        try:
            unregister_service(registration)
        except Exception as e:
            print(f"Error removing {key}: {e}")
            continue
        del registered_services[key]
        changed = True

    for key, build_config in desired.items():
        try:
            replacement = prepare_service(build_config())
            previous = registered_services.get(key)
            if previous and previous.configuration == replacement.configuration:
                continue

            if previous:
                unregister_service(previous)
            try:
                register_service(replacement)
            except Exception:
                if previous:
                    # The old records are valid and should survive a failed edit.
                    try:
                        register_service(previous)
                    except Exception as rollback_error:
                        # Do not keep a stale entry that would suppress retries.
                        del registered_services[key]
                        print(f"Error restoring {key}: {rollback_error}")
                raise
            registered_services[key] = replacement
            changed = True
        except Exception as e:
            print(f"Error processing {key}: {e}")

    return changed


def main():
    global v1, custom, zc
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    custom = client.CustomObjectsApi()
    zc = Zeroconf()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    while True:
        try:
            if sync_services():
                print(f"mDNS advertisements active ({len(registered_services)} services)")
        except Exception as e:
            print(f"Error syncing services: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
