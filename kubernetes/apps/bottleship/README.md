# BottleShip

Classic Windows games in the browser at `https://games.fultonhuffman.com`,
for friends signed in through Pocket ID (group `games`).

The emulator runs entirely in each visitor's browser (WebGPU, so Chrome or
Edge). This app serves the frontend, the game bundles, and a WebSocket relay
that puts players' browsers on one virtual LAN for multiplayer.

## Architecture

- **Image**: `ghcr.io/bafulton/bottleship`, built from a pinned commit of
  `ievans/bottleship` (`images/bottleship/`)
- **Bundles**: `bottleship-apps`, a hostPath on beelink's USB disk
  (`/var/mnt/usb/bottleship`), backed up weekly to Garage by VolSync
- **Library**: `games` in `values.yaml`, served as `/games-catalog.json`
- **Sign-in**: oauth2-proxy answers Traefik's `forwardAuth` for every request;
  Pocket ID only signs in members of the client's allowed groups
- **Ingress**: OCI edge forwarder → Traefik's edge listener for
  `games.fultonhuffman.com`. Bundles are multi-GB, which keeps them off
  Cloudflare's CDN for the same reason as Jellyfin's video

## Pocket ID Client

In Pocket ID, **OIDC Clients → Add**:

- **Callback URL**: `https://games.fultonhuffman.com/oauth2/callback`
- **Public Client**: off. oauth2-proxy needs a client secret
- **PKCE**: on
- **Allowed User Groups**: `games` (create the group first)

Put the client ID in `oauth2Proxy.clientId` and the client secret in Bitwarden,
referenced as `OAUTH2_PROXY_CLIENT_SECRET`.

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

Players in the same room share a virtual LAN (`192.168.77.0/24`), relayed
by the server. In a game, the 🌐 button creates a room and copies an invite
link; friends who open it join the same room, then use the game's own LAN
menu. Only games that network over Winsock work this way. DirectPlay is still
local-only.

Rooms live in the server's memory, so restarting the pod (a new image or a
catalog change) ends any game in progress.

## Updating BottleShip

Updates don't happen on their own: the image is pinned to one commit of
`ievans/bottleship`, so new commits on its `main` stay undeployed until you bump
it.

1. Run the **Bump BottleShip** workflow, from the Actions tab or with
   `gh workflow run bump-bottleship.yaml`. It uses the latest `main` unless you
   give it a `commit`.
2. Open the pull request from the link in the run's summary. It changes
   `BOTTLESHIP_COMMIT`, `images/bottleship/VERSION` and `image.tag` together, and
   lists the new commits.
3. Merge it when nobody is playing. The restart ends any game in progress.

The image downloads its `.wasm` files from the release the fork's CI publishes
for that commit's `wasm.lock.json`. If a bump changes the lock, wait for the
fork's CI on that commit to finish first, or the image build fails. A failed
build leaves the site on its current version.

Several people may be bumping at once: if another bump already includes your
change, you're done. Running the workflow again replaces the open bump.

This is an interim process. The fork will eventually have a formal version
release process, and then we can track its releases directly, with a more
straightforward update regime.
