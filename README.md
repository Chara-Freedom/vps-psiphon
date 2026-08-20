[РУССКОЕ ЧИТАЙМЕНЯ](README-RU.md)

# vps-psiphon

Psiphon as an egress point for an xray/remnawave node.

The script runs the Psiphon client in a container, publishes its SOCKS5 on a
host-private address and hands it to xray under systemd supervision. A separate watchdog tracks not
just whether the tunnel is alive, but whether the exit address is still usable —
and reconnects to a different one when it stops being usable.

The xray outbound is five lines. The node does everything else.

Companion project: **[vps-warp](https://github.com/tagashi666/vps-warp)** — the
same idea over Cloudflare WARP. The two coexist without conflict: WARP works at
kernel level through `fwmark`, vps-psiphon through a local SOCKS, so xray can
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
> connection. This script never publishes on a wildcard of its own accord: it binds
> either the docker0 gateway (the default) or `127.0.0.1` — both host-private, and
> neither routable from outside. Which of the two, and why it matters, is under
> [Where the SOCKS5 is published](#where-the-socks5-is-published). `--bind` takes
> any other address you hand it, a public one included — that is your call to make,
> and the access control such an address then needs is yours to add.
>
> If you use the image by hand regardless, the published ports are what you have to
> change — both of them, in the compose file the image ships with:
>
> ```yaml
> ports:
>   - "127.0.0.1:1080:1080"   # shipped as 1080:1080
>   - "127.0.0.1:8080:8080"   # shipped as 8080:8080
> ```
>
> and `-p 127.0.0.1:1080:1080` likewise for the `docker run` line next to it. The
> address prefix is the entire fix: `SOCKS_PORT` and `HTTP_PORT` stay as they are,
> because they decide where psiphon listens inside the container, not who may reach
> it from outside. Delete the 8080 entry altogether if you have no use for the HTTP
> proxy — an unpublished port cannot be exposed by mistake. Then verify rather than
> assume, since this is the kind of edit that silently does not apply: `ss -tlnp |
> grep -E '1080|8080'` must show `127.0.0.1`, never `0.0.0.0` or `[::]`.

## Links

- [Psiphon-Labs/psiphon-tunnel-core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) — the client itself
- [swarupsengupta2007/psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker) — the image, built from source in CI
- [vps-warp](https://github.com/tagashi666/vps-warp) — the same thing for Cloudflare WARP

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
| `--region CC[,CC…]` | auto | exit country, ISO 3166-1 alpha-2. Several form a rotation pool |
| `--device-region CC` | autodetected | region the client reports (cosmetic — the server decides by GeoIP) |
| `--socks-port N` | 1080 | SOCKS5 port for xray |
| `--http-port N` | 8080 | HTTP proxy port |
| `--no-http` | — | do not publish the HTTP proxy at all; remembered across reinstalls |
| `--http` | — | publish it after all — undoes a stored `--no-http` |
| `--deny-regions 'CC…'` | `RU BY IR SY CU KP CN VE` | countries the exit must never be in; checked in every mode. Empty disables it |
| `--bind ADDR` | docker0 gateway | host address the ports are published on |
| `--bind-loopback` | — | publish on `127.0.0.1` instead of the gateway |
| `--image REF` | `swarupsengupta2007/psiphon:latest` | container image |
| `--no-watchdog` | — | skip the watchdog |

Regions available at the time of writing: `AT AU BE BR CA CH CZ DE DK ES FR GB ID
IE IN IT JP NL NO PL RS SE SG US`. Empty means auto — the fastest server in any
country.

### Ports already in use

Docker allocates host ports when the container starts, which is after the
installer has written its files and enabled its units. An unchecked collision
therefore does not fail the install. What it used to give you, in order: a service
looping on a bind error, then about two minutes of complete silence while the
installer waited for a tunnel — the container runs with `--rm`, so each crash
deleted it and there was no log left to report — and then a closing "here is your
outbound" and exit 0, over a service that had never once run. Both published ports
are checked up front instead, and the two are not treated alike:

- **SOCKS** is refused, never moved. This port is the one xray's outbound dials,
  so relocating it would leave a healthy-looking tunnel that carries no traffic.
  The error names the process or container holding the port and suggests a free
  one for `--socks-port`.
- **HTTP** is moved to the next free port, because nothing in this setup consumes
  it. A port you name explicitly with `--http-port` is refused rather than
  reinterpreted; `--no-http` skips publishing it entirely. That last one is
  stored, so a reinstall keeps the proxy unpublished until `--http` asks for it
  back — a decision to remove a port should not be undone by re-running the
  installer.

A collision is judged the way the kernel judges it, not by comparing strings: a
listener on `0.0.0.0` blocks every bind of that port, so a neighbouring container
published on `0.0.0.0:8080` does collide with our `127.0.0.1:8080`.

Should the container fail to start anyway, the installer reports the actual docker
error, stops the unit so it is not looping while you read it, and exits non-zero —
about three seconds from launch, rather than two minutes of nothing.

## Outbound

```json
{
  "tag": "psiphon-out",
  "protocol": "socks",
  "settings": {
    "address": "172.17.0.1",
    "port": 1080
  }
}
```

The installer prints this block with the address it actually resolved — copy that
one, not the sample, since the default is read from the host.

Routing rules are yours to decide. One constraint: **do not send UDP here** — the
Psiphon local proxy does not support it (see Measurements).

### Where the SOCKS5 is published

Two addresses are supported, and the difference is measurable rather than stylistic:

| | reachable by | carried by |
|---|---|---|
| docker0 gateway — default, usually `172.17.0.1` | the host, and containers on the default bridge | the kernel |
| `127.0.0.1` — `--bind-loopback` | processes on the host only | `docker-proxy`, in userspace |

Docker writes a DNAT rule for every published port, but a loopback destination
needs `net.ipv4.conf.all.route_localnet`, which docker does not set. On loopback
that rule therefore never fires — its packet counter sits at zero — and
`docker-proxy` copies every byte between two sockets in userspace instead. On a
node carrying ~100 new connections per second that copy measured 0.10 of a core
sustained and 0.27-0.36 at peak; the same traffic published on the gateway took it
to exactly 0.00, with throughput unchanged. Bulk transfers hide this — the cost is
in connection setup, so the busier the node, the worse loopback looks.

Neither address is reachable from the internet. What the gateway costs is that
other containers on the default bridge reach the tunnel too, which is what
`--bind-loopback` is for when that matters more than the core does. Those two are
what the installer chooses between on its own; `--bind ADDR` publishes on any
address you name instead, and guarding one that is reachable from outside is then
yours to do.

Moving this on an existing install takes two edits and needs both: re-run the
installer with the new setting, and change the address in the outbound. The
installer cannot do the second — the outbound lives in your panel — so it warns
loudly and reprints the outbound whenever the address moves.

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
vps-psiphon pool 'DE NL FR' countries to rotate through ('' clears it)
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

Five rotation triggers, in order of how certain they are:

1. **tunnel dead** — SOCKS does not answer.
2. **denied country** — Google places the exit in a sanctioned or Google-blocked
   region (`DENY_REGIONS`, default `RU BY IR SY CU KP CN VE`). This is the only
   country check that runs in *every* mode: with no pinned region and no
   `OK_REGIONS`, the allow-list below is empty by definition and judges nothing —
   which is exactly when an exit in a sanctioned region would sit there unnoticed.
   The two lists are not alternatives. The set of acceptable countries is closed and
   short, so an allow-list handles a pinned region well; the set of dangerous ones is
   open, which is why it is worth naming them separately and checking them always.
3. **wrong country** — Google's own verdict about the exit does not match the region
   you asked for.
4. **slow tunnel** — the exit answers, from the right country, and carries almost
   nothing. Psiphon picks its server once per tunnel, so a bad pick persists until
   something forces a reconnect, and both checks above stay green the whole time.
   The rate is measured on the country check's own fetch, so it costs no extra
   traffic; below `MIN_THROUGHPUT_KBPS` counts as a failure. Every check logs its
   rate, which is what makes a gradual decline visible at all.

   The floor is one number for every node, and 800 KB/s is where measurement put it:
   replaying three nodes' own logged history (~40 hours each, medians 1765 / 1987 /
   3079 KB/s) through the window rule, 800 causes no rotation on any of them while
   1000 costs the slowest two and 1200 five — and a real collapse is caught on the
   second check either way. What made the old default of 100 useless was its distance
   from reality: a working tunnel reads in the thousands, so a fifteen-fold collapse
   passed for health. The gate is skipped for
   `THROUGHPUT_GRACE_SEC` after a start: a freshly dialled tunnel is still ramping
   while every client the restart cut loose reconnects at once, and that first
   reading is far below where the tunnel settles minutes later.
5. **`HEALTH_CMD`** — an optional command of your own; a non-zero exit rotates.

Google's captcha wall (`302 → /sorry/index`) is shown in `status` and logged when it
changes, but never rotates on its own: a human solves a captcha in seconds, and
churning the tunnel over one costs more than it saves.

Threshold is 2 failures within the last 5 checks, cooldown between rotations 30
minutes (`FAIL_THRESHOLD`, `FAIL_WINDOW`, `ROTATE_COOLDOWN`). A window rather than a
run of consecutive failures, because the tunnel that most needs rotating is the one
that is degraded rather than dead — and that one passes every other check, which
resets a consecutive counter and keeps the rotation permanently out of reach.
Journal: `/var/log/vps-psiphon-watchdog.log`.

Rotation is meaningful here because Psiphon exits live on heterogeneous third-party
infrastructure — reconnecting changes both the address and the ASN.

### Rotating through a pool of countries

Psiphon takes **one** egress country, never a list, and rotating inside it retries
that country's servers — the very set that is exhausted when the country is busy.
Leaving the region empty (`auto`) does widen the choice, but it can answer from
another continent, and the watchdog would only notice a check later.

`REGION_POOL` closes that gap on this side: every rotation advances one step
through the list, so the retry draws on a different country while the exit stays
inside a set you chose.

```
bash psiphon_install.sh --region DE,NL,FR      # first entry is where it starts
vps-psiphon pool 'DE NL FR AT'                 # or set it later
vps-psiphon pool ''                            # back to a single fixed country
```

The pool doubles as the country check's allow-list — anything you list is accepted
as a destination, so keep it to countries you actually want to be seen from and
that are near enough not to cost you the latency. Empty (the default) leaves
behaviour exactly as it was: rotations stay in `EGRESS_REGION`.

The region is applied by rewriting `psiphon.config` in place. The image seeds that
file only when it is absent, so the edit sticks — and the client keeps its cached
server list, which `vps-psiphon region` discards along with the whole config
directory.

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
| `MIN_THROUGHPUT_KBPS=800` | throughput floor in KB/s, measured on the watchdog's own fetch. One value for every node; change it only for a node that genuinely cannot reach it. `0` disables the check |
| `FAIL_WINDOW=5` | how many recent checks `FAIL_THRESHOLD` failures are counted over |
| `THROUGHPUT_GRACE_SEC=300` | seconds after a container start during which the rate is logged but not judged, while the tunnel ramps |
| `REGION_POOL='DE NL FR'` | countries each rotation advances through, and the country check's allow-list; empty pins rotations to `EGRESS_REGION` |
| `DENY_REGIONS='RU BY IR SY CU KP CN VE'` | countries the exit must never be in. Checked first and in every mode, unlike the allow-lists above; empty disables it |
| `HEALTH_CMD='curl -sf --socks5-hostname $BIND:$SOCKS_PORT -o /dev/null https://example.com/'` | extra probe; non-zero exit rotates. `$SOCKS_PORT` is exported for it |

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
  container psiphon listens on `0.0.0.0`, so `-p 1080:1080` with no address prefix
  publishes an open SOCKS proxy to the internet. The script always supplies one —
  the docker0 gateway or `127.0.0.1`, both host-private — and never picks a
  wildcard on its own, though a `--bind` you name is used exactly as given. Keep
  it in mind if you edit by hand.
- **A host firewall does not contain a published container port.** Docker's publish
  is a DNAT rule in `nat/PREROUTING`, which runs before the filter rules ufw
  manages, so `ufw deny 1080` on an exposed port changes nothing and "the firewall
  is up" is not evidence the port is closed. Check what is actually listening —
  `ss -tlnp | grep 1080` should show your `BIND` address, never `0.0.0.0` or `[::]`. If you
  must leave a port published wider, filter it in the `DOCKER-USER` chain, which
  docker consults first.
- **Changing the region requires clearing `/opt/vps-psiphon/config`.** The image
  seeds the config on first run only; after that `EGRESS_REGION` from the
  environment is silently ignored and you stay in the old country without being
  told. `vps-psiphon region` and a re-install both handle this.
- **`--bind-loopback` requires the xray container to use host networking.**
  Loopback exists separately inside every namespace, so from a bridged container
  `127.0.0.1` names that container, not the tunnel. The default gateway address
  carries no such ambiguity and needs nothing changed about xray. The script checks
  and warns.
- **Moving the published address is two edits, not one.** The installer rewrites
  its own files; the outbound lives in your panel, out of its reach. Until both are
  done the tunnel is up, every check reads green, and it carries nothing.
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
