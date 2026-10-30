# BottleShip: runs classic Windows games in the browser, served with the
# COOP/COEP headers, Range support and LAN relay its client needs.
#
# Built from ievans/bottleship, the fork we develop in, rather than upstream
# jenissimo/bottleship: it carries the virtual-LAN multiplayer, a WebSocket
# relay in the server plus real Winsock in the emulator.
#
# Pinned to a commit of its main, not the branch: a branch would rebuild to
# different
# content under the same VERSION. Renovate does not track this; bump the commit
# and VERSION together by hand.
ARG BOTTLESHIP_REPO=https://github.com/ievans/bottleship.git
ARG BOTTLESHIP_COMMIT=e8a376bf6991cb425ec38c65da53bedf1ac10540

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
FROM --platform=$BUILDPLATFORM oven/bun:1.4.4 AS build
WORKDIR /src
COPY --from=source /src .
RUN bun install --frozen-lockfile && bun run build

FROM oven/bun:1.4.4-alpine
WORKDIR /app
COPY --from=build /src/dist ./dist
COPY --from=build /src/deploy/server.ts /src/deploy/wgb-etag.ts /src/deploy/lan-relay.ts ./deploy/
# lan-relay.ts imports ../src/net/lan-protocol, so it keeps its relative path.
COPY --from=build /src/src/net/lan-protocol.ts ./src/net/lan-protocol.ts
ENV NODE_ENV=production PORT=5173 BS_DIST_DIR=/app/dist BS_APPS_DIR=/apps
USER bun
EXPOSE 5173
CMD ["bun", "/app/deploy/server.ts"]
