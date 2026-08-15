#!/usr/bin/env bash
# vps-psiphon — Psiphon egress for an xray/remnawave node.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh)
#
# The tunnel runs as a container; its SOCKS5 is bound to loopback and handed to
# xray through a four-line outbound. systemd owns the lifecycle, and a watchdog
# rotates the tunnel when the exit address stops being usable.
#
# Installs:
#   /etc/default/vps-psiphon              parameters
#   /usr/local/sbin/vps-psiphon-run       container launcher (systemd ExecStart)
#   /usr/local/sbin/vps-psiphon-watchdog  liveness + burned-exit detector
#   /usr/local/sbin/vps-psiphon           management CLI
#   /etc/systemd/system/vps-psiphon.service
#   /etc/systemd/system/vps-psiphon-watchdog.service + .timer
set -euo pipefail

IMAGE="${IMAGE:-swarupsengupta2007/psiphon:latest}"
NAME="${NAME:-vps-psiphon}"
BIND="${BIND:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"
EGRESS_REGION="${EGRESS_REGION:-}"
DEVICE_REGION="${DEVICE_REGION:-}"
WATCHDOG=1
CONF_DIR=/opt/vps-psiphon/config
ENVF=/etc/default/vps-psiphon

usage() {
  cat <<'U'
psiphon_install.sh [options]
  --region CC          egress country (ISO 3166-1 alpha-2). Empty = auto, the
                       fastest server in any country. Available at the time of
                       writing: AT AU BE BR CA CH CZ DE DK ES FR GB ID IE IN IT
                       JP NL NO PL RS SE SG US
  --device-region CC   region the client reports. Cosmetic — the server decides
                       by GeoIP. Default: autodetected from this host.
  --socks-port N       loopback SOCKS5 port for xray, default 1080
  --http-port N        loopback HTTP proxy port, default 8080
  --image REF          container image, default swarupsengupta2007/psiphon:latest
  --no-watchdog        skip the watchdog
U
}

while [ $# -gt 0 ]; do
  case "$1" in
    --region)        EGRESS_REGION="${2:-}"; shift 2 ;;
    --device-region) DEVICE_REGION="${2:-}"; shift 2 ;;
    --socks-port)    SOCKS_PORT="${2:?}";    shift 2 ;;
    --http-port)     HTTP_PORT="${2:?}";     shift 2 ;;
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

# Re-running over an existing install must work. The listener on our port is
# docker-proxy, never a process called "$NAME", so ask docker who owns it.
if ss -tlnH "sport = :$SOCKS_PORT" 2>/dev/null | grep -q . ; then
  if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    say "port $SOCKS_PORT held by the existing '$NAME' container — reinstalling over it"
  else
    die "port $SOCKS_PORT is already in use by something else"
  fi
fi

# xray must live in the host network namespace, otherwise 127.0.0.1 in the
# outbound points at the xray container itself instead of at this tunnel.
XRAY_CT="$(docker ps --format '{{.Names}}' | grep -iE 'remnanode|xray' | head -1 || true)"
if [ -n "$XRAY_CT" ]; then
  NETMODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$XRAY_CT" 2>/dev/null || echo '?')"
  if [ "$NETMODE" != "host" ]; then
    echo
    echo "  !! container '$XRAY_CT' runs with NetworkMode=$NETMODE, not host."
    echo "     127.0.0.1:$SOCKS_PORT will NOT be reachable from xray."
    echo "     Either give it host networking, or reinstall with BIND=172.17.0.1"
    echo "     and use that address in the outbound."
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

say "image=$IMAGE  egress=${EGRESS_REGION:-auto}  device=$DEVICE_REGION  socks=$BIND:$SOCKS_PORT"

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
OLD_HEALTH_CMD=""; OLD_OK_REGIONS=""
if [ -r "$ENVF" ]; then
  OLD_HEALTH_CMD="$(sed -n 's/^HEALTH_CMD=//p' "$ENVF")"
  OLD_OK_REGIONS="$(sed -n 's/^OK_REGIONS=//p' "$ENVF")"
fi

cat > "$ENVF" <<EOF
# vps-psiphon — written by psiphon_install.sh
IMAGE=$IMAGE
NAME=$NAME
BIND=$BIND
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
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
#   HEALTH_CMD='curl -sf --max-time 15 --socks5-hostname 127.0.0.1:$SOCKS_PORT -o /dev/null https://example.com/'
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
exec docker run --rm --name "$NAME" \
  -p "${BIND}:${SOCKS_PORT}:${SOCKS_PORT}" \
  -p "${BIND}:${HTTP_PORT}:${HTTP_PORT}" \
  -e PUID=1000 -e PGID=1000 \
  -e SOCKS_PORT="$SOCKS_PORT" -e HTTP_PORT="$HTTP_PORT" \
  -e DEVICE_REGION="$DEVICE_REGION" -e EGRESS_REGION="$EGRESS_REGION" \
  -v "${CONF_DIR}:/config" \
  "$IMAGE"
