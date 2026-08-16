[РУССКОЕ ЧИТАЙМЕНЯ](README-RU.md)

# vps-psiphon

Psiphon as an egress point for an xray/remnawave node.

The script runs the Psiphon client in a container, binds its SOCKS5 to loopback
and hands it to xray under systemd supervision. A separate watchdog tracks not
just whether the tunnel is alive, but whether the exit address is still usable —
and reconnects to a different one when it stops being usable.

The xray outbound is four lines. The node does everything else.

Companion project: **[vps-warp](https://github.com/tagashi666/vps-warp)** — the
same idea over Cloudflare WARP. The two coexist without conflict: WARP works at
kernel level through `fwmark`, vps-psiphon through a loopback SOCKS, so xray can
hold both outbounds at once and split traffic by rules.

> ⚠️ **Do not install this on a server inside the country you are circumventing.**
> The Psiphon client generates recognisable outbound circumvention traffic: under
> DPI it is both blockable itself and a fingerprint that exposes the server. This
> belongs on a foreign node you already reach through your own transport.

> ⚠️ **Running the image by hand is not equivalent, and the difference is a public
> open proxy.** Psiphon listens on `0.0.0.0` inside the container, so the plain
> `docker run -p 1080:1080` — or the compose snippet you will find alongside the
> image — publishes SOCKS5, and the HTTP proxy with it, on *every* address the host
> has, with no authentication. Port 1080 is scanned continuously; an exposed one is
> found within hours and lands on public open-proxy lists, from where reputation
> blocklists pick it up — being an open proxy is a listable condition on its own,
> independent of anything you send. After that, strangers' traffic leaves through
> your tunnel, on your bandwidth, and any egress filtering you run by port number
> does not see it: whatever they do is encapsulated inside the tunnel's own
> connection. This script publishes on `127.0.0.1` for that reason.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh)
```

With an explicit exit country:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh) --region DE
```

Requires root, docker and curl.

### Flags

| Flag | Default | Purpose |
|---|---|---|
| `--region CC` | auto | exit country, ISO 3166-1 alpha-2 |
| `--device-region CC` | autodetected | region the client reports (cosmetic — the server decides by GeoIP) |
| `--socks-port N` | 1080 | loopback SOCKS5 port for xray |
| `--http-port N` | 8080 | loopback HTTP proxy port |
| `--no-http` | — | do not publish the HTTP proxy at all |
| `--image REF` | `swarupsengupta2007/psiphon:latest` | container image |
| `--no-watchdog` | — | skip the watchdog |

Regions available at the time of writing: `AT AU BE BR CA CH CZ DE DK ES FR GB ID
IE IN IT JP NL NO PL RS SE SG US`. Empty means auto — the fastest server in any
country.

### Ports already in use

Docker allocates host ports when the container starts, which is after the
installer has written its files and enabled its units. An unchecked collision
therefore does not fail the install — it leaves a crash-looping service behind an
installer that reported success. Both published ports are checked up front
instead, and the two are not treated alike:

- **SOCKS** is refused, never moved. This port is the one xray's outbound dials,
  so relocating it would leave a healthy-looking tunnel that carries no traffic.
  The error names the process or container holding the port and suggests a free
  one for `--socks-port`.
- **HTTP** is moved to the next free port, because nothing in this setup consumes
  it. A port you name explicitly with `--http-port` is refused rather than
  reinterpreted; `--no-http` skips publishing it entirely.

A collision is judged the way the kernel judges it, not by comparing strings: a
listener on `0.0.0.0` blocks every bind of that port, so a neighbouring container
published on `0.0.0.0:8080` does collide with our `127.0.0.1:8080`.

Should the container fail to start anyway, the installer reports the error,
stops the unit so it is not looping while you read it, and exits non-zero.

## Outbound

```json
{
  "tag": "psiphon-out",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": 1080
  }
}
```

Routing rules are yours to decide. One constraint: **do not send UDP here** — the
Psiphon local proxy does not support it (see Measurements).

Older guides wrap this in a `"servers": [ … ]` array. Xray still parses that form —
`infra/conf/socks.go` keeps both — but it is V2Ray legacy, no longer in the Xray
documentation, and panels that validate against the current schema will flag it.

