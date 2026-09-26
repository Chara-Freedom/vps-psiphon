#!/usr/bin/env bash
# vps-psiphon — Psiphon egress for an xray/remnawave node.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh)
#
# The tunnel runs as a container; its SOCKS5 is published on a host-private address
# and handed to xray through a four-line outbound. systemd owns the lifecycle, and a
# watchdog rotates the tunnel when the exit stops being usable.
#
# Installs:
#   /etc/default/vps-psiphon                    parameters
#   /usr/local/sbin/vps-psiphon-run             container launcher (systemd ExecStart)
#   /usr/local/sbin/vps-psiphon-prestart        clears an orphaned docker-proxy (ExecStartPre)
#   /usr/local/sbin/vps-psiphon-watchdog        liveness + burned-exit detector
#   /usr/local/sbin/vps-psiphon-gemini-check    asks Gemini itself whether it serves the exit
#   /usr/local/sbin/vps-psiphon-advance-region  walks REGION_POOL on each rotation
#   /usr/local/sbin/vps-psiphon                 management CLI
#   /etc/systemd/system/vps-psiphon.service, vps-psiphon-watchdog.{service,timer}
#   /opt/vps-psiphon/config                     psiphon's own config and server list
#   /var/log/vps-psiphon-watchdog.log           watchdog journal
#   /var/lib/vps-psiphon-watchdog.state         watchdog counters
#
# `vps-psiphon uninstall` removes all of those, the container, the image and itself.
set -euo pipefail

IMAGE="${IMAGE:-swarupsengupta2007/psiphon:latest}"
NAME="${NAME:-vps-psiphon}"
# Chosen after preflight: the default address exists only once docker is running.
BIND="${BIND:-}"

SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
EGRESS_REGION="${EGRESS_REGION:-}"
REGION_POOL=""; REGION_POOL_SET=0
DEVICE_REGION="${DEVICE_REGION:-}"
WATCHDOG=1
PUBLISH_HTTP=1
# Where Google withholds service, plus CN, which blocks Google itself. Checked first
# and in every mode; a false positive costs one rotation.
DENY_REGIONS_DEFAULT="RU BY IR SY CU KP CN VE"
DENY_REGIONS=""; DENY_REGIONS_SET=0

CONF_DIR=/opt/vps-psiphon/config
ENVF=/etc/default/vps-psiphon
# Ports asked for explicitly are honoured or refused, never silently moved.
SOCKS_PORT_SET=0
HTTP_PORT_SET=0
PUBLISH_HTTP_SET=0

usage() {
  cat <<'U'
psiphon_install.sh [options]
  --region CC[,CC…]    egress country (ISO 3166-1 alpha-2). Empty = auto, the
                       fastest server in any country. Several, comma-separated,
                       form a POOL: every rotation advances to the next country,
                       widening the server choice while keeping the exit inside a
                       set you chose — unlike auto, which may land on another
                       continent. Available at the time of writing: AT AU BE BR
                       CA CH CZ DE DK ES FR GB ID IE IN IT JP NL NO PL RS SE SG US
  --device-region CC   region the client reports. Cosmetic — the server decides
                       by GeoIP. Default: autodetected from this host.
  --socks-port N       SOCKS5 port for xray, default 1080. Refused if taken —
                       xray's outbound names this port, so it is never moved.
  --http-port N        HTTP proxy port, default 8080. Nothing here consumes it,
                       so a taken default moves to the next free port; a port
                       you name explicitly is refused instead.
  --no-http            do not publish the HTTP proxy. Remembered across reinstalls
  --http               publish it after all — undoes a stored --no-http
  --deny-regions 'CC…' countries the exit must never be in, space or comma
                       separated. Default: RU BY IR SY CU KP CN VE. Checked in
                       every mode, before anything else. Empty disables it.
  --bind ADDR          host address to publish the SOCKS5 on. Default: the
                       docker0 gateway (usually 172.17.0.1), where the kernel
                       DNATs the traffic. On loopback it cannot, and docker-proxy
                       copies every byte in userspace instead — 0.10 of a core
                       sustained on a busy node. Any address is accepted, a
                       public one included; its access control is then yours.
  --bind-loopback      publish on 127.0.0.1 instead: narrower (containers on the
                       default bridge cannot reach it), at the price of that
                       userspace copy. Neither default is reachable from outside.
  --image REF          container image, default swarupsengupta2007/psiphon:latest
  --no-watchdog        skip the watchdog
U
}

while [ $# -gt 0 ]; do
  case "$1" in
    --region)
      REGION_POOL="$(printf '%s' "${2:-}" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
      EGRESS_REGION="${REGION_POOL%% *}"
      [ "$REGION_POOL" = "$EGRESS_REGION" ] && REGION_POOL=""
      REGION_POOL_SET=1; shift 2 ;;
    --device-region) DEVICE_REGION="${2:-}"; shift 2 ;;
    --socks-port)    SOCKS_PORT="${2:?}"; SOCKS_PORT_SET=1; shift 2 ;;
    --http-port)     HTTP_PORT="${2:?}";  HTTP_PORT_SET=1;  shift 2 ;;
    --no-http)       PUBLISH_HTTP=0; PUBLISH_HTTP_SET=1; shift ;;
    --http)          PUBLISH_HTTP=1; PUBLISH_HTTP_SET=1; shift ;;
    --deny-regions)
      DENY_REGIONS="$(printf '%s' "${2:-}" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
      DENY_REGIONS_SET=1; shift 2 ;;
    --bind)          BIND="${2:?}";          shift 2 ;;
    --bind-loopback) BIND=127.0.0.1;         shift   ;;
    --image)         IMAGE="${2:?}";         shift 2 ;;
    --no-watchdog)   WATCHDOG=0;             shift   ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
[ "$(id -u)" = 0 ] || die "run as root"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "docker daemon is not running"
command -v curl >/dev/null || die "curl is not installed"

