# Game server

Shared Helm chart for a dedicated game server: a single-replica StatefulSet,
a Tailscale Service the OCI edge forwarder reaches it through, and an optional
MetalLB Service for playing from home. One release is one instance; a second
world is a second wrapper app.

The chart is at 0.x until two games run on it (CAT-83 Minecraft, CAT-91
Valheim). Expect the values interface to change before 1.0.0.

What stays in each game's wrapper: the image, game configuration, mods, the
save-and-stop command, the game's own access control (whitelist or password -
its ports are public), and the companion charts below.

## A new game

A wrapper composes this chart with the existing shared charts, the same way
other apps do. Each companion is its own dependency rather than a subchart of
this one, so its values sit at the top level where they always do.

```yaml
# kubernetes/apps/valheim/Chart.yaml
apiVersion: v2
name: valheim
version: 1.0.0
dependencies:
  - name: game-server
    version: 0.1.0
    repository: file://../../../charts/game-server
  - name: longhorn-storage
    version: 1.0.0
    repository: file://../../../charts/longhorn-storage
  - name: bitwarden-secret
    version: 1.0.0
    repository: file://../../../charts/bitwarden-secret
```

```yaml
# kubernetes/apps/valheim/values.yaml
longhorn-storage:
  pvcs:
    - name: valheim-config
      size: 10Gi                     # storageClass defaults to config

bitwarden-secret:
  secrets:
    - name: valheim-server
      data:
        SERVER_PASS: <bitwarden-secret-uuid>

game-server:
  game: valheim
  arch: amd64                        # the image is amd64-only
  workload:
    image:
      repository: ghcr.io/community-valheim-tools/valheim-server
      tag: <pinned>
    envFrom:
      - secretRef:
          name: valheim-server
    resources:
      requests: {cpu: 500m, memory: 3Gi}
      limits: {memory: 6Gi}
    lifecycle:
      preStop:
        exec:
          command: [supervisorctl, stop, valheim-server]
  persistence:
    config:
      claimName: valheim-config
      mountPath: /config
  ports:
    - {name: game, port: 2456, protocol: UDP}
    - {name: query, port: 2457, protocol: UDP}
```

That gives a running server at `game-valheim.catfish-mountain.ts.net`. To let
friends in from the internet, see [Making a game public](#making-a-game-public).

`ci/` holds the fixtures `helm template` is checked against, one per mode.

## Two modes

**Direct** (`workload.enabled: true`, the default): this chart runs the game
server. Valheim and Factorio work this way.

**Services only** (`workload.enabled: false`): a game manager or an upstream
chart brings its own pods, and this chart adds the Services and the
`games.homelab.io/*` labels. Point `service.selector` at those pods. A manager
like Crafty runs several game servers as child processes of one pod, so list
every child server's port in `ports`.

## Storage

Each entry in `persistence` mounts a PVC by name. Create the PVC with the
`longhorn-storage` chart in the wrapper, so its name is stable for backups and
restores.

Use the Longhorn `config` class (its default). Its two replicas live on the
home nodes and the volume attaches wherever the pod runs, so a game floats
between nodes, ocifree included, with nothing pinned. The strict-local
`state` and `scratch` classes would tie the game to beelink.

Set `workload.fixPermissions.enabled` when the image writes as a different
user than the volume's files belong to, for example after restoring a world
copied from elsewhere. It chowns each mount to `runAsUser:runAsGroup` before
the game starts.

## Ports and Services

Each entry in `ports` becomes a container port and a port on every Service.
A Service mixes TCP and UDP freely.

- **Tailnet** (always): a Tailscale LoadBalancer named
  `game-<release>.catfish-mountain.ts.net`, tagged `tag:k8s-games`. The
  Tailscale proxy forwards to the ClusterIP, so it reaches the pod on any node.
  This is what the edge forwarder connects to.
- **LAN** (`lan.enabled`): a MetalLB address from `192.168.1.200-250`, for
  playing from home without the round trip through OCI.

## Placement

`arch` sets the only selector: `amd64`, `arm64`, or empty for a multi-arch
image. ARM64 games can run on ocifree, which has the free memory; amd64-only
games land on beelink. Add `workload.nodeSelector` only for a real constraint,
not to choose a location.

## Start and stop

`workload.replicas: 0` stops the server and frees its memory request on the
node. `1` starts it. The `preStop` hook in `workload.lifecycle` is where each
game saves the world; `terminationGracePeriodSeconds` (120 by default) must be
long enough for it.

For something other than git to start and stop a server (the game portal, or
mc-router waking Minecraft on connect), set
`workload.replicasManagedExternally: true`. The StatefulSet is then rendered
without `spec.replicas`, the way a workload scaled by an autoscaler is, and
`portal.subjects` grants a ServiceAccount the scale subresource of this one
StatefulSet. When switching an instance that already exists, also add this to
the wrapper's `values.yaml`, because the manifest ArgoCD last applied still
sets replicas:

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers: [/spec/replicas]
```

## Making a game public

The public entrance is the OCI edge forwarder, configured in
`opentofu/oci-forwarder`. It is explicit infrastructure, separate from this
chart: a game Service on the tailnet is not reachable from the internet until
the forwarder is told about it.
