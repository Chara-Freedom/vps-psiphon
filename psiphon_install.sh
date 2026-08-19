#!/usr/bin/env bash
# vps-psiphon — Psiphon egress for an xray/remnawave node.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh)
#
# The tunnel runs as a container; its SOCKS5 is published on a host-private
# address and handed to xray through a four-line outbound. systemd owns the
# lifecycle, and a watchdog rotates the tunnel when the exit stops being usable.
#
# Installs:
#   /etc/default/vps-psiphon              parameters
#   /usr/local/sbin/vps-psiphon-run       container launcher (systemd ExecStart)
#   /usr/local/sbin/vps-psiphon-watchdog  liveness + burned-exit detector
#   /usr/local/sbin/vps-psiphon           management CLI
#   /etc/systemd/system/vps-psiphon.service
#   /etc/systemd/system/vps-psiphon-watchdog.service + .timer
#   /opt/vps-psiphon/config               psiphon's own config and server list
#   /var/log/vps-psiphon-watchdog.log     watchdog journal
#   /var/lib/vps-psiphon-watchdog.state   watchdog counters
#
# `vps-psiphon uninstall` removes every one of those, plus the container and the
# image, and finally unlinks itself: a clean uninstall leaves nothing behind.
set -euo pipefail

IMAGE="${IMAGE:-swarupsengupta2007/psiphon:latest}"
NAME="${NAME:-vps-psiphon}"
# Resolved after preflight, because the default is an address that does not exist
# until docker is running. Empty here means "not chosen yet".
BIND="${BIND:-}"

SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
EGRESS_REGION="${EGRESS_REGION:-}"
REGION_POOL=""; REGION_POOL_SET=0
DEVICE_REGION="${DEVICE_REGION:-}"
WATCHDOG=1
PUBLISH_HTTP=1
CONF_DIR=/opt/vps-psiphon/config
ENVF=/etc/default/vps-psiphon
# Ports asked for explicitly are honoured or refused, never silently moved.
SOCKS_PORT_SET=0
HTTP_PORT_SET=0

usage() {
  cat <<'U'
psiphon_install.sh [options]
  --region CC[,CC…]    egress country (ISO 3166-1 alpha-2). Empty = auto, the
                       fastest server in any country. Give several, comma-
                       separated, to form a POOL: every rotation advances to the
                       next country in it. That widens the server choice when one
                       country is congested, while keeping the exit inside a set
                       you chose — unlike auto, which may land on another
                       continent and cost you the latency. Available at the time
                       of writing: AT AU BE BR CA CH CZ DE DK ES FR GB ID IE IN
                       IT JP NL NO PL RS SE SG US
  --device-region CC   region the client reports. Cosmetic — the server decides
                       by GeoIP. Default: autodetected from this host.
  --socks-port N       SOCKS5 port for xray, default 1080. Refused if
                       taken — xray's outbound names this port, so moving it
                       behind your back would leave a tunnel nothing routes to.
  --http-port N        HTTP proxy port, default 8080. Nothing here
                       consumes it, so a taken default is moved to the next free
                       port; a port you name explicitly is refused instead.
  --no-http            do not publish the HTTP proxy at all
  --bind ADDR          host address to publish the SOCKS5 on. Default: the
                       docker0 gateway (usually 172.17.0.1). Publishing there
                       lets the kernel DNAT the traffic; publishing on loopback
                       cannot, so every byte is copied through docker-proxy in
                       userspace instead — 0.10 of a core sustained on a node
                       carrying ~100 new connections/s, 0.27-0.36 at peak. On a
                       1-core box that copy is the difference that matters.
  --bind-loopback      publish on 127.0.0.1 instead. Narrower — only processes
                       on the host reach it, whereas the gateway is also
                       reachable by containers on the default bridge — at the
                       price of that userspace copy. Neither address is
                       reachable from the internet.
  --image REF          container image, default swarupsengupta2007/psiphon:latest
  --no-watchdog        skip the watchdog
U
}

