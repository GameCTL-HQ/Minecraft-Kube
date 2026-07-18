#!/usr/bin/env bash
# GameCTL Minecraft entrypoint. Resolves + caches the server jar on the /data
# volume, manages the handful of server.properties keys GameCTL owns (ports,
# RCON, optional LEVEL/MOTD) while preserving everything else, then runs the
# JVM as an unprivileged user. Env contract mirrors what GameCTL's minecraft
# generator has always sent (itzg-compatible names):
#   EULA, TYPE (PAPER|VANILLA|SPIGOT->paper), VERSION (LATEST|x.y.z), MEMORY,
#   ENABLE_RCON / RCON_PASSWORD / RCON_PORT, SPIGET_RESOURCES (plugin ids,
#   83557=BlueMap fetched from its official GitHub releases), LEVEL, MOTD,
#   JVM_OPTS, OVERRIDE_OPS/OVERRIDE_WHITELIST (accepted; we never touch either).
set -euo pipefail

DATA="${DATA_DIR:-/data}"
uid="${UID:-1000}"; gid="${GID:-1000}"
type="$(echo "${TYPE:-PAPER}" | tr '[:lower:]' '[:upper:]')"
version="${VERSION:-LATEST}"
mkdir -p "$DATA" "$DATA/.gamectl"
cd "$DATA"

# --- EULA ------------------------------------------------------------------
if [ "$(echo "${EULA:-FALSE}" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
  echo "eula=true" > eula.txt
elif [ ! -f eula.txt ] || ! grep -q 'eula=true' eula.txt; then
  echo "ERROR: set EULA=TRUE to accept the Minecraft EULA (https://aka.ms/MinecraftEULA)" >&2
  exit 1
fi

# --- Resolve + cache the server jar ---------------------------------------
if [ "$type" = "SPIGOT" ]; then
  echo "gamectl: TYPE=SPIGOT has no official download; using Paper (drop-in Spigot-compatible)"
  type=PAPER
fi

resolve_paper() { # -> sets jar_url, resolved
  local ver="$1"
  if [ "$ver" = "LATEST" ]; then
    ver="$(curl -fsSL https://fill.papermc.io/v3/projects/paper/versions | jq -r '.versions[0].version.id')"
  fi
  local build_json
  build_json="$(curl -fsSL "https://fill.papermc.io/v3/projects/paper/versions/${ver}/builds/latest")"
  jar_url="$(echo "$build_json" | jq -r '.downloads["server:default"].url')"
  resolved="paper-${ver}-b$(echo "$build_json" | jq -r '.id')"
}

resolve_vanilla() { # -> sets jar_url, resolved
  local ver="$1" manifest url
  manifest="$(curl -fsSL https://launchermeta.mojang.com/mc/game/version_manifest_v2.json)"
  if [ "$ver" = "LATEST" ]; then
    ver="$(echo "$manifest" | jq -r '.latest.release')"
  fi
  url="$(echo "$manifest" | jq -r --arg v "$ver" '.versions[] | select(.id==$v) | .url')"
  [ -n "$url" ] || { echo "ERROR: vanilla version $ver not in Mojang manifest" >&2; exit 1; }
  jar_url="$(curl -fsSL "$url" | jq -r '.downloads.server.url')"
  resolved="vanilla-${ver}"
}

jar_url=""; resolved=""
if ! { [ "$type" = "PAPER" ] && resolve_paper "$version" || { [ "$type" = "VANILLA" ] && resolve_vanilla "$version"; }; } 2>/dev/null; then
  # Resolution failed (offline / API down): fall back to the newest cached jar.
  cached="$(ls -t "$DATA/.gamectl"/*.jar 2>/dev/null | head -1 || true)"
  if [ -n "$cached" ]; then
    echo "gamectl: WARN — version resolve failed, using cached $(basename "$cached")"
    jar="$cached"
  else
    echo "ERROR: could not resolve $type $version and no cached jar exists" >&2
    exit 1
  fi
else
  jar="$DATA/.gamectl/${resolved}.jar"
  if [ ! -s "$jar" ]; then
    echo "gamectl: downloading ${resolved}"
    curl -fSL --retry 3 -o "$jar.part" "$jar_url" && mv "$jar.part" "$jar"
  fi
fi

# --- server.properties: manage only GameCTL-owned keys ---------------------
touch server.properties
setprop() { # key value
  grep -qE "^$1=" server.properties \
    && sed -i "s|^$1=.*|$1=$2|" server.properties \
    || echo "$1=$2" >> server.properties
}
setprop server-port 25565
if [ "$(echo "${ENABLE_RCON:-true}" | tr '[:lower:]' '[:upper:]')" = "TRUE" ] && [ -n "${RCON_PASSWORD:-}" ]; then
  setprop enable-rcon true
  setprop rcon.port "${RCON_PORT:-25575}"
  setprop rcon.password "${RCON_PASSWORD}"
fi
[ -n "${LEVEL:-}" ] && setprop level-name "$LEVEL"
[ -n "${MOTD:-}" ]  && setprop motd "$MOTD"

# --- Plugins (Paper): SPIGET_RESOURCES, BlueMap from its official releases --
if [ "$type" = "PAPER" ] && [ -n "${SPIGET_RESOURCES:-}" ]; then
  mkdir -p plugins
  IFS=',' read -ra ids <<< "$SPIGET_RESOURCES"
  for id in "${ids[@]}"; do
    id="$(echo "$id" | tr -d ' ')"
    if [ "$id" = "83557" ]; then
      # BlueMap is externally hosted (spiget can't serve it); fetch the paper
      # jar from BlueMap's own GitHub releases. Skip if ANY BlueMap jar is
      # already present (any variant/case) — a second copy makes Paper reject
      # the plugin as ambiguous.
      if ! find plugins -maxdepth 1 -iname 'bluemap-*.jar' | grep -q .; then
        bm_url="$(curl -fsSL https://api.github.com/repos/BlueMap-Minecraft/BlueMap/releases/latest \
          | jq -r '.assets[] | select(.name | test("paper.jar$")) | .browser_download_url' | head -1)"
        [ -n "$bm_url" ] && { echo "gamectl: installing BlueMap ($(basename "$bm_url"))"; curl -fSL -o "plugins/$(basename "$bm_url")" "$bm_url"; } \
          || echo "gamectl: WARN — could not resolve BlueMap release"
      fi
    else
      if ! ls "plugins/spiget-${id}-"*.jar >/dev/null 2>&1; then
        echo "gamectl: installing spiget resource $id"
        curl -fSL -o "plugins/spiget-${id}.jar" "https://api.spiget.org/v2/resources/${id}/download" \
          || echo "gamectl: WARN — spiget download failed for $id (externally hosted?)"
      fi
    fi
  done
fi

# --- Run -------------------------------------------------------------------
chown -R "$uid:$gid" "$DATA" 2>/dev/null || true
mem="${MEMORY:-4G}"
echo "gamectl: starting $type $(basename "$jar" .jar) (Xms/Xmx ${mem}, rcon ${RCON_PORT:-25575})"
run=(java -Xms"$mem" -Xmx"$mem" ${JVM_OPTS:-} -jar "$jar" nogui)
if [ "$(id -u)" = "0" ]; then
  exec setpriv --reuid "$uid" --regid "$gid" --clear-groups "${run[@]}"
else
  exec "${run[@]}"
fi
