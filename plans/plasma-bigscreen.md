# Plasma Bigscreen as the TV session (with a switch back to Plasma)

Status: **in progress** — the session switcher, Plezy as the TV app and the removal of the
`jellyfin-desktop` autostart are implemented (§3). **Bigscreen itself is not enabled yet**:
the pinned nixpkgs does not contain the package (§9). Nothing deployed; the user asked to
stay off the box while the TV was in use.

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
