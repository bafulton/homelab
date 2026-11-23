# game-ports: routes Gameplane's port-pool servers (Valheim, Factorio) to the
# gateway, and runs the canary check. See game_ports.py.
#
# The kubernetes client requires PyYAML, which this image builds against
# libyaml in a builder stage, as mdns-advertiser's does: a pip install at
# container start once OOM-looped mdns-advertiser (images/README.md).

# renovate: datasource=docker depName=python versioning=docker
FROM python:3.15-alpine AS build

# renovate: datasource=pypi depName=kubernetes
ARG KUBERNETES_VERSION=37.0.3

RUN apk add --no-cache gcc musl-dev yaml-dev

RUN pip install --no-cache-dir --root-user-action=ignore --prefix=/install \
      "kubernetes==${KUBERNETES_VERSION}"

# renovate: datasource=docker depName=python versioning=docker
FROM python:3.15-alpine

COPY --from=build /install /usr/local
COPY game_ports.py /app/game_ports.py

# Fail the build rather than the cluster if a dep is missing or incompatible.
RUN python3 -c "import kubernetes, yaml; print('deps ok')" \
    && python3 -m py_compile /app/game_ports.py

USER 65532:65532
ENTRYPOINT ["python3", "-u", "/app/game_ports.py"]