# ------------------------------------------------------------- bind address --
# Docker writes a DNAT rule per published port, but a loopback destination needs
# route_localnet, which docker does not set — so on 127.0.0.1 that rule never fires and
# docker-proxy carries everything in userspace. The docker0 gateway has no such cost.
# Both lookups end in `|| true`: under `set -e` a missing `ip` would kill the install
# before it reaches the fallback.
docker_gateway() {
  local g=""
  g="$(ip -4 -o addr show docker0 2>/dev/null \
       | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  [ -n "$g" ] || g="$(docker network inspect bridge \
                      -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  printf '%s' "$g"
}
if [ -z "$BIND" ]; then
  BIND="$(docker_gateway)"
  [ -n "$BIND" ] || BIND=127.0.0.1   # no docker0: loopback still works
fi

# --------------------------------------------------------- port arbitration --
# Docker allocates host ports only when the container starts, so an unchecked
# collision does not fail the install — the service loops on a bind error while the
# run ends with exit 0. Both published ports are cleared up front.
#
# Collision is the kernel's rule, not string equality: a listener on 0.0.0.0 blocks
# every bind of that port, one on a specific address blocks only that address.
#
# Prints who holds $1 when a bind on $2 would collide; exit 0 = taken, 1 = free.
port_conflict() {
  local port="$1" bind="$2" line field addr label ct
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    addr=""
    for field in $line; do
      case "$field" in *:"$port") addr="${field%:"$port"}"; break ;; esac
    done
    [ -n "$addr" ] || continue
    case "$addr" in
      '0.0.0.0'|'*'|'[::]'|'::') : ;;   # wildcard: blocks any bind of this port
      "$bind")                   : ;;   # same address
      *) continue ;;                    # some other specific address: no clash
    esac
    label="$(printf '%s\n' "$line" \
             | sed -n 's/.*users:((\"\([^\"]*\)\",pid=\([0-9]\{1,\}\).*/\1 (pid \2)/p')"
    [ -n "$label" ] || label="an unidentified listener"
    # docker-proxy holds every published port, so ask docker which container it is.
    case "$label" in
      docker-proxy*)
        ct="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
              | awk -v pat=":$port->" 'index($0, pat) { print $1; exit }')"
        [ -n "$ct" ] && label="container '$ct'"
        ;;
    esac
    printf '%s\n' "$label"
    return 0
  done <<EOF
$(ss -tlnpH "sport = :$port" 2>/dev/null)
EOF
  return 1
}

# First port at or above $1 that is free for a bind on $2.
free_port() {
  local port="$1" bind="$2" tries=0
  while [ "$tries" -lt 100 ]; do
    port_conflict "$port" "$bind" >/dev/null || { printf '%s\n' "$port"; return 0; }
    port=$((port + 1)); tries=$((tries + 1))
  done
  return 1
}

# Ports and the HTTP decision settled on an earlier run survive a reinstall — otherwise
# the HTTP port drifts one higher every run, and a reset SOCKS port leaves the panel's
# outbound dialing nothing. An explicit flag always wins.
if [ -r "$ENVF" ]; then
  if [ "$SOCKS_PORT_SET" = 0 ]; then
    V="$(sed -n 's/^SOCKS_PORT=//p' "$ENVF" | head -1)"; [ -n "$V" ] && SOCKS_PORT="$V"
  fi
  if [ "$HTTP_PORT_SET" = 0 ]; then
    V="$(sed -n 's/^HTTP_PORT=//p' "$ENVF" | head -1)"; [ -n "$V" ] && HTTP_PORT="$V"
  fi
  if [ "$PUBLISH_HTTP_SET" = 0 ]; then
    V="$(sed -n 's/^PUBLISH_HTTP=//p' "$ENVF" | head -1)"; [ -n "$V" ] && PUBLISH_HTTP="$V"
  fi
fi

# On a reinstall our own container holds the port — that is not a conflict.
SOCKS_HOLDER="$(port_conflict "$SOCKS_PORT" "$BIND" || true)"
if [ -n "$SOCKS_HOLDER" ]; then
  if [ "$SOCKS_HOLDER" = "container '$NAME'" ]; then
    say "port $SOCKS_PORT held by the existing '$NAME' container — reinstalling over it"
  else
    ALT="$(free_port $((SOCKS_PORT + 1)) "$BIND" || true)"
    die "SOCKS port $SOCKS_PORT is taken by ${SOCKS_HOLDER}.
       This port is the one xray's outbound dials, so it is never moved for you:
       a tunnel on a port nothing routes to looks healthy and carries no traffic.
       Re-run with --socks-port ${ALT:-<a free port>} and set the same port in the
       outbound, or free $SOCKS_PORT first."
  fi
fi

if [ "$PUBLISH_HTTP" = 1 ]; then
  HTTP_HOLDER="$(port_conflict "$HTTP_PORT" "$BIND" || true)"
  if [ -n "$HTTP_HOLDER" ] && [ "$HTTP_HOLDER" != "container '$NAME'" ]; then
    if [ "$HTTP_PORT_SET" = 1 ]; then
      die "HTTP port $HTTP_PORT is taken by ${HTTP_HOLDER}.
       Choose another with --http-port N, or drop it entirely with --no-http."
    fi
    ALT="$(free_port $((HTTP_PORT + 1)) "$BIND" || true)"
    if [ -n "$ALT" ]; then
      say "HTTP proxy port $HTTP_PORT is taken by ${HTTP_HOLDER} — publishing it on $ALT instead"
      HTTP_PORT="$ALT"
    else
      say "HTTP proxy port $HTTP_PORT is taken by ${HTTP_HOLDER} and no free port found — publishing SOCKS only"
      PUBLISH_HTTP=0
    fi
  fi
fi

# 127.0.0.1 in the outbound means "this container" unless xray runs on host networking.
XRAY_CT="$(docker ps --format '{{.Names}}' | grep -iE 'remnanode|xray' | head -1 || true)"
if [ -n "$XRAY_CT" ] && [ "$BIND" = "127.0.0.1" ]; then
  NETMODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$XRAY_CT" 2>/dev/null || echo '?')"
  if [ "$NETMODE" != "host" ]; then
    echo
    echo "  !! container '$XRAY_CT' runs with NetworkMode=$NETMODE, not host."
    echo "     127.0.0.1:$SOCKS_PORT will NOT be reachable from xray."
    echo "     Drop --bind-loopback: the default gateway address is reachable"
    echo "     from both, and needs no change to that container."
    echo
  fi
fi

