# Keep Jellyfin SSO on the starting origin

The old branding button starts authentication at the public hostname even
when opened at `media.local`. The SSO provider also forces HTTPS, so changing
only the button would generate an unusable `https://media.local` callback.

These are dashboard-managed settings on persistent storage, not Helm values.
This runbook prepares their migration; merging it does not perform the migration.
Do not restart Jellyfin while someone is streaming without arranging a window.

## Expected behavior

| Starting entrance | Pocket ID callback | Session and playback entrance |
| --- | --- | --- |
| `http://media.local` | `http://media.local/sso/OID/redirect/pocket-id` | `http://media.local` |
| `https://media.fultonhuffman.com` | `https://media.fultonhuffman.com/sso/OID/redirect/pocket-id` | `https://media.fultonhuffman.com` |

Pocket ID stays at `https://auth.fultonhuffman.com`. Keep the existing client
secret, PKCE, `media` allowed group, and plugin `media`/`media-admins` role checks.
Jellyfin establishes its own session on each origin; this is not cookie sharing.
Local HTTP traffic, including Jellyfin session tokens, remains unencrypted.
Browser casting still requires HTTPS.

## Rollout

1. Record the current Jellyfin **Networking → Known Proxies**, SSO provider
   scheme/port overrides, branding login disclaimer, and Pocket ID callback list.
   Keep the existing local administrator password available for recovery.
2. Add the exact local callback in the table to the existing Pocket ID Jellyfin
   client. Retain its public callback; do not add wildcard callbacks. Verify
   Pocket ID accepts the local callback before proceeding. A working Home
   Assistant HTTP login does not prove that this client accepts one. Pocket ID
   2.19.2 has an `ALLOW_INSECURE_CALLBACK_URLS` setting affecting the provider
   globally; do not silently enable it or relax HTTPS issuer validation as part
   of this migration. If the callback is rejected, stop and retain public SSO.
3. Configure Jellyfin **Networking → Known Proxies** with the actual Traefik
   pod source IPs. Find the current candidates with:

   ```sh
   kubectl -n traefik-apps get pods -l app.kubernetes.io/name=traefik -o wide
   ```

   Confirm the transport source seen by Jellyfin for both entrances, especially
   if networking or placement changes. Use individual proxy addresses, not the
   LAN VIP, the OCI forwarder address, or an unrestricted proxy trust range.
   Include both Traefik replicas. Pod IPs are ephemeral: refresh this setting
   and restart Jellyfin after proxy replacement before relying on SSO. This
   manual maintenance is a limitation of the dashboard-managed configuration.
   Do not widen trust to the entire cluster or enable insecure forwarded-header
   trust in Traefik to avoid maintaining this list.
4. Restart Jellyfin to load its known proxies. Leave the SSO scheme override
   at `https` until the restart completes.
5. In **SSO Authentication → pocket-id**, clear **Scheme Override** and
   **Port Override**. Keep **Disable HTTPS**, **Do Not Validate Endpoints**, and
   **Do Not Validate Issuer Name** off: those govern the identity provider,
   which remains HTTPS. The plugin now uses Jellyfin's request host and scheme;
   trusted Traefik forwarding supplies HTTPS for the public entrance.
6. In **General → Branding → Login disclaimer**, replace the absolute form
   action with the relative path, preserving the button styling:

   ```html
   <form action="/sso/OID/start/pocket-id">
     <button class="raised block emby-button button-submit">Sign in with Pocket ID</button>
   </form>
   ```

## Verification before declaring the migration complete

- In separate fresh browser sessions, open each starting entrance and click
  Pocket ID. Preserve the network log. The first SSO request must stay on the
  starting origin, and the authorization request's `redirect_uri` must match
  the table exactly. Public SSO must never request an HTTP callback.
- Complete both logins as a `media` user. Confirm the callback, final Jellyfin
  page, API requests, and session stay on their respective origins. Verify a
  user outside `media` cannot sign in, and a plain `media` user is not an admin.
- At `media.local`, play a known video and seek. Confirm segment/range requests
  and WebSocket connections target `media.local`, resolving to `192.168.1.200`,
  rather than the public hostname or OCI address. Check public playback too.
- Log out of each origin, confirm its Jellyfin session is cleared, then sign
  in again. Pocket ID may retain its own SSO session; that is expected. Check
  local password login and a TV/app Quick Connect login still work.
- Try a mismatched `X-Forwarded-Proto` header at each gateway entrance. It must
  not let the caller change the callback scheme. Check both Traefik replicas;
  if public requests generate HTTP callbacks, restore the override and verify
  the trusted transport source rather than disabling validation.

These browser checks require the dashboard migration; they have not been
completed merely by reviewing this runbook. No ingress resources change, so
the existing ingress boundaries remain in place.

## Rollback

Restore the public absolute form action and the `https` scheme override first.
Restore the previous port override. Remove the newly added local callback from
the Pocket ID client, retaining its public callback. Restore the saved Known
Proxies list and restart Jellyfin if it changed. Verify a fresh public Pocket
ID login and password login. This restores the previous behavior where the
Pocket ID button on `media.local` leads to the public origin.

## Source checks

- [SSO plugin 5.1.1 controller](https://github.com/K0lin/jellyfin-plugin-sso/blob/v5.1.1/SSO-Auth/Api/SSOController.cs): `OidChallenge`, `OidPost`, and `GetRequestBase`
  build authentication URLs from `Request.Host` and either `SchemeOverride`
  or `Request.Scheme`; callback completion also uses that base URL.
- [Jellyfin reverse proxy guidance](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/)
  requires known proxies before forwarded headers are accepted.
- [Pocket ID 2.19.2 callback checks](https://github.com/pocket-id/pocket-id/blob/v2.19.2/backend/internal/oidc/provider.go)
  distinguish redirect matching from the insecure-callback policy.
