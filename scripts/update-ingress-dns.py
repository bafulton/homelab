#!/usr/bin/env python3
"""Populate split DNS from provisioned, explicitly tagged gateway Services.

Changes a local values file only. Does not sync Argo or mutate the cluster.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ADMIN_NAMES = (
    'argocd',
    'longhorn',
    'garage',
    'signoz',
    'goldpinger',
    'traefik-apps',
    'traefik-admin',
)


def address(service, role):
    metadata, spec = service['metadata'], service['spec']
    name = 'traefik-admin' if role == 'admin' else 'traefik-apps-tailscale'
    if (metadata['namespace'], metadata['name']) != ('traefik-' + role, name):
        raise ValueError('Unexpected gateway Service identity')
    if spec.get('loadBalancerClass') != 'tailscale':
        raise ValueError('Gateway Service is not Tailscale-managed')
    if metadata.get('annotations', {}).get('tailscale.com/tags') != 'tag:k8s-' + role:
        raise ValueError('Gateway Service must declare only its dedicated role tag')
    addresses = [ipaddress.ip_address(x['ip']) for x in service.get('status', {}).get('loadBalancer', {}).get('ingress', []) if 'ip' in x]
    ipv4 = [ip for ip in addresses if ip.version == 4 and ip in ipaddress.ip_network('100.64.0.0/10')]
    if len(ipv4) != 1:
        raise ValueError('Expected exactly one assigned Tailscale IPv4 address; wait for proxy provisioning')
    return str(ipv4[0])


def update(text, admin, apps):
    # Keep the existing upstream chart configuration and comments intact.
    serial = re.search(r'^(\s*)(\d+)( ; serial)$', text, re.M)
    if not serial:
        raise ValueError('Missing zone serial')
    text = text[:serial.start()] + serial[1] + str(int(serial[2]) + 1) + serial[3] + text[serial.end():]
    lines = [f'        @       60 IN A {apps}', f'        *       60 IN A {apps}']
    lines += [f'        {name:<15} 60 IN A {admin}' for name in ADMIN_NAMES]
    # This zone is the final block in the values file. Refuse unexpected layouts.
    records = re.search(r'^        @\s+IN\s+A\s+[^\n]+\n        \*\s+IN\s+A\s+[^\n]+\s*$', text, re.M)
    if not records:
        records = re.search(r'^        @\s+60 IN A[^\n]+\n        \*\s+60 IN A[^\n]+\n(?:        (?:' + '|'.join(ADMIN_NAMES) + r')\s+60 IN A[^\n]+\n?)+\s*$', text, re.M)
    if not records:
        raise ValueError('Unexpected zone layout; refusing to replace records')
    return text[:records.start()] + '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--values', type=Path, default=ROOT / 'kubernetes/infra/coredns/values.yaml')
    parser.add_argument('--check', action='store_true', help='Verify the committed records match current Services without writing')
    args = parser.parse_args()
    endpoints = {}
    for role, name in [('admin', 'traefik-admin'), ('apps', 'traefik-apps-tailscale')]:
        raw = subprocess.check_output(['kubectl', '-n', 'traefik-' + role, 'get', 'service', name, '-o', 'json'], text=True)
        endpoints[role] = address(json.loads(raw), role)
    if endpoints['admin'] == endpoints['apps']:
        raise ValueError('Admin and apps proxy addresses must differ')
    current = args.values.read_text()
    expected = update(current, endpoints['admin'], endpoints['apps'])
    without_serial = lambda text: re.sub(r'(?m)^\s*\d+ ; serial$', '<serial>', text)
    same = without_serial(current) == without_serial(expected)
    if args.check:
        if not same:
            raise ValueError('DNS records differ from live proxy addresses; regenerate and update the CoreDNS values in Git before syncing')
        print('DNS records match the assigned gateway addresses')
        return
    if same:
        print('DNS records already match; no values change required')
        return
    args.values.write_text(expected)
    print(f"Updated {args.values}: admin={endpoints['admin']}, apps={endpoints['apps']}. Review and commit before syncing DNS.")


if __name__ == '__main__':
    main()
