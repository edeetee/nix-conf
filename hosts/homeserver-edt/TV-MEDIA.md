# Watching things on the TV

Four separate things, often confused with each other, all about getting video
onto the Sony TV that this box drives:

| Want | Mechanism | Needs the phone? |
| --- | --- | --- |
| Browse a library, cast to the TV, control from the phone | Jellyfin + Jellyfin Desktop as a cast target | Yes |
| Play/pause/volume for mpv (or anything else on MPRIS) from the phone | Unified Remote's free Media remote + mpv-mpris | Yes |
| Relaunch/stop a TV app from the phone without walking over | KDE Connect run commands | Yes |
| Play a file that lives on the Mac | `/mnt/mac` (cifs automount) or `vlc smb://…` | No |
| Let Jellyfin serve Mac media | a library on `/mnt/mac/<folder>` | Yes |

AirPlay (audio + screen mirroring) is a fifth, unrelated path — that one is in
`AIRPLAY.md`.

## 1. Jellyfin Desktop is always a cast target

There is no standalone "Jellyfin remote" app: remote control is a feature of
every Jellyfin client, and it can only control a client that is **running and
logged in**. A sleeping client cannot be woken from the phone, which is exactly
why the TV client is now part of the session rather than something launched by
hand:

```nix
# desktop.nix
systemd.user.services.jellyfin-desktop = {
  after = [ "plasma-plasmashell.service" ];
  wantedBy = [ "plasma-plasmashell.service" ];
  serviceConfig.ExecStart = "${pkgs.jellyfin-desktop}/bin/jellyfin-desktop --tv --windowed";
  serviceConfig.Restart = "on-failure";
};
```

Decisions worth remembering:

- **`--tv --windowed`, not `--fullscreen`.** This box is also the Steam machine,
  so the client must not own the screen permanently. It does not have to: the
  client honours the web player's HTML5 fullscreen request, so a casted video
  still goes fullscreen (the client's own `fullscreen` setting help says
  *"Regular HTML5 fullscreen does still work"*). If this box ever becomes a pure
  media appliance, change `--windowed` to `--fullscreen`.
- **`Restart=on-failure`, not `always`.** A crash comes back; *quitting* the app
  stays quit so the desktop can be used, and it needs an explicit restart.
- **No login step at runtime.** Jellyfin Desktop is a QtWebEngine shell around
  jellyfin-web, so "logged in" is just a device token in its WebEngine profile
  (`~/.local/share/jellyfin-desktop/profiles/<id>/QtWebEngine`), pointing at
  `http://localhost:8096`. It is only lost by revoking the device in Dashboard →
  Devices, "sign out of all devices", or wiping that directory.

Timing: the cast target appears roughly 15–30 s after boot (Plasma → app →
WebEngine → session registration). Casting inside that window just won't list it.

The one permission that gates everything: Dashboard → Users → `edeetee` →
**"Allow remote control of other users"** (or "Allow remote control of shared
devices"). Without one of those the phone's cast UI stays hidden, which looks
identical to "the client isn't running".

```bash
# status / manual control (over ssh)
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status jellyfin-desktop'
ssh homeserver-edt.local 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start jellyfin-desktop'
```

Note the AGENTS.md deploy rule: a *new* user unit is not started on an
already-running user manager, so after the first `nixup` that adds this unit it
must be started by hand once (or by rebooting).

## 2. Phone side: KDE Connect run commands

The daemon already autostarts as a user unit
(`app-org.kde.kdeconnect.daemon@autostart.service`, from the xdg autostart
entry), and the iPhone is paired — so this is only about the commands.

Two commands are registered for the paired phone:

| Name | Command |
| --- | --- |
| `Jellyfin TV` | `systemctl --user start jellyfin-desktop` |
| `Jellyfin TV (stop)` | `systemctl --user stop jellyfin-desktop` |

`start` is idempotent — tapping it while the client runs is a no-op, whereas
launching the binary again would open a second window. That is why these go
through systemd rather than executing `jellyfin-desktop`.

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
`ro`), so any local account can read it — Jellyfin included. Two facts force
that shape: a `nounix` cifs mount has exactly one owner, and the nixpkgs Jellyfin
module sets `PrivateUsers=yes`, which makes the mount's owner render as `nobody`
to jellyfin, so only the `other` bits are ever consulted. The price is that
`~/.ssh` and the sops age key under `~/Library/Application Support/sops/age/`
are readable by every service account on this box; narrow it by mounting a
`subpath` with `fileMode = "0600"/dirMode = "0700"` if that ever matters more
than the convenience.

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

### Jellyfin libraries

Point a library at `/mnt/mac/<folder>` and it works: the mount is readable by
any local account now, and jellyfin re-arms it on first access (verified inside
jellyfin's sandbox). The caveat that remains is the Mac itself — a library rooted
on a share that comes and goes makes Jellyfin mark items missing on every scan
that lands while the Mac is asleep, and mangles resume state. That is why the
general advice is still to sync Mac media to `/mnt/hdd` (rsync/Syncthing) if it
should behave like a permanent library. Also note that if the Mac sleeps
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
