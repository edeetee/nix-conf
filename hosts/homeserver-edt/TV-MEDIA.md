# Watching things on the TV

Three separate things, often confused with each other, all about getting video
onto the Sony TV that this box drives:

| Want | Mechanism | Needs the phone? |
| --- | --- | --- |
| Browse a library, cast to the TV, control from the phone | Jellyfin + Jellyfin Desktop as a cast target | Yes |
| Relaunch/stop a TV app from the phone without walking over | KDE Connect run commands | Yes |
| Play a file that lives on the Mac | `/mnt/mac` (cifs automount) or `vlc smb://…` | No |

AirPlay (audio + screen mirroring) is a fourth, unrelated path — that one is in
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

`/mnt/mac` is a **cifs automount**: nothing is mounted at boot, and the first
read of the path triggers the connection. If the Mac is asleep the read fails
fast and the *next* read tries again, so `ls /mnt/mac` is a retry button.
Prerequisites: File Sharing on the Mac, and the macOS Shared Folder name must
match `shareName` in `mac-share.nix`.

The credentials come from sops (a mount.cifs credentials file), so this must
exist **before** deploying or the switch fails at activation:

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
- **`uid=1000,gid=100,file_mode=0644,dir_mode=0755`** — macOS' SMB server does
  not implement the CIFS Unix extensions, so ownership and modes come from these
  options. World-readable is what lets the `jellyfin` user read the files.
  (`uid` is only expressible because `packages.nix` now pins `edeetee`'s uid to
  1000 — NixOS otherwise allocates it dynamically.)
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

`mac-share-heal.timer` (every 2 min) checks `systemctl is-active
mnt-mac.automount`, and if it is not active resets the failed state and re-arms
it. Manual equivalent, if ever needed:

```bash
ssh homeserver-edt.local 'sudo systemctl restart mnt-mac.automount'
```

### Do not point a Jellyfin library at it

A library rooted on a share that comes and goes makes Jellyfin mark items
missing on every scan that lands while the Mac is asleep, and mangles resume
state. If Mac media should be a *library*, sync it to `/mnt/hdd` instead
(rsync/Syncthing) — the mount is for "play this file now". Also note that if the
Mac sleeps mid-playback, playback stalls: that is inherent to pulling from a
Mac, mount or not (`caffeinate -i` on the Mac avoids it).

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
```

| Symptom | Cause |
| --- | --- |
| Cast target not in the phone's list | Client not running, or missing the "remote control of other users" permission, or within ~30 s of boot |
| `/mnt/mac` lists nothing, `systemctl is-active mnt-mac.automount` says `inactive` | The start-limit wedge above; the heal timer fixes it within 2 min, or `sudo systemctl restart mnt-mac.automount` |
| `/mnt/mac` empty but the automount is active | Mac asleep, File Sharing off, wrong `shareName`, or wrong credentials — check `journalctl -u mnt-mac.mount -n 30` |
| Mount works, Jellyfin can't read the files | `file_mode`/`dir_mode`/`uid` options, or the `jellyfin` user cannot traverse `/mnt/mac` |
| VLC `smb://` fails with "cannot open" | File Sharing off, or the share password prompt was dismissed on the TV |
