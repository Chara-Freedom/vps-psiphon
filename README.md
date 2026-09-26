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
| `--deny-regions 'CC…'` | `RU BY IR SY CU KP CN VE` | countries the exit must never be in; checked first, in every mode. Empty disables it |
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
vps-psiphon                 state: region, server's country, exit IP, Google's verdict, Gemini's answer, traffic
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
| `/usr/local/sbin/vps-psiphon-gemini-check` | asks Gemini itself whether it serves the exit |
| `/usr/local/sbin/vps-psiphon` | CLI |
| `vps-psiphon.service` | container under systemd, `Restart=always` |
| `vps-psiphon-watchdog.timer` | check every 10 minutes |
| `/opt/vps-psiphon/config` | Psiphon config (container volume) |
| `/var/log/vps-psiphon-watchdog.log` | watchdog journal |
| `/var/lib/vps-psiphon-watchdog.state` | watchdog counters |

## The watchdog

Six rotation triggers, in order of how certain they are:

1. **tunnel dead** — SOCKS does not answer.
2. **denied country** — Google places the exit in a sanctioned or Google-blocked
   region (`DENY_REGIONS`, default `RU BY IR SY CU KP CN VE`). Checked first, in
   every mode.
3. **country mismatch** — Google's verdict about the exit (`GL`) is not the country
   Psiphon reports for the server it connected to. Google has reclassified that
   address, and such exits break Google's AI services — see
   [A mismatch, not a country](#a-mismatch-not-a-country). There is no list of
   acceptable verdicts: the fault is the disagreement itself, and an exit where both
   sides say the same country works, whichever country it is. If either side cannot
   be read, nothing is judged.
4. **stalled tunnel** — SOCKS answers the liveness probe, but no HTTP request through
   the tunnel completes at all. Judged by the absence of a response rather than its
   size, so Google's captcha — small, but a response — is never read as a stall.
5. **slow tunnel** — the exit answers, from the right country, and carries almost
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
   passed for health. A new tunnel is judged from its first check, which comes about
   ten minutes in, well past its ramp. An earlier version excused that reading all the
   same; across four nodes over five weeks, of 276 tunnels with a slow first reading,
   the excuse changed nothing for 28, spared 22 that went on to serve, and kept 226
   that were rotated anyway one check longer — ten minutes each, 45 hours in all.
6. **Gemini refuses** — asked directly: once for every new tunnel, at its first check
   — a rotation, `rotate`, `region` and a reinstall all start one — and then every
   `GEMINI_CHECK_SEC` (two hours by default), so a refused exit does not stand until
   the old clock runs out. Gemini keeps a geo-check of its own that `GL` does not track, so an exit
   can pass everything above and still be refused — see
   [Gemini keeps its own geo-check](#gemini-keeps-its-own-geo-check). This trigger is
   decisive: one refusal rotates at once, past the failure window, because a refused
   exit stays refused. An answer that is neither a reply nor a
   refusal is logged as inconclusive and never rotates.

Google's captcha wall (`302 → /sorry/index`) is not probed at all. It never justified
a rotation — a human solves a captcha in seconds — and the probe that watched for it,
the same search every ten minutes from the same address, was the most bot-like thing
the watchdog did.

Threshold is 2 failures within the last 5 checks (`FAIL_THRESHOLD`, `FAIL_WINDOW`).
A window rather than a run of consecutive failures, because the tunnel that most needs
rotating is the one that is degraded rather than dead — and that one passes every
other check, which resets a consecutive counter and keeps the rotation permanently out
of reach. Journal: `/var/log/vps-psiphon-watchdog.log`.

There is no cooldown between rotations. The window starts empty after each rotation,
so two checks — about twenty minutes — always separate one from the next. An earlier
version held rotations 30 minutes apart; across five deployments over three weeks that
cooldown held a rotation back 113 times and prevented none, because the failures that
asked for it were still in the window when it expired. All it did was keep a known-bad
exit — dead, stalled, or one Google places in a denied country — for a median of ten
more minutes.

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

Keep the pool to countries near enough not to cost you the latency. Empty (the
default) keeps rotations in `EGRESS_REGION`.

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
| The VPS's own address, over IPv6 | FI | FI | `FI` | 200 |
| The VPS's own address, over IPv4 | FI | FI | **`RU`** | — |
| A Russian VPS, as a control | RU | — | `RU` | **403, "Russia not available"** |

Only Google calls the WARP exit Russian. Independent geolocation says Finland, and
wikidot serves that exit normally while refusing a genuinely Russian address — so
this is not WARP leaking anyone's location. Google classifies those ranges that way
for its own reasons, and changing WARP endpoints does not help, because the
classification follows the range rather than the endpoint.

⚠️ **Probe with `curl -4`, or you will measure an address nobody uses.** The last two
rows are the same machine at the same moment, split only by which protocol the request
left over. On a dual-stack host `getent ahosts www.youtube.com` returns the AAAA first,
so an unflagged `curl` reads the country of the v6 address — while a Psiphon tunnel, and
usually the traffic you care about, leaves over IPv4. That is not a hypothetical: the
`FI` originally recorded for this VPS was an IPv6 reading, and forcing IPv4 turned it
into `RU`, which is a supported-country failure rather than the mystery it looked like.
Google also demonstrably rewrites an ordinary hoster address, not just a VPN provider's
ranges, once enough traffic through it looks like it belongs somewhere else.

```
# the host itself
curl -4 -s https://www.youtube.com/ | grep -o '"GL":"[A-Z]\{2\}"'

# through the tunnel
curl -4 -s --socks5-hostname 127.0.0.1:1080 https://www.youtube.com/ | grep -o '"GL":"[A-Z]\{2\}"'
```

`vps-psiphon status` and the watchdog are unaffected by this: both read `GL` through the
SOCKS tunnel, so they see the exit's own address and nothing else.

The consequence is therefore narrow and specific: **services gated on Google's view
refuse a WARP exit, while services with honest IP geolocation are unaffected.**
Psiphon is mostly consistent across both — most exits come back as the country asked
for, from Google and from the geolocation services alike. The ones that do not are
the subject of [A mismatch, not a country](#a-mismatch-not-a-country).

**`GL` is YouTube's verdict.** Force `-4` and take it at face value for YouTube. A `GL`
that agrees with the server's country says nothing reliable about Gemini, which runs a
geo-check of its own — that is the next section; a `GL` that disagrees is a sign of
trouble for all of Google's AI services.

### Gemini keeps its own geo-check

An exit can read as the right country to YouTube and still be refused by Gemini, and
the reverse happens too. Measured on one day across ten addresses, all logged out:

| Address | YouTube `GL` | Gemini |
|---|---|---|
| A Psiphon exit held for six days | `NL` | **refused, error 1060** |
| Four other Psiphon exits | `NL`, `DE` | replies |
| A Finnish VPS's own address, IPv4 | **`RU`** | replies, and places it in Finland |
| Another Finnish VPS's own address | `FI` | replies, and places it in Finland |
| A Dutch VPS's own address | `NL` | replies |
| Two Russian VPSes | `RU`, one not read | **refused, error 1060** |

The first row is the failure no country check can see: the tunnel fast, every check
green, and Gemini refusing it for days until its users noticed. The third row is the
mirror image.

Chatting without an account is part of Gemini — logged-out messages are answered by a
lighter model — so it can simply be asked: fetch the page for its session fields and
cookies, send one message. A serving address replies and states the country Gemini
places it in; a refused one returns error 1060 and nothing else. Every refused address
above gave 1060 and every serving one replied, which is why one refusal is enough.

```
vps-psiphon-gemini-check            # through the tunnel
vps-psiphon-gemini-check --direct   # from the host's own address
```

Exit status 0 means served, 1 refused, 2 inconclusive. The watchdog asks once per new
tunnel and then every `GEMINI_CHECK_SEC`, and rotates on a refusal; `vps-psiphon
status` asks as well. What
tells an address problem apart from your account: an account-level restriction follows
you from exit to exit, while this one disappears the moment the exit changes.

### AI Studio keeps a third one

Google AI Studio can refuse an exit that Gemini serves: the page opens, and the model
list fails with *"Failed to list models: User location is not supported for the API
use."* The verdict belongs to the exit, so it comes and goes as exits rotate, and two
servers can disagree at the same moment.

It is not the Gemini API's check, although the wording is the API's. The message comes
from the page's own model-list request, which only runs for a signed-in account —
logged out, the page is nothing but a redirect to sign-in. The public API, called with
a key through the very same exits, answered every one of them, including exits YouTube
places in Russia. So there is no anonymous way to ask, and vps-psiphon does not ask. It
does not need to: the exits AI Studio refuses are the ones the next section is about,
and a manual `vps-psiphon rotate` covers the rest.

### A mismatch, not a country

Fifty-nine exits (55 distinct addresses) in one night, each checked four ways — Google's
verdict, Gemini, AI Studio through a throwaway signed-in account, and the country
Psiphon reports for the server it connected to:

| Exit | Exits | Gemini or AI Studio broken |
|---|---|---|
| Google's verdict matches the server's country (FR, NL, DE) | 39 | 7 |
| Genuine US — the server in the US, and Google says US | 8 | 0 |
| Google's verdict differs from the server's — `US` or `RU` for a server in FR, NL or DE | 12 | **12** |

The seven in the first row are refused by Gemini itself (error 1060), and the Gemini
check rotates them away. The last row is what nothing else saw: an address Google has
reclassified keeps working for YouTube and breaks the AI services. A `US` verdict on a
European server looked like a harmless rewrite and was once accepted by default for
that reason — but genuine US exits work; what breaks is the disagreement. So the
watchdog compares Google's verdict with the country Psiphon reports and rotates on a
mismatch, and there is no list of acceptable verdicts at all.

By provider, DigitalOcean's servers in Germany fared worst that night — 9 of 11
broken, mismatched or refused — and Akamai's best, 7 of 7 fine. Psiphon does not let
you choose the provider, so that is information, not a setting.

### Optional settings

These live in `/etc/default/vps-psiphon`. That file is sourced by the shell, so **any
value containing spaces must be quoted** — unquoted, everything after the first space
is run as a command.

| Setting | Effect |
|---|---|
| `MIN_THROUGHPUT_KBPS=800` | throughput floor in KB/s, measured on the watchdog's own fetch. One value for every node; change it only for a node that genuinely cannot reach it. `0` disables the check |
| `FAIL_WINDOW=5` | how many recent checks `FAIL_THRESHOLD` failures are counted over |
| `REGION_POOL='DE NL FR'` | countries each rotation advances through; empty pins rotations to `EGRESS_REGION` |
| `DENY_REGIONS='RU BY IR SY CU KP CN VE'` | countries the exit must never be in. Checked first, in every mode; empty disables it |
| `GEMINI_CHECK_SEC=7200` | seconds between asking Gemini whether it serves the exit; every new tunnel is also asked at its first check. One refusal rotates at once. `0` disables it |

## Measurements

VPS in Finland (Hetzner, 12 CPU / 64 GB), August 2026, exit region DE.

**There is no rate limit.** The server reports `TrafficRateLimits: {downstream: 0,
upstream: 0}` with `ActiveAuthorizationIDs: []`. One gigabyte through a single
stream in twenty 50 MB blocks came out flat at 20.8–23.0 Mbit/s — first block
22.91, twentieth 22.93. No knee where `ReadUnthrottledBytes` would run out. A paid
subscription is not needed to lift a limit that is not applied.

| What | Value |
|---|---|
| Single stream | ~23 Mbit/s, steady across 1 GB — at Psiphon's default window, see below |
| 8 streams aggregate | 196 Mbit/s on one German exit, 53 on another |
| Upload, 4 streams | 62 Mbit/s |
| TTFB to DE/NL | 0.12 s |
| TTFB to SG | 1.11 s — a single stream fell to 1.6 Mbit/s purely from RTT, see [The window per connection](#the-window-per-connection) |
| Reconnects | none across the whole run, exit IP never changed |
| UDP | `UDP ASSOCIATE` → `REP=7 COMMAND NOT SUPPORTED`; `CONNECT` → `REP=0` |

Exit region affects throughput more than anything else: from Europe, DE versus SG
differs by more than tenfold. The individual server within a region matters too —
aggregate differed fourfold between two German exits.

### The window per connection

Every connection through the tunnel is one SSH channel, and Psiphon gives each channel
a window of 4 × 32 KB = 128 KB by default. The window is how much the Psiphon server may
send down the channel before the client on the VPS allows it to send more. Once the
server has sent a full window it waits: the data has to reach the VPS and the grant has
to come back. That wait is the round trip (RTT), meaning the one between the VPS and the
Psiphon server, not the one to the site. Hence the ceiling: a connection moves at most
a window per round trip, however idle the tunnel is.

In practice less than a window is in flight. The client returns the window in batches
rather than after every piece, a rule Psiphon takes from OpenSSH: a grant goes out once
more than three 32 KB packets or more than half the window are unreturned. Against
OpenSSH's 2 MB window that is nothing, but at 128 KB the window comes back every
64–96 KB, so on average 32–48 KB has reached the VPS without being returned yet and
~80–96 KB is left in flight. On two nodes with different round trips a connection held
the same ~75 KB in flight, the signature of a fixed window — ~20 Mbit/s over a 30 ms
tunnel; the batches account for most of the gap to 128 KB. That is the single-stream
figure above. Psiphon keeps the window small on purpose: its client serves one person,
and a large window lets one bulk download queue ahead of everything else on the shared
SSH connection.

The launcher sets `SSHChannelWindowSize` to 32 (1 MB). Measured on a test box, exits in
DE, round trip held at ~30 ms, two runs per value on a different server each time (one
broken server each at 128 KB and 2 MB left out):

| Window | One connection | Small request, idle → behind 8 downloads |
|---|---|---|
| 128 KB (Psiphon's default) | 21 Mbit/s | 100 → 101 ms |
| 512 KB | 35–45 Mbit/s | 210 → 260, 260 → 265 ms |
| 1 MB | 110–300 Mbit/s | 99 → 102, 92 → 95 ms |
| 2 MB | 260–290 Mbit/s | 109 → 160 ms |
| 4 MB | 65–550 Mbit/s | 95 → 106, 108 → 250 ms |

At 1 MB one connection got several times faster and nothing else waited longer; from
2 MB a small request behind the downloads began to wait. It matters for whatever moves
a lot through one connection, and YouTube is the usual case: with QUIC unavailable a
player typically takes video and audio from one host over one connection. 1080p at 60
frames runs at roughly 5–9 Mbit/s, and the player keeps a margin above the bitrate it
picks, so it lands right at the default window's ceiling — ~20 Mbit/s at 30 ms, ~10 at
60 ms — and drops quality on any slower server. 1440p and 4K sit above that ceiling
outright. It changes nothing for Gemini, whose answers are small. The watchdog's own fetch rose only
1.3–1.7x, so its throughput floor keeps its meaning.

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
