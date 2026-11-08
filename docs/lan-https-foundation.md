# LAN HTTPS foundation

This foundation issues the private-CA server certificate and permits a shared
`local` HTTPS listener and explicit `.local` route names in the shared chart and admission policy. It does
not publish port 443, add Gateway listeners, change application routes, or redirect
existing HTTP traffic. The dependent household-access PR enables those pieces
only after this certificate is Ready.

## Certificates and Mac enrollment

`traefik-apps` owns `Certificate/household-local` and Secret `household-local-tls`.
Its explicit SANs are `games.local`, `home.local`, and `media.local`. It is signed
by the existing `homelab-ca` ClusterIssuer, uses 90-day server certificates, and
renews 30 days before expiry. The private root/key remains in the cluster.

Before enrollment or rollout, verify the live issuer and root:

```sh
kubectl get clusterissuer homelab-ca
kubectl -n cert-manager get certificate homelab-root-ca -o wide
kubectl -n cert-manager get certificate homelab-root-ca \
  -o jsonpath='{.status.notAfter}{"\n"}{.status.renewalTime}{"\n"}'
```

Readiness/expiry checked on November 7, 2026: root Ready, expires
January 1, 2036. Recheck rather than relying on that observation indefinitely.

Export **only the public certificate**, not the Secret YAML or its private key:

```sh
kubectl -n cert-manager get secret homelab-root-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/homelab-root-ca.crt
openssl x509 -in /tmp/homelab-root-ca.crt -noout -subject -issuer -dates -fingerprint -sha256
```

On the personal Mac, open Keychain Access, import that certificate into the
System keychain, open its Trust settings, and set **Secure Sockets Layer (SSL)**
to **Always Trust**. Authenticate the change and restart the browser if needed.
Verify the SHA-256 fingerprint against the exported certificate. This trusts the
CA, not just one server certificate: its other issued TLS certificates can also
be accepted by this Mac. Keep the root key protected.

Routine server renewal or adding a SAN under the same trusted root does not
require re-enrollment. A new/reset device, removed trust, or root replacement
does. Do not replace/recreate the root as part of this rollout.

The existing root Certificate has a ten-year duration and renews one year before
expiry. **Do not assume this automatically preserves client trust.** Before its
reported renewal time, plan an overlapping root transition: distribute and trust
the replacement root, reissue server certificates, verify clients, then retire
the old trust. Changes to an issuer Secret do not automatically reissue all its
leaves. Also track root and leaf expiry; the CA issuer can issue a leaf that
outlives its CA. Restore the existing CA Secret from a protected backup during
recovery rather than silently minting a new root.

## Foundation rollout and verification

Sync `gateway-policies` and `traefik-apps` after merging the foundation PR.
Confirm the updated policies have no `status.typeChecking.expressionWarnings`:

```sh
kubectl get validatingadmissionpolicies gateway-public-listeners-need-public-hostname httproute-access-boundary -o yaml
kubectl -n traefik-apps wait --for=condition=Ready certificate/household-local --timeout=120s
kubectl -n traefik-apps get certificate household-local -o wide
kubectl -n traefik-apps get gateway,svc
```

The existing Gateway/Service still expose only their previous entrances. The new
`local` listener is permitted only on traefik-apps, with HTTPS port 443 and
hostname `*.local`. Attached routes must list explicit `.local` names. The
certificate still lists only games/home/media.local; a routing wildcard does
not make certificates valid for other names. Existing admin/public boundaries and
CRD ownership remain intact. Run `./scripts/validate-ingress.sh` with freshly
resolved dependencies before merge.

For rollback before the application PR, revert this foundation through GitOps;
only the new leaf certificate and policy permissions are removed. Never delete
the shared root CA. If application routes/listeners have subsequently been
installed, remove them first, then roll back this foundation. The dependent PR
contains the full application verification and rollback runbook.