while [ $# -gt 0 ]; do
  case "$1" in
    --region)
      # One country behaves as before. Several make a pool the watchdog walks
      # on each rotation — a wider server choice without "auto" reaching
      # another continent.
      REGION_POOL="$(printf '%s' "${2:-}" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
      EGRESS_REGION="${REGION_POOL%% *}"
      [ "$REGION_POOL" = "$EGRESS_REGION" ] && REGION_POOL=""
      REGION_POOL_SET=1; shift 2 ;;
    --device-region) DEVICE_REGION="${2:-}"; shift 2 ;;
    --socks-port)    SOCKS_PORT="${2:?}"; SOCKS_PORT_SET=1; shift 2 ;;
    --http-port)     HTTP_PORT="${2:?}";  HTTP_PORT_SET=1;  shift 2 ;;
    --no-http)       PUBLISH_HTTP=0;         shift   ;;
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
# Where the SOCKS5 is published decides whether the kernel can carry it. Docker
# writes a DNAT rule for every published port, but a loopback destination needs
# net.ipv4.conf.all.route_localnet, which docker does not set — so that rule sits
# at zero packets and docker-proxy copies every byte through userspace instead.
# Measured on a live node: 0.10 of a core sustained, 0.27-0.36 at peak, and
# exactly 0.00 once the same traffic is published on the gateway address, with
# throughput unchanged.
#
# The gateway is host-private either way — RFC1918, no route from outside — so
# what this actually trades is reachability from other containers on the default
# bridge, which loopback does not grant and the gateway does.
# Both lookups end in `|| true`: this script runs under `set -e` with pipefail,
# where a missing `ip` binary makes the assignment itself the failing command and
# kills the install before it reaches the fallback it has.
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
  # No docker0 — a custom bridge, or docker configured without one. Loopback
  # still works, docker-proxy and all.
  [ -n "$BIND" ] || BIND=127.0.0.1
fi

# --------------------------------------------------------- port arbitration --
# Docker allocates host ports when the container starts, which is long after this
# script has written its files and enabled its units. An unchecked collision
# therefore does not fail the install. What it produces instead, in this order: a
# service looping on a bind error, then two minutes of silence from the wait loop
# below — the container is `--rm`, so every crash deletes it and `docker logs` has
# nothing to report — and finally the closing "here is your outbound" and exit 0,
# over a service that has never once run. Both published ports get cleared up front.
#
# Whether two binds collide is the kernel's rule, not string equality: a listener
# on 0.0.0.0 (or ::) blocks every bind of that port, while one on a specific
# address blocks only that address. That asymmetry is the whole bug — a bot
# publishing 0.0.0.0:8080 collides with our 127.0.0.1:8080, which never looks
# like a conflict if you compare addresses literally.
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
    # Every published container port is held by docker-proxy, so that name alone
    # tells the operator nothing. Ask docker which container is behind it.
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

# Re-running over an existing install must work. The listener on our port is
# docker-proxy, never a process called "$NAME", so ask docker who owns it.
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

# The HTTP proxy is a convenience nothing in this setup consumes, so a busy
# default is worth working around rather than dying on. An explicitly requested
# port is a different matter — honour the request or refuse it, never reinterpret.
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

# Loopback exists separately inside every namespace, so 127.0.0.1 in the outbound
# means "this container" unless xray runs on host networking. The docker0 gateway
# has no such ambiguity — the host and every bridged container reach the same
# address — which is the second reason it is the default.
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
  # ifconfig.co answers datacenter IPs with a Cloudflare challenge, so it cannot
  # be the only source. Try a few, take the first plausible country code.
  for probe in https://ipinfo.io/country \
               https://api.country.is \
               https://ifconfig.co/country-iso ; do
    DEVICE_REGION="$(curl -fsS --max-time 8 "$probe" 2>/dev/null \
                     | grep -oE '\b[A-Z]{2}\b' | head -1 || true)"
    [ -n "$DEVICE_REGION" ] && break
  done
  [ -n "$DEVICE_REGION" ] || DEVICE_REGION="US"