RUN
chmod 755 /usr/local/sbin/vps-psiphon-run

# ---- watchdog ---------------------------------------------------------------
cat > /usr/local/sbin/vps-psiphon-watchdog <<'WD'
#!/usr/bin/env bash
# Rotation triggers, in order of how certain they are:
#   1. tunnel dead   — SOCKS does not answer.
#   2. wrong country — Google's own verdict about this exit does not match the region
#      we asked for. YouTube publishes that verdict in its page source as "GL":"XX".
#      This is the failure that makes Cloudflare WARP unusable for region-gated
#      services: WARP geolocates back to the client's real country, so they refuse.
#   3. HEALTH_CMD    — anything further that only you can verify.
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
S=(--socks5-hostname "127.0.0.1:${SOCKS_PORT}")
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

reason=""; gl=""
if [ "$alive" = 0 ]; then
  reason="socks-dead"
else
  gl="$(curl -s --max-time 25 "${S[@]}" -H 'Accept-Language: en-US' https://www.youtube.com/ 2>/dev/null \
        | grep -oE '"GL":"[A-Z]{2}"' | head -1 | cut -d'"' -f4 || true)"
  if [ -n "$gl" ]; then
    if [ -n "${EGRESS_REGION:-}" ] && [ "$gl" != "$EGRESS_REGION" ]; then
      reason="wrong-country (asked $EGRESS_REGION, Google sees $gl)"
    elif [ -z "${EGRESS_REGION:-}" ] && [ -n "${OK_REGIONS:-}" ]; then
      case " $OK_REGIONS " in
        *" $gl "*) : ;;
        *) reason="wrong-country (Google sees $gl, not in '$OK_REGIONS')" ;;
      esac
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

now=$(date +%s)
if [ "$fails" -ge "${FAIL_THRESHOLD:-2}" ] && [ $((now - last_rotate)) -ge "${ROTATE_COOLDOWN:-1800}" ]; then
  old="$(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotating away from exit $old"
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
. /etc/default/vps-psiphon
S=(--socks5-hostname "127.0.0.1:${SOCKS_PORT}")

status() {
  echo "container : $(docker ps --filter "name=^${NAME}$" --format '{{.Status}}' || echo 'DOWN')"
  echo "service   : $(systemctl is-active vps-psiphon.service) / $(systemctl is-enabled vps-psiphon.service 2>/dev/null)"
  echo "watchdog  : $(systemctl is-active vps-psiphon-watchdog.timer) / $(systemctl is-enabled vps-psiphon-watchdog.timer 2>/dev/null)"
  echo "socks     : 127.0.0.1:${SOCKS_PORT}   (region requested: ${EGRESS_REGION:-auto})"
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
  rotate) echo "rotating (fresh tunnel, new exit)…"; systemctl restart vps-psiphon.service; sleep 45; status ;;
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
    systemctl disable --now vps-psiphon-watchdog.timer vps-psiphon.service 2>/dev/null
    docker rm -f "$NAME" 2>/dev/null
    rm -f /etc/systemd/system/vps-psiphon.service \
          /etc/systemd/system/vps-psiphon-watchdog.service \
          /etc/systemd/system/vps-psiphon-watchdog.timer
    rm -f /usr/local/sbin/vps-psiphon-run /usr/local/sbin/vps-psiphon-watchdog \
          /etc/default/vps-psiphon /var/lib/vps-psiphon-watchdog.state
    rm -rf /opt/vps-psiphon
    systemctl daemon-reload
    echo "removed (this CLI itself: rm -f /usr/local/sbin/vps-psiphon)" ;;
  *) echo "usage: vps-psiphon {status|rotate|region <CC>|speed|logs [n]|watchdog [n]|uninstall}" ;;
esac
CLI
chmod 755 /usr/local/sbin/vps-psiphon

# ---- units ------------------------------------------------------------------
cat > /etc/systemd/system/vps-psiphon.service <<'U1'
[Unit]
Description=vps-psiphon egress tunnel (loopback SOCKS5 for xray)
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
for i in $(seq 1 60); do
  docker logs "$NAME" 2>&1 | grep -q '"noticeType":"Tunnels"' && break
  sleep 2
done
sleep 3
echo
/usr/local/sbin/vps-psiphon status
echo
say "xray outbound:"
cat <<OUT
    { "tag": "psiphon-out", "protocol": "socks",
      "settings": { "address": "127.0.0.1", "port": $SOCKS_PORT } }
OUT
say "manage with:  vps-psiphon {status|rotate|region <CC>|speed|logs|uninstall}"
