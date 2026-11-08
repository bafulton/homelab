#!/usr/bin/env python3
"""Refresh isolated chart copies; export policy-only renders and a safe live inventory."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import yaml

# Helm CRD schemas can contain the plain scalar '=' (a YAML 1.1 value tag).
yaml.SafeLoader.add_constructor('tag:yaml.org,2002:value', lambda loader, node: loader.construct_scalar(node))

ROOT = Path(__file__).resolve().parents[2]


def run(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)


def normalized(spec):
    """Apply API defaults without hiding changed selectors, peers, or ports."""
    if spec is None:
        return None
    spec = json.loads(json.dumps(spec))
    spec.setdefault('policyTypes', ['Ingress'] + (['Egress'] if 'egress' in spec else []))
    for direction in ('ingress', 'egress'):
        for rule in spec.get(direction, []):
            for port in rule.get('ports', []):
                port.setdefault('protocol', 'TCP')
    return spec


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--context', required=True, help='Explicit kubectl context for read-only collection')
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    report = {'collectedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'revision': run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip(),
              'context': a.context, 'charts': []}
    k = ['kubectl', '--context', a.context, '--request-timeout=30s']
    # Never export Secrets, pod env values, or whole rendered charts.
    policies = json.loads(run(k + ['get', 'networkpolicies', '-A', '-o', 'json']))
    cleaned = [{'apiVersion': x['apiVersion'], 'kind': x['kind'],
                'metadata': {f: x['metadata'][f] for f in ('name', 'namespace')},
                'spec': x['spec']} for x in policies['items']]
    (a.output / 'live-policies.yaml').write_text(yaml.safe_dump_all(cleaned, sort_keys=False))
    for resource in ('nodes', 'pods', 'services', 'endpointslices.discovery.k8s.io'):
        items = json.loads(run(k + ['get', resource, '-A', '-o', 'json']))['items']
        safe = []
        for x in items:
            s = x.get('spec', {})
            row = {'name': x['metadata']['name'], 'namespace': x['metadata'].get('namespace'),
                   'labels': x['metadata'].get('labels', {})}
            if resource == 'pods':
                row.update(node=s.get('nodeName'), hostNetwork=s.get('hostNetwork', False),
                           hostPID=s.get('hostPID', False), podIP=x.get('status', {}).get('podIP'),
                           containers=[{'name': c['name'], 'image': c['image'],
                                        'ports': c.get('ports', []),
                                        'securityContext': c.get('securityContext', {})}
                                       for c in s.get('containers', []) + s.get('initContainers', [])])
            elif resource == 'nodes':
                row.update(podCIDR=s.get('podCIDR'), addresses=x.get('status', {}).get('addresses'),
                           nodeInfo=x.get('status', {}).get('nodeInfo'))
            else:
                row['spec'] = s if resource == 'services' else {
                    f: x.get(f) for f in ('addressType', 'ports', 'endpoints')}
            safe.append(row)
        (a.output / f'live-{resource}.json').write_text(json.dumps(safe, indent=2) + '\n')
    with tempfile.TemporaryDirectory(prefix='cat6-helm-') as tmp:
        tmp = Path(tmp)
        for folder in ('charts', 'kubernetes'):
            shutil.copytree(ROOT / folder, tmp / folder, ignore=shutil.ignore_patterns('*.tgz', 'charts', '.git')
                            if folder == 'kubernetes' else shutil.ignore_patterns('*.tgz'))
        env = dict(os.environ, HELM_REPOSITORY_CONFIG=str(tmp / 'repos.yaml'),
                   HELM_REPOSITORY_CACHE=str(tmp / 'cache'))
        wrappers = sorted((tmp / 'kubernetes').glob('*/*/Chart.yaml'))
        repos = sorted({d['repository'] for chart in wrappers + sorted((tmp / 'charts').glob('*/Chart.yaml'))
                        for d in yaml.safe_load(chart.read_text()).get('dependencies', [])
                        if d.get('repository', '').startswith(('https://', 'http://'))})
        for i, repo in enumerate(repos):
            run(['helm', 'repo', 'add', f'cat6-{i}', repo], env=env)
        rendered = []
        # Build shared charts first so nested file dependencies are fresh too.
        for chart in sorted((tmp / 'charts').glob('*/Chart.yaml')) + wrappers:
            run(['helm', 'dependency', 'update', str(chart.parent), '--skip-refresh'], env=env)
        for chart in wrappers:
            print(f'Rendering {chart.parent.name}', flush=True)
            values = yaml.safe_load((chart.parent / 'values.yaml').read_text()) or {}
            name = values.get('name', chart.parent.name)
            namespace = values.get('namespace', chart.parent.name)
            output = run(['helm', 'template', name, str(chart.parent), '--namespace', namespace,
                          '--include-crds', '--kube-version', '1.37.2'], env=env)
            objects = [x for x in yaml.safe_load_all(output) if isinstance(x, dict)]
            netpol = [x for x in objects if x.get('kind') == 'NetworkPolicy']
            for x in netpol:
                x['metadata'].setdefault('namespace', namespace)
            rendered.extend(netpol)
            report['charts'].append({'path': str(chart.relative_to(tmp).parent), 'release': name,
                                     'namespace': namespace, 'policies': [x['metadata']['name'] for x in netpol]})
        (a.output / 'rendered-policies.yaml').write_text(yaml.safe_dump_all(rendered, sort_keys=False))
    live_specs = {(x['metadata']['namespace'], x['metadata']['name']): x['spec'] for x in cleaned}
    rendered_specs = {(x['metadata']['namespace'], x['metadata']['name']): x['spec'] for x in rendered}
    # Keep raw differences visible while distinguishing Kubernetes API defaults.
    report['rawSpecDifferences'] = [f'{ns}/{name}' for ns, name in sorted(live_specs.keys() | rendered_specs.keys())
                                    if live_specs.get((ns, name)) != rendered_specs.get((ns, name))]
    report['policyDrift'] = [f'{ns}/{name}' for ns, name in sorted(live_specs.keys() | rendered_specs.keys())
                             if normalized(live_specs.get((ns, name))) != normalized(rendered_specs.get((ns, name)))]
    (a.output / 'audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