if [ -z "$DEVICE_REGION" ]; then
  # Several probes, because ifconfig.co challenges datacenter IPs. -4: unflagged, curl
  # prefers AAAA and reports an address the traffic does not leave from.
  for probe in https://ipinfo.io/country \
               https://api.country.is \
               https://ifconfig.co/country-iso ; do
    DEVICE_REGION="$(curl -4 -fsS --max-time 8 "$probe" 2>/dev/null \
                     | grep -oE '\b[A-Z]{2}\b' | head -1 || true)"
    [ -n "$DEVICE_REGION" ] && break
  done
  [ -n "$DEVICE_REGION" ] || DEVICE_REGION="US"
fi

if [ "$PUBLISH_HTTP" = 1 ]; then HTTP_DESC="$BIND:$HTTP_PORT"; else HTTP_DESC="not published"; fi
say "image=$IMAGE  egress=${EGRESS_REGION:-auto}  device=$DEVICE_REGION  socks=$BIND:$SOCKS_PORT  http=$HTTP_DESC"

# ------------------------------------------------------------------ install --
mkdir -p "$CONF_DIR"
# The image seeds /config once and then ignores EGRESS_REGION, so a stale config
# would silently keep the old country across a --region change.
OLD_REGION="__none__"
[ -r "$ENVF" ] && OLD_REGION="$(sed -n 's/^EGRESS_REGION=//p' "$ENVF")"
if [ "$OLD_REGION" != "__none__" ] && [ "$OLD_REGION" != "$EGRESS_REGION" ]; then
  say "egress region ${OLD_REGION:-auto} -> ${EGRESS_REGION:-auto}: clearing cached config"
  rm -rf "${CONF_DIR:?}"/*
fi
chown -R 1000:1000 "$CONF_DIR"

# Preserve operator-set values across a reinstall. The deny-list is tracked as
# set-or-not, not by value: a deliberately emptied one must stay empty.
OLD_MIN_THROUGHPUT=""; OLD_REGION_POOL=""; OLD_FAIL_WINDOW=""; OLD_GEMINI_CHECK=""
OLD_DENY_SET=0; OLD_DENY_REGIONS=""
if [ -r "$ENVF" ] && grep -q '^DENY_REGIONS=' "$ENVF"; then
  OLD_DENY_SET=1
  OLD_DENY_REGIONS="$(sed -n 's/^DENY_REGIONS=//p' "$ENVF" | tr -d "'")"
fi
if [ "$DENY_REGIONS_SET" = 0 ]; then
  if [ "$OLD_DENY_SET" = 1 ]; then DENY_REGIONS="$OLD_DENY_REGIONS"
  else DENY_REGIONS="$DENY_REGIONS_DEFAULT"; fi
fi
if [ -r "$ENVF" ]; then
  OLD_MIN_THROUGHPUT="$(sed -n 's/^MIN_THROUGHPUT_KBPS=//p' "$ENVF")"
  OLD_FAIL_WINDOW="$(sed -n 's/^FAIL_WINDOW=//p' "$ENVF")"
  OLD_GEMINI_CHECK="$(sed -n 's/^GEMINI_CHECK_SEC=//p' "$ENVF")"
  OLD_REGION_POOL="$(sed -n 's/^REGION_POOL=//p' "$ENVF" | tr -d "'")"
  [ "$REGION_POOL_SET" = 1 ] || REGION_POOL="$OLD_REGION_POOL"
fi

# A country both requested and denied rotates forever.
for r in ${EGRESS_REGION:-} ${REGION_POOL:-}; do
  case " $DENY_REGIONS " in
    *" $r "*) say "!! '$r' is both requested and denied — every exit there will be rejected" ;;
  esac
done

# A moved address leaves the panel's outbound dialing one nobody listens on — a tunnel
# that reads healthy and carries nothing. Warned here and again beside the outbound.
OLD_BIND=""
[ -r "$ENVF" ] && OLD_BIND="$(sed -n 's/^BIND=//p' "$ENVF")"
BIND_CHANGED=0
if [ -n "$OLD_BIND" ] && [ "$OLD_BIND" != "$BIND" ]; then
  BIND_CHANGED=1
  echo
  printf '\033[1;33m  !! published address changes: %s -> %s\033[0m\n' "$OLD_BIND" "$BIND"
  echo "     xray still dials $OLD_BIND, and will carry nothing until you change it."
  echo "     Update the outbound printed at the end of this run."
  echo "     To stay where you are instead: re-run with --bind $OLD_BIND"
  echo
fi

# Unquoted heredoc, for the values — so nothing below may contain a backtick or a
# dollar sign that is not meant to expand.
cat > "$ENVF" <<EOF
# vps-psiphon — written by psiphon_install.sh
#
# NOTE: this file is sourced by the shell, so any value containing spaces MUST be
# quoted. Unquoted, everything after the first space is run as a command.
IMAGE=$IMAGE
NAME=$NAME
BIND=$BIND
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
PUBLISH_HTTP=$PUBLISH_HTTP
EGRESS_REGION=$EGRESS_REGION
DEVICE_REGION=$DEVICE_REGION
CONF_DIR=$CONF_DIR
# FAIL_THRESHOLD failures within the last FAIL_WINDOW checks rotate a slow tunnel; a
# dead or stalled tunnel, a country failure and a Gemini refusal rotate at once. A
# window, not a run: a degraded tunnel flaps around the floor, and a counter reset by
# every passing check never reaches the threshold. There is no cooldown: the window
# starts empty after a rotation, so a slow tunnel always gets two checks. A cooldown
# could only delay a rotation, never prevent one — the failures that asked for it were
# still in the window when it expired — and the exit it held was a known-bad one.
FAIL_THRESHOLD=2
FAIL_WINDOW=${OLD_FAIL_WINDOW:-5}
# Countries to rotate through, space separated; empty keeps rotations inside
# EGRESS_REGION. A retry then draws on another country's servers.
REGION_POOL='$REGION_POOL'
# Countries the exit must never be in, per Google's verdict. Checked first, in every
# mode. Empty disables it.
DENY_REGIONS='$DENY_REGIONS'
# Minimum throughput, KB/s, of the watchdog's own YouTube fetch; 0 disables. One floor
# for every node: 800 came from replaying three nodes' logged history through the
# window rule — none would have rotated at 800, the slowest twice at 1000 — while a
# real collapse trips it on the second check at 600 and at 1000 alike. Lower it only
# for a node whose own history shows it cannot reach it.
MIN_THROUGHPUT_KBPS=${OLD_MIN_THROUGHPUT:-800}
# Seconds between asking Gemini itself whether it serves the exit — one anonymous
# message, about 1 MB; every new tunnel is also asked at its first check. Gemini keeps
# a geo-check of its own that no country check sees. A refusal rotates at once; an
# inconclusive answer never does. 0 disables it.
GEMINI_CHECK_SEC=${OLD_GEMINI_CHECK:-7200}
EOF
chmod 600 "$ENVF"

say "pulling image"
docker pull -q "$IMAGE" >/dev/null
docker image inspect -f '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null \
  | sed 's/^/    deployed digest: /' || true

# ---- launcher ---------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-run <<'RUN'
#!/usr/bin/env bash
# Foreground container launcher; systemd owns the lifecycle.
set -euo pipefail
. /etc/default/vps-psiphon
docker rm -f "$NAME" >/dev/null 2>&1 || true

# Psiphon's window per connection, in 32 KB blocks. Its default, 4 (128 KB), caps one
# connection at about a window per round trip — ~20 Mbit/s over a 30 ms tunnel, however
# idle the tunnel is. 32 (1 MB) measured 5-14x faster per connection with no added wait
# for a small request behind eight downloads; 64 and 128 began to delay it.
WINDOW=32
cfg="${CONF_DIR}/psiphon.config"
# The image writes psiphon.config only when it is absent, from its template plus the
# ports and regions. Seeded here the same way, so the first tunnel after an install or
# `region` carries the window too. If the template cannot be read, the image seeds the
# file as before and the window applies from the next start.
if [ ! -f "$cfg" ] &&
   docker run --rm --entrypoint cat "$IMAGE" /etc/psiphon/psiphon.config > "$cfg.new" 2>/dev/null &&
   [ -s "$cfg.new" ]; then
  sed -i -E \
    -e "s/\"LocalHttpProxyPort\"[[:space:]]*:[[:space:]]*[0-9]+/\"LocalHttpProxyPort\": ${HTTP_PORT}/" \
    -e "s/\"LocalSocksProxyPort\"[[:space:]]*:[[:space:]]*[0-9]+/\"LocalSocksProxyPort\": ${SOCKS_PORT}/" \
    "$cfg.new"
  if [ -n "${DEVICE_REGION:-}" ]; then
    sed -i -E "s/\"DeviceRegion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"DeviceRegion\": \"${DEVICE_REGION}\"/" "$cfg.new"
  fi
  if [ -n "${EGRESS_REGION:-}" ]; then
    sed -i -E "s/\"EgressRegion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"EgressRegion\": \"${EGRESS_REGION}\"/" "$cfg.new"
  fi
  mv "$cfg.new" "$cfg"
fi
rm -f "$cfg.new"
if [ -f "$cfg" ]; then
  if grep -q '"SSHChannelWindowSize"' "$cfg"; then
    sed -i -E "s/\"SSHChannelWindowSize\"[[:space:]]*:[[:space:]]*[0-9]+/\"SSHChannelWindowSize\": ${WINDOW}/" "$cfg"
  else
    sed -i "0,/{/s/{/{\n \"SSHChannelWindowSize\": ${WINDOW},/" "$cfg"
  fi
fi

# The BIND prefix is load-bearing: psiphon listens on 0.0.0.0 inside the container,
# so publishing without it exposes an OPEN SOCKS5 PROXY to the internet.
PUB=( -p "${BIND}:${SOCKS_PORT}:${SOCKS_PORT}" )
[ "${PUBLISH_HTTP:-1}" = 1 ] && PUB+=( -p "${BIND}:${HTTP_PORT}:${HTTP_PORT}" )
exec docker run --rm --name "$NAME" \
  "${PUB[@]}" \
  -e PUID=1000 -e PGID=1000 \
  -e SOCKS_PORT="$SOCKS_PORT" -e HTTP_PORT="$HTTP_PORT" \
  -e DEVICE_REGION="$DEVICE_REGION" -e EGRESS_REGION="$EGRESS_REGION" \
  -v "${CONF_DIR}:/config" \
  "$IMAGE"
RUN
chmod 755 /usr/local/sbin/vps-psiphon-run

# ---- orphaned-proxy sweeper -------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-prestart <<'PRE'
#!/usr/bin/env bash
# Clear a docker-proxy left behind by a container that died uncleanly.
#
# The container runs with --rm, so a bad death removes the container while
# docker-proxy can outlive it, still holding the published port. `docker run` then
# fails with exit code 125 ("address already in use") and Restart=always retries
# into the same wall indefinitely. Seen in production: a node lost its tunnel at
# 07:27 and was still looping three hours later while every external check kept
# reporting the node healthy — the port was held, so nothing ever started, and the
# watchdog's own rotations kept restarting a service that could not come up.
#
# Deliberately narrow. Only a docker-proxy is removed, and only when its cmdline
# carries exactly our -host-ip/-host-port AND no running container publishes that
# address. Anything else holding the port belongs to somebody else: killing it
# silently would be a worse failure than letting docker fail loudly, so this leaves
# it alone and says why.
#
# Ports come from the env file. Arguments override them, which is what makes both
# interesting paths testable without touching a live tunnel.
set -uo pipefail
. /etc/default/vps-psiphon
BIND="${BIND:-127.0.0.1}"

log() { printf 'vps-psiphon-prestart: %s\n' "$*"; }

free_port() {
  local port="$1" line pid cmd
  line="$(ss -tlnpH 2>/dev/null | awk -v a="${BIND}:${port}" '$4 == a {print; exit}')"
  [ -z "$line" ] && return 0                      # free: the ordinary case

  pid="$(printf '%s' "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  [ -z "$pid" ] && { log "${BIND}:${port} is taken but its owner is not visible - leaving it"; return 0; }

  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  case "$cmd" in
    *docker-proxy*"-host-ip ${BIND} "*"-host-port ${port} "*) ;;
    *) log "${BIND}:${port} is held by an unrelated process (pid $pid) - leaving it"; return 0 ;;
  esac

  # A live container publishing this address means the proxy is not an orphan.
  if docker ps --format '{{.Ports}}' 2>/dev/null | grep -qF "${BIND}:${port}->"; then
    log "${BIND}:${port} belongs to a running container - leaving it"
    return 0
  fi

  log "clearing orphaned docker-proxy on ${BIND}:${port} (pid $pid)"
  kill "$pid" 2>/dev/null
  for _ in 1 2 3 4 5; do
    sleep 1
    ss -tlnpH 2>/dev/null | awk -v a="${BIND}:${port}" '$4 == a {found=1} END{exit !found}' || return 0
  done
  log "port not released on SIGTERM, escalating to SIGKILL"
  kill -9 "$pid" 2>/dev/null
  sleep 1
  return 0
}

if [ "$#" -gt 0 ]; then
  for p in "$@"; do free_port "$p"; done
else
  free_port "${SOCKS_PORT:-1080}"
  [ "${PUBLISH_HTTP:-1}" = 1 ] && free_port "${HTTP_PORT:-8080}"
fi
exit 0
PRE
chmod 755 /usr/local/sbin/vps-psiphon-prestart

# ---- region pool ------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-advance-region <<'ADV'
#!/usr/bin/env bash
# Advance EGRESS_REGION to the next country in REGION_POOL and apply it. Prints
# "old -> new" when it changes anything, silent when there is no pool.
#
# Applied by editing psiphon.config in place — the image seeds that file only when
# absent — which keeps the client's cached server list, unlike `vps-psiphon region`.
set -uo pipefail
ENVF=/etc/default/vps-psiphon
[ -r "$ENVF" ] && . "$ENVF"
[ -n "${REGION_POOL:-}" ] || exit 0

cur="${EGRESS_REGION:-}"; first=""; nxt=""; take=0
for r in $REGION_POOL; do
  [ -z "$first" ] && first="$r"
  if [ "$take" = 1 ]; then nxt="$r"; break; fi
  [ "$r" = "$cur" ] && take=1
done
# Outside the pool falls to the first entry, which also makes the last one wrap around.
[ -n "$nxt" ] || nxt="$first"
[ "$nxt" = "$cur" ] && exit 0

sed -i "s/^EGRESS_REGION=.*/EGRESS_REGION=$nxt/" "$ENVF"
cfg="${CONF_DIR:-/opt/vps-psiphon/config}/psiphon.config"
[ -f "$cfg" ] && sed -i -E "s/\"EgressRegion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"EgressRegion\": \"$nxt\"/" "$cfg"
printf '%s -> %s\n' "${cur:-auto}" "$nxt"
ADV
chmod 0755 /usr/local/sbin/vps-psiphon-advance-region

