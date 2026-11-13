# Gameplane

[Gameplane](https://github.com/GameplanePanel/Gameplane) runs game servers
for friends. They sign in with Pocket ID at
<https://server-admin.fultonhuffman.com>, pick a game template (Minecraft,
Valheim, Factorio and more), and create, start, stop and manage their own
servers. Each server is a `GameServer` in `gameplane-games`, created at
runtime, not kept in git.

The chart comes from GHCR (`oci://ghcr.io/gameplanepanel/charts/gameplane`);
Renovate opens bump PRs. It runs the API and dashboard, and the operator,
which turns each `GameServer` into a StatefulSet, a Service and a world
volume, with an agent sidecar for the console, files and players.

## Setup

### Pocket ID client

In Pocket ID, create the `game-servers` group, then **OIDC Clients → Add**:

- **Callback URL**: `https://server-admin.fultonhuffman.com/auth/oidc/helm/callback`
- **Public Client**: off
- **PKCE**: off. Gameplane doesn't send a PKCE verifier, so Pocket ID would
  reject its sign-ins ("oauth exchange failed"). The client secret still
  authenticates the token exchange.
- **Allowed User Groups**: `game-servers`

Put the client ID in `gameplane.api.oidc.clientID` and the client secret in
Bitwarden, referenced as `gameplane-oidc`'s `clientSecret`.

Pocket ID decides who can sign in. Gameplane's Helm-configured sign-in
doesn't request the `groups` scope, so it can't give roles by group:
everyone who signs in is an **operator**, who can create and run servers.

### First admin and Pocket ID only

Everyone signs in with Pocket ID; local password accounts are turned off.
Gameplane can't make anyone an admin from their Pocket ID groups, so a local
admin is needed once, to promote the first Pocket ID account:

1. Create a local admin:

   ```sh
   kubectl -n gameplane-system exec -it deploy/gameplane-api -- \
     /api bootstrap-admin --username admin --password-stdin
   ```

2. Sign in with Pocket ID once, so your account exists. Sign out, sign in as
   `admin`, and in **Users** make your Pocket ID account an admin.
3. Sign in with Pocket ID again, and in **Admin Settings → Authentication**
   turn off local login. Then delete the `admin` account in **Users**.

This setting lives in Gameplane's database, not in git; the database's
nightly backups keep it. If Pocket ID ever stops working, turn local login
back on, and create an admin again, from the cluster:

```sh
kubectl -n gameplane-system exec deploy/gameplane-api -- \
  /api bootstrap-admin --enable-local-login
kubectl -n gameplane-system exec -it deploy/gameplane-api -- \
  /api bootstrap-admin --username admin --password-stdin --force
```

## Local access

On the LAN, <https://server-admin.local> serves the same dashboard over the
`local` listener, with the homelab CA (see
[household access](../../../docs/local-household-access.md) for enrolling a
device). Gameplane has one sign-in callback, on the public hostname, so
signing in with Pocket ID from `server-admin.local` finishes on
`server-admin.fultonhuffman.com`.

## Game templates

Install game templates from the dashboard's module catalog. Before
installing one, check its image's architectures: Gameplane doesn't place
pods by architecture, so add an amd64-only game to `amd64OnlyGames` in
values.yaml, and `templates/amd64-placement.yaml` pins its pods to amd64
nodes. Valheim and Terraria are amd64 only; Minecraft and Factorio run
anywhere. Game servers keep their templates' CPU limits; only Gameplane's
own pods have theirs removed.

## Public Minecraft

Every Minecraft server is public at `<server>.minecraft.fultonhuffman.com`,
on the usual port. `templates/minecraft-names.yaml` gives each server that
name as it's created, mc-router (`kubernetes/apps/mc-router`) routes players
to it by the hostname their client sends, and the OCI edge forwarder
(`opentofu/oci-forwarder`) carries port 25565 to mc-router. Anyone on the
internet can reach the port, so turn on each server's whitelist.

## Storage and backups

- **Worlds** are `config` Longhorn volumes, replicated, so servers can run on
  any node. Deleting a server deletes its world: Gameplane's world volume
  belongs to the `GameServer`.
- **The API's database** (accounts, roles, settings) is `gameplane-api-data`,
  with nightly snapshots and an off-node backup.

## Notes

- **Agent mTLS:** the API and operator talk to each game's agent over mTLS.
  `templates/agent-mtls.yaml` issues that CA and client certificate with
  cert-manager, since the chart's own generation needs a Helm lookup that
  Argo CD can't do.
- **Telemetry:** off (`gameplane.api.telemetry.enabled: false`). The chart
  turns it on by default.
- **CPU limits:** the upstream chart sets them; `cpu: null` removes them, with
  `honorNulls: true` so Argo CD applies those nulls.
- **Pruning** is off for this app: removing a CRD would delete every
  `GameServer`, and with it every world.
