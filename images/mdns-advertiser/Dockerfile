# mDNS advertiser: publishes labeled ConfigMaps as Bonjour/Zeroconf records.
#
# Deps are resolved at build time, not container start. The previous runtime
# `pip install` broke when the base image moved to python:3.15-alpine: PyYAML
# ships no cp315 musl wheel, so pip built it from source inside a 128Mi limit
# and OOMKilled on a loop, taking every .local record down with it.
#
# PyYAML is unavoidable here — the kubernetes client requires it (pyyaml>=5.4.1)
# even though advertiser.py itself now parses JSON with the stdlib. Hence the
# builder stage: it carries a compiler so PyYAML builds deterministically
# against libyaml instead of silently falling back to a pure-Python wheel, and
# the final image ships neither the compiler nor the build caches.

# renovate: datasource=docker depName=python versioning=docker
FROM python:3.15-alpine AS build

# Pin kubernetes<36 due to auth_settings() regression in v36:
# https://github.com/kubernetes-client/python/issues/2582
# renovate: datasource=pypi depName=zeroconf
ARG ZEROCONF_VERSION=0.153.0
# renovate: datasource=pypi depName=kubernetes
ARG KUBERNETES_VERSION=35.0.0

RUN apk add --no-cache gcc musl-dev yaml-dev

RUN pip install --no-cache-dir --root-user-action=ignore --prefix=/install \
      "zeroconf==${ZEROCONF_VERSION}" \
      "kubernetes==${KUBERNETES_VERSION}"

# renovate: datasource=docker depName=python versioning=docker
FROM python:3.15-alpine

COPY --from=build /install /usr/local
COPY advertiser.py /app/advertiser.py

# Fail the build rather than the cluster if a dep is missing or incompatible.
RUN python3 -c "import zeroconf, kubernetes, yaml; print('deps ok')" \
    && python3 -m py_compile /app/advertiser.py

ENTRYPOINT ["python3", "-u", "/app/advertiser.py"]