# ---- gemini check -----------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-gemini-check <<'GEM'
#!/usr/bin/env bash
# Asks Gemini itself whether it serves this exit, and prints one line:
#   exit 0  ok            Gemini replied; the line names the place it puts us in
#   exit 1  REFUSED       error 1060 and no reply: Gemini declines this address
#   exit 2  inconclusive  anything else — never grounds for a rotation
# Logged out: the page is fetched for its session fields and cookies, then one message
# is sent.
#
#   --direct  probe from this host's own address instead of through the tunnel, to
#             tell a burned exit apart from a refusal that follows the whole host.
set -uo pipefail
[ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
P=(--socks5-hostname "${BIND:-127.0.0.1}:${SOCKS_PORT:-1080}")
[ "${1:-}" = --direct ] && P=(-4)
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
d="$(mktemp -d)" || { echo "inconclusive (no temp dir)"; exit 2; }
trap 'rm -rf "$d"' EXIT
C=(-s "${P[@]}" -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -b "$d/jar" -c "$d/jar")

code="$(curl "${C[@]}" --max-time 30 -o "$d/app" -w '%{http_code}' https://gemini.google.com/app 2>/dev/null || true)"
bl="$(grep -oE '"cfb2h":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
sid="$(grep -oE '"FdrFJe":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
if [ -z "$bl" ] || [ -z "$sid" ]; then
  echo "inconclusive (page answered ${code:-nothing}, without the session fields)"; exit 2
fi

curl "${C[@]}" --max-time 60 -o "$d/out" \
  -H 'Content-Type: application/x-www-form-urlencoded;charset=utf-8' \
  -H 'Origin: https://gemini.google.com' -H 'Referer: https://gemini.google.com/' -H 'X-Same-Domain: 1' \
  --data-urlencode 'f.req=[null,"[[\"hi\"],null,null]"]' \
  "https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate?bl=${bl}&f.sid=${sid}&hl=en&_reqid=$(( RANDOM * 10 + 100000 ))&rt=c" 2>/dev/null

# A reply is a frame whose payload is not null. Error codes can trail a reply — 1096
# follows every logged-out one — so they are only read when no reply came at all.
if grep -q '"wrb.fr",null,"\[' "$d/out" 2>/dev/null; then
  where="$(grep -oE '\\"[^"\\]+\\",\\"SWML_DESCRIPTION' "$d/out" | head -1 | cut -d'"' -f2 | tr -d '\\')"
  echo "ok — Gemini replies, and places this exit in ${where:-an unnamed country}"; exit 0
fi
errs="$(grep -oE 'BardErrorInfo",\[[0-9]+\]' "$d/out" 2>/dev/null | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
case " $errs " in
  *" 1060 "*) echo "REFUSED — Gemini declines this exit (error 1060, no reply)"; exit 1 ;;
esac
echo "inconclusive (no reply${errs:+, error ${errs% }})"; exit 2
GEM
chmod 755 /usr/local/sbin/vps-psiphon-gemini-check

# ---- watchdog ---------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-watchdog <<'WD'
#!/usr/bin/env bash
# Rotation triggers, in order of how certain they are:
#   1. tunnel dead       — SOCKS does not answer.
#   2. denied country    — Google places the exit in DENY_REGIONS. Checked first.
#   3. country mismatch  — Google's verdict ("GL":"XX" in YouTube's page source) is not
#      the country Psiphon reports for the server. Such an address is one Google has
#      reclassified, and it breaks Google's AI services: of 59 exits measured in one
#      night, all 12 mismatched ones broke Gemini or AI Studio, while genuine US exits,
#      where both sides say US, all worked. The fault is the disagreement, not any
#      country — so there is no allow-list of verdicts.
#   4. stalled tunnel    — SOCKS answers, yet no HTTP request through the tunnel
#      completes. Judged by the absence of a response, so a captcha is not a stall.
#   5. slow tunnel       — the exit carries almost nothing. Psiphon picks its server
#      per tunnel, so a bad pick stays until something forces a reconnect. Judged
#      from the first check, ~5 minutes into a tunnel; the ramp takes a minute or two.
#   6. Gemini refuses    — asked at the first check of every new tunnel, then every
#      GEMINI_CHECK_SEC; Gemini keeps a geo-check of its own. Error 1060 rotates at
#      once, past the failure window.
set -uo pipefail
. /etc/default/vps-psiphon
LOG=/var/log/vps-psiphon-watchdog.log
STATE=/var/lib/vps-psiphon-watchdog.state
S=(--socks5-hostname "${BIND:-127.0.0.1}:${SOCKS_PORT}")
touch "$LOG" 2>/dev/null
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

fails=0; window=""; last_gemini=0; gemini_tunnel=""
[ -r "$STATE" ] && . "$STATE"
now=$(date +%s)

alive=0
# Retry once, so a check racing a (re)start does not log a failure that never was.
for attempt in 1 2; do
  code="$(curl -s -o /dev/null --max-time 20 "${S[@]}" -w '%{http_code}' \
          https://www.gstatic.com/generate_204 2>/dev/null || true)"
  [ "$code" = "204" ] && { alive=1; break; }
  [ "$attempt" = 1 ] && sleep 15
done

reason=""; gl=""; sr=""; kbps=""; started=""
if [ "$alive" = 0 ]; then
  reason="socks-dead"
else
  # One fetch serves the country verdict and the throughput.
  ytf="$(mktemp)"
  probe="$(LC_ALL=C curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' \
           -o "$ytf" -w '%{speed_download} %{http_code}' https://www.youtube.com/ 2>/dev/null || echo '0 000')"
  spd="${probe%% *}"; ytcode="${probe##* }"
  gl="$(grep -oE '"GL":"[A-Z]{2}"' "$ytf" 2>/dev/null | head -1 | cut -d'"' -f4)"
  got="$(stat -c %s "$ytf" 2>/dev/null || echo 0)"
  rm -f "$ytf"
  kbps=$(( ${spd%%.*} / 1024 ))
  # The server's own country, as Psiphon announced it for the current tunnel.
  sr="$(docker logs "${NAME:-vps-psiphon}" 2>&1 | grep -oE '"serverRegion":"[A-Z]{2}"' | tail -1 | cut -d'"' -f4)"
  if [ -n "$gl" ]; then
    case " ${DENY_REGIONS:-} " in
      *" $gl "*) reason="denied-country (Google sees $gl — sanctioned or Google-blocked)" ;;
    esac
    # Either side unread is not a mismatch: judging on a missing value rotates for nothing.
    if [ -z "$reason" ] && [ -n "$sr" ] && [ "$gl" != "$sr" ]; then
      reason="country-mismatch (Google sees $gl, the server is in $sr)"
    fi
  fi
  started="$(docker inspect -f '{{.State.StartedAt}}' "${NAME:-vps-psiphon}" 2>/dev/null)"
  if [ -z "$reason" ] && [ "$ytcode" = "000" ]; then
    reason="stalled-tunnel (no HTTP response in 25s while SOCKS answered)"
  fi
  # A partial download still counts once it carries enough bytes for a rate to mean
  # anything — a truncated fetch is itself a symptom.
  if [ -z "$reason" ] && [ "${MIN_THROUGHPUT_KBPS:-0}" -gt 0 ] && [ "$got" -ge 50000 ]; then
    if [ "$kbps" -lt "${MIN_THROUGHPUT_KBPS}" ]; then
      reason="slow-tunnel (${kbps} KB/s < ${MIN_THROUGHPUT_KBPS} KB/s floor)"
    fi
  fi
