# TV session switcher: Plasma ⇄ Plasma Bigscreen, picked at login time.
#
# Why a wrapper session rather than just making Bigscreen the autologin
# session: SDDM's `Autologin.Session` is static configuration, so choosing *at
# login time* is the only way to move between the desktop and the TV UI without
# a rebuild — and without needing a keyboard at the TV. SDDM autologins into
# `homeserver-tv`, which execs whichever real session `~/.local/state/tv-session`
# names (`plasma` by default).
#
#   tv-session bigscreen    # → ends this session; autologin comes back in the TV UI
#   tv-session plasma       # → back to the desktop
#   tv-session status
#
# Three ways to run it, in order of how much has to be working: a TTY
# (Ctrl+Alt+F2), ssh from another machine, or the KDE Connect run commands in
# kde-connect-run-commands.nix. The state file is user-writable, so none of them
# needs root. Design notes and the decided trade-offs: plans/plasma-bigscreen.md.
#
# IMPORTANT — Bigscreen is not in this flake's nixpkgs yet. The pin (rev
# c6d6588) carries Plasma 6.6.4, and `kdePackages.plasma-bigscreen` first appears
# in nixpkgs-unstable at Plasma 6.8 (nor is it in nixos-25.11 / nixos-26.05).
# Everything here is therefore written to degrade instead of fail: while the
# package is absent, `tv-session bigscreen` refuses and explains, and the wrapper
# starts Plasma. After a nixpkgs bump the TV session appears with no change to
# this file. Do NOT pull bigscreen in from a newer nixpkgs while staying on
# Plasma 6.6 — it is a KWin/plasmashell shell and has to match the running
# Plasma major.
{ lib, pkgs, ... }:
let
  bigscreen = pkgs.kdePackages.plasma-bigscreen or null;
  bigscreenAvailable = bigscreen != null;
  bigscreenSession = "plasma-bigscreen-wayland";

  # Plasma is started from its own binary, not from a session .desktop file. The
  # files only exist in the *installed sessions* package, which reaches a session
  # only through XDG_DATA_DIRS — and SDDM does not necessarily hand that to the
  # session it launches. A missing session file must never mean "no session", so
  # the desktop path depends on nothing but a store path.
  startPlasma = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland";

  # Resolves a session name to its .desktop file without hard-coding store paths
  # and without referencing `sessionData.desktops` (which would be a cycle: it is
  # built from sessionPackages, which contains this very package). NixOS puts the
  # installed sessions' share dir on XDG_DATA_DIRS for every session.
  findSession = ''
    find_session() {
      _dirs="''${XDG_DATA_DIRS:-/run/current-system/sw/share}:/run/current-system/sw/share"
      for _d in $(printf '%s' "$_dirs" | tr ':' ' '); do
        if [ -r "$_d/wayland-sessions/$1.desktop" ]; then
          printf '%s\n' "$_d/wayland-sessions/$1.desktop"
          return 0
        fi
      done
      return 1
    }
  '';

  start = pkgs.writeShellScript "homeserver-tv-session" ''
    set -eu
    ${findSession}

    state="''${XDG_STATE_HOME:-$HOME/.local/state}/tv-session"
    mode=$(cat "$state" 2>/dev/null || echo plasma)

    if [ "$mode" = bigscreen ]; then
      if file=$(find_session ${bigscreenSession}); then
        exec_line=$(sed -n 's/^Exec=//p' "$file" | head -n1 | sed 's/ *%[a-zA-Z]//g')
        if [ -n "$exec_line" ]; then exec sh -c "$exec_line"; fi
      fi
      # Unreadable state, or a mode whose session is gone: log in to the desktop
      # rather than to a black screen.
      echo "tv-session: no ${bigscreenSession} session found, starting plasma" >&2
    fi

    exec ${startPlasma}
  '';

  # The session SDDM autologins into; it re-execs the real one above.
  sessionPackage =
    (pkgs.writeTextDir "share/wayland-sessions/homeserver-tv.desktop" ''
      [Desktop Entry]
      Name=HomeServer TV
      Comment=Plasma or Plasma Bigscreen, chosen by ~/.local/state/tv-session
      Exec=${start}
      DesktopNames=KDE
      Type=Application
    '')
    // {
      # Read as a top-level attribute by the display-manager module
      # (`p.providedSessions`) and normally set through passthru; both are set
      # here because this package is hand-made rather than a kdePackages build.
      providedSessions = [ "homeserver-tv" ];
      passthru.providedSessions = [ "homeserver-tv" ];
    };

  switch = pkgs.writeShellScriptBin "tv-session" ''
    ${findSession}

    state="''${XDG_STATE_HOME:-$HOME/.local/state}/tv-session"
    case "''${1:-status}" in
      status)
        cat "$state" 2>/dev/null || echo plasma
        exit 0
        ;;
      plasma|bigscreen) ;;
      *)
        echo "usage: tv-session {plasma|bigscreen|status}" >&2
        exit 2
        ;;
    esac

    if [ "$1" = bigscreen ] && [ "${if bigscreenAvailable then "1" else "0"}" != 1 ]; then
      echo "tv-session: plasma-bigscreen is not installed in this system (the pinned" >&2
      echo "nixpkgs has Plasma 6.6; the package starts at Plasma 6.8) — staying on plasma." >&2
      exit 1
    fi

    mkdir -p "$(dirname "$state")"
    echo "$1" > "$state"
    echo "tv-session: switching to $1, ending the graphical session…"
    # End ONLY the graphical session: `loginctl terminate-user` also kills every
    # ssh session, which terminates the very command that asked for the switch
    # (and would drop a remote session mid-repair). SDDM then re-autologins into
    # the wrapper, which reads the new state.
    switched=0
    for s in $(loginctl show-user "$(id -u)" -p Sessions --value); do
      if [ "$(loginctl show-session "$s" -p Type --value)" = wayland ]; then
        loginctl terminate-session "$s" && switched=1
      fi
    done
    if [ "$switched" = 0 ]; then
      echo "tv-session: no graphical session to end; log out to apply" >&2
    fi
  '';
in
{
  services.displayManager = {
    sessionPackages = [ sessionPackage ] ++ lib.optional (bigscreen != null) bigscreen;
    # SDDM autologins into this (autoLogin.enable in desktop.nix); the wrapper
    # re-execs plasma or bigscreen from the state file.
    defaultSession = "homeserver-tv";
    # NixOS defaults Relogin to false, which means "autologin once, then sit at
    # the greeter forever". Without this, `tv-session` writes the new state,
    # ends the session, and nothing ever starts again — the box is left with no
    # graphical session at all (measured, 2026-10-21). It also makes a crashed
    # TV session retry instead of needing root to restart display-manager.
    sddm.settings.Autologin.Relogin = true;
  };

  # Bigscreen's app launcher needs its portal configuration to find apps.
  xdg.portal.configPackages = lib.optional (bigscreen != null) bigscreen;

  environment.systemPackages = [ switch ];
}