fi

if [ "$PUBLISH_HTTP" = 1 ]; then HTTP_DESC="$BIND:$HTTP_PORT"; else HTTP_DESC="not published"; fi
say "image=$IMAGE  egress=${EGRESS_REGION:-auto}  device=$DEVICE_REGION  socks=$BIND:$SOCKS_PORT  http=$HTTP_DESC"

# ------------------------------------------------------------------ install --
mkdir -p "$CONF_DIR"
# Reinstalling with a different --region must actually change the region. The
# image seeds /config once and then ignores EGRESS_REGION, so a stale config
# would silently keep the old country.
OLD_REGION="__none__"
[ -r "$ENVF" ] && OLD_REGION="$(sed -n 's/^EGRESS_REGION=//p' "$ENVF")"
if [ "$OLD_REGION" != "__none__" ] && [ "$OLD_REGION" != "$EGRESS_REGION" ]; then
  say "egress region ${OLD_REGION:-auto} -> ${EGRESS_REGION:-auto}: clearing cached config"
  rm -rf "${CONF_DIR:?}"/*
fi
chown -R 1000:1000 "$CONF_DIR"

# Preserve operator-set values across a reinstall.
OLD_HEALTH_CMD=""; OLD_OK_REGIONS=""; OLD_MIN_THROUGHPUT=""; OLD_REGION_POOL=""
if [ -r "$ENVF" ]; then
  OLD_HEALTH_CMD="$(sed -n 's/^HEALTH_CMD=//p' "$ENVF")"
  OLD_OK_REGIONS="$(sed -n 's/^OK_REGIONS=//p' "$ENVF")"
  OLD_MIN_THROUGHPUT="$(sed -n 's/^MIN_THROUGHPUT_KBPS=//p' "$ENVF")"
  OLD_REGION_POOL="$(sed -n 's/^REGION_POOL=//p' "$ENVF" | tr -d "'")"
  # An explicit --region wins; otherwise an existing pool survives the reinstall.
  [ "$REGION_POOL_SET" = 1 ] || REGION_POOL="$OLD_REGION_POOL"
fi

# A reinstall that moved the published address without saying so would leave the
# outbound dialing an address nobody listens on — a tunnel that reads healthy in
# every check and carries nothing. The installer cannot repair that itself: the
# outbound lives in the panel, out of its reach. So it says so here, and again
# beside the new outbound at the end, where it cannot be scrolled past.
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

cat > "$ENVF" <<EOF
# vps-psiphon — written by psiphon_install.sh
IMAGE=$IMAGE
NAME=$NAME
BIND=$BIND
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
PUBLISH_HTTP=$PUBLISH_HTTP
EGRESS_REGION=$EGRESS_REGION
DEVICE_REGION=$DEVICE_REGION
CONF_DIR=$CONF_DIR
# watchdog tuning
FAIL_THRESHOLD=2
ROTATE_COOLDOWN=1800
#
# NOTE: this file is sourced by the shell, so any value containing spaces MUST be
# quoted. Unquoted, everything after the first space is run as a command.
#
# Acceptable countries for Google's verdict when no region is pinned:
#   OK_REGIONS='DE NL JP'
# Ignored while EGRESS_REGION is set — then the verdict must equal that region.
OK_REGIONS=$OLD_OK_REGIONS
# Optional extra probe for what no unauthenticated check can see: whether the
# service you actually care about accepts this exit. Non-zero exit = rotate.
#   HEALTH_CMD='curl -sf --max-time 15 --socks5-hostname $BIND:$SOCKS_PORT -o /dev/null https://example.com/'
# Minimum throughput, KB/s, measured on the watchdog's own YouTube fetch — no extra
# traffic. Below this for FAIL_THRESHOLD consecutive checks, the tunnel is rotated:
# Psiphon picks a server per tunnel, and a bad pick otherwise persists indefinitely
# while liveness and country both read green. 0 disables the gate.
MIN_THROUGHPUT_KBPS=${OLD_MIN_THROUGHPUT:-100}
# Countries to rotate through, space separated. Empty = stay in EGRESS_REGION and
# only change server within it. A pool is what you want when one country is busy:
# each rotation advances to the next entry, so the retry draws on a different
# country's servers instead of the same crowded set. Keep them near each other —
# the pool is also what stops the watchdog calling a legitimate exit "wrong
# country", so anything you list here you are accepting as a destination.
REGION_POOL='$REGION_POOL'
HEALTH_CMD=$OLD_HEALTH_CMD
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
# NOTE: the BIND prefix is load-bearing. Publishing without it exposes an OPEN
# SOCKS5 PROXY to the internet — psiphon binds 0.0.0.0 inside the container.
# Both supported values are host-private (loopback, or the docker0 gateway); what
# BIND must never become is a wildcard or a public address.
PUB=( -p "${BIND}:${SOCKS_PORT}:${SOCKS_PORT}" )
# Default to publishing it, so env files written before this was an option keep
# their old behaviour instead of silently losing the HTTP proxy.
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

# ---- region pool ------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-advance-region <<'ADV'
#!/usr/bin/env bash
# Advance EGRESS_REGION to the next country in REGION_POOL and apply it. Prints
# "old -> new" when it changes anything, and stays silent when there is no pool.
#
# Rotating within one country retries that country's servers — exactly the set
# that is exhausted when it is busy. Walking a pool draws on a different country
# instead, without handing the choice to "auto", which may answer from another
# continent.
#
# The region is applied by rewriting psiphon.config in place: the image seeds that
# file only when it is absent, so the edit sticks. That is deliberately gentler
# than the `region` subcommand, which wipes the config directory and throws away
# the client's cached server list along with it.
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
# Not in the pool (hand-edited, or the pool changed under us) falls to the first
# entry, which is also what makes the last entry wrap around.
[ -n "$nxt" ] || nxt="$first"
[ "$nxt" = "$cur" ] && exit 0

sed -i "s/^EGRESS_REGION=.*/EGRESS_REGION=$nxt/" "$ENVF"
cfg="${CONF_DIR:-/opt/vps-psiphon/config}/psiphon.config"
[ -f "$cfg" ] && sed -i -E "s/\"EgressRegion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"EgressRegion\": \"$nxt\"/" "$cfg"
printf '%s -> %s\n' "${cur:-auto}" "$nxt"
ADV
chmod 0755 /usr/local/sbin/vps-psiphon-advance-region
# ---- watchdog ---------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-watchdog <<'WD'
#!/usr/bin/env bash
# Rotation triggers, in order of how certain they are:
#   1. tunnel dead   — SOCKS does not answer.
#   2. wrong country — Google's own verdict about this exit does not match the region
#      we asked for. YouTube publishes that verdict in its page source as "GL":"XX".
#      This is the failure that makes Cloudflare WARP unusable for region-gated
#      services: WARP geolocates back to the client's real country, so they refuse.
#   3. slow tunnel   — the exit answers from the right country but carries almost
#      nothing. Psiphon picks its server per tunnel, so a bad pick stays until
#      something forces a reconnect, while liveness and country both stay green
#      throughout — without this gate a 30-90x throughput collapse is invisible.
#      Measured on the YouTube fetch below, so it costs no extra traffic.
#   4. HEALTH_CMD    — anything further that only you can verify.
#
# Google's /sorry captcha is recorded but never rotates on its own: a human solves
# one in seconds, and churning the tunnel over it costs more than it saves.
#
# A correct country is necessary, not sufficient. An exit can sit in the right
# country and still be refused on the address's own reputation, and no unauthenticated
# probe sees that — which is what HEALTH_CMD is for.
set -uo pipefail
. /etc/default/vps-psiphon
LOG=/var/log/vps-psiphon-watchdog.log
STATE=/var/lib/vps-psiphon-watchdog.state
S=(--socks5-hostname "${BIND:-127.0.0.1}:${SOCKS_PORT}")
touch "$LOG" 2>/dev/null
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