fi

# Only a slow reading can be a passing dip, so only it waits for the window. A dead or
# stalled tunnel and a country failure rotate at once: in four nodes' logs the next
# check found Google's verdict unchanged 173 times out of 173 and a dead or stalled
# tunnel still failing 98 times out of 113 — carrying nothing meanwhile — while a slow
# one had recovered 387 times out of 755.
decisive=0
case "$reason" in
  socks-dead*|stalled-tunnel*|denied-country*|country-mismatch*) decisive=1 ;;
esac

# Gemini is asked once per tunnel as soon as it is up — a rotation, `rotate`, `region`
# or a reinstall all start a new container, and an exit Gemini refuses should not
# stand until the old clock runs out — and then on its own clock, since the answer
# changes over days. An inconclusive answer still counts as asked.
if [ "$alive" = 1 ] && [ "${GEMINI_CHECK_SEC:-7200}" -gt 0 ] \
   && { { [ -n "$started" ] && [ "$started" != "$gemini_tunnel" ]; } \
        || [ $((now - last_gemini)) -ge "${GEMINI_CHECK_SEC:-7200}" ]; }; then
  gem="$(/usr/local/sbin/vps-psiphon-gemini-check)"; grc=$?
  last_gemini=$now; gemini_tunnel="$started"
  log "gemini: $gem"
  if [ "$grc" = 1 ]; then
    decisive=1
    [ -z "$reason" ] && reason="gemini-refused (error 1060 — one refusal is decisive)"
  fi
