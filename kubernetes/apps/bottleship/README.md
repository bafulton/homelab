# BottleShip

Classic Windows games in the browser at `https://games.fultonhuffman.com`,
for friends signed in through Pocket ID (group `games`).

The emulator runs entirely in each visitor's browser (WebGPU, so Chrome or
Edge). This app serves the frontend and the game bundles; a separate relay puts
players' browsers on one virtual LAN for multiplayer.

## Architecture

- **Image**: `ghcr.io/ievans/bottleship`, published by `ievans/bottleship` for
  each release
- **LAN relay**: `ghcr.io/ievans/bottleship-lan`, the Rust relay from
  `ievans/bottleship` (`Dockerfile.lan`), published for each release with the
  app's version. Its own Deployment (`templates/lan-relay.yaml`), ClusterIP only:
  browsers reach it at `/socket.io/` on the games hostnames, behind the same
  sign-in as the site. The relay has no accounts, so that path rule is its only
  access control. Never give it a route of its own
- **Bundles**: `bottleship-apps`, a hostPath on beelink's USB disk
  (`/var/mnt/usb/bottleship`), backed up weekly to Garage by VolSync
- **Library**: `games` in `values.yaml`, served as `/games-catalog.json`
- **Sign-in**: oauth2-proxy answers Traefik's `forwardAuth` for every request;
  Pocket ID only signs in members of the client's allowed groups. The proxy
  requires `homelab.io/location=local` so session handling stays at home;
  any separate `games.local` session deployment must use the same placement.
  Public Pocket ID login remains an internet dependency. See the
  [household rollout and rollback](../../infra/traefik-apps/README.md#household-placement-and-rollout).
- **Ingress**: OCI edge forwarder → Traefik's edge listener for
  `games.fultonhuffman.com`. Bundles are multi-GB, which keeps them off
  Cloudflare's CDN for the same reason as Jellyfin's video

## Pocket ID Client

In Pocket ID, **OIDC Clients → Add**:

- **Callback URLs**: `https://games.fultonhuffman.com/oauth2/callback` and
  `https://games.local/oauth2/callback` (add the local callback to the existing
  client before testing LAN login; keep the public one)
- **Public Client**: off. oauth2-proxy needs a client secret
- **PKCE**: on
- **Allowed User Groups**: `games` (create the group first)

Put the client ID in `oauth2Proxy.clientId` and the client secret in Bitwarden,
referenced as `OAUTH2_PROXY_CLIENT_SECRET`.

## Local HTTPS

On an enrolled personal Mac, use `https://games.local`. mDNS resolves it to the
LAN gateway, and HTTP games.local redirects there with a temporary 302. BottleShip
requires a trusted secure context plus cross-origin isolation for its browser
APIs. A separate local oauth2-proxy uses its own fixed callback and host-only
Secure cookie, while retaining the existing Pocket ID client/group policy.
Local application/download/WebSocket traffic stays on the LAN; Pocket ID login
still uses its public HTTPS URL. Other devices can use the existing public URL.

See [household access](../../../docs/local-household-access.md) for CA enrollment,
origin-specific saves, rollout/rollback, and browser/network verification.

## Adding a Game

`docs/game-bringup.md` in `ievans/bottleship` covers getting a new game working.
This section covers deploying one.

1. Make a bundle from the game's GOG **offline backup installer**
   (`setup_<game>_*.exe`, plus any `.bin` files beside it; the small
   GOG Galaxy downloader has no game in it), in a BottleShip checkout with
   `bun install` done. Run each step in
   `docker run --rm -v "$PWD":/src -w /src oven/bun:1.2.22`, mounting the
   folders it names.
   - Look up the title in `docs/compatibility.md` first. A tested game lists
     the settings it was tested with, and `gog-to-wgb`'s defaults (Windows 98,
     64 MB, 640x480, BottleShip's own DLLs) can crash it: Empire Earth died
     in its sound setup until it had its own `mss32.dll`.
   - No tested settings: `bun tools/gog-to-wgb.ts <setup>.exe <id>.wgb`
     converts and packs in one step.
   - Tested settings: extract with `bun tools/gog-to-wgb.ts <setup>.exe
     unused.wgb --extract-only --keep-gog --extract-dir <dir>`, then pack the
     installed folder with `bun tools/make-wgb.ts`, which takes every option
     (`--os`, `--ram`, `--width`/`--height`/`--bpp`, `--app-dir-dlls`,
     `--create-dirs`). The extracted `goggame-<id>.script` lists the registry
     values the installer writes; turn its `setRegistry` actions into a `.reg`
     file for `--reg-import`, with `{app}` as `C:`. Keep each game folder
     under its own name, as the installer does.
   - A game installed from disc goes straight to `make-wgb` with its
     installed folder.
2. Copy it onto the volume under a temporary name and rename it, so the server
   never serves a half-copied bundle:
   ```sh
   POD=$(kubectl -n bottleship get pod -l app.kubernetes.io/name=bottleship -o name | cut -d/ -f2)
   kubectl -n bottleship cp <id>.wgb "$POD:/apps/.<id>.wgb"
   kubectl -n bottleship exec "$POD" -- mv /apps/.<id>.wgb /apps/<id>.wgb
   ```
3. Add or enable its entry in `games` in `values.yaml`, with
   `wgbUrl: /apps/<id>.wgb`, then commit and push. Reloader restarts the
   server with the new catalog, which ends any game in progress, so check
   nobody's playing first. For cover art, add the file to `files/covers/` and
   set `coverUrl: /covers/custom/<file>`.

Empire Earth and The Art of Conquest are built that way, with the settings
from BottleShip's compatibility notes: `--os winxp --ram 1536 --width 1024
--height 768 --bpp 32 --app-dir-dlls "binkw32.dll,mss32.dll"`, the installer's
registry values, and `--create-dirs` for each game's `Data\Saved Games`. The
Art of Conquest's bundle carries both game folders, since it refuses to start
without the base game.

Empire Earth II and The Art of Supremacy share one installer and differ only in
`entrypoint`. Give an expansion like that its own `gameId` (`bun tools/wgb.ts
patch-manifest <id>.wgb gameId gog:<productId>-<suffix>`): the id is the browser
storage key, so two bundles with one id share their saves.

## Multiplayer

Players in the same room share a virtual LAN (`10.0.0.0/8`), relayed by the
LAN relay. A room is admitted by its name alone, so use an unguessable one for
a private game. Each player sets Settings → Network to
`https://games.fultonhuffman.com` (or `https://games.local` at home), or opens an
invite link (`?lanServer=<url-encoded server>&room=<room>`), then uses the
game's own LAN menu. Winsock games and DirectPlay (1 to 4 and 8) work between
BottleShip players; see the upstream `docs/multiplayer.md` for what does not.

Rooms live in the relay's memory, so restarting its pod (a new relay image or an
`allowedOrigins` change) ends any game in progress. Restarting the app pod does
not.

## Updating BottleShip

Each `ievans/bottleship` release publishes `ghcr.io/ievans/bottleship:X.Y.Z`
(its `CONTRIBUTING.md`, "Releases") and `ghcr.io/ievans/bottleship-lan:X.Y.Z`,
and Renovate opens a pull request bumping each `image.tag`. Neither is
automerged, because a rollout of the app restarts its server and one of the relay
ends any game in progress. Keep the two on the same version.

1. Read the release notes linked in the Renovate pull request.
2. Merge it when nobody is playing.
