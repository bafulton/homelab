#!/usr/bin/env python3
"""Exercise disposable pod/Service paths; never enable a cluster policy engine."""
import argparse
import datetime
import itertools
import json
from pathlib import Path
import subprocess
import time
import uuid

IMAGE = 'python:3.13.11-alpine3.23'
PROBE = '''import socket,sys
try:
 s=socket.create_connection((sys.argv[1],int(sys.argv[2])),3); s.close()
except (TimeoutError,ConnectionRefusedError): sys.exit(1)
except OSError as e: print(e); sys.exit(2)
'''
DNS = '''import socket,struct,sys
name=b''.join(bytes([len(x)])+x.encode() for x in 'kubernetes.default.svc.cluster.local'.split('.'))+b'\\0'
q=struct.pack('!6H',1234,256,1,0,0,0)+name+struct.pack('!2H',1,1)
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if sys.argv[2]=='TCP' else socket.SOCK_DGRAM); s.settimeout(3)
s.connect((sys.argv[1],53))
if sys.argv[2]=='TCP':
 s.sendall(struct.pack('!H',len(q))+q)
 def read(n):
  b=b''
  while len(b)<n:
   t=s.recv(n-len(b))
   if not t: raise RuntimeError('short DNS response')
   b+=t
  return b
 data=read(struct.unpack('!H',read(2))[0])
else: s.send(q); data=s.recv(4096)
ident,flags,qd,answers,ns,ar=struct.unpack('!6H',data[:12])
assert ident==1234 and flags&32768 and flags&15==0 and answers>0
'''