fi

if [ -z "$reason" ]; then
  [ "$fails" -gt 0 ] && log "recovered (exit $(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null), country ${gl:-?})"
  window="${window}0"
else
  window="${window}1"
fi
# Trimmed only when longer than the window: in bash an offset larger than the string
# yields the EMPTY string, which would silently forget every failure.
[ "${#window}" -gt "${FAIL_WINDOW:-5}" ] && window="${window: -${FAIL_WINDOW:-5}}"
ones="${window//0/}"; fails="${#ones}"
[ -n "$reason" ] && log "check failed ($reason), $fails of the last ${#window} checks"
[ -n "$kbps" ] && log "throughput ${kbps} KB/s (country ${gl:-?}, server ${sr:-?})"

if [ "$fails" -ge "${FAIL_THRESHOLD:-2}" ] || [ "$decisive" = 1 ]; then
  old="$(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotating away from exit $old"
  moved="$(/usr/local/sbin/vps-psiphon-advance-region 2>/dev/null)"
  [ -n "$moved" ] && log "region $moved"
  systemctl restart vps-psiphon.service
  sleep 45
  new="$(curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotated: $old -> $new"
  fails=0; window=""
fi

printf "fails=%s\nwindow=%s\nlast_gemini=%s\ngemini_tunnel='%s'\n" \
       "$fails" "$window" "$last_gemini" "$gemini_tunnel" > "$STATE"
