# qbzd in Docker

Containerised [QBZ headless daemon](https://github.com/vicrodh/qbz/wiki/Headless-Daemon):
a Qobuz Connect endpoint plus HTTP/CLI control plane, without the desktop app.

The image installs the upstream prebuilt release tarball (checksum-pinned in the
`Dockerfile`) on top of `debian:bookworm-slim`. The binary needs only
`libasound.so.2` beyond libc, so the runtime layer stays small. `amd64` and
`arm64` are both supported, which covers a Raspberry Pi as well as an x86 NUC.

## Requirements

A **Linux** host with the DAC attached. Audio leaves the container through ALSA
on `/dev/snd`, so Docker Desktop on macOS or Windows can run the daemon and its
API but cannot produce sound — there is no ALSA device inside the VM.

## Quick start

```bash
cp .env.example .env               # adjust QBZD_UID/QBZD_GID and AUDIO_GID
stat -c %g /dev/snd/controlC0      # the value AUDIO_GID needs
mkdir -p data && chown "$(id -u):$(id -g)" data

docker compose up -d --build
```

First start seeds `data/config/qbzd/qbzd.toml` and warns in the log if
`/dev/snd` is missing. The daemon tolerates a missing DAC or network at
start-up and retries with backoff rather than exiting.

### 1. Log in to Qobuz

The browser OAuth listener binds an ephemeral port, which a container cannot
publish, so use the paste flow (or inject a token directly):

```bash
docker compose exec -it qbzd qbzd login --paste
# or, if you already have one:
docker compose exec qbzd qbzd login --token <user_auth_token>
```

`--paste` prints a URL, you open it in any browser, and you paste the redirect
URL you land on back into the prompt.

An existing desktop installation can be handed over instead — export on the
desktop machine with `qbz`/`qbzd settings export --from desktop --include-auth`,
drop the `.qbzb` bundle into `data/`, then:

```bash
docker compose exec qbzd qbzd settings import /data/qbz-settings-XXXX.qbzb --include-auth
```

### 2. Pick the DAC and name the device

```bash
docker compose exec qbzd aplay -L                    # list ALSA devices
docker compose exec qbzd qbzd settings set audio.backend alsa
docker compose exec qbzd qbzd settings set audio.device 'hw:CARD=sndrpihifiberry,DEV=0'
docker compose exec qbzd qbzd settings set qconnect.device_name 'Living Room'
docker compose exec qbzd qbzd settings set playback.quality hires
docker compose restart qbzd
```

`audio.backend` matters here: it defaults to `system`, meaning the host sound
server, and there is no PipeWire or PulseAudio in the container. Set it to
`alsa` so the daemon drives `/dev/snd` directly.

`docker compose exec -it qbzd qbzd setup` opens the six-screen TUI configurator
if you prefer that to individual keys.

### 3. Enable the Connect endpoint

QConnect is off until you turn it on, and `qbzd settings set qconnect.enabled`
is not the key — it lives under its own subcommand:

```bash
docker compose exec qbzd qbzd qconnect enable
docker compose exec qbzd qbzd settings set qconnect.startup_mode on   # across restarts
```

### 4. Volume on DACs with an unconventional mixer name

The daemon's hardware-volume path matches conventional ALSA element names
(`Master`, `PCM`, `Headphone`, …). Many USB DACs name their single control
after the device — a Topping D50 III exposes `'D50 III'` — so the lookup fails
and the log shows `No volume control found`. Check yours:

```bash
docker compose exec qbzd amixer -c <card> scontrols
```

A conventional name means the daemon handles volume itself: enable it and
delete the `volume-bridge` service from `docker-compose.yml`.

```bash
docker compose exec qbzd qbzd settings set audio.alsa_hardware_volume true
```

An unconventional name means the `volume-bridge` service does the work. Set
`ALSA_CARD` and `ALSA_CONTROL` in `.env` to the values above, and leave
`audio.alsa_hardware_volume` enabled — the daemon's failing attempt is what
stops it applying software attenuation, so the samples reach the DAC untouched
and the DAC's own control does the attenuating.

The service sits behind a compose profile, so it only runs when you ask for it:

```bash
docker compose --profile volume-bridge up -d --build
docker compose logs -f qbzd-volume-bridge
```

Keep using `--profile volume-bridge` on later `up` calls, or the bridge is left
stopped while the daemon restarts.

The alternative is software volume — `audio.alsa_hardware_volume false`, no
bridge service — which works everywhere but scales samples in the daemon and
gives up bit-perfect output.

### 5. Verify and play

```bash
docker compose exec qbzd qbzd status     # auth, audio, playback, QConnect state
docker compose exec qbzd qbzd now
curl http://localhost:8182/api/status
```

The box now appears in the Connect picker of the official Qobuz apps. Qobuz
Connect is brokered over a cloud WebSocket rather than mDNS, so bridge
networking is enough — no host networking or multicast forwarding required.

## Configuration

`data/config/qbzd/qbzd.toml` holds process settings only — bind address, port,
optional bearer token, log level. Everything about audio and playback lives in
the daemon's stores and is changed through `qbzd settings set` or `qbzd setup`.

Edit the file and `docker compose restart qbzd` to apply.

## Security

The control API is unauthenticated by default, matching upstream's LAN-first
posture. Set a token in `qbzd.toml` when the port is reachable by anything you
do not trust, and never port-forward 8182 to the internet:

```toml
[server]
token = "a-long-random-string"
```

Clients then need `Authorization: Bearer <token>`; the CLI reads `QBZD_TOKEN`.

## Remote control from the host

```bash
export QBZD_HOST=127.0.0.1:8182
qbzd status          # a local qbzd binary can drive the container's daemon
```

Or drive the HTTP API directly: `/api/status`, `/api/now-playing`,
`/api/events` (SSE), `/api/playback/*`, `/api/queue/*`.

## Layout of `./data`

| Path | Contents |
| --- | --- |
| `config/qbzd/` | `qbzd.toml`, encrypted credentials, credential salt (mode 0700) |
| `share/qbzd/` | queue/session state, settings and QConnect databases |
| `cache/qbzd/` | artwork and loudness-analysis cache |

Back up `config/qbzd/` to keep the login; it is as sensitive as a password.

## Troubleshooting

**The image builds, but the container will not start:**

```
OCI runtime create failed: runc create failed: unable to apply cgroup
configuration: unable to start unit "docker-<id>.scope" (...):
The name org.freedesktop.systemd1 was not provided by any .service files
```

Docker defaults to the systemd cgroup driver when systemd is PID 1, so `runc`
asks systemd over D-Bus to create a transient scope unit for the container. On
DietPi that request has no recipient: systemd runs as PID 1 and the bus is up,
but systemd never registers `org.freedesktop.systemd1` on it — the image boots
with D-Bus activation trimmed away. Installing `dbus` and re-executing PID 1 do
not help; `busctl --system list | grep systemd1` stays empty either way.

The fix is to stop asking systemd. Merge this into `/etc/docker/daemon.json`
(create the file if absent) so Docker writes the cgroups itself:

```json
{ "exec-opts": ["native.cgroupdriver=cgroupfs"] }
```

```bash
systemctl restart docker
docker info | grep -i cgroup     # Cgroup Driver: cgroupfs
```

Docker and systemd then own separate subtrees of the cgroup v2 hierarchy, which
is harmless on a single-purpose audio host. On a normal Debian install where
`busctl --system list` *does* show `systemd1`, this error means the bus itself is
down — start `dbus.socket` and restart Docker rather than switching drivers.

**The entrypoint exits with `Permission denied` under `/data`:** `./data` is not
owned by the uid the container runs as. The daemon runs unprivileged and creates
its profile directories itself, so ownership must match `QBZD_UID`/`QBZD_GID`
from `.env` — which default to `1000:1000`, not to root. Working as `root`,
`chown "$(id -u):$(id -g)" data` yields `0:0`, so either set both variables to
`0` or chown `./data` to the uid you configured:

```bash
chown "${QBZD_UID:-1000}:${QBZD_GID:-1000}" data
```

**`qbzd status` says `not present` but playback works:** Docker masks
`/proc/asound` by default — it is in the standard masked-paths set with
`/proc/kcore` and `/proc/acpi` — and the daemon's presence check reads
`/proc/asound/cards`. ALSA output itself goes through `/dev/snd`, which is
passed through, so this is a false negative and not a fault. Confirm with
`docker inspect qbzd --format '{{.HostConfig.MaskedPaths}}' | grep asound`, and
check the log for `[ALSA Direct Engine]` lines to see the real state.

Leave it masked unless hires playback degrades. `curl -s
localhost:8182/api/status | jq .audio` during a 24/192 track reports the
negotiated PCM parameters, which come from the open device rather than from
`/proc`; if they read `44100`/`16` on a hires track, unmask by adding
`- systempaths=unconfined` to `security_opt` in `docker-compose.yml`. That
unmasks every masked path and drops the read-only guard on `/proc/sys`, so it
trades container hardening for the fix — with `cap_drop: ALL` in place, mostly
read access to host kernel state. Bind-mounting only `/proc/asound` does not
work: runc applies masked paths after mounts, so the mask wins.

**No sound at all, or the daemon cannot open the device:** the container is
missing the ALSA group. Note that `aplay -L` is no test for this — it only
parses ALSA's configuration and prints the card whether or not the process may
use it. Compare the gid of the device nodes with the groups the daemon holds:

```bash
stat -c %g /dev/snd/controlC0        # host side
docker compose exec qbzd id          # groups= must contain that gid
```

Set `AUDIO_GID` in `.env` to the first value and `docker compose up -d`. A
recreate is required; `docker compose restart` will not change `group_add`.
Running the container as `root` does not help either — `cap_drop: ALL` removes
`CAP_DAC_OVERRIDE`, so uid 0 gets no exemption from the `crw-rw---- root audio`
mode on the nodes. For a real open test, write a second of silence:

```bash
docker compose exec qbzd aplay -D hw:CARD=<name>,DEV=0 -f S32_LE -r 44100 -c 2 -d 1 /dev/zero
```

## Notes and limitations

- **MPRIS is disabled.** There is no D-Bus session bus in the container, so
  desktop media-key integration cannot work. `QBZD_MPRIS=0` and
  `[mpris] enabled = false` make that explicit.
- **A fixed `/etc/machine-id` is baked into the image.** Credential encryption
  derives its key from a machine identifier, and Docker regenerates the
  container hostname on recreate; without a stable id the stored session would
  be lost on every `--force-recreate`. Per-install uniqueness still comes from
  the random salt kept in `data/config/qbzd/`.
- **Exclusive/bit-perfect output** works as on the host — the container shares
  the host's ALSA devices — but nothing else on the host may hold the DAC.

## Upgrading to a new release

The release tarballs are checksum-pinned, so an upgrade means bumping the
version *and* the two hashes — a stale hash fails the build instead of
installing something unexpected.

Find the current release:

```bash
curl -s https://api.github.com/repos/vicrodh/qbz/releases/latest | grep '"tag_name"'
```

Compute the checksums for it:

```bash
V=2.0.3
for a in amd64 aarch64; do
  curl -sL "https://github.com/vicrodh/qbz/releases/download/v$V/qbzd-$V-linux-$a.tar.gz" \
    | shasum -a 256 | awk -v a="$a" '{print a, $1}'
done
```

Apply them:

- `Dockerfile` — `ARG QBZD_VERSION`, and `QBZD_SHA256_AMD64` / `QBZD_SHA256_ARM64`
  (the `amd64` hash and the `aarch64` hash respectively).
- `.env` — `QBZD_VERSION`, which drives both the build arg and the image tag.

Then rebuild and check the daemon came back healthy:

```bash
docker compose up -d --build
docker compose exec qbzd qbzd --version
docker compose exec qbzd qbzd status
```

`./data` is untouched by the swap, so the login, settings and queue survive.
There is no manual migration step — `config_version` in `qbzd.toml` is the
daemon's own upgrade hook. Back up `data/config/qbzd/` before a major bump
anyway; it holds the credentials.

To roll back, restore the previous version and hashes and rebuild. The old
image is still tagged `qbzd:<old-version>` locally unless you pruned it, so
`docker compose up -d` with the previous `.env` is usually enough on its own.
