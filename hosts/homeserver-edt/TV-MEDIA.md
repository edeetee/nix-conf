# Watching things on the TV

Four separate things, often confused with each other, all about getting video
onto the Sony TV that this box drives:

| Want | Mechanism | Needs the phone? |
| --- | --- | --- |
| A TV-shaped UI on the box (couch launcher, library, player) | **Kodi** (`modules/nixos/kodi.nix`), fullscreen inside Plasma, autostarted with the session | No |
| Drive Kodi from the phone | **Official Kodi Remote** (iOS, free) or Kore (Android) over `:8080`, or Unified Remote arrows → Kodi's own keyboard navigation | Yes |
| Launch games from the TV UI | Kodi's **Steam Launcher** addon, or a controller press → `steam-on-demand` | No |
| Play/pause/volume for mpv (or anything else on MPRIS) from the phone | Unified Remote's free Media remote + mpv-mpris | Yes |
| Send Kodi back to the TV, or drop to the desktop, from the phone | KDE Connect run commands (`TV UI`, `Desktop`) | Yes |
| Play a file that lives on the Mac | `/mnt/mac` (cifs automount) or `vlc smb://…` | No |

AirPlay (audio + screen mirroring) is a fifth, unrelated path — that one is in
`AIRPLAY.md`.

## 1. Kodi is the TV app

The box is a TV: SDDM autologins to Plasma, Plasma is invisible behind **Kodi**,
and quitting Kodi is how you get to the desktop. `modules/nixos/kodi.nix` owns
that; the design and the history it replaced are in `plans/kodi-tv.md`. Before
this the TV was a Plezy + plasma-bigscreen + Jellyfin stack — all three are gone
and this document no longer describes them.

Why Kodi rather than what was there: it is in the pinned nixpkgs (21.3, GPL, no
overlay, no second nixpkgs input, no 2 GiB Flutter SDK), it plays the files
directly instead of streaming them from a server on the same box, and it has an
official free remote.

```bash
# status / control (over ssh)
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status kodi-tv'
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start kodi-tv'  # back to the TV
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop kodi-tv'   # leave the desktop
```

Decisions worth remembering:

- **`Restart=on-failure`, not `always`.** A crash comes back; quitting stays
  quit. That is the entire "way back to the desktop" mechanism now — there is no
  session switcher, no state file and no SDDM relogin any more.
- **Content is `/mnt/hdd/downloads`** (the transmission folder), scraped by Kodi
  itself. `scripts/jellyfin-movie-import.sh` hardlinks films into
  `/mnt/hdd/media/library/movies` as `<Title> (<Year>)`, which any scraper matches
  more reliably than `www.UIndex.org - …1080p…`. Pointing Kodi at both is
  reasonable; the tree is scraper-neutral even though the script was written for
  Jellyfin.
- **Kodi's settings are GUI state**, in `~/.kodi/userdata/`. Display mode, audio
  device, passthrough toggles and the library source are not in the nix config
  and are not reproducible; `plans/kodi-tv.md` D3 records what to do about it.
- **Audio passthrough** is set once in Settings ▸ System ▸ Audio: the HDMI/PipeWire
  sink, allow passthrough, AC3/EAC3/DTS/TrueHD. `AUDIO.md` covers the stack;
  verify with a DD5.1 title and `pactl list sinks | grep -i iec958`.
- **Note the deploy rule** (AGENTS.md): a *new* user unit is not started for an
  already-running user manager, so after the first `nixup` that adds `kodi-tv` it
  must be started by hand once, or the box rebooted.

## 1a. The library: what is scanned, and why it is shaped that way

Sources (Kodi ▸ Videos ▸ Files, `~/.kodi/userdata/sources.xml`), with the
content type set on the first two — that assignment lives in
`~/.kodi/userdata/Database/MyVideos131.db`, table `path`, not in `sources.xml`:

| Source | Content | Scraper |
| --- | --- | --- |
| `/mnt/hdd/media/library/movies/` | Movies | `metadata.themoviedb.org.python` |
| `/mnt/hdd/media/library/shows/` | TV shows | `metadata.tvshows.themoviedb.org.python` |
| `/mnt/hdd/downloads/` | *none* — browsable, not scraped | — |

The two library trees hold **symlinks** into `/mnt/hdd/downloads`, so nothing is
copied and Transmission keeps seeding. Hardlinks are impossible: the files are
owned by `transmission`, and `fs.protected_hardlinks` refuses them (`EPERM`).
`scripts/jellyfin-movie-import.sh` builds the movie tree; the shows tree was
linked by hand.