class Harness:
    def __init__(self, args):
        self.args = args
        self.ns = 'cat6-probe-' + uuid.uuid4().hex[:8]
        self.k = ['kubectl', '--context', args.context, '--request-timeout=30s']
        self.results = []
        self.targets = json.loads(args.targets.read_text()) if args.targets else []
        for target in self.targets:
            if not isinstance(target.get('host'), str) or not isinstance(target.get('port'), int) or not 1 <= target['port'] <= 65535:
                raise ValueError('Targets require host string and port integer 1..65535')

    def call(self, *args, data=None):
        return subprocess.check_output(self.k + list(args), text=True,
                                       input=json.dumps(data) if data is not None else None)

    def apply(self, obj):
        self.call('apply', '-f', '-', data=obj)

    def policy(self, name, selector, **spec):
        self.apply({'apiVersion': 'networking.k8s.io/v1', 'kind': 'NetworkPolicy',
                    'metadata': {'namespace': self.ns, 'name': name},
                    'spec': {'podSelector': {'matchLabels': selector}, **spec}})

    def record(self, phase, source, target, expected, command):
        result = subprocess.run(self.k + ['exec', '-n', self.ns, source, '--', 'python', '-c', *command],
                                text=True, capture_output=True)
        # kubectl transport/exec errors are never evidence of a policy denial.
        transport_error = bool(result.stderr.strip())
        observed = 'allow' if result.returncode == 0 else 'deny' if result.returncode == 1 and not transport_error else 'error'
        row = dict(phase=phase, source=source, target=target, expected=expected,
                   observed=observed, passed=observed == expected)
        if transport_error or observed == 'error':
            row['error'] = (result.stderr + result.stdout)[-1500:]
        self.results.append(row)
        print(json.dumps(row), flush=True)

    def matrix(self, phase, denied):
        for i, j in itertools.product(range(len(self.args.nodes)), repeat=2):
            for role in ('allow', 'deny'):
                source = f'{role}-{i}'
                for path, address in [('pod', self.addresses[j]), ('service', f'server-{j}.{self.ns}.svc.cluster.local')]:
                    self.record(phase, source, f'{path}:{j}',
                                'deny' if denied and role == 'deny' else 'allow', [PROBE, address, '8080'])
                for protocol in ('TCP', 'UDP'):
                    self.record(phase, source, f'dns:{protocol}', 'allow', [DNS, self.dns, protocol])

        for i in range(len(self.args.nodes)):
            for role in ('allow', 'deny'):
                for target in self.targets:
                    self.record(phase, f'{role}-{i}', f"external:{target['host']}:{target['port']}",
                                'deny' if phase == 'egress' and role == 'deny' else 'allow',
                                [PROBE, target['host'], str(target['port'])])

    def execute(self):
        nodes = json.loads(self.call('get', 'nodes', '-o', 'json'))['items']
        actual = {n['metadata']['name']: n for n in nodes}
        for node in self.args.nodes:
            if node not in actual:
                raise ValueError(f'Unknown node: {node}')
        self.dns = json.loads(self.call('get', 'service', 'kube-dns', '-n', 'kube-system', '-o', 'json'))['spec']['clusterIP']
        self.apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {
            'name': self.ns, 'labels': {'homelab.io/purpose': 'cat6-probe',
                                      'pod-security.kubernetes.io/enforce': 'baseline'}}})
        try:
            for i, node in enumerate(self.args.nodes):
                for role in ('server', 'allow', 'deny'):
                    name = f'{role}-{i}'
                    container = {'name': 'probe', 'image': self.args.image,
                                 'command': ['python', '-m', 'http.server', '8080'] if role == 'server' else
                                            ['python', '-c', 'import time; time.sleep(7200)'],
                                 'resources': {'requests': {'cpu': '5m', 'memory': '16Mi'}, 'limits': {'memory': '64Mi'}},
                                 'securityContext': {'allowPrivilegeEscalation': False, 'runAsNonRoot': True,
                                                     'runAsUser': 65532, 'capabilities': {'drop': ['ALL']},
                                                     'seccompProfile': {'type': 'RuntimeDefault'}}}
                    if role == 'server':
                        container['readinessProbe'] = {'tcpSocket': {'port': 8080}, 'periodSeconds': 2}
                    self.apply({'apiVersion': 'v1', 'kind': 'Pod',
                                'metadata': {'name': name, 'namespace': self.ns,
                                             'labels': {'role': role, 'instance': name}},
                                'spec': {'nodeSelector': {'kubernetes.io/hostname': node},
                                         'automountServiceAccountToken': False, 'restartPolicy': 'Never',
                                         'containers': [container]}})
                self.apply({'apiVersion': 'v1', 'kind': 'Service',
                            'metadata': {'name': f'server-{i}', 'namespace': self.ns},
                            'spec': {'selector': {'instance': f'server-{i}'},
                                     'ports': [{'port': 8080, 'targetPort': 8080}]}})
            self.call('wait', '-n', self.ns, '--for=condition=Ready', 'pods', '--all', '--timeout=180s')
            self.addresses = [json.loads(self.call('get', 'pod', f'server-{i}', '-n', self.ns, '-o', 'json'))['status']['podIP']
                              for i in range(len(self.args.nodes))]
            self.matrix('baseline', False)
            if not all(r['passed'] for r in self.results):
                raise RuntimeError('Baseline failed; policy results would be inconclusive')
            if self.args.enforce:
                self.policy('ingress', {'role': 'server'}, policyTypes=['Ingress'],
                            ingress=[{'from': [{'podSelector': {'matchLabels': {'role': 'allow'}}}],
                                      'ports': [{'port': 8080, 'protocol': 'TCP'}]}])
                time.sleep(self.args.settle)
                self.matrix('ingress', True)
                self.call('delete', 'networkpolicy', 'ingress', '-n', self.ns)
                # Recheck open connectivity before testing the independent egress direction.
                time.sleep(self.args.settle)
                self.matrix('between-phases', False)
                dns = {'to': [{'ipBlock': {'cidr': self.dns + '/32'}}],
                       'ports': [{'port': 53, 'protocol': p} for p in ('UDP', 'TCP')]}
                self.policy('egress', {'role': 'deny'}, policyTypes=['Egress'], egress=[dns])
                time.sleep(self.args.settle)
                self.matrix('egress', True)
                self.call('delete', 'networkpolicy', 'egress', '-n', self.ns)
                time.sleep(self.args.settle)
                self.matrix('rollback', False)
        finally:
            # Delete only our generated namespace, including policies on any failed phase.
            self.call('delete', 'namespace', self.ns, '--wait=true', '--timeout=120s')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--context', required=True)
    p.add_argument('--nodes', nargs='+', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--image', default=IMAGE, help='Multi-architecture Python image; pin a digest for activation')
    p.add_argument('--enforce', action='store_true', help='Also exercise ingress/egress deny and policy rollback')
    p.add_argument('--targets', type=Path, help='JSON list of known listening LAN/tailnet endpoints: host, port')
    p.add_argument('--settle', type=int, default=10)
    a = p.parse_args()
    if len(set(a.nodes)) != len(a.nodes):
        p.error('nodes must be unique')
    if a.output.exists():
        p.error('output already exists; choose a new evidence file')
    h = Harness(a)
    error = None
    try:
        h.execute()
    except Exception as exc:
        error = str(exc)
    finally:
        a.output.write_text(json.dumps({'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                        'context': a.context, 'nodes': a.nodes, 'namespace': h.ns,
                                        'image': a.image, 'enforcementRequested': a.enforce,
                                        'error': error, 'results': h.results}, indent=2) + '\n')
    if error or not h.results or not all(r['passed'] for r in h.results):
        raise SystemExit(error or 'Connection matrix failed; see evidence file')


if __name__ == '__main__':
    main()
