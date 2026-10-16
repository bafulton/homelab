# The site is built on the CI runner, not in here.
#
# Astro's output is plain HTML, CSS and JS - byte-identical whatever the
# architecture - so it is built once natively and copied into both the amd64
# and arm64 images. Running `npm ci` under arm64 emulation instead would be
# minutes slower and would put dependency resolution back on the critical path
# of an image build.
#
# Build it by hand with:
#   npm ci && npm run build && docker build -t yak-shave .
FROM caddy:2.11.7-alpine

COPY Caddyfile /etc/caddy/Caddyfile
COPY dist /srv

# Caddy autosaves config and keeps data under XDG paths. Pointing them at
# mounted emptyDirs is what lets the container run read-only and non-root.
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

EXPOSE 8080
