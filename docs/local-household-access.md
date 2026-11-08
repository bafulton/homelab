# Household LAN access

Use these names on the home LAN. Router/client DNS settings are unchanged: the
mDNS advertiser answers for the LAN VIP `192.168.1.200`.

| URL | Behavior | Device setup |
| --- | --- | --- |
| `http://games.local` | 302 to `https://games.local`, preserving path/query | Trust the homelab root CA |
| `https://games.local` | BottleShip with local HTTPS, bundles and secure WebSockets | Trust the homelab root CA |
| `http://home.local` | Existing Home Assistant HTTP entrance | None |
| `https://home.local` | 302 to `http://home.local`, preserving path/query | Trust the root to receive the redirect |
| `http://media.local` | Existing Jellyfin HTTP entrance, including TV clients | None |
| `https://media.local` | 302 to `http://media.local`, preserving path/query | Trust the root to receive the redirect |

The home/media HTTPS entrances are redirect conveniences, not encrypted app
sessions. No global HTTP redirect or HSTS policy is enabled. A browser with
HTTPS-only mode or previously cached HSTS can still refuse a downgrade; use a
browser policy that permits these HTTP URLs. Unenrolled clients see a certificate
error before any HTTPS redirect. They can use the HTTP home/media URLs directly
and the existing public HTTPS BottleShip URL.

## Certificates and Mac enrollment

The prerequisite foundation PR issues the shared private-CA certificate.
Follow [LAN HTTPS foundation](lan-https-foundation.md) for CA verification,
one-time Mac enrollment, leaf renewal, and root-rotation planning. Confirm
`Certificate/household-local` is Ready and the updated policies have no type
warnings before enabling this PR's listeners and routes.

## Pocket ID prerequisite

In the existing BottleShip OIDC client, add the exact callback:

```text
https://games.local/oauth2/callback
```

Keep `https://games.fultonhuffman.com/oauth2/callback`, PKCE, confidential-client
mode, and the `games` allowed group unchanged. This is an additive edit in
Pocket ID; OIDC client registrations are not currently managed by this repo.
It must be completed before testing local login. A callback wildcard is not
needed.

The public and local entrances use separate oauth2-proxy Deployments/Services
and host-only, Secure cookies with distinct names. Both use the existing
credentials and public issuer `https://auth.fultonhuffman.com`. There is no
`auth.local`; initial login, token operations, and later reauthentication can use
the internet. Session validation and application forwarding remain at home.

Browser storage is origin-specific. Existing public-origin saves/filesystem
permissions do not automatically appear at `https://games.local`; export/import
saves through BottleShip if needed. Multiplayer invite URLs reflect the entrance
used by the host: `.local` links are for players on the same LAN.

## Rollout

This change follows the mandatory household placement work in CAT-22 / PR #605.
The apps gateway and all household app/session endpoints must be on home nodes.
Private CoreDNS, Tailscale proxies, and administrative gateway placement are not
part of this change.

1. Capture the current revision, Gateway/Service/HTTPRoute/Certificate status and
   home-node pod placement. Add the Pocket ID callback and enroll the personal
   Mac. Keep a public URL available for access throughout rollout.
2. Merge and sync the foundation PR first. Confirm `Certificate/household-local`
   is Ready and the updated policies have no type warnings. This makes the leaf
   certificate available before this PR enables any listeners.
3. Merge this dependent PR; sync `traefik-apps`, then `bottleship`,
   `home-assistant`, and `jellyfin`. Check listener/route status and both gateway
   replicas. Argo apps reconcile independently; a route waiting for its listener
   should be retried after the gateway sync, not worked around by weakening the
   policies.
4. Execute the checks below and CAT-24's full client/path matrix. Record evidence
   against the deployed revision. The PR's render tests do not establish live
   browser behavior or prove a local network path.

## Verification after deployment

```sh
kubectl -n traefik-apps get gateway,svc,certificate
kubectl -n bottleship get deployment,svc,httproute
kubectl -n home-assistant get httproute
kubectl -n jellyfin get httproute
kubectl -n traefik-apps get pods -o wide
kubectl -n bottleship get pods -o wide
```

Check the LAN Service exposes 80/443, the Tailscale Service still exposes only
80/8443, all three exact-host LAN listeners are Programmed/Accepted, and all
routes have Accepted/ResolvedRefs. Check the local certificate is Ready and
matches the enrolled CA.

Use the exported public CA for independent TLS verification, without `-k`:

```sh
curl --cacert /tmp/homelab-root-ca.crt -I https://games.local/
curl -I 'http://games.local/test/path?probe=local'
curl --cacert /tmp/homelab-root-ca.crt -I 'https://home.local/test/path?probe=local'
curl --cacert /tmp/homelab-root-ca.crt -I 'https://media.local/test/path?probe=local'
```

Expect games HTTP -> HTTPS, home/media HTTPS -> HTTP, correct default ports and
unchanged path/query. Check no `Strict-Transport-Security` response header is
present on the LAN entrances. Verify HTTP home/media still work on an unenrolled
device; an unenrolled HTTPS request should fail certificate validation.

Open `https://games.local` in the intended Chrome/Edge profile, sign in through
public Pocket ID, and confirm the browser returns to games.local. In the console:

```js
window.isSecureContext // true
window.crossOriginIsolated // true (COOP/COEP must remain intact)
typeof SharedArrayBuffer // "function"
!!navigator.gpu // true on a supported browser/GPU
```

Exercise filesystem/save permissions, a real game, bundle downloads/range
requests, session expiry/logout, and multiplayer over `wss://games.local`.
Browser network logs must show local application URLs rather than redirects or
absolute asset URLs using the public entrance. Recheck public BottleShip login,
public HA/Jellyfin access, and rejection of admin Host/SNI requests on LAN/public
entrances.

For CAT-24, test clients with Tailscale both enabled and disabled. Correlate
requests with gateway/backend logs. Explicitly test a gateway and backend on
different home nodes: inspect subnet-route-steering's rules plus narrowly scoped
captures to show Flannel's bare-LAN transport, not just home pod placement. DNS
lookups through mDNS and all application connections must remain on the LAN;
public authentication and unrelated integrations are accepted dependencies.

## Rollback

Revert the HTTPS change through GitOps, removing LAN HTTPS routes/listeners and
the games advertisement/HTTP redirect. Keep the existing public callback and
public ingress; do not weaken auth or publish admin services on household ingress.
The additive Pocket ID local callback can then be removed. The foundation's
certificate/policy permissions may stay installed; roll that PR back separately
only after these routes/listeners are gone. Remove root trust in Keychain Access
if no longer wanted. Never delete the shared root CA or public TLS Secrets.
