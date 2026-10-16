#!/usr/bin/env python3
"""Advertise LAN services over mDNS from labeled Kubernetes ConfigMaps.

Discovers ConfigMaps labeled mdns.homelab.io/advertise=true (written by the
mdns-config library chart) and publishes each as Bonjour/Zeroconf records.
Runs with hostNetwork on a LAN node so the records reach the local segment.
"""

import json
import signal
import socket
import sys
import time

from kubernetes import client, config
from zeroconf import ServiceInfo, Zeroconf

LABEL_SELECTOR = "mdns.homelab.io/advertise=true"
CONFIG_KEY = "config.json"
POLL_INTERVAL = 30

config.load_incluster_config()
v1 = client.CoreV1Api()

zc = Zeroconf()
registered_services = {}  # configmap_key -> (name, ip, port, list of ServiceInfo)


def shutdown(signum, frame):
    print("Shutting down mDNS advertiser...")
    for name, ip, port, infos in registered_services.values():
        for info in infos:
            zc.unregister_service(info)
    zc.close()
    sys.exit(0)


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)


def parse_txt_records(txt_records):
    """Parse TXT records from list of 'key=value' strings to dict."""
    props = {}
    if txt_records:
        for record in txt_records:
            if '=' in record:
                key, value = record.split('=', 1)
                props[key] = value
    return props


def register_service(svc_config):
    """Register mDNS services for a config and return (name, ip, port, infos)."""
    infos = []
    name = svc_config['name']
    hostname = svc_config['hostname']
    ip = svc_config['ip']
    port = svc_config['port']

    print(f"Publishing {name} ({ip}:{port})")

    for svc_type in svc_config.get('types', []):
        type_str = svc_type['type']
        txt_records = svc_type.get('txtRecords', [])

        info = ServiceInfo(
            f"{type_str}.local.",
            f"{name}.{type_str}.local.",
            addresses=[socket.inet_aton(ip)],
            port=port,
            properties=parse_txt_records(txt_records),
            server=f"{hostname}.local."
        )
        zc.register_service(info, cooperating_responders=True)
        infos.append(info)

    return (name, ip, port, infos)


def unregister_service(name, ip, port, infos):
    """Unregister a list of ServiceInfo."""
    print(f"Unpublishing {name} ({ip}:{port})")
    for info in infos:
        zc.unregister_service(info)


def sync_services():
    """Sync mDNS services with labeled ConfigMaps.

    Returns True if services were added or removed."""
    cms = v1.list_config_map_for_all_namespaces(label_selector=LABEL_SELECTOR)

    current_keys = set()
    changed = False

    for cm in cms.items:
        key = f"{cm.metadata.namespace}/{cm.metadata.name}"
        current_keys.add(key)

        # Skip if already registered
        if key in registered_services:
            continue

        # Parse config from ConfigMap
        raw_config = (cm.data or {}).get(CONFIG_KEY, '')
        if not raw_config:
            print(f"Warning: ConfigMap {key} has no {CONFIG_KEY}")
            continue

        try:
            svc_config = json.loads(raw_config)
            registered_services[key] = register_service(svc_config)
            changed = True
        except Exception as e:
            print(f"Error processing ConfigMap {key}: {e}")

    # Unregister services for removed ConfigMaps
    removed_keys = set(registered_services.keys()) - current_keys
    for key in removed_keys:
        name, ip, port, infos = registered_services[key]
        unregister_service(name, ip, port, infos)
        del registered_services[key]
        changed = True

    return changed


# Initial sync
sync_services()
print(f"mDNS advertisements active ({len(registered_services)} services)")

# Poll for changes
while True:
    time.sleep(POLL_INTERVAL)
    try:
        if sync_services():
            print(f"mDNS advertisements active ({len(registered_services)} services)")
    except Exception as e:
        print(f"Error syncing services: {e}")