fails=0; last_rotate=0; captcha=0
[ -r "$STATE" ] && . "$STATE"
export SOCKS_PORT          # so HEALTH_CMD can reach the proxy

alive=0
# Retry once: a check that races tunnel establishment (boot, restart, rotate)
# would otherwise log a failure the tunnel never actually had.
for attempt in 1 2; do
  code="$(curl -s -o /dev/null --max-time 20 "${S[@]}" -w '%{http_code}' \
          https://www.gstatic.com/generate_204 2>/dev/null || true)"
  [ "$code" = "204" ] && { alive=1; break; }
  [ "$attempt" = 1 ] && sleep 15
done

reason=""; gl=""; kbps=""
if [ "$alive" = 0 ]; then
  reason="socks-dead"
else
  # One fetch serves two checks: the country verdict and how fast it arrived.
  ytf="$(mktemp)"
  spd="$(LC_ALL=C curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' \
         -o "$ytf" -w '%{speed_download}' https://www.youtube.com/ 2>/dev/null || echo 0)"
  gl="$(grep -oE '"GL":"[A-Z]{2}"' "$ytf" 2>/dev/null | head -1 | cut -d'"' -f4)"
  got="$(stat -c %s "$ytf" 2>/dev/null || echo 0)"
  rm -f "$ytf"
  kbps=$(( ${spd%%.*} / 1024 ))
  if [ -n "$gl" ]; then
    # With a pool, every country in it is a destination we accepted, so the
    # verdict is judged against the whole pool — otherwise the watchdog would
    # call its own last rotation a wrong-country failure and rotate forever.
    if [ -n "${REGION_POOL:-}" ]; then
      case " $REGION_POOL " in
        *" $gl "*) : ;;
        *) reason="wrong-country (Google sees $gl, not in pool '$REGION_POOL')" ;;
      esac
    elif [ -n "${EGRESS_REGION:-}" ] && [ "$gl" != "$EGRESS_REGION" ]; then
      reason="wrong-country (asked $EGRESS_REGION, Google sees $gl)"
    elif [ -z "${EGRESS_REGION:-}" ] && [ -n "${OK_REGIONS:-}" ]; then
      case " $OK_REGIONS " in
        *" $gl "*) : ;;
        *) reason="wrong-country (Google sees $gl, not in '$OK_REGIONS')" ;;
      esac
    fi
  fi
  # Throughput gate. A truncated fetch is itself the symptom, so a partial download
  # still counts, but it needs enough bytes for the rate to mean anything. Rotating
  # drops every live client connection, so this only fires through FAIL_THRESHOLD
  # consecutive checks and the rotate cooldown.
  if [ -z "$reason" ] && [ "${MIN_THROUGHPUT_KBPS:-0}" -gt 0 ] && [ "$got" -ge 50000 ]; then
    if [ "$kbps" -lt "${MIN_THROUGHPUT_KBPS}" ]; then
      reason="slow-tunnel (${kbps} KB/s < ${MIN_THROUGHPUT_KBPS} KB/s floor)"
    fi
  fi
  if [ -z "$reason" ] && [ -n "${HEALTH_CMD:-}" ]; then
    sh -c "$HEALTH_CMD" >/dev/null 2>&1 || reason="health-cmd failed"
  fi
  # Informational only, and logged on change so a captcha'd exit does not fill the log.
  rd="$(curl -s -o /dev/null --max-time 25 "${S[@]}" -w '%{redirect_url}' \
        'https://www.google.com/search?q=status' 2>/dev/null || true)"
  now_captcha=0; case "$rd" in */sorry/*) now_captcha=1 ;; esac
  if [ "$now_captcha" != "$captcha" ]; then
    [ "$now_captcha" = 1 ] && log "note: Google now serves a captcha to this exit (informational, no action)" \
                           || log "note: Google no longer serves a captcha to this exit"
  fi
  captcha="$now_captcha"
fi

if [ -z "$reason" ]; then
  [ "$fails" -gt 0 ] && log "recovered (exit $(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null), country ${gl:-?})"
  fails=0
else
  fails=$((fails + 1))
  log "check failed ($reason), consecutive=$fails"
fi
# Always record the rate: this is the history that makes a slow decline legible.
[ -n "$kbps" ] && log "throughput ${kbps} KB/s (country ${gl:-?})"

now=$(date +%s)
if [ "$fails" -ge "${FAIL_THRESHOLD:-2}" ] && [ $((now - last_rotate)) -ge "${ROTATE_COOLDOWN:-1800}" ]; then
  old="$(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotating away from exit $old"
  moved="$(/usr/local/sbin/vps-psiphon-advance-region 2>/dev/null)"
  [ -n "$moved" ] && log "region $moved"
  systemctl restart vps-psiphon.service
  sleep 45
  new="$(curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotated: $old -> $new"
  fails=0; last_rotate=$now
fi

printf 'fails=%s\nlast_rotate=%s\ncaptcha=%s\n' "$fails" "$last_rotate" "$captcha" > "$STATE"
WD
chmod 755 /usr/local/sbin/vps-psiphon-watchdog
touch /var/log/vps-psiphon-watchdog.log

# ---- management CLI ---------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon <<'CLI'
#!/usr/bin/env bash
set -uo pipefail
# Sourced defensively. Once the env file is gone — a half-finished uninstall, a
# hand-deleted file — `set -u` would abort on the first unset variable and leave
# the CLI unable to clean up after itself. The defaults keep every branch usable.
[ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
IMAGE="${IMAGE:-swarupsengupta2007/psiphon:latest}"
NAME="${NAME:-vps-psiphon}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
PUBLISH_HTTP="${PUBLISH_HTTP:-1}"
CONF_DIR="${CONF_DIR:-/opt/vps-psiphon/config}"
# Env files written before --bind existed carry no BIND line at all.
BIND="${BIND:-127.0.0.1}"
S=(--socks5-hostname "${BIND}:${SOCKS_PORT}")

status() {
  echo "container : $(docker ps --filter "name=^${NAME}$" --format '{{.Status}}' || echo 'DOWN')"
  echo "service   : $(systemctl is-active vps-psiphon.service) / $(systemctl is-enabled vps-psiphon.service 2>/dev/null)"
  echo "watchdog  : $(systemctl is-active vps-psiphon-watchdog.timer) / $(systemctl is-enabled vps-psiphon-watchdog.timer 2>/dev/null)"
  echo "socks     : ${BIND}:${SOCKS_PORT}   (region requested: ${EGRESS_REGION:-auto})"
  [ -n "${REGION_POOL:-}" ] && echo "pool      : ${REGION_POOL}   (each rotation advances one step)"
  if [ "$PUBLISH_HTTP" = 1 ]; then
    echo "http      : ${BIND}:${HTTP_PORT}   (unused by xray; handy for curl -x)"
  else
    echo "http      : not published"
  fi
  echo -n "server    : "; docker logs "$NAME" 2>&1 | grep -o '"serverRegion":"[A-Z]*"' | tail -1 || echo '?'
  echo -n "tunnels   : "; docker logs "$NAME" 2>&1 | grep -c '"noticeType":"Tunnels"' || echo 0
  echo -n "limits    : "; docker logs "$NAME" 2>&1 | grep -o '"downstreamBytesPerSecond":[0-9]*' | tail -1 || echo 'n/a'
  echo -n "exit IP   : "; curl -s --max-time 20 "${S[@]}" https://api.ipify.org 2>/dev/null || echo 'UNREACHABLE'; echo
  local gl; gl="$(curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' https://www.youtube.com/ 2>/dev/null \
                  | grep -oE '"GL":"[A-Z]{2}"' | head -1 | cut -d'"' -f4)"
  if [ -n "${EGRESS_REGION:-}" ] && [ -n "$gl" ] && [ "$gl" != "$EGRESS_REGION" ]; then
    echo "country   : ${gl} — MISMATCH, asked for ${EGRESS_REGION}; region-gated services will refuse"
  else
    echo "country   : ${gl:-?}   (Google's own verdict about this exit)"
  fi
  local rd; rd="$(curl -s -o /dev/null --max-time 25 "${S[@]}" -w '%{redirect_url}' 'https://www.google.com/search?q=status' 2>/dev/null)"
  case "$rd" in */sorry/*) echo "captcha   : yes (informational — no rotation, a human solves it)" ;;
                        *) echo "captcha   : no" ;; esac
  echo -n "traffic   : "; docker exec "$NAME" cat /proc/net/dev 2>/dev/null | awk '/eth0/{printf "rx %.2f GB / tx %.2f GB\n", $2/1e9, $10/1e9}' || echo 'n/a'
}

case "${1:-status}" in
  status) status ;;
  rotate)
    echo "rotating (fresh tunnel, new exit)…"
    moved="$(/usr/local/sbin/vps-psiphon-advance-region 2>/dev/null)"
    [ -n "$moved" ] && echo "region    : $moved"
    systemctl restart vps-psiphon.service; sleep 45; status ;;
  pool)
    # An empty string is a valid argument here — it clears the pool — so this
    # tests for a MISSING argument, not an empty one.
    [ $# -ge 2 ] || { echo "usage: vps-psiphon pool '<CC CC …>'   (empty string clears it)"; exit 1; }
    np="$(printf '%s' "$2" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
    sed -i "s/^REGION_POOL=.*/REGION_POOL='$np'/" /etc/default/vps-psiphon
    REGION_POOL="$np"
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
    EGRESS_REGION="$r"   # the file was sourced at startup; keep status() honest
    # The image only seeds /config on first run; an existing psiphon.config
    # silently keeps the OLD region. Wipe it or the change is a no-op.
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
    # The installer pulled this image and a reinstall pulls it again, so it is ours
    # to drop. Docker refuses if anything else still references it — that is fine.
    docker image rm "$IMAGE" >/dev/null 2>&1
    rm -f /usr/local/sbin/vps-psiphon-run /usr/local/sbin/vps-psiphon-watchdog \
          /usr/local/sbin/vps-psiphon-advance-region \
          /etc/default/vps-psiphon /var/lib/vps-psiphon-watchdog.state \
          /var/log/vps-psiphon-watchdog.log /tmp/vpspsi.speed
    rm -rf /opt/vps-psiphon
    # Unlinking the running script is safe: bash holds an open descriptor on the
    # inode, so the rest of this branch keeps executing after the name is gone.
    rm -f /usr/local/sbin/vps-psiphon
    # Claiming "removed" is worth nothing unmeasured — look at the disk and say so.
    left=""
    for p in /usr/local/sbin/vps-psiphon /usr/local/sbin/vps-psiphon-run \
             /usr/local/sbin/vps-psiphon-watchdog /etc/default/vps-psiphon \
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
Description=Run the vps-psiphon watchdog every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
AccuracySec=30s

[Install]
WantedBy=timers.target
U3

systemctl daemon-reload
systemctl enable vps-psiphon.service >/dev/null 2>&1
# restart, not "enable --now": on a reinstall the service is already active and
# would keep running with the previous parameters.
systemctl restart vps-psiphon.service
[ "$WATCHDOG" = 1 ] && systemctl enable --now vps-psiphon-watchdog.timer

# ------------------------------------------------------------------- verify --
say "waiting for the tunnel"
# Watch the unit, not just the log. Restart=always means a container that cannot
# start does not stay dead quietly — it loops, and this loop used to wait out all
# sixty iterations against a container that `--rm` had already deleted: no output,
# no error, ~2 minutes, then a success-shaped ending and exit 0. systemd reports an
# auto-restarting unit as "activating", so anything other than "active" here is the
# failure — caught in one iteration, ~3 s in practice.
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
  # Stop it rather than leave docker being hammered every 10s while you read this.
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