WD
chmod 755 /usr/local/sbin/vps-psiphon-watchdog
touch /var/log/vps-psiphon-watchdog.log

# ---- management CLI ---------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon <<'CLI'
#!/usr/bin/env bash
set -uo pipefail
# Sourced defensively, so a half-finished uninstall can still be finished.
[ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
IMAGE="${IMAGE:-swarupsengupta2007/psiphon:latest}"
NAME="${NAME:-vps-psiphon}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
PUBLISH_HTTP="${PUBLISH_HTTP:-1}"
CONF_DIR="${CONF_DIR:-/opt/vps-psiphon/config}"
BIND="${BIND:-127.0.0.1}"
S=(--socks5-hostname "${BIND}:${SOCKS_PORT}")

status() {
  echo "container : $(docker ps --filter "name=^${NAME}$" --format '{{.Status}}' || echo 'DOWN')"
  echo "service   : $(systemctl is-active vps-psiphon.service) / $(systemctl is-enabled vps-psiphon.service 2>/dev/null)"
  echo "watchdog  : $(systemctl is-active vps-psiphon-watchdog.timer) / $(systemctl is-enabled vps-psiphon-watchdog.timer 2>/dev/null)"
  echo "socks     : ${BIND}:${SOCKS_PORT}   (region requested: ${EGRESS_REGION:-auto})"
  [ -n "${REGION_POOL:-}" ] && echo "pool      : ${REGION_POOL}   (each rotation advances one step)"
  [ -n "${DENY_REGIONS:-}" ] && echo "deny      : ${DENY_REGIONS}   (rejected in every mode, checked first)"
  if [ "$PUBLISH_HTTP" = 1 ]; then
    echo "http      : ${BIND}:${HTTP_PORT}   (unused by xray; handy for curl -x)"
  else
    echo "http      : not published"
  fi
  local sr gl
  sr="$(docker logs "$NAME" 2>&1 | grep -oE '"serverRegion":"[A-Z]{2}"' | tail -1 | cut -d'"' -f4)"
  echo "server    : ${sr:-?}   (the country Psiphon reports for this exit)"
  echo -n "tunnels   : "; docker logs "$NAME" 2>&1 | grep -c '"noticeType":"Tunnels"' || true
  echo -n "limits    : "; docker logs "$NAME" 2>&1 | grep -o '"downstreamBytesPerSecond":[0-9]*' | tail -1 || echo 'n/a'
  echo -n "exit IP   : "; curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || echo 'UNREACHABLE'; echo
  gl="$(curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' https://www.youtube.com/ 2>/dev/null \
        | grep -oE '"GL":"[A-Z]{2}"' | head -1 | cut -d'"' -f4)"
  # The same judgement the watchdog makes, so the two never disagree.
  case " ${DENY_REGIONS:-} " in *" ${gl:-none} "*) gl_verdict="DENIED — the watchdog will rotate" ;; *) gl_verdict="" ;; esac
  if [ -z "$gl_verdict" ] && [ -n "$gl" ] && [ -n "$sr" ] && [ "$gl" != "$sr" ]; then
    gl_verdict="does NOT match the server's $sr — the watchdog will rotate"
  fi
  # Not folded into a default expansion: an apostrophe inside it opens a quote.
  [ -n "$gl_verdict" ] || gl_verdict="Google's own verdict about this exit"
  echo "country   : ${gl:-?}   ($gl_verdict)"
  echo -n "gemini    : "; /usr/local/sbin/vps-psiphon-gemini-check
  echo -n "traffic   : "; docker exec "$NAME" cat /proc/net/dev 2>/dev/null | awk '/eth0/{printf "rx %.2f GB / tx %.2f GB\n", $2/1e9, $10/1e9}' || echo 'n/a'
}

