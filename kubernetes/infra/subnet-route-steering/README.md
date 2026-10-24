# subnet-route-steering

Home-node companion to the per-node Tailscale **subnet-route** pod mesh. A tiny
NET_ADMIN DaemonSet (one pod per `local` node) that keeps **local↔local** pod
traffic on the bare LAN (flannel), while **remote** pod traffic rides Tailscale.

## The point

The two home nodes (beelink, rpi5) must be able to talk to each other over
**nothing but the LAN** — no Tailscale, no internet, no reachable Tailscale
coordination server. The home cluster (Home Assistant, mosquitto, MetalLB, DNS,
storage) has to keep working through an ISP outage, a Tailscale outage, or a WAN
blip; coupling that traffic to Tailscale would mean a cloud dependency can take
the house offline. So home↔home pod traffic must **never** ride Tailscale — even
though every node runs `--accept-routes` so it *can* reach the remote cloud node.

That tension is the whole reason this app exists. Tailscale's `--accept-routes`
is all-or-nothing: a home node that accepts the remote node's routes also
accepts the *other* home node's, which would quietly pull local↔local traffic
onto Tailscale and break the guarantee above. This DaemonSet supplies the
missing selectivity — pinning the local routes back to the LAN — so the cluster
can span the internet without making the home half depend on it.

## The mesh it belongs to

Every node runs `--accept-routes` and `--snat-subnet-routes=false`, and
advertises its own pod `/24` as a Tailscale subnet route (autoApproved for
`tag:k8s-node`, see `tailscale/policy.hujson`). So each node installs every
other node's pod `/24` into Tailscale's own routing table (table 52, selected by
`ip rule` priority 5270), and cross-node pod traffic rides Tailscale natively -
no second WireGuard layer, no reconcile loop, no path flap. `snat=false`
preserves the real pod source IP, which is why replies route back and why the
ACL lists the pod space as both src and dst.

## How it supplies the missing selectivity

The native behaviour above is right for the **remote** node but wrong for the
two **home** nodes (see [The point](#the-point)): left alone, each home node
accepts the other's advertised `/24` into table 52 and sends local↔local pod
traffic over Tailscale.

So on each local node this DaemonSet adds an `ip rule` at priority **5260** -
after Tailscale's fwmark rules (≤5250) and *before* its table-52 rule (5270) -
that sends each **other** local node's pod CIDR to the `main` table, where
flannel's LAN route wins:

    5260:  to 10.244.1.0/24  lookup main   # on beelink, for rpi5's pods -> LAN
    5270:  from all          lookup 52      # everything else (incl. remote) -> Tailscale

Remote pod CIDRs get no such override, so they fall through to 5270/table 52 and
ride Tailscale.

### Node IPs, not just pod CIDRs

The home nodes also advertise their own **node `/32`** (e.g. `192.168.1.86/32`)
as a subnet route, so the remote node can reach the apiserver — the `kubernetes`
ClusterIP (`10.96.0.1`) DNATs to a control-plane node's LAN IP — and any other
node-IP-backed service. Without it, every pod on the remote node fails to reach
the API.

That means each home node accepts the other's node `/32` into table 52, which
would send home↔home node traffic over Tailscale — and because flannel's VXLAN
underlay is keyed on node IPs, that would drag pod traffic onto Tailscale too.
So this DaemonSet also pins the whole home LAN (`localLanCIDR`, `192.168.1.0/24`)
to `main` at priority 5260, keeping all home↔home node/LAN traffic on flannel.

### Each tick (default 5m)

1. Pin `localLanCIDR` (`192.168.1.0/24`) to `main` at priority 5260.
2. `kubectl get nodes -l homelab.io/location=local` → each node's name + `.spec.podCIDR`.
3. Skip our own node (its pods are local, on `cni0`).
4. For every other local node: add `ip rule to <cidr> table main priority 5260` if absent.

It is a reconcile loop, not a one-shot, so the rules survive a Tailscale restart
(which recreates `tailscale0` and can reset policy) and new local nodes are
picked up with no redeploy. `enabled: false` flips it into a self-cleanup that
removes the rules it added and idles - the rollback path.

## Why the invariant still holds

- **Internet up:** the 5260 rules keep local↔local on flannel; remote rides Tailscale.
- **Internet down:** Tailscale drops its routes, table 52 empties, and
  local↔local falls back to flannel on its own - the override is simply moot.

The only gap is a few seconds at boot before the pod's first tick, and only
while the internet is *up* (when it's down, table 52 is empty anyway), so it
never threatens outage survival.

## Scaling

Adding a node touches only that node's own Talos config (advertise its `/24`);
nothing here and no other node's config:

- **Another local node** - gets this DaemonSet automatically (nodeSelector
  `location=local`), and every local node discovers it via the label selector
  and pins it to the LAN on the next tick.
- **Another remote node** - rides Tailscale natively; nothing to pin.

The ACL grants and auto-approves the whole pod space (`10.244.0.0/16`) for
`tag:k8s-node`, so a new node's advertised `/24` is covered with no ACL edit.

Rules are added, not pruned: if a local node is removed its stale rule lingers
harmlessly (its CIDR is unused) until the pod restarts.
