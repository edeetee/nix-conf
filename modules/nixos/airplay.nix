# AirPlay audio receiver — shairport-sync (+ nqptp for AirPlay 2).
#
# Makes the host appear in the iPhone's AirPlay output list and plays the stream
# on whatever PipeWire sink is default (here: HDMI → TV). See
# hosts/homeserver-edt/AIRPLAY.md for the full story and troubleshooting.
#
# Two non-obvious constraints shape this module:
#
#  1. shairport-sync must run as a *user* service. PipeWire on this host is
#     per-user (services.pipewire.systemWide = false), so the sound server only
#     exists inside the logged-in session — a system service cannot reach
#     /run/user/<uid>/pulse/native. Upstream is explicit about this
#     (ADVANCED TOPICS/PulseAudioAndPipeWire.md: "Shairport Sync must be set up
#     as a user service"). The NixOS shairport-sync module only creates a system
#     unit, so that unit is neutered below and a user unit is defined instead.
#     autoLogin (desktop.nix) keeps the session alive from boot.
#
#  2. AirPlay 2 additionally needs nqptp: a privileged daemon that takes
#     exclusive ownership of UDP 319/320 (PTP) and publishes timing data in
#     /dev/shm/nqptp. nixpkgs 25.11 ships the binary but has no NixOS module, so
#     the unit is hand-rolled here (mirroring upstream's nqptp.service). The SHM
#     is created world-readable (0644) and shairport-sync opens it O_RDONLY, so
#     the unprivileged user service can read it without any group juggling.
#     Ordering note: shairport-sync waits 10s for that SHM at startup and then
#     exits ("can not find the nqptp service ... Is nqptp installed and
#     running?"). nqptp comes up at multi-user.target, well before the graphical
#     session, so the ordering works out; Restart=on-failure covers the rest.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    types
    getExe
    ;
  cfg = config.services.airplay;

  # AirPlay 2 build. It advertises _airplay._tcp *and* _raop._tcp and can fall
  # back to classic AirPlay, so it is a superset of the classic-only build.
  package = pkgs.shairport-sync-airplay2;

  # Fullscreen "now playing" display + idle inhibitor. Reads shairport-sync's
  # MPRIS/Metadata off the session bus, so no extra plumbing is needed.
  nowPlayingPackage = pkgs.writers.writePython3Bin "airplay-nowplaying" {
    libraries = [ pkgs.python3Packages.pyqt6 ];
    flakeIgnore = [ "E501" ]; # house style allows long lines
  } (builtins.readFile ./airplay-nowplaying.py);
in
{
  options.services.airplay = {
    enable = mkEnableOption "the AirPlay audio receiver (shairport-sync + nqptp)";

    user = mkOption {
      type = types.str;
      default = "edeetee";
      description = ''
        The auto-logged-in desktop user whose PipeWire session shairport-sync
        runs in, and whose default sink the audio lands on.
      '';
    };

    name = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "Name advertised to AirPlay clients.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the classic AirPlay ports (TCP 5000, UDP 6001-6011, via the
        shairport-sync module) plus nqptp's PTP ports (UDP 319/320). A no-op
        while `networking.firewall.enable = false`, but keeps this correct if
        the firewall is ever switched back on.

        Note: an AirPlay 2 receiver also needs the ephemeral UDP port range
        reachable from the LAN, which is why the firewall is left off here.
      '';
    };

    nowPlaying = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Put a fullscreen "now playing" window on the attached display while a
          stream is playing (cover art, track, artist, album, progress).
        '';
      };

      inhibitIdle = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Hold an idle inhibitor for as long as a stream is connected, so the
          machine behaves like it does while a video is playing instead of
          blanking/locking/sleeping in the middle of an album. Like a video
          player this is the `org.freedesktop.ScreenSaver.Inhibit` call, plus a
          best-effort logind inhibitor (see AIRPLAY.md — logind only authorises
          the sleep/shutdown part for an active seat session).
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    services.shairport-sync = {
      enable = true;
      package = package;
      openFirewall = cfg.openFirewall;

      # Written to /etc/shairport-sync.conf; the package is built with
      # --sysconfdir=/etc, which is where the daemon looks by default.
      settings = {
        general = {
          name = cfg.name;
          # Go through pipewire-pulse. The native "pipewire" backend is the
          # alternative, but it hard-fails if the socket isn't up yet, whereas
          # this path is the one the module and most deployments exercise.
          output_backend = "pulseaudio";
        };
        diagnostics.log_verbosity = 1;
      };
    };

    # ── shairport-sync: user unit, not the module's system unit ────────────
    systemd.services.shairport-sync.wantedBy = lib.mkForce [ ];

    systemd.user.services.shairport-sync = {
      description = "Shairport Sync — AirPlay audio receiver";
      documentation = [ "https://github.com/mikebrady/shairport-sync" ];
      after = [
        "pipewire.socket"
        "pipewire-pulse.socket"
        "wireplumber.service"
      ];
      wants = [
        "pipewire.socket"
        "pipewire-pulse.socket"
      ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${getExe package} -c /etc/shairport-sync.conf";
        Restart = "on-failure";
        RestartSec = 2;
        RuntimeDirectory = "shairport-sync";
      };
    };

    # ── nqptp: PTP timing for AirPlay 2 ────────────────────────────────────
    systemd.services.nqptp = {
      description = "nqptp — Not Quite PTP (AirPlay 2 timing daemon)";
      documentation = [ "https://github.com/mikebrady/nqptp" ];
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = getExe pkgs.nqptp;
        # Mirrors upstream's nqptp.service: ports 319/320 are privileged, and
        # the daemon wants realtime scheduling for its timing threads.
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        LimitRTPRIO = 6;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [
      319
      320
    ];

    # ── now-playing display (+ keep-awake while playing) ──────────────────
    environment.systemPackages = [ nowPlayingPackage ];

    systemd.user.services.airplay-nowplaying = mkIf cfg.nowPlaying.enable {
      description = "AirPlay now-playing display (fullscreen art, holds idle inhibitors)";
      documentation = [ "https://github.com/mikebrady/shairport-sync" ];
      # Needs the session: X/Wayland socket, session bus, and the session itself
      # for the inhibitor calls to be attributed to an active session.
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${getExe nowPlayingPackage}${
          lib.optionalString (!cfg.nowPlaying.inhibitIdle) " --no-inhibit"
        }";
        # Qt from nixpkgs' qt6 has no Wayland platform plugin, and the session
        # runs Xwayland anyway (DISPLAY/XAUTHORITY are imported into the user
        # manager by Plasma).
        Environment = [
          "QT_QPA_PLATFORM=xcb"
          "AIRPLAY_SH=${pkgs.bash}/bin/bash"
          "AIRPLAY_SLEEP=${pkgs.coreutils}/bin/sleep"
          "AIRPLAY_SYSTEMD_INHIBIT=${pkgs.systemd}/bin/systemd-inhibit"
        ];
        Restart = "on-failure";
        RestartSec = 3;
      };
    };
  };
}
