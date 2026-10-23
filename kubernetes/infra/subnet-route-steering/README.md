# subnet-route-steering

Home-node companion to the per-node Tailscale **subnet-route** pod mesh that
replaced Kilo. A tiny privileged DaemonSet (one pod per `local` node) that keeps
a route to each **remote** node's pod CIDR on `tailscale0`, plus an ip rule
steering only those CIDRs into it.

## Why it exists

ocifree (the remote node) reaches home pods natively: it runs
`--accept-routes`, so Tailscale installs the home nodes' advertised pod CIDRs
for it (in table 52, flap-safe).

The home nodes **cannot** do the same. `--accept-routes` is all-or-nothing, and
turning it on would make beelink and rpi5 pull *each other's* advertised /24
onto Tailscale - breaking the hard invariant that local↔local pod traffic rides
the bare LAN (flannel) and survives a full home-internet outage. So the home
nodes run `--accept-routes=false`, and Tailscale installs no route to the remote
pod CIDR for them. This DaemonSet installs that one route by hand.

Talos can't express it declaratively: a `LinkConfig` naming `tailscale0` makes
Talos try to own the tailscaled-managed interface and knocks it offline
(verified - it took ocifree down). A DaemonSet only runs `ip` against the live
interface, so it adds a route without ever reconfiguring the link.

## How it works

Each tick (default 30s) the pod:

1. checks `tailscale0` exists - skips the tick if not, so a Tailscale restart
   never crashes the loop;
2. lists nodes matching `remoteNodeSelector` (`homelab.io/location=remote`) and
   reads each one's `.spec.podCIDR` - **remote CIDRs are discovered, never
   hardcoded**;
3. for each CIDR: `ip route replace <cidr> dev tailscale0 table 200`, and adds
   `ip rule to <cidr> table 200 priority 5260` if absent.

### The flap-dodge

Priority **5260** sits *after* Tailscale's own fwmark ip rules (its `5210/5230`
`lookup main/default` and `5250` catch-all) and before its `5270` (`lookup 52`).
The effect, proven live on beelink:

- a normal packet to a remote pod → matches `to <cidr> lookup 200` → exits via
  `tailscale0` (rides the tailnet);
- Tailscale's own disco/underlay packets, stamped `fwmark 0x80000`, are matched
  by the earlier `5230`/`5250` rules first → exit via the **LAN default route**
  (and are dropped upstream), *not* back through `tailscale0`.

That asymmetry is what stops the self-referential loop that made Kilo-over-
Tailscale flap. Home↔home pod traffic never enters any of this - it stays on
flannel over the LAN.

## Scaling

Adding a node touches only that node's *own* config, never the others':

- **Another local node** - gets this DaemonSet automatically (nodeSelector
  `location=local`) and steers whatever remote CIDRs it discovers. Local↔local
  is flannel, which auto-discovers pod CIDRs. Nothing to edit here.
- **Another remote node** - discovered on the next tick via the label selector.
  Nothing to edit here either.

The only cluster-wide prerequisite is the Tailscale ACL, which grants and
auto-approves the whole pod space (`10.244.0.0/16`) for `tag:k8s-node`, so any
node's advertised sub-range is covered without a per-CIDR ACL edit. See
`tailscale/policy.hujson`.

Routes/rules are added, not pruned: if a remote node is removed its stale route
lingers harmlessly until the pod restarts. Acceptable for this fleet's size.
