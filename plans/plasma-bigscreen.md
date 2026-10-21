# Plasma Bigscreen as the TV session (with a switch back to Plasma)

Status: **in progress, and questioned** — the session switcher, Plezy as the TV app and the
removal of the `jellyfin-desktop` autostart are implemented (§3). **Bigscreen itself is not
enabled yet**: the pinned nixpkgs does not contain the package (§9). §10 lists the
non-Plasma-coupled options, and one of them (`jellyfin-mpv-shim`) solves the actual problem
— remote control of the TV — with no new shell at all. Read §10 before spending anything
more on the Bigscreen path.

## 1. Why

The TV on this box is driven by `jellyfin-desktop --tv --fullscreen`
(`hosts/homeserver-edt/desktop.nix`), which is *not* a remote-control target: its
sessions report `SupportsRemoteControl=false`, so the phone app never lists it in
Play On. Upstream and open:

> **jellyfin/jellyfin-desktop#1260** — "2.0.0: session reports SupportsRemoteControl=false
> – server messages / remote stop don't work", opened 2026-10-07, open, no maintainer
> comment, no linked PR. <https://github.com/jellyfin/jellyfin-desktop/issues/1260>

A *browser* session does advertise the capability, which is why casting works when
Jellyfin runs in a browser on the Mac. So the fix is not in the client we have, it is
in what the TV session hosts.

Plasma Bigscreen is KDE's 10-foot shell: `plasmashell --shell org.kde.plasma.bigscreen`,
with a couch launcher, remote-friendly navigation, and it runs on the Plasma 6.7+
codebase — it was revived, not a Plasma 5 artefact. This plan makes it a **second
login session** alongside Plasma, so the TV UI can host the Jellyfin **web** client
(remote-controllable) while `jellyfin-desktop` stays installed as the direct-play
fallback for AC-3/DTS (`hosts/homeserver-edt/AUDIO.md`).

Available today in the pinned nixpkgs:

| Fact | Value | How checked |
| --- | --- | --- |
| Package | `kdePackages.plasma-bigscreen` 6.8.0 | `nix eval --raw nixpkgs#kdePackages.plasma-bigscreen.name` |
| Session it provides | `plasma-bigscreen-wayland` | `... .providedSessions` |
| Plasma session name | `plasma` | `nixpkgs#kdePackages.plasma-workspace.providedSessions` |
| Plasma 5 alias | removed (Gear 5/Plasma 5 EOL) | eval error message |

## 2. Non-goals

- Not fixing `#1260`, and not deleting `jellyfin-desktop`.
- Not moving the box off Plasma: it is also the Steam machine and the desktop is the
  fallback when the phone is not to hand.
- No changes to PipeWire/rtkit tuning, `AUDIO.md`, or the AirPlay stack — Bigscreen is
  a shell, it does not replace the audio path.

## 3. Shape

Two Wayland sessions, one of which is chosen at login time by a state file, plus a
`tv-session` command that flips the state file and re-logs-in. Autologin keeps working,
so a reboot never needs a keyboard.

| Decision | Choice | Rationale |
| --- | --- | --- |
| How Bigscreen is installed | `services.displayManager.sessionPackages = [ kdePackages.plasma-bigscreen ]` | NixOS then generates `plasma-bigscreen-wayland.desktop`; no hand-written session file |
| Which session SDDM autologins | a **wrapper** session (`homeserver-tv`) that reads a state file | SDDM's autologin session is static config; a wrapper is the only way to switch without a rebuild |
| Where the state lives | `~/.local/state/tv-session`, contents `plasma` or `bigscreen` | user-writable (no sudo to switch), survives reboots, survives a nixos-rebuild |
| How the switch happens | write state, then terminate the user session; SDDM autologins into the wrapper again | no reboot, no rebuild, ~10 s |
| `jellyfin-desktop` autostart | **not** in the Bigscreen session (§6.1) | two fullscreen TV UIs fighting over one screen is worse than one |
| Phone-driven switching | two KDE Connect run commands in `kde-connect-run-commands.nix` | same mechanism already used to restart the TV client |
| Portal | `xdg.portal.configPackages = [ kdePackages.plasma-bigscreen ]` | Bigscreen ships portal configs for its app launcher |

