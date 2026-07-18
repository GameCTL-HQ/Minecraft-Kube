# Minecraft-Kube

A from-scratch **Minecraft server** image (Paper / Vanilla) for Kubernetes,
maintained by [GameCTL](https://github.com/GameCTL-HQ/GameCTL) so nothing
changes underneath us.

Only first-party sources are in the chain: Eclipse Temurin's official JRE,
**Mojang's version manifest** (vanilla) and **PaperMC's official fill API**
(paper). No community images, no third-party jar mirrors.

## Image

`ghcr.io/gamectl-hq/minecraft-kube`

- `:latest` / `:java25` — JRE 25 + entrypoint. The server jar itself is
  resolved at runtime (see below), because Minecraft worlds are version-bound
  and TYPE/VERSION are per-server choices — baking one jar would force
  upgrades on every image pull.

## Usage

```bash
docker run -d --name mc \
  -p 25565:25565 \
  -v /srv/minecraft:/data \
  -e EULA=TRUE -e TYPE=PAPER -e VERSION=LATEST \
  -e MEMORY=4G -e RCON_PASSWORD=change-me \
  ghcr.io/gamectl-hq/minecraft-kube:latest
```

First boot downloads the jar (cached at `/data/.gamectl/`), writes `eula.txt`,
and generates the world on the volume. A **pinned `VERSION` is reproducible and
works offline once cached**; `LATEST` re-resolves each boot (falls back to the
cached jar if the API is unreachable).

### Environment (itzg-compatible names)

| Var | Default | Notes |
|-----|---------|-------|
| `EULA` | `FALSE` | Must be `TRUE` (accepts the Minecraft EULA) |
| `TYPE` | `PAPER` | `PAPER` or `VANILLA` (`SPIGOT` → Paper: no official Spigot download exists; Paper is drop-in compatible) |
| `VERSION` | `LATEST` | e.g. `26.1.2`, `1.21.8` — pin to protect a world from auto-upgrade |
| `MEMORY` | `4G` | JVM `-Xms`/`-Xmx` |
| `ENABLE_RCON` / `RCON_PASSWORD` / `RCON_PORT` | `true` / — / `25575` | Managed in `server.properties`; keep RCON off public tunnels |
| `LEVEL` / `MOTD` | — | Optional `server.properties` overrides |
| `SPIGET_RESOURCES` | — | Comma-separated SpigotMC ids (Paper only). `83557` (BlueMap) is fetched from BlueMap's **official GitHub releases** |
| `JVM_OPTS` | — | Extra JVM flags |
| `UID` / `GID` | `1000` | Server runs unprivileged |

Only GameCTL-owned keys in `server.properties` are managed (port, RCON,
optional LEVEL/MOTD) — everything else you set there is preserved.

## Ports

`25565/tcp` game · `25575/tcp` RCON (internal only) · `8100/tcp` BlueMap web.