### Expect to keep a second outbound

Psiphon exits are shared circumvention infrastructure, which is exactly the category
aggressive bot protection refuses. Measured: Reddit answers a Psiphon exit with
"you've been blocked by network security" while serving the same client normally
through a Cloudflare WARP exit.

So route per domain rather than sending everything one way. In practice the two
egresses fail on opposite sides — Google distrusts WARP ranges, Cloudflare-fronted
sites distrust shared circumvention exits — which makes them complements rather than
alternatives. That reasoning is inference; the Reddit and Google results behind it are
measured.

## Managing it

```
vps-psiphon                 state: region, exit IP, Google's country verdict, traffic
vps-psiphon rotate          fresh tunnel → different exit IP
vps-psiphon region JP       change exit country
vps-psiphon speed           50 MB single stream + 4 streams aggregate
vps-psiphon logs [n]        Psiphon client log
vps-psiphon watchdog [n]    watchdog journal
vps-psiphon uninstall       remove everything, including this CLI
```

## What gets installed

| File | Role |
|---|---|
| `/etc/default/vps-psiphon` | parameters |
| `/usr/local/sbin/vps-psiphon-run` | container launcher (`ExecStart`) |
| `/usr/local/sbin/vps-psiphon-watchdog` | liveness + unusable-exit detector |
| `/usr/local/sbin/vps-psiphon` | CLI |
| `vps-psiphon.service` | container under systemd, `Restart=always` |
| `vps-psiphon-watchdog.timer` | check every 10 minutes |
| `/opt/vps-psiphon/config` | Psiphon config (container volume) |
| `/var/log/vps-psiphon-watchdog.log` | watchdog journal |
| `/var/lib/vps-psiphon-watchdog.state` | watchdog counters |

## The watchdog

Three rotation triggers, in order of how certain they are:

1. **tunnel dead** — SOCKS does not answer.
2. **wrong country** — Google's own verdict about the exit does not match the region
   you asked for.
3. **`HEALTH_CMD`** — an optional command of your own; a non-zero exit rotates.

Google's captcha wall (`302 → /sorry/index`) is shown in `status` and logged when it
changes, but never rotates on its own: a human solves a captcha in seconds, and
churning the tunnel over one costs more than it saves.

Threshold is 2 consecutive failures, cooldown between rotations 30 minutes
(`FAIL_THRESHOLD`, `ROTATE_COOLDOWN`). Journal: `/var/log/vps-psiphon-watchdog.log`.

Rotation is meaningful here because Psiphon exits live on heterogeneous third-party
infrastructure — reconnecting changes both the address and the ASN.

### Why the country check is the one that matters

Google keeps its own opinion about where an address is, and that opinion can disagree
with everyone else's. YouTube publishes it in its page source as `"GL":"XX"`, which
costs one request and no credentials. Measured from a Finnish VPS, alongside two
independent geolocation services and wikidot.com — which blocks Russia outright and
therefore answers honestly:

| Exit | ip-api | ipinfo | Google | wikidot.com |
|---|---|---|---|---|
| Psiphon, region DE | DE | DE | `DE` | 200 |
| Cloudflare WARP | FI | FI | **`RU`** | 200 |
| The VPS's own address | FI | FI | `FI` | 200 |
| A Russian VPS, as a control | RU | — | `RU` | **403, "Russia not available"** |

Only Google calls the WARP exit Russian. Independent geolocation says Finland, and
wikidot serves that exit normally while refusing a genuinely Russian address — so
this is not WARP leaking anyone's location. Google classifies those ranges that way
for its own reasons, and changing WARP endpoints does not help, because the
classification follows the range rather than the endpoint.

The consequence is therefore narrow and specific: **services gated on Google's view
refuse a WARP exit, while services with honest IP geolocation are unaffected.**
Psiphon is consistent across both — asking for JP, NL or DE yields exactly `JP`,
`NL`, `DE` from Google and from the geolocation services alike.

