# Kodi as the TV UI.
#
# Why this module exists: the TV used to be a chain of pushed-forward pieces —
# plasma-bigscreen 6.7.5 overlaid onto a Plasma 6.6 stack, Plezy overlaid from a
# newer nixpkgs with a 2 GiB Flutter SDK, a KWin script forcing fullscreen — with
# a Jellyfin server behind them all. Kodi is in the pinned nixpkgs, is a real
# 10-foot UI, plays the files directly, and has an official free remote. Design,
# the deleted stack and the migration order: plans/kodi-tv.md.
#
# Shape decided there (§3): Kodi runs **fullscreen inside the normal Plasma
# session**, not as its own DRM/GBM session (`kodi --standalone`). That choice is
# what keeps `steam-launcher` — and anything else — able to launch a window: a
# standalone Kodi owns the display with no compositor for a launched app to draw
# on. It also keeps audio on pipewire-pulse, the sink `mpv` and AUDIO.md are
# already tuned for, instead of Kodi's own output path.
#
# What this module deliberately does NOT do: Kodi's settings (display mode, audio
# device, passthrough toggles, the video source, the scraper) are GUI state in
# ~/.kodi/userdata/. There is no NixOS option for any of it. plans/kodi-tv.md D3
# (snapshot into the repo vs seed-if-absent on activation) is left unimplemented
# on purpose: the file does not exist until Kodi has run once, so there is
# nothing to snapshot yet. Capture it after the first run.
{ pkgs, ... }:
let
  kodi = pkgs.kodi.withPackages (kp: with kp; [
    # Steam in Big Picture from Kodi's home screen (addon 3.7.11, in the pin).
    # Baked in rather than installed through Kodi's GUI store, which writes into
    # ~/.kodi/addons — a directory no rebuild reproduces.
    #
    # Not included on purpose: jellycon and jellyfin. This host has no media
    # server any more; Kodi reads /mnt/hdd directly.
    steam-launcher
  ]);
in
{
  environment.systemPackages = [ kodi ];

  # Kodi's JSON-RPC + web UI ("Chorus2"), spoken by the free Official Kodi
  # Remote (iOS, Kodi Foundation) and Kore (Android). Chorus2 also works from any
  # phone browser at http://<host>:8080 with no app at all.
  #
  # Plain HTTP, and unauthenticated unless a user is set in guisettings, so this
  # belongs on the LAN and must never be forwarded. 8096 (Jellyfin) is gone with
  # the service; nothing else on this host listens on 8080.
  networking.firewall.allowedTCPPorts = [ 8080 ];

  # Starts with the session, the way jellyfin-desktop used to.
  #
  # Restart=on-failure, deliberately not `always`: a crash comes back, but
  # quitting Kodi must stay quit — that is now the whole answer to "how do I get
  # to the desktop from the couch", which used to cost tv-session.nix, a state
  # file and an SDDM relogin. `systemctl --user start|stop kodi-tv` is the
  # phone-side switch (see kde-connect-run-commands.nix).
  #
  # No --fullscreen flag here on purpose: check `kodi --help` on the box before
  # hard-coding one, and Kodi persists the fullscreen state in guisettings
  # anyway, so the first run is the one that sets it.
  #
  # Note the repo-wide gotcha: a *new* user unit is enabled but not started for a
  # user manager that is already running, so after the first deploy that adds
  # this, start it by hand once (or reboot).
  systemd.user.services.kodi-tv = {
    description = "Kodi (TV UI)";
    wantedBy = [ "plasma-plasmashell.service" ];
    after = [
      "plasma-plasmashell.service"
      "pipewire.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${kodi}/bin/kodi";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
