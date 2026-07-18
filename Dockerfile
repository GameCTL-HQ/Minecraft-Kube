# GameCTL Minecraft server image (Paper / Vanilla) — built from scratch so
# GameCTL controls exactly what runs.
#
# Sources in the chain: Eclipse Temurin's official JRE base, Mojang's official
# version manifest (vanilla), and PaperMC's official fill API (paper). No
# community images, no third-party jar mirrors.
#
# Unlike GameCTL's baked-binary images, the server jar is resolved and cached
# at runtime (on the /data volume): Minecraft is version-plural by nature —
# TYPE + VERSION are runtime choices and worlds are version-bound, so baking
# one jar would force upgrades on every image pull. VERSION=LATEST re-resolves
# on boot; a pinned VERSION is fully reproducible and works offline once cached.
#
# Java 25 (current Paper/Vanilla requirement; runs 1.20/1.21 era servers too).
FROM eclipse-temurin:25-jre

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq tini util-linux \
    && rm -rf /var/lib/apt/lists/*

ENV DATA_DIR=/data \
    TYPE=PAPER \
    VERSION=LATEST \
    MEMORY=4G \
    EULA=FALSE \
    ENABLE_RCON=true \
    RCON_PORT=25575 \
    UID=1000 \
    GID=1000

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

# 25565/tcp game, 25575/tcp RCON (keep RCON off public tunnels),
# 8100/tcp BlueMap web when enabled.
EXPOSE 25565/tcp 25575/tcp 8100/tcp
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
