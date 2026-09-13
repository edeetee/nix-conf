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

**nqptp must already be running when shairport-sync starts.** The AirPlay 2 build
spends its first moments waiting for that shared memory (`shairport.c`: retry
every 50 ms for up to 10 s) and then exits with:

```
Shairport Sync can not find the nqptp service on this system.  Is nqptp installed and running?
```

Until it gets the SHM it never opens its RTSP port or advertises on Bonjour —
this is what "no AirPlay device visible" looks like in practice (verified by
running the binary with nqptp absent). In normal operation nqptp is up minutes
before the graphical session starts, and if nqptp ever restarts, the user unit's
`Restart=on-failure` brings shairport-sync back within ~12 s.

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

When debugging, the binary can be run by hand as the login user — no root needed
(the AirPlay ports are all > 1024):

```bash
BIN=$(nix eval --raw .#nixosConfigurations.homeserver-edt.config.services.shairport-sync.package)/bin/shairport-sync
printf 'general={name="test";output_backend="pulseaudio";};diagnostics={log_verbosity=3;};\n' > /tmp/ap.conf
$BIN -c /tmp/ap.conf      # log_verbosity=3 shows the nqptp/avahi handshake
```

The mDNS backend is Avahi by default (`shairport-sync -h` lists `avahi` first;
the deprecated bundled `tinysvcmdns` responder is only used if Avahi is
unavailable), which keeps the advertisement on the same Avahi daemon as
everything else on the LAN.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Not listed on the iPhone | `systemctl --user status shairport-sync` — usually the user session/PipeWire isn't up yet, or Avahi isn't publishing. Restart the unit. |
| Unit restarting every ~12 s, log says "can not find the nqptp service" | nqptp isn't running: `systemctl status nqptp`, `ss -ulnp \| grep -E ':319\|:320'`. AirPlay 2 refuses to advertise without its PTP timing source. |
| Listed, connects, then reverts to the iPhone | shairport-sync died — check `journalctl --user -u shairport-sync`. If it is `pulseaudio: failed to connect`, the user's PipeWire session restarted; `systemctl --user restart shairport-sync`. |
| Listed but never plays | For AirPlay 2 the sender streams from an ephemeral UDP port, so a firewall between phone and server breaks it. `networking.firewall.enable` is `false` here — keep it that way, or open the whole ephemeral range and UDP 319/320. |
| Audio plays but out of sync | Adjust `general.audio_backend_latency_offset_in_seconds` (HDMI/TV processing delay). |
| Nothing audible but `pw-top` shows the node | The default sink isn't the TV (e.g. a Bluetooth headset is connected). `wpctl status` / `wpctl set-default <id>`. |

After changing `services.airplay.*`, a rebuild is enough. If only the user unit
changed, `systemctl --user daemon-reload && systemctl --user restart
shairport-sync` (NixOS activation does not reload units of already-running user
sessions).

## Video: screen mirroring and video streaming (UxPlay)

