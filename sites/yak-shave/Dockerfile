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

# The upstream binary ships cap_net_bind_service as a *file* capability so it
# can bind :80. We serve :8080 behind Traefik and never need it - and the pod
# runs with capabilities.drop: [ALL], under which execve refuses a file whose
# permitted capabilities are not in the bounding set:
#
#   exec /usr/bin/caddy: operation not permitted
#
# Strip the capability rather than loosening the pod. Reproduce the failure
# locally with `docker run --cap-drop ALL`; Docker's default bounding set
# includes NET_BIND_SERVICE, so without that flag it starts fine and hides it.
RUN apk add --no-cache libcap \
    && setcap -r /usr/bin/caddy \
    && apk del libcap

COPY Caddyfile /etc/caddy/Caddyfile
# Written by `npm run build`; names the post that / redirects to.
COPY caddy/latest.caddy /etc/caddy/latest.caddy
COPY dist /srv

# Caddy autosaves config and keeps data under XDG paths. Pointing them at
# mounted emptyDirs is what lets the container run read-only and non-root.
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

EXPOSE 8080
