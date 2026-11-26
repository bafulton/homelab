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

## Game templates

Install game templates from the dashboard's module catalog. Before
installing one, check its image's architectures: Gameplane doesn't place
pods by architecture, so add an amd64-only game to `amd64OnlyGames` in
values.yaml, and `templates/amd64-placement.yaml` pins its pods to amd64
nodes. Valheim and Terraria are amd64 only; Minecraft and Factorio run
anywhere. Game servers keep their templates' CPU limits; only Gameplane's
own pods have theirs removed.

## Idle sleep

New servers sleep after 30 minutes without players, and wake when a player
joins: `templates/idle-sleep.yaml` sets `spec.idle` on each server as it is
created, from `idleSleep` in values.yaml. While a server sleeps, Gameplane's
sentinel pod holds its ports in place of the game, and a player joining
wakes it. A Minecraft player is held until the server is up, or, if it takes
longer than about 25 seconds, told to try again shortly; server-list pings
are answered without waking it. Players of UDP games (Valheim, Factorio)
retry until the server is up.

Owners change the delay, or turn sleep off, in a server's **Settings →
Lifecycle**; the policy only fills in servers created without idle settings,
so their choice sticks. A server only sleeps when Gameplane can count its
players: Valheim reports no player count, so Valheim servers never sleep,
until Gameplane can read it from the Steam query
([Gameplane#991](https://github.com/GameplanePanel/Gameplane/pull/991),
[module#74](https://github.com/GameplanePanel/module/pull/74)).

## Public Minecraft

Every Minecraft server is public at `<server>.minecraft.fultonhuffman.com`,
for Java players (no port) and Bedrock players (port 19132). Players at home
go out through the edge too, same as every other game
(`kubernetes/apps/game-ports`) - no LAN shortcut, no `.local` name; all
games stay consistent until there's measured evidence that routing a home
connection out through the edge and back is actually a problem. The
minecraft-gateway (`kubernetes/apps/minecraft-gateway`) routes players by
the hostname their client sends, and the OCI edge forwarder
(`opentofu/oci-forwarder`) carries its ports there. Two policies here set up
each server for it:

- **`templates/minecraft-names.yaml`** gives each Minecraft server its public
  name, both in the Service annotation the gateway routes by and as the
  hostname the dashboard shows. A server that sets its own keeps it.
- **`templates/minecraft-floodgate.yaml`** gives each Paper server the
  Floodgate plugin and the key it shares with the gateway's Geyser
  (`floodgate-key`, from Bitwarden), so Bedrock players can join without a
  Java account. Fabric and Forge servers get no Floodgate; only Java players
  can join those.

Anyone on the internet can reach the ports, so turn on each server's
whitelist, and add Bedrock players with `fwhitelist add <gamertag>` in its
console.

The policies apply when a server is created, updated or given a new pod. To
bring an existing server up to date, **stop and start** it in the dashboard:
stopping updates the server, and starting creates a new pod. **Restart**
isn't enough, since it restarts the game inside the same pod.

These policies depend on how Gameplane builds servers: the
`gameplane.local/template` pod label, a container named `game` with the
image's `TYPE` setting, and the plugins volume at `/data/plugins`. After a
Gameplane upgrade, check that a new Minecraft server still gets its name and
Floodgate.

## Public Valheim and Factorio

Valheim and Factorio servers are public at `valheim.fultonhuffman.com` and
`factorio.fultonhuffman.com`, each server on ports of its own: the first
server of each game has the game's default port, and later ones add theirs,
for example `valheim.fultonhuffman.com:2459`. The dashboard shows each
server's address. `operator.portPools` above hands out the ports
(GameplanePanel/Gameplane#1001); `templates/game-ports.yaml` gives each
server a loadBalancerClass and hostname (GameplanePanel/Gameplane#1000 and
#999); and the game-ports app (`kubernetes/apps/game-ports`) publishes that
hostname as the server's address, routes each port to the server holding
it, and runs an end-to-end canary check - see its README. Set a server
password on each: the ports are open to the internet.

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
- **CRDs and pruning:** the `gameplane-crds` app
  (`kubernetes/apps/gameplane-crds`) owns the CRDs, and this app sets
  `skipCrds: true`. Removing a CRD would delete every `GameServer` of that
  kind, and with it every world, so pruning stays off for this app until the
  `gameplane-crds` app has taken the CRDs over.