**A correct country is necessary, not sufficient**, and this probe has a second limit
worth knowing: `GL` is what Google thinks of the *address*. A signed-in user also
carries account-level signals, so a logged-in session can behave more restrictively
than this anonymous check suggests. `HEALTH_CMD` is where you put a check for what
this one cannot see.

### Optional settings

Both live in `/etc/default/vps-psiphon`. That file is sourced by the shell, so **any
value containing spaces must be quoted** — unquoted, everything after the first space
is run as a command.

| Setting | Effect |
|---|---|
| `OK_REGIONS='DE NL JP'` | acceptable verdicts when no region is pinned; ignored while `EGRESS_REGION` is set |
| `HEALTH_CMD='curl -sf --socks5-hostname 127.0.0.1:$SOCKS_PORT -o /dev/null https://example.com/'` | extra probe; non-zero exit rotates. `$SOCKS_PORT` is exported for it |

## Measurements

VPS in Finland (Hetzner, 12 CPU / 64 GB), August 2026, exit region DE.

**There is no rate limit.** The server reports `TrafficRateLimits: {downstream: 0,
upstream: 0}` with `ActiveAuthorizationIDs: []`. One gigabyte through a single
stream in twenty 50 MB blocks came out flat at 20.8–23.0 Mbit/s — first block
22.91, twentieth 22.93. No knee where `ReadUnthrottledBytes` would run out. A paid
subscription is not needed to lift a limit that is not applied.

| What | Value |
|---|---|
| Single stream | ~23 Mbit/s, steady across 1 GB |
| 8 streams aggregate | 196 Mbit/s on one German exit, 53 on another |
| Upload, 4 streams | 62 Mbit/s |
| TTFB to DE/NL | 0.12 s |
| TTFB to SG | 1.11 s — a single stream fell to 1.6 Mbit/s purely from RTT |
| Reconnects | none across the whole run, exit IP never changed |
| UDP | `UDP ASSOCIATE` → `REP=7 COMMAND NOT SUPPORTED`; `CONNECT` → `REP=0` |

Exit region affects throughput more than anything else: from Europe, DE versus SG
differs by more than tenfold. The individual server within a region matters too —
aggregate differed fourfold between two German exits.

## Pitfalls

- **The `BIND` prefix on the published ports is load-bearing.** Inside the
  container psiphon listens on `0.0.0.0`, so `-p 1080:1080` without `127.0.0.1:`
  publishes an open SOCKS proxy to the internet. The script handles this; keep it
  in mind if you edit by hand.
- **A host firewall does not contain a published container port.** Docker's publish
  is a DNAT rule in `nat/PREROUTING`, which runs before the filter rules ufw
  manages, so `ufw deny 1080` on an exposed port changes nothing and "the firewall
  is up" is not evidence the port is closed. Check what is actually listening —
  `ss -tlnp | grep 1080` should show `127.0.0.1`, never `0.0.0.0` or `[::]`. If you
  must leave a port published wider, filter it in the `DOCKER-USER` chain, which
  docker consults first.
- **Changing the region requires clearing `/opt/vps-psiphon/config`.** The image
  seeds the config on first run only; after that `EGRESS_REGION` from the
  environment is silently ignored and you stay in the old country without being
  told. `vps-psiphon region` and a re-install both handle this.
- **`127.0.0.1` requires the xray container to use host networking.** Otherwise
  that address points at the xray container itself. The script checks and warns;
  the workaround is to install with `BIND=172.17.0.1` and use that address in the
  outbound.
- **`TargetServerEntry`** in the Psiphon config pins one specific server, but it
  collapses the pool to size 1 with no failover and removes the ability to move
  off an unusable exit. Only the region is pinned here.

## Uninstall

```bash
vps-psiphon uninstall
```

Removes the units, the container, the image, the config directory, the watchdog log
and state — and finally unlinks itself, so nothing is left to clean up by hand. It
then checks the disk and, if anything survived, names it and exits non-zero.

## Links

- [Psiphon-Labs/psiphon-tunnel-core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) — the client itself
- [swarupsengupta2007/psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker) — the image, built from source in CI
- [vps-warp](https://github.com/tagashi666/vps-warp) — the same thing for Cloudflare WARP
