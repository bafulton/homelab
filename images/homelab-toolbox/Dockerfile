# Shared toolbox image for homelab jobs that need curl/jq/git/kubectl.
#
# Replaces the `apk add` calls these workloads used to run at container start,
# which made every pod boot depend on Alpine's CDN being reachable. node-health
# had already failed that way (DNS: transient error -> "curl (no such package)").
#
# renovate: datasource=docker depName=alpine
FROM alpine:3.24

# kubectl must stay within one minor of the API server (beelink, control-plane).
# Value carries the leading "v" so it matches kubernetes/kubernetes release tags
# verbatim and Renovate can rewrite it in place.
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.37.1
ARG TARGETARCH

RUN apk add --no-cache \
      ca-certificates \
      curl \
      git \
      jq

RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client=true

ENTRYPOINT ["/bin/sh"]