**The layout is load-bearing**, measured the hard way:

- Movies need `Movies/<Title> (<Year>)/<Title> (<Year>).<ext>`. Without the year
  the scraper picks the wrong film — `Wallace and Gromit The Curse of the Were
  Rabbit` matched a *making-of* documentary until it was renamed.
- Shows need `Shows/<Show> (<Year>)/Season NN/SxxExx…`. A flat
  `Shows/Silo/*.mkv` does **not** scrape the folder name: Kodi matched the source
  directory itself, so every episode landed under "Your Show of Shows" (a 1950s
  series). With the canonical structure, `Silo` → TMDb id 125988.
- The library directories must be owned by `edeetee` — they were `root:169` with
  a gid that no longer exists, and every import failed with `EACCES`. The rule is
  in `hosts/homeserver-edt/services.nix` (`systemd.tmpfiles.rules`).

**Scanning is serial and slow.** A *new* `VideoLibrary.Scan` aborts the one in
flight, so queuing several means only the last is honoured. Each film costs
~12 s of TMDb lookups; the full library takes 3–4 minutes. Drive it over
JSON-RPC on port 8081 and poll, rather than firing and forgetting:

```bash
c(){ curl -s -H 'Content-Type: application/json' -X POST \
  -d "$1" http://homeserver-edt.local:8081/jsonrpc; }
c '{"jsonrpc":"2.0","id":1,"method":"VideoLibrary.Scan","params":{"directory":"/mnt/hdd/media/library/movies/"}}'
c '{"jsonrpc":"2.0","id":2,"method":"VideoLibrary.GetMovies"}'      # "total":9
c '{"jsonrpc":"2.0","id":3,"method":"VideoLibrary.GetEpisodes"}'    # "total":29
```

Two things are GUI state and will not come back from a rebuild: this scan
database, and `~/.kodi/addons/`, which holds **newer** versions of both scrapers
(3.2.2 / 1.7.13) that override the bundled ones (1.3.1 / 1.6.0) — Kodi updates
them itself.

Known gap: **Peppa Pig** is not in the library — its collection folder nests
seasons in a way the season-directory pattern above does not match. It still
plays from the Downloads source.

## 1b. Driving Kodi from the phone

| Input | Works? | Notes |
| --- | --- | --- |
| **Official Kodi Remote** (iOS) | yes, the rich one | Free, Kodi Foundation, App Store. Speaks Kodi's JSON-RPC: library browsing, artwork, now-playing, seek. Needs Settings ▸ Services ▸ Control ▸ "Allow remote control via HTTP" (port 8080) |
| Kore (Android) | yes | The same API on Android |
| Chorus2 (any phone browser) | yes | Ships with Kodi: `http://homeserver-edt.local:8080` — no app, no pairing |
| **Unified Remote arrows/enter** | yes | The §4 uinput chain. Kodi navigates by keyboard natively, so no API is involved: `urserver` injects events and KWin delivers them to the focused window |
| Gamepad (DualShock) | supported, none connected as of 2026-10-21 | Kodi drives SDL controllers itself; `/dev/input/js0` here is the ASRock RGB controller, not a pad |
| TV remote over HDMI-CEC | **no hardware** | Kodi links `libcec`, but there is no `/dev/cec*` — RDNA2 has no CEC and no Pulse-Eight dongle is attached. That dongle is the only path to the Sony remote driving this UI |

Port 8080 is plain HTTP and unauthenticated unless a user is set in guisettings,
so it is a LAN port: do not forward it.

Launching games from the TV UI: Kodi's **Steam Launcher** addon (baked into
`modules/nixos/kodi.nix`) starts Steam in Big Picture, and a controller press
still starts `steam-on-demand` independently (`steam.nix`). Both depend on the
Plasma session underneath — which is exactly why Kodi is not a standalone
session.

## 2. Phone side: KDE Connect run commands

The daemon already autostarts as a user unit
(`app-org.kde.kdeconnect.daemon@autostart.service`, from the xdg autostart
entry), and the iPhone is paired — so this is only about the commands.

Two commands are registered for the paired phone:

| Name | Command |
| --- | --- |
| `TV UI` | `systemctl --user start kodi-tv` |
| `Desktop` | `systemctl --user stop kodi-tv` |