`services.airplay.mirror` runs [UxPlay](https://github.com/FDH2/UxPlay) as a user
service. shairport-sync is audio-only by design, UxPlay speaks the AirPlay
*mirror* protocol, so this is what gives you iPhone/iPad/Mac screen mirroring on
the TV, plus:

| Works | Does not work |
|---|---|
| Screen mirroring from iOS/iPadOS/macOS (H.264 + AAC) | **DRM-protected video** — the Apple TV app, Netflix and friends can only be decrypted by genuine Apple hardware; UxPlay will stream their audio only |
| Audio-only AirPlay (ALAC) as a second target | AirPlay 2 multi-room audio (use shairport-sync for that) |
| YouTube video via `-hls` (the YouTube app's AirPlay icon) | AirPlay video from browsers or other apps (not implemented upstream yet) |

Both receivers are advertised at once, so the iPhone's picker shows two entries,
deliberately named apart:

| Picker entry | Server | Ports | Protocol |
|---|---|---|---|
| `homeserver-edt` | shairport-sync | TCP 7000, UDP 6001-6011 | AirPlay 2 audio (lossless, multi-room) |
| `homeserver-edt Video` | UxPlay | TCP+UDP 7100-7102 | AirPlay mirror (video + audio) |

They do not collide because UxPlay is moved off shairport-sync's port (`-p 7100`
becomes 7100/7101/7102 for both TCP and UDP). AirPlay 1 clients cope with several
receivers behind one IP; AirPlay 2 *audio* clients do not, which is why only one
shairport-sync instance runs.

### The pipeline, and why it is pinned

UxPlay renders through GStreamer, and its own README suggests `pipewiresink` on
PipeWire systems. **That would fail here**: the nixpkgs build of
gst-plugins-bad has no PipeWire plugin (checked its closure — no
`libgstpipewire.so`), so audio is sent to `pulsesink`, which lands in
pipewire-pulse exactly like shairport-sync's audio.

Video goes to `waylandsink` rather than the OpenGL or Xv sink. This session is
Wayland, and the Xwayland route is what rendered "a corner of the screen in a
small tile in the middle of the TV" here. (`waylandsink` from UxPlay's own
closure was checked by pushing a test pattern through it — the pipeline ran
clean, which rules out a missing/broken sink but is not a visual check.)
The sink survey in upstream
[issue 480](https://github.com/FDH2/UxPlay/issues/480) is worth reading when
picking another one — but note its list does not all exist in this build:
present here are `waylandsink` (default), `glimagesink`, `xvimagesink`,
`ximagesink`, `gtkwaylandsink`; **there is no `gtksink`**. The stream is
requested at 1920x1080@60 (`-s`, `-fps 60`; UxPlay defaults to 30):

```bash
airplay-mirror --help                    # the wrapper, same options as uxplay
systemctl --user status uxplay
journalctl --user -u uxplay -f
```

### If mirroring looks wrong

Iterate without a rebuild — stop the service so the wrapper can bind the ports,
then pass overrides on the command line (later options win over the wrapper's):

```bash
systemctl --user stop uxplay
airplay-mirror -d                       # same settings the service uses, with debug
airplay-mirror -vs glimagesink          # next sink to try
airplay-mirror -vs xvimagesink          # Xwayland/X11 route
airplay-mirror -s 1280x720@60           # if a session negotiated a silly size
airplay-mirror -vd vah264dec            # hardware decode (AMD VA-API, GStreamer 1.26)
airplay-mirror -FPSdata                 # show the client's framerate reports
```

| Symptom | What it usually is |
|---|---|
| Small picture in the middle, or only a corner of the client's screen | Negotiated video size or the sink's window sizing — try the sinks above, or pin `-s 1920x1080@60`. Putting the player fullscreen on the sender also forces a size change. |
| Picture freezes but the client stays connected | Two very different causes: a **static client screen sends no new frames**, so a frozen image is correct (move a window on the sender to check); or the GStreamer 1.26/1.28 `avdec` freeze that upstream tracks in issues 519/564, where `-vs xvimagesink sync=false`, hardware decode, or `-vsync no -async no` sometimes get a session running |
| Connects, then client drops with *"missed client feedback signals"* | Timing/NTP side of the mirror protocol (issue 564); a firewall between client and server on UDP 123 is one cause, and there is no firewall here |
| Black window, no output | Sink/decoder negotiation — try `-avdec -vs waylandsink`, then `-vd vah264dec -vc vapostproc` |

`GST_DEBUG=2 airplay-mirror -d` shows what GStreamer is doing.

## Now-playing display (and keeping the box awake while music plays)
The mirroring server needs no setup of its own beyond the desktop session: it
renders through Xwayland (`DISPLAY`/`XAUTHORITY` are in the user manager's
environment) and `-scrsv 1` keeps the screensaver off while video is playing.
While a client is actually mirroring, the now-playing window steps aside (it
detects an established connection to UxPlay's ports — see `mirror_active()` in
`airplay-nowplaying.py`) so the album art cannot cover the mirrored screen.

### What can actually send video to it

There are two different AirPlay video paths, and only one of them is available here:

| Sender | Result |
|---|---|
| **macOS/iOS/iPadOS screen mirroring** (Control Centre → Screen Mirroring → `homeserver-edt Video`) | **Works.** The whole screen is mirrored as H.264 + AAC, so *any* player works: fullscreen YouTube in Firefox, VLC, IINA, a video call, anything. No per-app support needed. |
| **YouTube iOS app**'s AirPlay icon | Works, because UxPlay implements HLS video (`-hls`) and YouTube is the one service it supports |
| Firefox (macOS) AirPlay button | **Does not exist.** Mozilla has never implemented AirPlay (bug 1171706, open since 2015); this is not a UxPlay limitation |
| VLC (macOS) AirPlay video output | **Does not exist.** VLC's AirPlay `stream_out` module is RAOP, i.e. audio only; for video its own forum answer is "use mirroring" |
| Safari's AirPlay button | Exists, but Apple's HTML5-video path is not what third-party receivers implement; expect mirroring (which works) rather than an app-level stream |
| Apple TV app, Netflix, Disney+, … (DRM) | **Impossible on any non-Apple receiver** — FairPlay decryption needs Apple hardware; you may get audio only |

So the practical recipe for Firefox or VLC on the Mac: start screen
mirroring to `homeserver-edt Video` and put the player fullscreen. Mirroring
requests 1920x1080@60 by default and is capped at 30 fps (`-fps`); it may show
the Mac's notifications and menu bar unless the player is fullscreen, and it
carries AAC audio rather than lossless — for music, use the audio receiver
(`homeserver-edt`) instead.

Audio-only from a desktop app is a separate, easier case: macOS lists AirPlay
receivers as system audio output devices, so both `homeserver-edt`
(shairport-sync, AirPlay 2, lossless — the better choice) and
`homeserver-edt Video` (UxPlay's audio-only mode) appear as selectable outputs.

## Now-playing display (and keeping the box awake while music plays)

`modules/nixos/airplay-nowplaying.py` runs as a user service in the Plasma
session (`services.airplay.nowPlaying`, enabled by default). While a stream is
connected it shows the cover art, track, artist, album and a progress bar
fullscreen, and it holds idle inhibitors; when the stream ends the window
disappears. It reads everything from the session bus — shairport-sync's MPRIS
interface (`PlaybackStatus`, `Metadata`, including `mpris:artUrl` pointing at the
cached cover JPEG), so nothing extra needed enabling.

Inhibitors while a stream is live:

| Inhibitor | Effect | Status |
|---|---|---|
| `org.freedesktop.ScreenSaver.Inhibit` | KWin/PowerDevil do not blank or lock the screen, nor run idle actions — the same call a video player makes | works |
| `systemd-inhibit --what=idle:sleep:shutdown` (logind) | block logind idle/sleep/shutdown | attempted; logind only authorises the sleep/shutdown part for a session that is *active on a seat*, and a systemd user service belongs to the user manager session, so it is normally refused and the app logs a warning and carries on |

Run it by hand (it is in `environment.systemPackages`) when debugging:

```bash
airplay-nowplaying --windowed -v      # a window, not fullscreen; verbose
airplay-nowplaying --no-inhibit -v    # skip the inhibitor calls
systemctl --user restart airplay-nowplaying
journalctl --user -u airplay-nowplaying -f
```

The service starts with `graphical-session.target` (Plasma 6 implements it), so
it inherits the session environment — `WAYLAND_DISPLAY`, `DISPLAY=:0`,
`XAUTHORITY` — from the user manager. Qt from nixpkgs' `qt6Packages` has no
Wayland platform plugin, so the window is a plain X11 client on Xwayland
(`QT_QPA_PLATFORM=xcb`). Cover art is the JPEG shairport-sync caches under
`/tmp/shairport-sync/.cache/coverart/`.

**After the first `nixos-rebuild switch` that adds this unit, start it by hand
(or log out/in, or reboot)** — NixOS activation enables new user units but does
not start them for sessions that are already running, and
`graphical-session.target` is already reached by then:

```bash
systemctl --user start airplay-nowplaying      # confirm with: systemctl --user status airplay-nowplaying
```

An inactive unit with no journal entries at all means exactly that: it was never
started (a crash would leave output).

### Premade alternatives (checked, not used)

* [shairport-display-qt](https://github.com/lrusak/shairport-display-qt) (also
  forked by mikebrady): single Python file, PyQt5 + D-Bus. Last touched 2023,
  aimed at the RPi 7" DSI panel (800x480, backlight control), and it queries the
  `org.gnome.ShairportSync.RemoteControl` interface name that 5.x no longer
  uses — so it needs patching before it will even read our metadata.
* [shairport-metadata-display](https://github.com/AlainGourves/shairport-metadata-display)
  and [ShairportGUI](https://github.com/Rosalina121/ShairportGUI): web UIs that
  parse shairport-sync's metadata pipe (Node/Python) and need a browser in kiosk
  mode — no browser is installed on this host.
* Kodi: its AirPlay receiver is broken on modern iOS (mDNS identifiers), see
  xbmc#27924.

## Machine turning off while music plays

Investigated because "it turns off while I'm playing music, but not when I watch
videos". What the logs actually show on this host (September 2026):

* **No suspend ever happens.** `journalctl | grep -i "PM: suspend\|Suspending system"`
  is empty for every boot, and `AllowSuspend=no` (`desktop.nix`) makes logind
  report `CanSuspend=no`.
* **Plasma cannot power the box off either.** PowerDevil's compiled-in AC
defaults are: dim at 5 min, screen off at 10 min, auto-suspend at 15 min — but
  the auto-suspend *action* is `NoAction` whenever the system reports it cannot
  suspend, which is the case here. And `isActionSupported("TurnOffDisplay")`
  returns `false` for this display stack, so PowerDevil never blanks either:

  ```bash
  busctl --user call org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement \
    org.kde.Solid.PowerManagement isActionSupported s TurnOffDisplay   # -> false
  busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanSuspend                          # -> "no"
  ```
* Every power-off/shutdown in the journal is *orderly* (`systemd-logind: System
  is powering down.` / `Reached target System Power Off`) except one: boot -2
  ended abruptly at 23:00:00 mid-log with **no shutdown sequence at all**, which
  is what a mains-level power cut looks like, not a software shutdown.
* The remaining orderly power-offs coincide with the box being used as a media
  player in the evening (18:28, 19:32, 20:01, 20:08, 21:15). Nothing in the
  logs names a software initiator; `IdleAction=ignore` and `AllowSuspend=no` are
  both in effect.

So the now-playing service fixes the part that *is* software (it makes music
behave like video: nothing goes idle, nothing blanks, nothing locks), but if the
box still dies mid-album with a clean journal ending, suspect the power
arrangement — e.g. the TV and PC sharing a switched socket or a master/slave
power board, since the PC goes down when the TV does. Diagnose the next
occurrence with:

```bash
journalctl --list-boots | tail -3
journalctl -b -1 -n 8            # orderly shutdown, or mid-log cut?
journalctl -b -1 | grep -iE "logind.*(powering|rebooting)|logrotate|Shutting down"
```

An orderly ending means something asked logind to stop (`logout prompt`,
power button, menu); a mid-log ending means the power went away.

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
