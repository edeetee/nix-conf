# Unified Remote — the phone remote for mpv, and for the TV UI.
#
# Two users of the same chain. The media keys drive mpv through MPRIS (§4 of
# TV-MEDIA.md); the *arrow keys* drive whatever window has focus — which since
# plans/kodi-tv.md means Kodi itself, not the retired Plasma Bigscreen shell.
# Kodi navigates by keyboard natively, so nothing here needs a D-Bus "send key"
# API: `urserver` injects kernel-level input events and KWin delivers them to the
# focused window. Kodi's own remote (§1b) is the richer option — it speaks Kodi's
# JSON-RPC and can browse the library — and this chain is what still drives mpv.
#
# Why this exists at all: the iOS KDE Connect app has no MPRIS/media plugin
# (its whole plugin set is Battery, Clipboard, FindMyPhone, Ping, Presenter,
# RemoteInput, RunCommand, Share, verified against KDE/kdeconnect-ios), so the
# phone cannot drive KDE Connect's media widget no matter how many MPRIS
# players this host exposes. Unified Remote's own *free* "Media" remote does
# the same job from the other side: it synthesises the standard media keys
# (remotes/Unified/Main/Media/remote.lua in the server tarball is seven
# `keyboard.press("media…")` calls), which Plasma resolves through its media
# controller to the *active MPRIS player*. mpv has no MPRIS of its own, which
# is what mpv-mpris below supplies.
#
# The whole chain, for whoever debugs this next:
#
#   iPhone app → urserver (this host, user service)
#              → uinput virtual input device (`uinput-unifiedremote`)
#              → KWin → the XF86AudioPlay global shortcut
#              → Plasma media controller → MPRIS → mpv-mpris → mpv
#
# Four non-obvious things:
#
#  1. **No udev rule or group is needed for uinput.** /dev/uinput is tagged
#     `uaccess` by systemd's own rule, which grants the active seat session's
#     user rw — `getfacl /dev/uinput` shows `user:edeetee:rw-`. That is what
#     lets this be a *user* service. It also means injection stops working
#     without an active session; auto-login (desktop.nix) guarantees one.
#  2. The server is Wayland-aware and chooses its backend from
#     XDG_SESSION_TYPE ("since wayland WAS detected. try to fallback to uinput
#     instead…"): on this host's Plasma Wayland session it injects kernel-level
#     input events, so the keys do reach KWin's global shortcuts. The vendor's
#     Ubuntu help page still says to disable Wayland; it predates this path.
#  3. `urserver` is a closed-source *unfree* binary (allowUnfree is already on
#     in modules/common.nix). Its own protocol has no authentication by default
#     and it listens on every interface, so set a password in the web manager
#     at http://localhost:9510/web — this host's firewall is off.
#  4. The built-in remotes are read-only, straight out of the Nix store
#     ($out/bin/remotes, which is why the derivation copies them next to the
#     binary). The free "Media" remote is one of them, so nothing needs
#     copying. A *custom* remote — the paid-tier mpv IPC one — would need a
#     writable remotes root plus `--remotes=$HOME/.urserver/remotes`, seeded
#     the way the vendor's urserver-start script does it. Deliberately not done
#     here: this is the free-tier change.
{ pkgs, lib, ... }:
let
  # urserver is an *interactive REPL on stdin*: it announces "enter 'exit' to
  # terminate server" and treats a stdin read that returns EOF as that exit.
  # systemd's default StandardInput=null is exactly such a stdin, and the first
  # version of this unit pointed ExecStart straight at the binary — it logged
  # "starting server...", then "> stopping server... / exiting..." (once after
  # 60 s, once instantly), which reads like a crash and is not one. So it gets
  # a pipe whose writer never writes and never closes: `sleep infinity`.
  #
  # The pipeline makes urserver a child of this shell rather than systemd's main
  # PID; that costs nothing (the shell exits when the server does, so Restart
  # still fires) and is the only way to express "stdin is an open pipe" from a
  # unit file.
  urserverStart = pkgs.writeShellScript "urserver-start" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/sleep infinity | exec ${lib.getExe pkgs.urserver}
  '';
in
{
  # mpv-mpris: mpv as an MPRIS player, so the media keys above (and playerctl,
  # and Plasma's media widget) have something to act on.
  #
  # Installed into mpv's *system* script directory rather than through
  # home-manager: mpv-unwrapped is built with --sysconfdir=/etc, and
  # hosts/homeserver-edt/home.nix reserves home-manager for the Plasma settings
  # in kde.nix. It also means every launch path gets the plugin — KRunner,
  # Dolphin, and the `systemd-run --user` invocations in TV-MEDIA.md.
  environment.etc."mpv/scripts/mpris.so".source =
    "${pkgs.mpvScripts.mpris}/share/mpv/scripts/mpris.so";

  # Talks the same MPRIS interface. This is how TV-MEDIA.md tells you to check
  # that mpv-mpris loaded, and what a KDE Connect run command would call.
  environment.systemPackages = [ pkgs.playerctl ];

  systemd.user.services.urserver = {
    description = "Unified Remote server (phone remote; media keys for mpv)";
    documentation = [ "https://www.unifiedremote.com/help" ];
    # Wants the session: XDG_SESSION_TYPE picks the input backend, and DISPLAY
    # is what the X11 fallback would need. It runs in the foreground (no
    # --daemon) because systemd is the supervisor.
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = urserverStart;
      # `always`, not `on-failure`: the server can also leave through its own
      # "stopping server... / exiting..." path with status 0 (see
      # urserverStart), and `on-failure` would leave it dead and silent.
      Restart = "always";
      RestartSec = 3;
    };
  };

  networking.firewall = {
    # 9512/TCP is the connection the phone app opens, 9510 is the web client
    # and manager. Declared although the firewall is off (networking.nix), for
    # the same reason as the KDE Connect range there: so turning it on later
    # does not silently break the phone.
    allowedTCPPorts = [
      9510
      9512
    ];
    # 9511/UDP is the LAN discovery broadcast the app uses to find this box,
    # 9512/UDP the "fast connection" socket.
    allowedUDPPorts = [
      9511
      9512
    ];
  };
}