`start` is idempotent — tapping it while Kodi runs is a no-op, whereas launching
the binary again would open a second window. That is why these go through
systemd rather than executing `kodi`. Neither needs root, and `stop` leaves Kodi
quit until the next login, which is what makes the desktop usable.

**These are per-device application state, not NixOS config.** The plugin stores
them per paired device, as a KConfig file with a JSON blob:

```
~/.config/kdeconnect/<device-id>/kdeconnect_runcommand/config
  [General]
  commands="@ByteArray({\"<uuid>\":{\"command\":\"…\",\"name\":\"…\"}})"
```

Consequences: the file is owned by the app (it rewrites the value whenever the
phone edits the list), the path contains the phone's pairing id, and **re-pairing
the phone loses the commands**. So they are *not* declared in this repo —
re-add them from the phone: KDE Connect app → `homeserver-edt` → Run command →
Add command. (The tracked copy of this fact is this document.)

## 3. Playing files that live on the Mac

### No mount: hand VLC the SMB URL

VLC on this box is built with `samba`/`libsmbclient` (and `libssh2`), so it opens
`smb://` directly — no mountpoint:

```bash
# on the Mac
URL='smb://edeetee@Edwards-MacBook-Max.local/Media/film.mkv'
ssh homeserver-edt.local "export XDG_RUNTIME_DIR=/run/user/1000
systemctl --user stop vlc-mac 2>/dev/null
systemd-run --user --unit=vlc-mac --collect vlc --fullscreen '$URL'"
```

`systemd-run --user` is not decoration: an ssh session has no display, no audio
socket and no session bus. Starting the process from the *user manager* gives it
the graphical session's environment (`DISPLAY`, `WAYLAND_DISPLAY`,
`DBUS_SESSION_BUS_ADDRESS`), so the window lands on the TV *and* KDE Connect gets
MPRIS control of it. Requires File Sharing on the Mac (its share name is the
path segment after the host). VLC will prompt for the share password on the TV
unless it is embedded as `smb://user:pass@host/…`.

### With a mount: `/mnt/mac` (mac-share.nix)

One cifs automount of the whole home share, **world-readable** (`0444/0755`, and
`ro`), so any local account can read it — Jellyfin included (now retired,
`plans/kodi-tv.md`). Two facts force
that shape: a `nounix` cifs mount has exactly one owner, and the nixpkgs Jellyfin
module sets `PrivateUsers=yes`, which makes the mount's owner render as `nobody`
to jellyfin, so only the `other` bits are ever consulted. The price is that
`~/.ssh` and the sops age key under `~/Library/Application Support/sops/age/`
are readable by every service account on this box; narrow it by mounting a
`subpath` with `fileMode = "0600"/dirMode = "0700"` if that ever matters more
than the convenience. **Now that Kodi runs as `edeetee`, that forcing condition
is gone** — pinning `0444/0755` existed only for Jellyfin's `PrivateUsers` — so
`0400/0700` works and is step 5 of `plans/kodi-tv.md`.

It is lazy: nothing is mounted at boot, and the first read of the path triggers
the connection. If the Mac is asleep the read fails
fast and the *next* read tries again, so `ls /mnt/mac` is a retry button.
Prerequisites: File Sharing on the Mac. `shareName = "edeetee"` is the share
macOS creates automatically for each user's **home directory**, so this one mount
covers every folder — `/mnt/mac/Downloads`, `/mnt/mac/Movies`, … — with no
per-folder setup on the Mac. (macOS also offers the whole volume as `Macintosh HD`
once all folders are shared; point `shareName` at it for the entire disk.)

The credentials come from sops (a mount.cifs credentials file), so this must
exist **before** deploying: sops-nix validates the declared secret names while
*building* `manifest.json`, so a missing one fails the build with
`the key 'mac-smb-credentials' cannot be found`. That is before anything is
switched, so it is harmless — just wasted evaluation.

```yaml
# hosts/homeserver-edt/secrets.yaml  (edit with `sops`, on a host that can decrypt)
mac-smb-credentials: |
  username=edeetee
  password=<the Mac's SMB password>
  domain=WORKGROUP
```

Shape of the change, and why each part is there:

- **Explicit `systemd.mounts` + `systemd.automounts`, not `fileSystems` +
  `x-systemd.automount`.** NixOS renders `fileSystems` entries into its own
  `.mount` units *and* into `/etc/fstab`, and nothing in
  `nixos/modules/tasks/filesystems.nix` understands the systemd-only `x-systemd.*`
  options (only `x-systemd.growfs`/`makefs` are special-cased). Declaring both
  units is unambiguous.
