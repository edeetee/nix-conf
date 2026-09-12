# AirPlay on homeserver-edt

`homeserver-edt` shows up in the iPhone's AirPlay output picker and the audio
comes out of the default PipeWire sink (HDMI → Sony TV). Implemented in
`modules/nixos/airplay.nix`, enabled from `desktop.nix` as
`services.airplay.enable = true`.

## Stack

```
iPhone ──AirPlay 2 (RTSP + ALAC/AAC)──▶┌──────────────────────────────┐
        ──mDNS/Bonjour discovery──────▶│ shairport-sync               │
                                       │ (systemd --user, uid 1000)   │
                                       └───────────────┬──────────────┘
                                                       │ libpulse
                                       ┌───────────────▼──────────────┐
                                       │ pipewire-pulse → PipeWire    │
                                       └───────────────┬──────────────┘
                                                       │ ALSA
                                                       ▼ HDMI → TV

        nqptp (root, UDP 319/320) ──/dev/shm/nqptp──▶ PTP timing for AirPlay 2
```

- **shairport-sync** — `pkgs.shairport-sync-airplay2` (5.0.4 at the pinned
  nixpkgs rev). The AirPlay 2 build advertises both `_airplay._tcp` and
  `_raop._tcp` and can fall back to classic AirPlay, so it covers current iOS and
  older senders.
- **nqptp** — "Not Quite PTP", required by AirPlay 2 for timing.
- **Avahi** — already enabled in `networking.nix` (`publish.userServices = true`),
  which is what makes the receiver discoverable.

## Why shairport-sync is a *user* service

That is not a style choice, it is a hard requirement here. PipeWire runs per-user
on this host (`services.pipewire.systemWide = false`), so the socket lives at
`/run/user/1000/pulse/native` and only exists while `edeetee` is logged in. A
system service cannot reach it. Upstream says the same:

> The main thing to remember about PipeWire and PulseAudio sound servers is that
> the services they offer only become available when a user logs in. … Shairport
> Sync relies on them, so it must also be set up as a user service; it can not be
> set up as a system service.
> — `ADVANCED TOPICS/PulseAudioAndPipeWire.md`

The NixOS `services.shairport-sync` module only generates a *system* unit, so
`airplay.nix` disables that unit's `wantedBy` and defines
`systemd.user.services.shairport-sync` instead. It is still worth keeping the
module enabled — it generates and validates `/etc/shairport-sync.conf`, installs
the package, and declares the Avahi publishing options.

`services.displayManager.autoLogin` keeps the user session (and therefore the
AirPlay receiver) alive from boot.

## Why nqptp has a hand-rolled unit

nixpkgs 25.11 ships the `nqptp` binary (and its upstream unit file) but no NixOS
module, and AirPlay 2 does not work without it. The unit in `airplay.nix` mirrors
upstream's `nqptp.service.in`: `DynamicUser`, `CAP_NET_BIND_SERVICE` (ports 319
and 320 are privileged) and `LimitRTPRIO = 6`.

It needs no group/permission plumbing: nqptp creates `/dev/shm/nqptp` with mode
`0644` (`shm_open(..., O_RDWR | O_CREAT, 0644)` in `nqptp.c`) and shairport-sync
opens it **read-only** (`shm_open(..., O_RDONLY, 0)` in `ptp-utilities.c`), so an
unprivileged user service can read the timing data.

## Verification

```bash
# Service states (note: user unit, so --user, and it needs the session to exist)
systemctl --user status shairport-sync
systemctl status nqptp
ss -ulnp | grep -E ':319|:320'          # nqptp owns these

# Is the receiver advertised? (run on the server or any LAN machine)
avahi-browse -rt _airplay._tcp | grep -A6 homeserver-edt
avahi-browse -rt _raop._tcp    | grep -A6 homeserver-edt

# Logs
journalctl --user -u shairport-sync -f   # connection/playback events
journalctl -u nqptp -n 20

# What the audio is doing while streaming
pw-top      # "Shairport Sync" node should appear with zero ERR
pactl list short sink-inputs
```

Then, on the iPhone: Control Centre → the AirPlay/audio-output button →
`homeserver-edt`. The stream should start within a second or two.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Not listed on the iPhone | `systemctl --user status shairport-sync` — usually the user session/PipeWire isn't up yet, or Avahi isn't publishing. Restart the unit. |
| Listed, connects, then reverts to the iPhone | shairport-sync died — check `journalctl --user -u shairport-sync`. If it is `pulseaudio: failed to connect`, the user's PipeWire session restarted; `systemctl --user restart shairport-sync`. |
| Listed but never plays | For AirPlay 2 the sender streams from an ephemeral UDP port, so a firewall between phone and server breaks it. `networking.firewall.enable` is `false` here — keep it that way, or open the whole ephemeral range and UDP 319/320. |
| Audio plays but out of sync | Adjust `general.audio_backend_latency_offset_in_seconds` (HDMI/TV processing delay). |
| Nothing audible but `pw-top` shows the node | The default sink isn't the TV (e.g. a Bluetooth headset is connected). `wpctl status` / `wpctl set-default <id>`. |

After changing `services.airplay.*`, a rebuild is enough. If only the user unit
changed, `systemctl --user daemon-reload && systemctl --user restart
shairport-sync` (NixOS activation does not reload units of already-running user
sessions).

## Known limitations

- **Version lag.** nixpkgs (pinned) builds shairport-sync 5.0.4; upstream is
  5.5.1, which contains security fixes for malformed SETUP/pairing requests from
  a hostile client on the LAN, plus iOS 26 bug fixes. Worth revisiting when the
  nixpkgs pin is bumped.
- **iOS 26 + Apple Music lossless seek** ([upstream #2193](https://github.com/mikebrady/shairport-sync/issues/2193)):
  seeking within a track could silence the stream until shairport-sync is
  restarted. Reported against 5.0.2 on the AirPlay 2 buffered-audio path; no fix
  was merged. If it bites, the workaround is `systemctl --user restart
  shairport-sync` and re-select the output. Falling back to classic AirPlay only
  (i.e. `package = pkgs.shairport-sync`) avoids that code path — one line in
  `airplay.nix`.
- **One AirPlay 2 instance per IP address.** AirPlay 2 clients get confused by
  several players behind the same IP, so don't add a second receiver config here.
- **48 kHz sink, 44.1 kHz streams.** The HDMI sink runs at 48 kHz; shairport-sync
  transcodes (ffmpeg) losslessly for the rate change. AirPlay's own volume slider
  only affects its own stream, not the system volume.
