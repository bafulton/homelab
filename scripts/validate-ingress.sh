#!/usr/bin/env bash
# Refresh dependencies using an isolated Helm repository config, then test ingress.
set -euo pipefail
cd "$(dirname "$0")/.."
task_helm_dir=$(mktemp -d)
trap 'rm -rf "$task_helm_dir"' EXIT
export HELM_REPOSITORY_CONFIG="$task_helm_dir/repositories.yaml"
export HELM_REPOSITORY_CACHE="$task_helm_dir/cache"
python3 - <<'PY'
from pathlib import Path
import subprocess
import yaml
charts = []
repositories = set()
for values in sorted(Path('kubernetes').glob('*/*/values.yaml')):
    if 'gateway-route' not in yaml.safe_load(values.read_text()):
        continue
    charts.append(values.parent)
    for dependency in yaml.safe_load((values.parent / 'Chart.yaml').read_text()).get('dependencies', []):
        url = dependency.get('repository', '')
        if url.startswith(('https://', 'http://')):
            repositories.add(url)
for index, url in enumerate(sorted(repositories)):
    subprocess.run(['helm', 'repo', 'add', f'ingress-{index}', url], check=True)
subprocess.run(['helm', 'dependency', 'update', 'charts/gateway-route', '--skip-refresh'], check=True)
for chart in charts:
    subprocess.run(['helm', 'dependency', 'update', str(chart), '--skip-refresh'], check=True)
PY
go -C scripts/tests/ingress test -count=1 -v ./...