### 3.1 Sketch — `hosts/homeserver-edt/tv-session.nix` (new)

```nix
{ pkgs, ... }:
let
  # Started by SDDM as the autologin session. Execs whichever real session the
  # state file names, by reading the Exec= line out of the NixOS-generated
  # session file — so the launcher path is never hard-coded here.
  start = pkgs.writeShellScript "homeserver-tv-session" ''
    set -eu
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/tv-session"
    case "$(cat "$state" 2>/dev/null || echo plasma)" in
      bigscreen) name=plasma-bigscreen-wayland ;;
      *)         name=plasma ;;
    esac
    dir=/run/current-system/sw/share/wayland-sessions
    [ -r "$dir/$name.desktop" ] || name=plasma          # never fail to log in
    exec_line=$(sed -n 's/^Exec=//p' "$dir/$name.desktop" | head -n1 | sed 's/ *%[a-zA-Z]//g')
    exec sh -c "$exec_line"
  '';

  sessionFile = pkgs.writeTextDir "share/wayland-sessions/homeserver-tv.desktop" ''
    [Desktop Entry]
    Name=HomeServer TV (plasma or bigscreen)
    Comment=Switches on ~/.local/state/tv-session; see plans/plasma-bigscreen.md
    Exec=${start}
    DesktopNames=KDE
    Type=Application
  '';

  switch = pkgs.writeShellScriptBin "tv-session" ''
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/tv-session"
    case "''${1:-status}" in
      status)    cat "$state" 2>/dev/null || echo plasma; exit 0 ;;
      plasma|bigscreen) mkdir -p "$(dirname "$state")"; echo "$1" > "$state" ;;
      *)         echo "usage: tv-session {plasma|bigscreen|status}" >&2; exit 2 ;;
    esac
    echo "switching to $1; ending this session…"
    loginctl terminate-user "$(id -un)" || \
      echo "log out from the desktop menu to apply"   # fallback, see §5
  '';
in
{
  services.displayManager = {
    sessionPackages = [ pkgs.kdePackages.plasma-bigscreen ];
    defaultSession = "homeserver-tv";
    # autoLogin.{enable,user} already set in desktop.nix; SDDM's Autologin.Session
    # derives from defaultSession, so it is not written again here.
  };

  xdg.portal.configPackages = [ pkgs.kdePackages.plasma-bigscreen ];
  environment.systemPackages = [ sessionFile switch ];
}
```

### 3.2 Sketch — gate the TV client to the Plasma session

```nix
systemd.user.services.jellyfin-desktop = {
  # …unchanged, plus:
  unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=KDE"; # read §6.1 first
};
```

Better candidate than the condition, if it works: `wantedBy`/`after` the plasmashell
unit stays the same under Bigscreen (same unit, different `--shell`), so the gate has
to be explicit. Verify with `systemctl --user cat plasma-plasmashell.service` under both
sessions.

## 4. Files touched

| File | Change |
| --- | --- |
| `hosts/homeserver-edt/tv-session.nix` | new — the above |
| `hosts/homeserver-edt/default.nix` | import it |
| `hosts/homeserver-edt/desktop.nix` | `ConditionEnvironment` gate on `jellyfin-desktop`; fix the misleading `description = "… (remote-control target)"` and cite `#1260` |
| `hosts/homeserver-edt/kde-connect-run-commands.nix` | `TV mode` → `tv-session bigscreen`, `Desktop mode` → `tv-session plasma` |
| `plans/README.md` | index row |

## 5. Getting back to the desktop (three layers, in order)

1. **TTY** — `Ctrl+Alt+F2`, log in as `edeetee`, `tv-session plasma`. Works even if
   KWin or the shell never came up; this is the reason the wrapper falls back to
   `plasma` instead of erroring out.
2. **SSH** — `ssh homeserver-edt.local tv-session plasma` (the box is always reachable
   while awake; `tv-session status` reports the current mode).
3. **Phone** — the KDE Connect run command, no prompt beyond the script's own output.

`loginctl terminate-user <self>` may ask polkit for authorisation on some polkit
revisions. If it does, the script's fallback message is the instruction: log out from
the shell's own menu, and SDDM autologin drops you into the *other* session because the
state file already changed. Add `pkgs.polkit` rule only if the fallback proves annoying —
do not paper over it before measuring it.

