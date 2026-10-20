# OCI edge forwarder

A free Oracle Cloud micro VM that accepts public HTTPS for one hostname and
passes the TLS, unterminated, over Tailscale to the cluster's Traefik gateway.

It exists so Jellyfin can be publicly reachable without routing video through
Cloudflare's CDN (outside their Service-Specific Terms), without opening a port
at home, and without depending on a stable home IP.

```
viewer ──TLS──> this VM (public IP)
                  │  Traefik TCP router: HostSNI match, tls.passthrough
                  ▼  (terminates nothing, reads nothing)
                Tailscale, outbound-dialed
                  ▼
                cluster-gateway.catfish-mountain.ts.net:443
                  ▼
                home Traefik ──> HTTPRoute ──> jellyfin:8096
```

Viewers need no Tailscale account or client. The tailnet hop is strictly
between the two machines above, both ours.

## Applying

```sh
source ./env.sh     # keychain -> TAILSCALE_*, ~/.oci/config -> compartment
tofu apply
```

`env.sh` holds no secrets, only lookups. Populate the keychain once:

```sh
security add-generic-password -a "$USER" -s tailscale-oauth-client-id -w
security add-generic-password -a "$USER" -s tailscale-oauth-client-secret -w
```

The OAuth client needs the `auth_keys` scope **and `tag:edge` in its tag list**.
The Kubernetes operator's client cannot be reused: OAuth clients are
tag-scoped, and that one carries `tag:k8s-operator`.

OCI needs no setup here - that provider reads `~/.oci/config` directly.

Apply this module **before** `opentofu/cloudflare`, which reads `public_ip`
from this state for the `media` A record.

## Verifying

Everything below should hold after an apply. Substitute the `public_ip` output.

```sh
# cloud-init finished, Traefik up
ssh ubuntu@edge-forwarder 'sudo cloud-init status; systemctl is-active traefik'

# the tailnet hop is DIRECT, not relayed  (see the warm-up note below)
ssh ubuntu@edge-forwarder 'sudo tailscale ping --c 6 cluster-gateway'

# end to end from outside, with the real certificate
curl -sv --resolve media.fultonhuffman.com:443:<public_ip> \
  https://media.fultonhuffman.com/health

# and the forwarder is not a general-purpose door: a different SNI is refused
curl --resolve argocd.catfish-mountain.com:443:<public_ip> \
  https://argocd.catfish-mountain.com      # must fail
```

Then play an actual video, not just a health check. Sustained bytes are the
point, and transcoding exercises different timing than direct play.

## Things that cost time to learn

**Always Free micro quota is per availability domain, and uneven.** In
us-ashburn-1 `standard-e2-micro-core-count` was 0 in AD-1 and AD-2 and 2 in
AD-3. Taking the first AD fails with `400-LimitExceeded`, which reads like an
account problem but just means "wrong AD". `instance.tf` queries
`oci_limits_resource_availability` per AD and picks one with quota.

**A fresh host reports DERP before it reports direct.** NAT traversal needs a
moment and some traffic. On first boot `tailscale ping cluster-gateway` relayed
through `DERP(iad)`, and only after a handful of real requests plus ~20s did it
upgrade to a direct path via the home public IP. Do not conclude the design is
relay-bound from an immediate check - send traffic, wait, then look again. A
genuinely relay-bound path is not worth shipping, since it would push video
through Tailscale's shared infrastructure.

**`udp:41641` inbound is load-bearing** for that direct path, and ICMP type 3
code 4 is open so path-MTU discovery works. Without the latter, large packets
fail in ways that look like random mid-stream stalls rather than a clean error.

**OCI's Ubuntu images DROP everything but SSH in host iptables**, independently
of the VCN security list, so a port reads as open in the console while nothing
can reach it. cloud-init opens and persists the rules.

**The edge cannot see the cluster nodes, by design.** Tailscale filters a
device's network map to peers its grants permit, so `beelink` and `rpi5`
(`tag:k8s-node`) do not resolve from here at all - name lookups fail with
"server misbehaving". Only `tag:k8s` devices and tailnet members are visible.
That is the restriction in `tailscale/policy.hujson` working.

**Traefik requires tailscaled**, because the upstream is a MagicDNS name it
cannot resolve before the tunnel is up.

**`websecure` must have no `tls` block.** Passthrough and termination are
mutually exclusive; this host must never terminate.

**The Tailscale API rejects punctuation in an auth key description** with
`description had invalid characters (400)`, on top of a 50-character cap.
Letters and spaces only.

## What is not here

The `media.fultonhuffman.com` DNS record lives in `opentofu/cloudflare`,
keeping all Cloudflare resources in one place. The tailnet policy lives in
`tailscale/policy.hujson`, applied by its own GitHub Actions workflow - do not
add a `tailscale_acl` resource here, it would fight that workflow for ownership
of the same document.
