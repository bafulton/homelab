# BottleShip: runs classic Windows games in the browser, served with the
# COOP/COEP headers, Range support and LAN relay its client needs.
#
# Built from a friend's fork rather than upstream jenissimo/bottleship, for the
# virtual-LAN multiplayer: a WebSocket relay in the server plus real Winsock in
# the emulator. split/ui stacks the room UI on the engine change
# (ievans/bottleship PRs 1 and 3). Move back to upstream once those merge.
#
# Pinned to a commit, not the branch: a branch would rebuild to different
# content under the same VERSION. Renovate does not track this; bump the commit
# and VERSION together by hand.
ARG BOTTLESHIP_REPO=https://github.com/ievans/bottleship.git
ARG BOTTLESHIP_COMMIT=cf5e714e82798441915cc0ecd6e8f7e5646e4362

# vendor/v86 is a submodule whose libv86.mjs and v86.wasm are committed
# prebuilt, so the build needs no Rust toolchain - only the checkout.
FROM alpine/git:2.54.0 AS source
ARG BOTTLESHIP_REPO
ARG BOTTLESHIP_COMMIT
WORKDIR /src
RUN git init -q . \
    && git remote add origin "$BOTTLESHIP_REPO" \
    && git fetch -q --depth 1 origin "$BOTTLESHIP_COMMIT" \
    && git checkout -q FETCH_HEAD \
    && git submodule update -q --init --depth 1

# The frontend is built on the build platform only: its output is static
# JS/WASM, identical for every architecture, so there is no reason to run the
# Vite build under arm64 emulation.
FROM --platform=$BUILDPLATFORM oven/bun:1.2.22 AS build
WORKDIR /src
COPY --from=source /src .
RUN bun install --frozen-lockfile && bun run build

FROM oven/bun:1.2.22-alpine
WORKDIR /app
COPY --from=build /src/dist ./dist
COPY --from=build /src/deploy/server.ts /src/deploy/wgb-etag.ts /src/deploy/lan-relay.ts ./deploy/
# lan-relay.ts imports ../src/net/lan-protocol, so it keeps its relative path.
COPY --from=build /src/src/net/lan-protocol.ts ./src/net/lan-protocol.ts
ENV NODE_ENV=production PORT=5173 BS_DIST_DIR=/app/dist BS_APPS_DIR=/apps
USER bun
EXPOSE 5173
CMD ["bun", "/app/deploy/server.ts"]
