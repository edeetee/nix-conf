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

  # AirPlay *mirroring* (video) — shairport-sync is audio-only by design, UxPlay
  # implements the mirror protocol (iOS/macOS screen mirroring) plus YouTube HLS
  # video and its own audio-only mode.
  #
  # Pipeline note: the nixpkgs build of gst-plugins-bad has no pipewire plugin
  # (verified: no libgstpipewire.so in its closure), so UxPlay's own "use
  # pipewiresink on PipeWire systems" advice would fail here — audio goes
  # through pulsesink into pipewire-pulse, exactly like shairport-sync does.
  # Video defaults to software decode + the OpenGL sink (both present);
  # hardwareDecoding switches to VA-API.
  mirrorName = cfg.mirror.name;
  mirrorPortRange = [
    cfg.mirror.port
    (cfg.mirror.port + 1)
    (cfg.mirror.port + 2)
  ];
  mirrorArgs = [
    "-n"
    mirrorName
    "-nh" # don't append "@hostname" to the advertised name
    "-m"
    cfg.mirror.deviceId # distinct from shairport-sync's id, see below
    "-p"
    (toString cfg.mirror.port)
    "-fs" # fullscreen on the TV
    "-s"
    "${cfg.mirror.resolution}@${toString cfg.mirror.maxFps}" # what to ask the client for
    "-fps"
    (toString cfg.mirror.maxFps)
    "-scrsv"
    "1" # inhibit the screensaver while video is being displayed
    "-as"
    "pulsesink"
  ]
  ++ lib.optional cfg.mirror.hls "-hls"
  ++ (
    if cfg.mirror.hardwareDecoding then
      [
        "-vd"
        "vah264dec" # GStreamer 1.26 name; older releases called it vaapih264dec
      ]
    else
      [ "-avdec" ]
  )
  ++ [
    "-vs"
    cfg.mirror.videoSink
  ];

  mirrorPackage = pkgs.writeShellScriptBin "airplay-mirror" ''
    # AirPlay mirroring server (see hosts/homeserver-edt/AIRPLAY.md).
    # Stop the uxplay user service first if it is running, then run this.
    # `--raw` skips the defaults below and hands everything to uxplay, for
    # experimenting with pipelines that need different arguments.
    if [ "''${1:-}" = "--raw" ]; then
      shift
      exec ${getExe pkgs.uxplay} "$@"
    fi

    # UxPlay aborts with "basic_string: construction from null is not valid" when
    # it is started without a runtime dir / session bus / XDG_CURRENT_DESKTOP,
    # which is what happens when it is run by hand from a plain ssh shell. The
    # user service inherits these from the Plasma session, so this only fills
    # gaps. (The last one is an upstream bug: -scrsv builds a std::string from
    # getenv("XDG_CURRENT_DESKTOP") without checking it is set.)
    : "''${XDG_RUNTIME_DIR:=/run/user/$(${pkgs.coreutils}/bin/id -u)}"
    : "''${DBUS_SESSION_BUS_ADDRESS:=unix:path=$XDG_RUNTIME_DIR/bus}"
    : "''${XDG_CURRENT_DESKTOP:=KDE}"
    if [ -z "''${XAUTHORITY:-}" ]; then
      XAUTHORITY=$(ls "$XDG_RUNTIME_DIR"/xauth_* 2>/dev/null | head -n1) || true
    fi
    : "''${DISPLAY:=:0}"
    export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS DISPLAY XDG_CURRENT_DESKTOP
    [ -n "''${XAUTHORITY:-}" ] && export XAUTHORITY

    # UxPlay generates a fresh keypair on every start unless it is told where to
    # keep one, and macOS caches the receiver's identity: without a stable key,
    # every restart invalidates what the client remembers and connections fail
    # with "could not connect". Mirrors StateDirectory= in the unit.
    : "''${XDG_STATE_HOME:=$HOME/.local/state}"
    KEYDIR="''${STATE_DIRECTORY:-$XDG_STATE_HOME/airplay-mirror}"
    mkdir -p "$KEYDIR"

    exec ${getExe pkgs.uxplay} ${lib.escapeShellArgs mirrorArgs} -key "$KEYDIR/key.pem" "$@"
  '';
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

    mirror = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run UxPlay, so iOS/iPadOS/macOS devices can *mirror* their screen to
          this machine (and stream YouTube video with its HLS support).
          shairport-sync cannot do video at all.

          This adds a second AirPlay entry next to the audio receiver and, like
          it, needs the desktop session. Note that DRM-protected content (Apple
          TV app, Netflix, ...) cannot be mirrored by anything that is not an
          Apple device.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "${cfg.name} Video";
        description = ''
          Name advertised to AirPlay clients. Kept distinct from the audio
          receiver's so the two are obvious in the iPhone's picker.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 7100;
        description = ''
          Base TCP and UDP port; UxPlay uses this and the next two. Deliberately
          away from shairport-sync's 7000 (RTSP) and 6001-6011 (UDP audio).
        '';
      };

      hardwareDecoding = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Decode H.264 with VA-API (`vah264dec`, in gst-plugins-bad 1.26 — the
          element was named `vaapih264dec` before the 1.26 rename, which is what
          UxPlay's help text still lists) instead of in software (`avdec_h264`).
          Worth trying if mirroring pegs CPU cores. Software decoding is the
          safer default: it avoids VA-API surface negotiation, where mirroring
          usually breaks. If it stays black, pair it with
          `-vc vapostproc` or `-vs glimagesink` on the command line.
        '';
      };

      videoSink = mkOption {
        type = types.str;
        default = "xvimagesink";
        description = ''
          GStreamer video sink. Defaults to `xvimagesink` — the X11 route through
          Xwayland — because UxPlay's `-fs` can only fullscreen a window it owns,
          while `glimagesink` and `waylandsink` create their own (Wayland)
          windows: that is what showed a small, wrongly-placed picture, and
          `waylandsink` additionally trips `gst_wl_window_ensure_fullscreen:
          assertion 'self' failed`. This build does link libX11, so the X11
          fullscreen path works.

          All of these render a test pattern on this display (checked), so trying
          another is reasonable: `xvimagesink` (default), `ximagesink`,
          `glimagesink`, `waylandsink` (the latter two need `--raw` without
          `-fs`). There is no `gtksink` in this build.
        '';
      };

      deviceId = mkOption {
        type = types.str;
        default = "02:00:00:00:00:02";
        description = ''
          AirPlay device id / MAC advertised by UxPlay (`-m`). It must **not** be
          the host's real interface MAC: shairport-sync derives its own device id
          from that, and two receivers behind one IP that claim the same id get
          collapsed by clients — macOS then keeps only one of them in its output
          list and fails to connect ("could not connect to homeserver-edt").
          Locally administered addresses (second nibble 2/6/A/E) are appropriate.
        '';
      };

      hls = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Also accept AirPlay *video streaming* (HLS) requests, not just screen
          mirroring. Without it, an app's own AirPlay button — which asks the
          receiver to fetch a stream rather than mirror the screen — is answered
          with `ignoring AirPlay video streaming request (use option -hls to
          activate HLS support)` and the client reports "could not connect".
          Control Centre → Screen Mirroring takes the mirroring path and does not
          need this; YouTube's HLS is the one known-working stream source, and
          DRM-protected video cannot be decrypted by any non-Apple receiver.
        '';
      };

      resolution = mkOption {
        type = types.str;
        default = "1920x1080";
        example = "1280x720";
        description = ''
          Display resolution to request from the client (`-s`). The TV is 1080p;
          if a mirror session negotiates something odd — a small picture in the
          middle of the screen — pinning this is the first thing to try.
        '';
      };

      maxFps = mkOption {
        type = types.int;
        default = 60;
        description = ''
          Framerate cap (`-fps`) and refresh rate requested with `-s`; UxPlay's
          own default is 30. Mirroring is client-driven, so the client still
          decides the rate frame by frame — this raises the ceiling. Higher rates
          cost CPU, or GPU when `hardwareDecoding` is on.
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

    networking.firewall = mkIf cfg.openFirewall {
      # nqptp's PTP ports, plus UxPlay's three TCP and three UDP ports.
      allowedUDPPorts = [
        319
        320
      ]
      ++ lib.optionals cfg.mirror.enable mirrorPortRange;
      allowedTCPPorts = lib.optionals cfg.mirror.enable mirrorPortRange;
    };

    # ── now-playing display (+ keep-awake while playing) ──────────────────
    environment.systemPackages = [
      nowPlayingPackage
      mirrorPackage
    ];

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
          "AIRPLAY_MIRROR_PORT=${toString cfg.mirror.port}"
        ];
        Restart = "on-failure";
        RestartSec = 3;
      };
    };

    # ── UxPlay: screen mirroring / video (shairport-sync cannot do video) ──
    systemd.user.services.uxplay = mkIf cfg.mirror.enable {
      description = "UxPlay — AirPlay mirroring server";
      documentation = [ "https://github.com/FDH2/UxPlay" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = getExe mirrorPackage;
        # Stable key/identity for the receiver (see the wrapper); macOS caches it.
        StateDirectory = "airplay-mirror";
        # Renders through Xwayland like the now-playing window (see AIRPLAY.md).
        Environment = [ "QT_QPA_PLATFORM=xcb" ];
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