Optional emergency switch that needs no session at all: keep `plasma` as
`services.displayManager.defaultSession` too? No — one switch point only. If the wrapper
itself breaks, `nixos-rebuild` with `defaultSession = "plasma"` is the escape hatch, and
it is a one-line revert.

## 6. Open decisions

1. **Does the TV session autostart `jellyfin-desktop`?** Current lean: no — Bigscreen's
   launcher starts it, or the phone's KDE Connect command does, and the web client runs
   from the launcher for the remote-control case. The counter-argument is the original
   design note in `desktop.nix`: "there is no way to wake a sleeping client from the
   phone", so an always-running target is what makes casting feel instant. Decide before
   implementing §3.2, since it decides whether the gate exists at all.
2. **Which player sits in the TV session — `jellyfin-desktop`, Plezy, or a browser?**
   Not yet decided, and it decides whether this plan is even needed (§6.4).
3. Not a decision, a warning: both shells read and write the same `~/.config`
   (`plasmashellrc`, panel layout, and `kde.nix`'s plasma-manager keys). Expect the panel
   arrangement to be shared, and check `plans/kde-declarative-settings.md` before
   declaring any new panel keys.

### 6.4 Plezy — the candidate that may make this plan unnecessary

Plezy (`edde746/plezy`, GPLv3, Flutter) is a cross-platform Plex **+ Jellyfin + Emby**
client for desktop, mobile and TV, with a real TV layout. On desktop its playback engine
is **mpv/libmpv**, so it is a player rather than a browser: HEVC/AV1, HDR10+, Dolby
Vision, TrueHD/EAC3/DTS/AC3, ASS subtitles, per-title audio/subtitle memory.

| Fact | Value | How checked |
| --- | --- | --- |
| In nixpkgs (`pkgs.plezy`) | `plezy-1.30.0` on this flake's pin, `2.23.0` on current unstable | `nix eval` against the flake input and against `nixpkgs#` |
| Linux platform | `x86_64-linux` listed | `nixpkgs#plezy.meta.platforms` |
| Newer builds | Flathub (`services.flatpak.enable` is already on in `services.nix`) | upstream README |
| mpv config | reads user `mpv.conf` ("Quoted mpv.conf values take effect", 2.17.0) | release notes — *unverified for passthrough* |
| Desktop playback requirement | needs a **Wayland** session; X11 shows UI but no video plane | upstream README |
| Cost | free/open source on desktop + Android; one-time $5.99 on the App Store | App Store listing |
| Origin | **Plex-only** from Oct 2025 | HowToGeek, repo created 2025-10-21 |
| Jellyfin support | beta 2026-05-02 (#957), shipped in **2.0.0** 2026-05-11 | issue #957, release notes |
| Jellyfin maturity | ~5 months of Jellyfin work vs ~10 of Plex; per-release Jellyfin items since 2.3.0 | release notes |

**The one test that decides this plan.** Whether a Plezy session advertises
`SupportsRemoteControl` is undocumented. Install it on the box, start a playback, open the
Jellyfin phone app's Play On:

- **appears** → Plezy replaces `jellyfin-desktop` as the TV target, and Bigscreen is only
  worth doing for the couch UI (or not at all);
- **absent** → check whether Plezy's own *companion remote* (phone → Plezy, mentioned in
  the 2.2.0 notes as "Remembered manual companion remote host addresses") is usable from
  the phone. If it is, that is a better answer than KDE Connect and still not a reason to
  sacrifice mpv playback.

Do this test before implementing anything below: it is minutes, and it can delete the
whole plan.

**Why the Jellyfin path is the weaker half.** Plezy shipped in Oct 2025 as a Plex-only
client; Jellyfin arrived as a beta in May 2026 and landed in 2.0.0. The branding still
leads with Plex (site title "A Beautiful Plex & Jellyfin Client"), most articles about it
are Plex articles, and there are ~349 open issues. Jellyfin is a genuine code path now —
Quick Connect, metadata editing, transcode info in the Jellyfin dashboard — but it is the
one with the shorter history, and a session-capability gap (the §6.4 test) is exactly the
kind of thing that would be built for Plex first and fixed on Plex's schedule. Treat "it
works for Plex" as evidence of engineering quality, not of Jellyfin parity.

## 7. Verification (before committing, per the repo rule)

```bash
nix flake check --no-build
nixos-rebuild build --flake .#homeserver-edt        # build half only, no root
```

Then on the server, after the user runs `nixup`:

```bash
ls /run/current-system/sw/share/wayland-sessions/   # plasma, plasma-bigscreen-wayland, homeserver-tv
tv-session status                                   # plasma
loginctl show-user edeetee -p Display --value        # session type under Bigscreen: wayland
systemctl --user cat plasma-plasmashell.service      # unit name/ordering identical in both shells
```

- Switch to `bigscreen`, confirm: shell comes up fullscreen, D-pad/arrow keys navigate,
  a Jellyfin **web** client launched from the launcher shows up in the phone's Play On and
  responds to pause/seek.
- Switch back to `plasma`, confirm the desktop, Steam, and `jellyfin-desktop` behave
  exactly as before (this is the regression that matters most).
- KDE Connect: both new run commands visible on the phone and working.
- A `nixos-rebuild switch` while in the Bigscreen session does not drop the session.

## 8. Risks

| Risk | Mitigation |
| --- | --- |
| SDDM autologin loop if the wrapper session dies instantly | wrapper falls back to `plasma` on any error; TTY + ssh paths above; `Relogin` can be set `false` to trade instant re-login for a greeter |
| Bigscreen is young (6.8 revival) — expect rough edges in the launcher | separate session, so rollback is "log into plasma" or delete `tv-session.nix`; nothing else depends on it |
| Two shells share `~/.config` | §6.3; verify panel/`plasmashellrc` behaviour before declaring keys in `kde.nix` |
| New user units are not started on an already-running user manager | `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start …` after the deploy (AGENTS.md "Deploying") |
| This plan does not fix `#1260` | `jellyfin-desktop` stays the direct-play fallback for AC-3/DTS; the remote-control path is the web client inside Bigscreen |
| Player choice may invalidate the plan | run the §6.4 Plezy test first; it is a minutes-long experiment, not a dependency of §3 |

## 9. What implementing it actually found

**`kdePackages.plasma-bigscreen` is not in this flake's nixpkgs.** Checked directly:

| Source | Result |
| --- | --- |
| flake pin, rev `c6d6588` (Plasma 6.6.4, Qt 6.11) | attribute **absent** |
| `nixpkgs/nixos-25.11` | absent |
| `nixpkgs/nixos-26.05` | absent |
| `nixpkgs/nixpkgs-unstable` at time of writing | `plasma-bigscreen-6.8.0`, sessions `plasma-bigscreen-wayland` |

So enabling Bigscreen is a **nixpkgs bump to Plasma 6.8**, not a two-line module. It cannot be
side-loaded from a newer nixpkgs either: Bigscreen is a KWin/plasmashell shell and has to
match the running Plasma major, so an overlay or a second `nixpkgs` input would give a 6.8
shell on a 6.6 stack.

What was shipped instead (`hosts/homeserver-edt/tv-session.nix`, plus edits to
`desktop.nix`, `packages.nix`, `kde-connect-run-commands.nix`):

- SDDM autologins into a wrapper session `homeserver-tv` that reads
  `~/.local/state/tv-session` and execs `plasma` or `plasma-bigscreen-wayland`, resolved at
  runtime through `XDG_DATA_DIRS` (never a hard-coded store path, and not through
  `sessionData.desktops`, which would be a dependency cycle).
- `tv-session {plasma|bigscreen|status}`; `bigscreen` refuses while the package is absent,
  and the wrapper falls back to `plasma` if a session file is missing — the way back to the
  desktop therefore already works today, from a TTY, over ssh, or from the phone.
- `jellyfin-desktop` no longer autostarts (it is the direct-play fallback) and
  `pkgs.plezy` is in `environment.systemPackages`, so it appears in Bigscreen's launcher
  once that session exists.

Still open: **bump nixpkgs** (whole-system update: kernel, Plasma 6.6 → 6.8, everything) or
**wait**. That is a separate decision with its own deploy risk, deliberately not taken here.

### 9.1 Option C — overlay *only* the shell (no nixpkgs bump)

Mechanically possible, and cheaper than a full bump. The evidence:

- The nixpkgs package is `mkKdeDerivation` with `postPatch` over the launcher script, one
  CMake flag, and build inputs `qtwebengine kdeconnect-kde libcec libcec_platform sdl3` —
  i.e. QML + a shell script, not compiled Plasma-internal API.
- Every symbol it needs already exists in **the pinned** nixpkgs: `kdePackages.callPackage`,
  `kdePackages.mkKdeDerivation`, `kdePackages.qtwebengine`, `libcec`, `sdl3` (checked by
  eval against the flake input).
- `hosts/homeserver-edt/tv-session.nix` already reads `pkgs.kdePackages.plasma-bigscreen
  or null`, so an overlay that adds that one attribute switches the session on with no
  further edits.

Sketch — a second input used purely as a **source tree**, built by the pinned scope:

```nix
# flake.nix
inputs.nixpkgs-bigscreen.url = "github:nixos/nixpkgs/nixpkgs-unstable";  # source only

# host module
{ inputs, lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages // {
        plasma-bigscreen = prev.kdePackages.callPackage
          "${inputs.nixpkgs-bigscreen}/pkgs/kde/plasma/plasma-bigscreen"
          { };
        # 6.8's QML is two Plasma minors away from the 6.6 runtime; pin the tag to
        # the closest release instead, by overriding src to v6.7.5:
        #   { version = "6.7.5"; src = fetchurl { ... }; }
      };
    })
  ];
}
```

What makes it *worth* trying: the blast radius is the TV session only. The desktop session
never loads the shell, and `tv-session bigscreen` still refuses/handles a bad state, so a
broken shell is a wasted experiment, not a broken box.

What makes it **unsupported**, and why it should not be committed as the final answer:

| Risk | Effect |
| --- | --- |
| QML imports/API introduced in Plasma 6.7/6.8 are absent from the 6.6 runtime | shell fails to load → blank TV session; desktop unaffected |
| build-time skew (`QT_FIND_PRIVATE_MODULES`, ECM/KF6 CMake macros, `qtwebengine`) | build fails, no runtime risk — a later tag (6.7.5) is the first thing to try |
| it can silently break on any Plasma point bump | no upstream support for the combination; the honest end state is still a nixpkgs bump |

Test order, cheapest first: **(1)** `nixos-rebuild build --flake .#homeserver-edt` on the
server with the overlay (proves it builds); **(2)** `tv-session bigscreen` plus a nested QML
smoke test rather than a logout, if one can be found; **(3)** only then log the TV session in,
with a TTY (`Ctrl+Alt+F2` → `tv-session plasma`) ready.

### 9.2 Option D — the whole `kdePackages` scope from a newer nixpkgs (rejected)

Possible in one line (`kdePackages = newpkgs.kdePackages`), and tempting because it avoids
touching the kernel and systemd. Rejected anyway:

- **The cost is nearly the same.** Plasma 6.8 means kwin, plasma-workspace, plasma-desktop,
  KF6, Qt, KIO, kdecoration and friends rebuilt. The pin is on `nixpkgs-unstable`, so a newer
  unstable rev gets **binary-cache hits** — a pin bump is mostly a large download, not hours of
  compilation. On cache hits the two options are close in cost; on misses, both lose.
- **The pin bump is the tested combination; this is not.** A pinned Plasma 6.6-era NixOS
  module driving a 6.8 stack, with systemd/pipewire/SDDM left behind, is a mix nobody runs or
  reports bugs against. KDE components talk to each other at runtime (portal backends, kded,
  kactivitymanagerd, KIO, `kdeconnect-kde`, plasma-manager's generated config), so skew
  shows up as session-level misbehaviour that is hard to bisect — unlike a pin bump, which
  either builds and boots or is rolled back with a generation.
- **If the KDE stack is being replaced anyway, replace the pin.** Same work, supported path,
  clean rollback (`nixos-rebuild --rollback`, old generations stay), and a diff you can read.

### 9.3 Is there an alternate flake for Bigscreen?

No. It ships only in nixpkgs; there is no upstream KDE flake and no dedicated third-party
packaging that this plan could find. The nearest upstream activity is nixpkgs PR #459790
("plasma: add mobile"), open with a merge conflict and marked stale — not a source to depend
on. So the real choice stays: overlay the one derivation (§9.1), or bump the pin (§9.2).

## 10. Options that are not coupled to Plasma (checked 2026-10-21)

The plan's actual goal is narrow — *the phone app can start and control playback on the TV,
with mpv-grade audio* — and Plasma Bigscreen is only one way to host that. It is also the
most coupled one: a shell has to match the running Plasma major (§9), so it drags a whole
nixpkgs bump along with it. Everything below sidesteps that by being an **app**, not a
shell.

| Option | In this flake's pin | Remote control from the phone | On-TV 10-foot UI | Notes |
| --- | --- | --- | --- | --- |
| `jellyfin-mpv-shim` 2.9.0 | **yes** | **yes** — upstream: "The Jellyfin mobile apps can fully control the client" | no (phone is the browser) | direct play via mpv, so AC-3/DTS decode like the fallback client |
| `kodi` 21.3 + `kodiPackages.jellyfin` 2.0.0 / `kodiPackages.jellycon` 0.9.1 | **yes** | **yes** — added "since day 1" in jellyfin-kodi; add-on has a documented remote-control/event path | yes (Kodi's own) | own session available: `services.xserver.desktopManager.kodi` (module exists in the pin's nixpkgs) |
| `fladder` 0.10.3 | **yes** | **no** — Play To/cast is an open discussion (#1024) | yes (Flutter, real TV layout) | best as a browser for the library, not as the cast target |
| `plezy` 1.30.0 | yes, but **Plex-only** | untested | yes | Jellyfin landed in 2.0.0 (2026-05-11); the pin is 1.30.0, i.e. *before* Jellyfin support — the TV app named in `packages.nix` cannot open a Jellyfin server at all |
| old Qt `jellyfin-media-player` | no — the attr now resolves to `jellyfin-desktop-2.0.0` | **no** | n/a | going back does not help: JMP never advertised the capability either (jellyfin-media-player#918, `SupportsRemoteControl: false`) |

Sources: jellyfin/jellyfin-mpv-shim README; jellyfin/jellyfin-kodi issue #709 and the
add-on's event-monitoring/remote-control docs; DonutWare/Fladder discussion #1024;
jellyfin/jellyfin-media-player#918. Package versions and the Kodi session module were
checked by eval against this flake's own pin, not from the web.

### 10.1 Recommendation

**A — `jellyfin-mpv-shim` as a user service in the existing Plasma session.** The phone app's
Jellyfin client is the library browser; mpv on the box is the player. No shell, no session
wrapper, no Plasma bump, and it is the only option whose remote control is a documented
feature rather than an open issue. This deletes §3's session switcher instead of extending
it — the box keeps autologging into Plasma, and `tv-session` loses its reason to exist
unless Kodi is also wanted.

**B — Kodi as the TV session** (`services.xserver.desktopManager.kodi`), if an on-TV UI is
wanted without Plasma. Castable, passthrough audio, remote-friendly, and the session is a
first-class NixOS module in the current pin — so the `tv-session` wrapper and its state file
are still useful (add `kodi` as a second mode), but Bigscreen's Plasma-version coupling
disappears.

**C — Bigscreen last.** It buys only the couch launcher, at the price of a whole nixpkgs
bump, and it is still pre-release upstream.

### 10.2 What to verify before committing to A or B

Not yet tested on the box (the TV was in use), and each is a minutes-long experiment:

- Does a `jellyfin-mpv-shim` session appear in the phone's **Play On** and accept
  pause/seek? That is the §6.4 test, applied to the shim rather than to Plezy.
- mpv-shim's audio path: it spawns its own mpv, so it must be told to follow the default
  sink / the HDMI passthrough settings in `AUDIO.md`, or it reintroduces the VLC problem.
- Under Plasma the shim is a plain fullscreen mpv window, so a stray notification or a
  keyboard shortcut can uncover the desktop — acceptable, but it is the difference that
  Bigscreen's session was supposed to buy.
