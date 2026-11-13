# Geyser Standalone: lets Minecraft Bedrock players join Java servers.
#
# GeyserMC publishes no container image, so this one pins a Geyser build and
# checks its SHA-256 at build time. Bump all three GEYSER_ args together from
# https://download.geysermc.org/v2/projects/geyser/versions/<version>/builds
# (the "standalone" download), and VERSION with them.
#
# Geyser reads config.yml, and writes its caches, in its working directory,
# /geyser: mount the config there, on a writable volume.

# renovate: datasource=docker depName=eclipse-temurin versioning=docker
FROM eclipse-temurin:25-jre-noble

ARG GEYSER_VERSION=2.12.1
ARG GEYSER_BUILD=1302
ARG GEYSER_SHA256=ccafefeb8f5447396bfc8e5411e5476c59fb84de3b99196b8d1b7de3306e92c8

RUN curl -fsSL -o /opt/Geyser.jar \
      "https://download.geysermc.org/v2/projects/geyser/versions/${GEYSER_VERSION}/builds/${GEYSER_BUILD}/downloads/standalone" \
    && echo "${GEYSER_SHA256}  /opt/Geyser.jar" | sha256sum -c - \
    && mkdir /geyser && chown 1000:1000 /geyser

USER 1000:1000
WORKDIR /geyser

# Heap from the container's memory limit, leaving room for Netty's direct
# buffers and the JVM itself.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=60", "-jar", "/opt/Geyser.jar", "--nogui"]