- **`boot.supportedFilesystems = [ "cifs" ]`** — this is what pulls in
  `cifs-utils` (`system.fsPackages`) and the module. With a `fileSystems` entry
  that wiring is automatic; with hand-written units it is not.
- **`uid=1000,gid=100,file_mode=0444,dir_mode=0755,ro`** — macOS' SMB server
  does not implement the CIFS Unix extensions, so ownership and modes come
  entirely from these options, applied to the whole tree: a 0600 file on the Mac
  is readable by whomever they allow here. `edeetee` stays the owner (`uid` is
  only expressible because `packages.nix` pins that uid; NixOS otherwise
  allocates it dynamically) while everyone else reads — see the header of
  `mac-share.nix` for why world-readable, not group-readable, is the only option
  that reaches jellyfin. `ro` because nothing here should write to the Mac.
- **`soft` + `echo_interval=10`** — a `hard` mount blocks the calling process
  until an absent Mac returns (a stuck Jellyfin scan thread); `soft` returns an
  error instead. `echo_interval` shortens dead-connection detection from 60 s.
- **`TimeoutIdleSec=300`** — the load-bearing option. It turns "stale mount
  pointing at a Mac that has been asleep for an hour" into "fresh connection on
  next access" rather than trusting the kernel's reconnect heuristics.
- **`nofail` semantics come for free**: the mount unit is not wanted by anything,
  only the automount unit is, so boot never waits for — or fails because of — the
  Mac.
- **`mac-share-heal.timer`** — see below; this is the part that makes the retry
  promise hold.

### The failure mode the timer exists for

systemd automount has no `Restart=` (systemd issue #16811). If the `.mount` unit
fails repeatedly inside the default start-limit window (5 starts / 10 s —
reachable when something enumerates the path while the Mac sleeps), systemd
propagates *start limit hit* to the automount unit, which goes FAILED and tears
down the autofs point. After that `/mnt/mac` is a plain empty directory and
**nothing will ever mount it again**: accesses cannot retry, because the thing
that retried is gone.

`mac-share-heal.timer` (every 2 min) checks every Mac automount
(`mnt-mac.automount`) and, for any that is not active, resets the failed state
and re-arms it. Manual equivalent, if ever needed:

```bash
ssh homeserver-edt.local 'sudo systemctl restart mnt-mac.automount'
```

### Pointing Kodi at the Mac (don't)

Kodi *can* take `/mnt/mac/<folder>` as a video source: the mount is readable by
`edeetee`, and it re-arms on first access. Don't. A library rooted on a share
that comes and goes makes Kodi mark items missing on every scan that lands while
the Mac is asleep, and mangles resume state — the same problem Jellyfin had, and
it was never a Kodi-specific one. Sync Mac media to `/mnt/hdd` (rsync/Syncthing)
if it should behave like a permanent library. And if the Mac sleeps
mid-playback, playback stalls: that is inherent to pulling from a Mac, mount or
not (`caffeinate -i` on the Mac avoids it).

## 4. mpv from the phone: Unified Remote + mpv-mpris

The KDE Connect route in §2 is one command per button, and the phone cannot use
Plasma's media widget at all: **the iOS KDE Connect app has no MPRIS plugin**, so
no number of MPRIS players on this host will put media controls in it. The way
around it is to send the right *keys* instead of MPRIS messages, which is the
whole of Unified Remote's free **Media** remote:

    iPhone → urserver (this host) → uinput virtual device → KWin
           → XF86AudioPlay → Plasma media controller → MPRIS → mpv-mpris → mpv

Both halves live in `unified-remote.nix`:

- `mpvScripts.mpris` is installed as `/etc/mpv/scripts/mpris.so` — mpv's
  *system* script directory (`mpv-unwrapped` is built with `--sysconfdir=/etc`)
  — so mpv appears on the session bus as an MPRIS player. No wrapper, and
  home-manager stays reserved for the Plasma settings (see `home.nix`).
- `urserver` runs as a user service in the graphical session. It needs **no**
  udev rule or input group: systemd's `uaccess` rule already grants the active
  session's user rw on `/dev/uinput` (`getfacl /dev/uinput` →
  `user:edeetee:rw-`), and the server picks its input backend from
  `XDG_SESSION_TYPE`, i.e. uinput on this Wayland session. Injection as kernel
  input events is also why the keys reach KWin's global shortcuts.

