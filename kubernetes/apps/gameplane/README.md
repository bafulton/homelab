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
- **PKCE**: on
- **Allowed User Groups**: `game-servers`

Put the client ID in `gameplane.api.oidc.clientID` and the client secret in
Bitwarden, referenced as `gameplane-oidc`'s `clientSecret`.

Pocket ID decides who can sign in. Gameplane's Helm-configured sign-in
doesn't request the `groups` scope, so it can't give roles by group:
everyone who signs in is an **operator**, who can create and run servers.

### First admin

Admins manage users, roles and settings. Create a local admin once, then use
it to promote your own Pocket ID account:

```sh
kubectl -n gameplane-system exec -it deploy/gameplane-api -- \
  /api bootstrap-admin --username admin --password-stdin
```

Keep the password in Bitwarden. Sign in with Pocket ID once, so your account
exists, then as `admin` open **Users** and make it an admin.

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
