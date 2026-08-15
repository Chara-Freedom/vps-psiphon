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
| `--image REF` | `swarupsengupta2007/psiphon:latest` | container image |
| `--no-watchdog` | — | skip the watchdog |

Regions available at the time of writing: `AT AU BE BR CA CH CZ DE DK ES FR GB ID
IE IN IT JP NL NO PL RS SE SG US`. Empty means auto — the fastest server in any
country.

## Outbound

```json
{
  "tag": "psiphon-out",
  "protocol": "socks",
  "settings": {
    "servers": [{ "address": "127.0.0.1", "port": 1080 }]
  }
}
```

Routing rules are yours to decide. One constraint: **do not send UDP here** — the
Psiphon local proxy does not support it (see Measurements).

## Managing it

```
vps-psiphon                 state: region, exit IP, whether the exit is usable, traffic
vps-psiphon rotate          fresh tunnel → different exit IP
vps-psiphon region JP       change exit country
vps-psiphon speed           50 MB single stream + 4 streams aggregate
vps-psiphon logs [n]        Psiphon client log
vps-psiphon watchdog [n]    watchdog journal
vps-psiphon uninstall       remove
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

## The watchdog

Two failure modes, one action — rotate:

1. **tunnel dead** — SOCKS does not answer;
2. **exit unusable** — Google answers `302 → /sorry/index`, meaning the address has
   been placed under restrictions.

The second mode is the reason the watchdog exists: such an exit passes every
liveness check. Traffic flows, nothing errors, some services simply stop working.
The signature is unambiguous and produces no false positives.

Threshold is 2 consecutive failures, cooldown between rotations is 30 minutes
(`FAIL_THRESHOLD`, `ROTATE_COOLDOWN` in `/etc/default/vps-psiphon`).
Journal: `/var/log/vps-psiphon-watchdog.log`.

Rotation works here because Psiphon exits live on heterogeneous third-party
infrastructure — reconnecting changes both the address and the ASN.

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
vps-psiphon uninstall && rm -f /usr/local/sbin/vps-psiphon
```

## Links

- [Psiphon-Labs/psiphon-tunnel-core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) — the client itself
- [swarupsengupta2007/psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker) — the image, built from source in CI
- [vps-warp](https://github.com/tagashi666/vps-warp) — the same thing for Cloudflare WARP
