"""Check the bootstrap and tuppr Talos/Kubernetes pins against Talos support."""

from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


def version(path: Path, key: str) -> str:
    matches = re.findall(rf"^{re.escape(key)}:\s*(v\d+\.\d+\.\d+)\s*$", path.read_text(), re.M)
    if len(matches) != 1:
        raise ValueError(f"{path}: expected one {key} version, found {len(matches)}")
    return matches[0]


def supported_minors(talos: str) -> range:
    url = f"https://raw.githubusercontent.com/siderolabs/talos/{talos}/pkg/machinery/constants/constants.go"
    with urlopen(url, timeout=20) as response:
        constants = response.read().decode()
    default = re.search(r'DefaultKubernetesVersion\s*=\s*"1\.(\d+)\.\d+"', constants)
    count = re.search(r'SupportedKubernetesVersions\s*=\s*(\d+)', constants)
    if not default or not count:
        raise ValueError(f"Could not parse Kubernetes support constants for Talos {talos}")
    maximum = int(default.group(1))
    return range(maximum - int(count.group(1)) + 1, maximum + 1)


def check(root: Path = Path(".")) -> None:
    bootstrap = root / "talos/cluster.yaml"
    upgrade = root / "kubernetes/infra/tuppr/values.yaml"
    pins = {
        "bootstrap": (version(bootstrap, "talosVersion"), version(bootstrap, "kubernetesVersion")),
        "tuppr": (version(upgrade, "talosVersion"), version(upgrade, "kubernetesVersion")),
    }

    if pins["bootstrap"] != pins["tuppr"]:
        raise ValueError(f"Bootstrap {pins['bootstrap']} and tuppr {pins['tuppr']} disagree; align both pins or add an explicitly reviewed transition")

    talos, kubernetes = pins["bootstrap"]
    supported = supported_minors(talos)
    minor = int(kubernetes.split(".")[1])
    if minor not in supported:
        raise ValueError(f"Kubernetes {kubernetes} is unsupported by Talos {talos}; supported range is 1.{supported.start}–1.{supported.stop - 1}")
    print(f"Bootstrap and tuppr agree: Talos {talos}, Kubernetes {kubernetes}; supported Kubernetes range 1.{supported.start}–1.{supported.stop - 1}")


if __name__ == "__main__":
    try:
        check()
    except (ValueError, HTTPError, URLError, TimeoutError) as error:
        print(f"::error::Compatibility could not be confirmed: {error}", file=sys.stderr)
        sys.exit(1)
