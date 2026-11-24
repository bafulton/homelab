# Geyser Standalone: lets Minecraft Bedrock players join Java servers.
#
# GeyserMC publishes no container image, so this one pins a Geyser build and
# checks its SHA-256 at build time. Renovate keeps the pin current: a
# customManager in renovate.json reads GeyserMC's build API and updates
# GEYSER_RELEASE (<version>-<build>) and GEYSER_SHA256 together. Bedrock
# clients update themselves, and an old Geyser stops letting them in.
#
# Geyser reads config.yml, and writes its caches, in its working directory,
# /geyser: mount the config there, on a writable volume.

# The download is split out because the Java image has no curl or wget, and
# this stage's shell takes the version and build apart for the URL.
# renovate: datasource=docker depName=alpine versioning=docker
FROM alpine:3.24 AS download

ARG GEYSER_RELEASE=2.12.1-1308
ARG GEYSER_SHA256=56dd35b3cd8e2b8a8ff44b97c819d76ca24f9ded769de96ae66b80cf1ecb8480

RUN wget -qO /Geyser.jar \
      "https://download.geysermc.org/v2/projects/geyser/versions/${GEYSER_RELEASE%-*}/builds/${GEYSER_RELEASE##*-}/downloads/standalone" \
    && echo "${GEYSER_SHA256}  /Geyser.jar" | sha256sum -c -

# renovate: datasource=docker depName=eclipse-temurin versioning=docker
FROM eclipse-temurin:25-jre-noble

COPY --from=download --chmod=644 /Geyser.jar /opt/Geyser.jar

RUN mkdir /geyser && chown 1000:1000 /geyser

USER 1000:1000
WORKDIR /geyser

# Heap from the container's memory limit, leaving room for Netty's direct
# buffers and the JVM itself.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=60", "-jar", "/opt/Geyser.jar", "--nogui"]