case "${1:-status}" in
  status) status ;;
  rotate)
    echo "rotating (fresh tunnel, new exit)…"
    moved="$(/usr/local/sbin/vps-psiphon-advance-region 2>/dev/null)"
    [ -n "$moved" ] && echo "region    : $moved"
    systemctl restart vps-psiphon.service; sleep 45
    # advance-region rewrote the env file; re-read it so status shows the new region.
    [ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
    status ;;
  pool)
    # An empty string is valid — it clears the pool — so test for a MISSING argument.
    [ $# -ge 2 ] || { echo "usage: vps-psiphon pool '<CC CC …>'   (empty string clears it)"; exit 1; }
    np="$(printf '%s' "$2" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
    sed -i "s/^REGION_POOL=.*/REGION_POOL='$np'/" /etc/default/vps-psiphon
    if [ -n "$np" ]; then
      echo "pool      : $np"
      case " $np " in
        *" ${EGRESS_REGION:-} "*) : ;;
        *) echo "note      : current region ${EGRESS_REGION:-auto} is outside the pool;"
           echo "            the next rotation moves to ${np%% *}" ;;
      esac
    else
      echo "pool cleared — rotations stay in ${EGRESS_REGION:-auto}"
    fi ;;
  region)
    [ -n "${2:-}" ] || { echo "usage: vps-psiphon region <CC|auto>"; exit 1; }
    r="$2"; [ "$r" = auto ] && r=""
    sed -i "s/^EGRESS_REGION=.*/EGRESS_REGION=$r/" /etc/default/vps-psiphon
    EGRESS_REGION="$r"
    # The image seeds /config only once; an existing config keeps the OLD region.
    rm -rf "${CONF_DIR:?}"/*; mkdir -p "$CONF_DIR"; chown -R 1000:1000 "$CONF_DIR"
    systemctl restart vps-psiphon.service; sleep 45; status ;;
  speed)
    U="https://speed.cloudflare.com/__down?bytes=50000000"
    echo -n "single 50MB : "
    curl -s -o /dev/null --max-time 300 "${S[@]}" -w '%{speed_download}\n' "$U" | awk '{printf "%.1f Mbit/s\n", $1*8/1e6}'
    echo -n "4x parallel : "
    rm -f /tmp/vpspsi.speed; t0=$(date +%s.%N)
    for i in 1 2 3 4; do curl -s -o /dev/null --max-time 300 "${S[@]}" -w '%{size_download}\n' "$U" >> /tmp/vpspsi.speed & done
    wait; t1=$(date +%s.%N)
    awk -v a="$t0" -v b="$t1" '{s+=$1} END{printf "%.1f Mbit/s aggregate\n", s*8/(b-a)/1e6}' /tmp/vpspsi.speed ;;
  logs)     docker logs --tail "${2:-50}" "$NAME" ;;
  watchdog) tail -n "${2:-30}" /var/log/vps-psiphon-watchdog.log ;;
  uninstall)
    systemctl disable --now vps-psiphon-watchdog.timer vps-psiphon-watchdog.service \
                            vps-psiphon.service >/dev/null 2>&1
    docker rm -f "$NAME" >/dev/null 2>&1
    rm -f /etc/systemd/system/vps-psiphon.service \
          /etc/systemd/system/vps-psiphon-watchdog.service \
          /etc/systemd/system/vps-psiphon-watchdog.timer
    systemctl daemon-reload
    systemctl reset-failed vps-psiphon.service vps-psiphon-watchdog.service >/dev/null 2>&1
    # Docker refuses while anything else references the image, which is fine.
    docker image rm "$IMAGE" >/dev/null 2>&1
    rm -f /usr/local/sbin/vps-psiphon-run /usr/local/sbin/vps-psiphon-watchdog \
          /usr/local/sbin/vps-psiphon-prestart \
          /usr/local/sbin/vps-psiphon-advance-region /usr/local/sbin/vps-psiphon-gemini-check \
          /etc/default/vps-psiphon /var/lib/vps-psiphon-watchdog.state \
          /var/log/vps-psiphon-watchdog.log /tmp/vpspsi.speed
    rm -rf /opt/vps-psiphon
    # Safe while running: bash holds the inode open.
    rm -f /usr/local/sbin/vps-psiphon
    # "Removed" is claimed only after looking at the disk.
    left=""
    for p in /usr/local/sbin/vps-psiphon /usr/local/sbin/vps-psiphon-run \
             /usr/local/sbin/vps-psiphon-prestart \
             /usr/local/sbin/vps-psiphon-watchdog /usr/local/sbin/vps-psiphon-gemini-check \
             /usr/local/sbin/vps-psiphon-advance-region /etc/default/vps-psiphon \
             /etc/systemd/system/vps-psiphon.service \
             /etc/systemd/system/vps-psiphon-watchdog.service \
             /etc/systemd/system/vps-psiphon-watchdog.timer \
             /var/lib/vps-psiphon-watchdog.state \
             /var/log/vps-psiphon-watchdog.log /opt/vps-psiphon ; do
      [ -e "$p" ] && left="$left $p"
    done
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME" && left="$left container:$NAME"
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
      && echo "note: image $IMAGE kept, something else on this host references it"
    [ -n "$left" ] && { echo "removed, but these remain:$left" >&2; exit 1; }
    echo "removed: units, container, image, config, state, log — and this CLI itself" ;;
  *) echo "usage: vps-psiphon {status|rotate|region <CC>|pool '<CC CC …>'|speed|logs [n]|watchdog [n]|uninstall}" ;;
esac
CLI
chmod 755 /usr/local/sbin/vps-psiphon

# ---- units ------------------------------------------------------------------
cat > /etc/systemd/system/vps-psiphon.service <<'U1'
[Unit]
Description=vps-psiphon egress tunnel (host-private SOCKS5 for xray)
After=docker.service network-online.target
Requires=docker.service

[Service]
ExecStartPre=/usr/local/sbin/vps-psiphon-prestart
ExecStart=/usr/local/sbin/vps-psiphon-run
ExecStop=/usr/bin/docker stop -t 10 vps-psiphon
Restart=always
RestartSec=10
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
U1

cat > /etc/systemd/system/vps-psiphon-watchdog.service <<'U2'
[Unit]
Description=vps-psiphon liveness and burned-exit watchdog
After=vps-psiphon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-psiphon-watchdog
U2

cat > /etc/systemd/system/vps-psiphon-watchdog.timer <<'U3'
[Unit]
Description=Run the vps-psiphon watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
U3

systemctl daemon-reload
systemctl enable vps-psiphon.service >/dev/null 2>&1
# restart, not "enable --now": on a reinstall the service is already active and would
# keep running with the previous parameters.
systemctl restart vps-psiphon.service
[ "$WATCHDOG" = 1 ] && systemctl enable --now vps-psiphon-watchdog.timer

# ------------------------------------------------------------------- verify --
say "waiting for the tunnel"
# Watch the unit, not just the log: with Restart=always a container that cannot start
# loops as "activating", and waiting on the log alone ends in a silent exit 0.
TUNNEL_UP=0
for i in $(seq 1 60); do
  systemctl is-active --quiet vps-psiphon.service || break
  docker logs "$NAME" 2>&1 | grep -q '"noticeType":"Tunnels"' && { TUNNEL_UP=1; break; }
  sleep 2
done

if [ "$TUNNEL_UP" = 0 ] && ! systemctl is-active --quiet vps-psiphon.service; then
  echo >&2
  printf '\033[1;31mERROR:\033[0m the tunnel never started.\n' >&2
  journalctl -u vps-psiphon.service -n 40 --no-pager 2>/dev/null \
    | grep -iE 'error|failed|cannot|denied' | tail -5 | sed 's/^/    /' >&2
  # Stopped rather than left hammering docker every 10s while you read this.
  systemctl stop vps-psiphon.service >/dev/null 2>&1 || true
  echo >&2
  echo "    The service is stopped, not looping. Fix the cause and re-run this" >&2
  echo "    installer, or 'vps-psiphon uninstall' to remove what was written." >&2
  exit 1
fi

if [ "$TUNNEL_UP" = 0 ]; then
  say "no tunnel after 120s, but the service is alive — leaving it to keep trying"
  say "watch it with:  vps-psiphon logs"
fi
sleep 3
echo
/usr/local/sbin/vps-psiphon status
echo
say "xray outbound:"
cat <<OUT
    { "tag": "psiphon-out", "protocol": "socks",
      "settings": { "address": "$BIND", "port": $SOCKS_PORT } }
OUT
if [ "${BIND_CHANGED:-0}" = 1 ]; then
  printf '\033[1;33m    !! this run MOVED the address (%s -> %s), so the outbound above is\n' "$OLD_BIND" "$BIND"
  printf '       NOT what your panel has. Update it now, or the tunnel carries nothing.\033[0m\n'
fi
say "manage with:  vps-psiphon {status|rotate|region <CC>|pool '<CC CC …>'|speed|logs|uninstall}"