What it is not: it is transport only — play/pause, next, previous, stop, volume
up/down/mute — and it acts on whichever player Plasma has marked **active**, not
on mpv by name. With VLC playing, VLC takes the keys; star the one you want in
Plasma's media widget. Starting a *file* from the phone is not part of this route
(that is the paid custom remote, or the web UI in the `simple-mpv-webui`
alternative).

The Media remote is one of Unified Remote's free 18 — `/remotes/all` tags it
`browse-card-free` — so no purchase is involved, and nothing copies remotes into
a writable directory: the built-in ones are read-only out of the Nix store
(`$out/bin/remotes`) on purpose.

**Set a password before relying on it.** `urserver` has no authentication by
default and listens on every interface, while this host's firewall is off
(`networking.nix`). The manager is at http://localhost:9510/web; that setting is
the server's own app state under `~/.urserver` and `~/.config`, not Nix — and
note that uinput access means "can type into your session".

```bash
# is it up, and which input backend did it choose
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status urserver'
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u urserver -n 50'
# the virtual input device it should have created
ssh homeserver-edt.local 'grep -i -A3 unified /proc/bus/input/devices'
# the other half: mpv as an MPRIS player, while something is playing
ssh homeserver-edt.local 'playerctl -l; playerctl -p mpv metadata'
```

After the first `nixup` that adds this, start the unit by hand — AGENTS.md: a new
user unit is not started on an already-running user manager:

```bash
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start urserver'
```

Two things that are easy to misread when it looks broken:

- **`> stopping server... / exiting...` in the journal is not a crash.**
  `urserver` is an interactive REPL on stdin and reads a stdin EOF as the `exit`
  command; a unit started on systemd's default `/dev/null` stdin dies that way
  (after 60 s, or immediately). `unified-remote.nix` therefore starts it on a
  pipe held open by `sleep infinity`, and the unit is `Restart=always` rather
  than `on-failure` because that exit path has status 0.
- **The web manager is bound to `127.0.0.1:9510` only.** Port-forward to the
  IPv4 address, not the name: `ssh -L 9510:127.0.0.1:9510 homeserver-edt.local`,
  then open http://localhost:9510/web. The phone app does not need this — it
  finds the box on the LAN over UDP 9511 and connects to TCP 9512, which are on
  every interface.

## Verifying

```bash
# 1. the client is a running session
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status jellyfin-desktop'

# 2. the automount is armed (before any access it is "active", mount not yet up)
ssh homeserver-edt.local 'systemctl status mnt-mac.automount mnt-mac.mount'

# 3. first access connects, if the Mac is up and sharing
ssh homeserver-edt.local 'ls /mnt/mac; findmnt /mnt/mac'

# 4. the SMB path itself, without putting anything on the TV
ssh homeserver-edt.local "smbclient -U edeetee //Edwards-MacBook-Max.local/Media -c 'ls'"

# 5. the heal timer is firing
ssh homeserver-edt.local 'systemctl list-timers mac-share-heal.timer'

# 6. the phone remote (§4): server up, and mpv visible on MPRIS
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active urserver'
ssh homeserver-edt.local 'playerctl -l'
```

| Symptom | Cause |
| --- | --- |
| Cast target not in the phone's list | Client not running, or missing the "remote control of other users" permission, or within ~30 s of boot |
| Phone's Media remote buttons do nothing | No active MPRIS player (mpv not running, or VLC holds the keys), or the uinput device is missing — `grep -i unified /proc/bus/input/devices` |
| mpv missing from `playerctl -l` | `mpv-mpris` not loaded: `/etc/mpv/scripts/mpris.so` absent (not deployed) or mpv started before it existed — restart mpv |
| `/mnt/mac` lists nothing, `systemctl is-active mnt-mac.automount` says `inactive` | The start-limit wedge above; the heal timer fixes it within 2 min, or `sudo systemctl restart mnt-mac.automount` |
| `/mnt/mac` empty but the automount is active | Mac asleep, File Sharing off, wrong `shareName`, or wrong credentials — check `journalctl -u mnt-mac.mount -n 30` |
| Mount works, Jellyfin can't read the files | By design: the mount is owner-only (`uid=1000`, `file_mode=0600`). Widening it is described above |
| VLC `smb://` fails with "cannot open" | File Sharing off, or the share password prompt was dismissed on the TV |
