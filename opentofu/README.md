# OpenTofu

Infrastructure outside the Kubernetes cluster. Everything here is **applied by
hand** - there is no CI for it, and state is local and gitignored.

| Module | What it manages |
|---|---|
| [`cloudflare/`](cloudflare/README.md) | Zones, DNS records, and the Cloudflare Tunnel that fronts the public domains |
| [`oci-forwarder/`](oci-forwarder/README.md) | The Oracle Cloud micro VM that serves `media.fultonhuffman.com` without putting video on Cloudflare's CDN |

## Apply order

`oci-forwarder` before `cloudflare`. The `media` A record reads the forwarder's
public IP out of its state, so applying the other way round plans against a
stale or empty value.

Modules are otherwise independent and have separate state.

## Credentials

Each module picks up what it needs from the environment rather than from files
in the repo:

- **`cloudflare/`** needs `CLOUDFLARE_API_TOKEN`, from Bitwarden.
- **`oci-forwarder/`** reads OCI credentials from `~/.oci/config` directly, and
  gets its Tailscale credentials plus two non-secret locals from
  `source ./env.sh` - that script holds only lookups and is safe to read.

No OCIDs, tokens, or keys belong in a committed `.tf` or `.tfvars` file.

## Oracle Cloud free-tier budget

Worth knowing before adding anything, since the allowances are shared across
the tenancy:

| Resource | Always Free | In use |
|---|---|---|
| AMD `VM.Standard.E2.1.Micro` | 2 instances (1/8 OCPU, 1 GB each) | 1 - `edge-forwarder` |
| Ampere A1 | 1,500 OCPU-hrs + 9,000 GB-hrs/month, i.e. 2 OCPU / 12 GB continuous | 0 - reserved for the `ocifree` cluster node |
| Block storage | 200 GB total, boot volumes included | 50 GB |
| Egress | 10 TB/month | far under |

The A1 allowance was halved from 4 OCPU / 24 GB on 2026-06-15.

**This tenancy is on Pay As You Go**, which has two consequences. Idle
instances are no longer reclaimed - the reclamation policy is scoped to Always
Free compute. But service limits no longer describe what is free: the A1 limit
reports 250 cores available, so exceeding the allowance above now succeeds and
bills, where an Always Free tenancy would simply refuse.

Micro quota is granted per availability domain and is not uniform - see
[`oci-forwarder/README.md`](oci-forwarder/README.md), which also records the
rest of what that build taught us.
