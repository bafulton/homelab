# Pocket ID

Passkey-only OIDC provider at `https://auth.fultonhuffman.com`. It holds one
account per friend, and each public service that should require a login is an
OIDC client restricted to a user group. Granting someone a service means adding
them to its group.

## Architecture

- **Deployment**: one replica, `Recreate`, pinned to local nodes (Longhorn volume)
- **Storage**: `pocket-id-data` (1Gi `config` class): SQLite database and uploads.
  Snapshot nightly, backed up to Garage nightly
- **Secret**: `ENCRYPTION_KEY` from Bitwarden, which encrypts the signing keys in the database
- **Ingress**: Cloudflare Tunnel; client addresses are read from `CF-Connecting-IP`

## First Start

The first visitor to `/setup` becomes the admin, so do this as soon as the app
first syncs:

1. Open `https://auth.fultonhuffman.com/setup` and register your passkey.
2. In **Application Configuration**, set **Enable User Signups** to **Signup with
   token**. Then nobody can register without an invite link.

## Inviting Someone

1. **Users → Create Signup Token**: an expiry, a usage limit of 1, and the
   groups for the services they should reach. Copy the link and send it.
2. They open it, choose a username and email, and register a passkey. A passkey
   works on any modern computer or phone. With no fingerprint reader, it
   unlocks with the device PIN or password, or by scanning a QR code with
   their phone.

A friend who loses their device can be given a **Login Code** from their user
page, which signs them in once without a passkey so they can register a new one.

## Granting and Revoking Access

Each OIDC client in **OIDC Clients** has **Allowed User Groups** set to its
service's group, so Pocket ID refuses to sign anyone else in to that service.

| Group | Service | Client |
|---|---|---|
| `games` | `games.fultonhuffman.com` | `bottleship` (oauth2-proxy) |

Removing someone from a group stops their next sign-in. Each service keeps
its own session, which lasts until that session expires (for games, the
oauth2-proxy cookie lifetime in `apps/bottleship/values.yaml`).

## Adding a Service

1. **OIDC Clients → Add**: callback URL from the service, **Allowed User Groups**
   set to a new group named after the service.
2. Store the client ID and secret in Bitwarden and reference them with the
   `bitwarden-secret` chart in that app.
3. Add a row to the table above.
