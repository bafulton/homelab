"""Check that the public game ports agree everywhere they are listed.

A game port is forwarded by the OCI edge (opentofu/oci-forwarder, var.games),
allowed by the tag:edge grant in tailscale/policy.hujson, and, for Valheim,
Factorio and game-ports' canary, routed by the game-ports app
(kubernetes/apps/game-ports, pools and canary). A port missing from any one
of them fails quietly, as a server nobody can reach, so this checks that:

- every var.games port is in the grant, and the grant has no others;
- each game-ports pool's range (plus the canary's port) is exactly its
  var.games entry's ports, and that entry forwards to game-ports'
  Tailscale Service.
"""

import json
from pathlib import Path
import re
import sys

import hcl2
import yaml

ROOT = Path(__file__).resolve().parents[2]
EDGE = ROOT / "opentofu/oci-forwarder/variables.tf"
POLICY = ROOT / "tailscale/policy.hujson"
GAME_PORTS = ROOT / "kubernetes/apps/game-ports/values.yaml"


def unquote(value):
    """python-hcl2 keeps the quotes on strings and keys."""
    return value.strip('"') if isinstance(value, str) else value


def edge_games():
    """var.games' default: {game: {"upstream": str or None, "ports": {"udp:2456", ...}}}."""
    variables = hcl2.load(EDGE.open())["variable"]
    block = next(v for v in variables if unquote(next(iter(v))) == "games")
    games = {}
    for name, game in next(iter(block.values()))["default"].items():
        ports = set()
        for p in game["ports"]:
            end = p.get("to") or p["port"]
            ports |= {f"{unquote(p['protocol'])}:{n}" for n in range(p["port"], end + 1)}
        games[unquote(name)] = {"upstream": unquote(game.get("upstream")), "ports": ports}
    return games


def strip_hujson(text):
    """HuJSON to JSON: drop // and /* */ comments outside strings, and trailing commas."""
    out, i, in_string = [], 0, False
    while i < len(text):
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def grant_ports():
    """The ports of the tag:edge to tag:k8s-games grant: {"udp:2456", ...}."""
    policy = json.loads(strip_hujson(POLICY.read_text()))
    grants = [
        g for g in policy.get("grants", [])
        if g.get("src") == ["tag:edge"] and g.get("dst") == ["tag:k8s-games"]
    ]
    if len(grants) != 1:
        sys.exit(f"{POLICY.relative_to(ROOT)}: expected one tag:edge -> tag:k8s-games grant, found {len(grants)}")
    ports = set()
    for entry in grants[0]["ip"]:
        protocol, _, span = entry.partition(":")
        start, _, end = span.partition("-")
        ports |= {f"{protocol}:{n}" for n in range(int(start), int(end or start) + 1)}
    return ports


def game_ports_ranges():
    """game-ports' pools, plus its canary: ({name: {"udp:2456", ...}}, its Tailscale upstream)."""
    values = yaml.safe_load(GAME_PORTS.read_text())
    ranges = {pool["name"]: {f"udp:{n}" for n in range(pool["from"], pool["to"] + 1)} for pool in values["pools"]}
    ranges["game-ports-canary"] = {f"udp:{values['canary']['port']}"}
    return ranges, f"{values['tailscale']['hostname']}.catfish-mountain.ts.net"


def fmt(ports):
    return ", ".join(sorted(ports, key=lambda p: (p.split(":")[0], int(p.split(":")[1]))))


def main():
    edge = edge_games()
    granted = grant_ports()
    ranges, upstream = game_ports_ranges()
    errors = []

    forwarded = set().union(*(g["ports"] for g in edge.values()))
    if forwarded - granted:
        errors.append(f"forwarded by the edge but not in the tag:edge grant: {fmt(forwarded - granted)}")
    if granted - forwarded:
        errors.append(f"in the tag:edge grant but not forwarded by the edge: {fmt(granted - forwarded)}")

    for name, ports in ranges.items():
        game = edge.get(name)
        if game is None:
            errors.append(f"game-ports game {name} has no var.games entry")
            continue
        if game["upstream"] != upstream:
            errors.append(f"var.games {name} forwards to {game['upstream']}, not {upstream}")
        if ports - game["ports"]:
            errors.append(f"game-ports routes {name} ports the edge doesn't forward: {fmt(ports - game['ports'])}")
        if game["ports"] - ports:
            errors.append(f"the edge forwards {name} ports game-ports doesn't route: {fmt(game['ports'] - ports)}")
    for name, game in edge.items():
        if game["upstream"] == upstream and name not in ranges:
            errors.append(f"var.games {name} forwards to game-ports, which has no game {name}")

    if errors:
        for error in errors:
            print(f"::error::{error}")
        sys.exit(1)
    print(f"game ports agree: {len(forwarded)} forwarded, granted and routed")


if __name__ == "__main__":
    main()
