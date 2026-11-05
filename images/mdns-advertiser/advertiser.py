#!/usr/bin/env python3
"""Advertise LAN services over mDNS from labeled Kubernetes ConfigMaps."""

import json
import signal
import socket
import sys
import time
from dataclasses import dataclass

from kubernetes import client, config
from zeroconf import ServiceInfo, Zeroconf

LABEL_SELECTOR = "mdns.homelab.io/advertise=true"
CONFIG_KEY = "config.json"
POLL_INTERVAL = 30

v1 = None
zc = None
registered_services = {}  # namespace/name -> Registration


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
    """Sync records with labeled ConfigMaps; return whether anything changed."""
    # A failed list must not be interpreted as an empty list (and delete records).
    cms = v1.list_config_map_for_all_namespaces(label_selector=LABEL_SELECTOR)
    current_keys = set()
    changed = False

    for cm in cms.items:
        key = f"{cm.metadata.namespace}/{cm.metadata.name}"
        current_keys.add(key)
        raw_config = (cm.data or {}).get(CONFIG_KEY, '')
        if not raw_config:
            print(f"Warning: ConfigMap {key} has no {CONFIG_KEY}")
            continue

        try:
            replacement = prepare_service(json.loads(raw_config))
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
                        print(f"Error restoring ConfigMap {key}: {rollback_error}")
                raise
            registered_services[key] = replacement
            changed = True
        except Exception as e:
            print(f"Error processing ConfigMap {key}: {e}")

    for key in set(registered_services) - current_keys:
        registration = registered_services[key]
        try:
            unregister_service(registration)
        except Exception as e:
            print(f"Error removing ConfigMap {key}: {e}")
            continue
        del registered_services[key]
        changed = True

    return changed


def main():
    global v1, zc
    config.load_incluster_config()
    v1 = client.CoreV1Api()
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
