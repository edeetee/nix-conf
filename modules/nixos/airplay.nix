# AirPlay audio receiver — shairport-sync (+ nqptp for AirPlay 2).
#
# Makes the host appear in the iPhone's AirPlay output list. There are two
# shapes, chosen with `services.airplay.desktop`:
#
#   desktop = true (default)  Inside a desktop session: shairport-sync runs as a
#                             *user* service and plays through the session's
#                             PipeWire, i.e. on whatever the default sink is
#                             (on homeserver-edt: HDMI → TV). Also enables the
#                             now-playing window and UxPlay screen mirroring.
#   desktop = false           Headless: the NixOS module's *system* unit, with
#                             output_backend = "alsa", writing straight to the
#                             card named by `outputDevice`. No session, no
#                             PipeWire, no display — upstream's "ideal system"
#                             (AIRPLAY2.md: "a bare Linux system without a GUI
#                             and without PipeWire or PulseAudio … In this case,
#                             Shairport Sync connects directly to the ALSA output
#                             DAC"), and the only shape that makes sense on a
#                             box like sink-pi.
#
# See hosts/homeserver-edt/AIRPLAY.md (desktop) and hosts/sink-pi/AIRPLAY.md
# (headless) for the full story and troubleshooting.
#
# Four non-obvious constraints shape this module:
#
#  1. In desktop mode shairport-sync must run as a *user* service. PipeWire on
#     such a host is
#     per-user (services.pipewire.systemWide = false), so the sound server only
#     exists inside the logged-in session — a system service cannot reach
#     /run/user/<uid>/pulse/native. Upstream is explicit about this
#     (ADVANCED TOPICS/PulseAudioAndPipeWire.md: "Shairport Sync must be set up
#     as a user service"). The NixOS shairport-sync module only creates a system
#     unit, so in desktop mode that unit is neutered below and a user unit is
#     defined instead. autoLogin (desktop.nix) keeps the session alive from boot.
#     In headless mode the module's *system* unit is the one that runs — as the
#     `shairport` system user the module creates, which it already puts in the
#     `audio` group — so ALSA access needs no extra plumbing.
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
#     session, so the desktop case orders itself; the headless case says `after`
#     and `wants` nqptp explicitly, and Restart=on-failure covers the rest.
#
#  3. The RTSP port is not a detail you can leave to chance. An AirPlay 2 build
#     listens on 7000 and a classic build on 5000 (shairport.c: `config.port =
#     7000` for APST_airplay2, 5000 otherwise), which means nixpkgs'
#     `services.shairport-sync.openFirewall` — which opens TCP 5000 — is wrong
#     for the AirPlay 2 package this module installs. The firewall is owned here
#     instead. AirPlay 2 also binds its control, event and realtime-audio UDP
#     sockets with local port 0 (rtsp.c: `conn->local_ap2_control_port = 0; //
#     any port`) and hands the chosen port to the sender in the SETUP reply, so
#     the sender's packets arrive inbound on a port nothing can know in advance:
#     a host with a firewall needs the ephemeral range open (`ephemeralUdpPorts`).
#
#  4. Upstream assumes exclusive access to the output device — "A problem with
#     this setup is that Shairport Sync expects exclusive access to the audio
#     device … an otherwise-bare system … but with PipeWire added, can be used,
#     so that all audio sources output to the PipeWire system, which takes care
#     of mixing" (AIRPLAY2.md) — but that is not universal hardware behaviour.
#     The bcm2835 driver on a Raspberry Pi exposes *eight* playback substreams,
#     and a second client is accepted and drained in real time while another
#     stream runs (measured on sink-pi; hosts/sink-pi/AIRPLAY.md has the
#     numbers), so headless sharing of the card with another ALSA client works
#     there without a sound server in the middle. Where the driver really is
#     exclusive the second open fails with EBUSY and the two do need mixing.
#
#     Note also what "sharing" means here: shairport-sync opens the device when a
#     stream starts and closes it when the stream ends (`audio_alsa.c`:
#     `stop()` → `do_close()` unless `keep_dac_busy`, which only
#     `disable_standby_mode = "always"` or `use_precision_timing = "yes"` set),
#     so an idle receiver holds no audio device at all.
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
  package = if cfg.airplay2 then pkgs.shairport-sync-airplay2 else pkgs.shairport-sync;

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
  ++ lib.optional (!cfg.mirror.vsync) "-vsync no"
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

    desktop = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run the receiver inside a graphical desktop session: shairport-sync as a
        user service on the session's PipeWire, plus the now-playing window and
        UxPlay screen mirroring.

        Set to false on a headless host. shairport-sync then runs as the NixOS
        module's system service with `output_backend = "alsa"`, writing straight
        to the card named by `outputDevice`.

        `nowPlaying.enable` and `mirror.enable` default to this value, and both
        need a session: enabling either while `desktop = false` is an assertion
        failure rather than a unit that can never start.
      '';
    };

    airplay2 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install the AirPlay 2 build of shairport-sync and run nqptp, the timing
        daemon it needs. AirPlay 2 advertises both `_airplay._tcp` and
        `_raop._tcp` and falls back to classic AirPlay for older senders, so it
        is a superset of the classic-only build.

        Set to false for plain `shairport-sync`: AirPlay 1 only (ALAC 44.1 kHz
        stereo, which every iPhone still sends), no nqptp, RTSP on 5000 rather
        than 7000, and a much smaller closure — the AirPlay 2 build links ffmpeg
        for AAC. Worth considering on a small board that will never use
        multi-room or the newer formats.
      '';
    };

    outputDevice = mkOption {
      type = types.str;
      default = "default";
      example = "hw:0,0";
      description = ''
        ALSA PCM for the audio, used only when `desktop = false`. The name is
        what shairport-sync's ALSA backend passes to `snd_pcm_open`;
        `shairport-sync -h` lists the hardware devices, e.g. "hw:0,0" for card
        0's first playback device.

        "default" is the safe guess, but naming the hardware device directly is
        better where it is known: it skips plug/dmix and their format, period
        and possibly rate conversion, which on a Raspberry Pi's bcm2835 driver
        is the difference between a clean stream and a stuttering one.
      '';
    };

    rtspPort = mkOption {
      type = types.port;
      default = if cfg.airplay2 then 7000 else 5000;
      description = ''
        TCP port the receiver listens on for RTSP — the control channel the
        client connects to first, over which the audio streams are set up.
        Written to the config file rather than left to shairport-sync's default
        so that the firewall rule below cannot drift from what the daemon
        actually binds. The default follows the build, because upstream's does:
        7000 for AirPlay 2, 5000 for classic AirPlay. Clients learn it from the
        Bonjour advertisement, so it is free to move.
      '';
    };

    ephemeralUdpPorts = mkOption {
      type = types.listOf (types.attrsOf types.port);
      default = [
        {
          from = 32768;
          to = 60999;
        }
      ];
      example = [ ];
      description = ''
        UDP ranges to open for AirPlay 2's dynamically-bound streams, used only
        when `openFirewall = true`. AirPlay 2's control, event and
        realtime-audio sockets are bound with local port 0 and the chosen ports
        are handed to the sender in the SETUP reply, so the sender's packets
        arrive inbound on ports that cannot be known in advance. The default
        covers Linux's usual ephemeral range (`net.ipv4.ip_local_port_range`),
        which is where those sockets land.

        Set to `[]` to close the range: classic AirPlay and mirroring still
        work, and an AirPlay 2 client connects and then stays silent. Only
        meaningful on a host whose firewall is on.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "edeetee";
      description = ''
        The auto-logged-in desktop user whose PipeWire session shairport-sync
        runs in, and whose default sink the audio lands on. Ignored when
        `desktop = false`, where the NixOS module's own `shairport` system user
        is used (`services.shairport-sync.user` to change it).
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
        Open the receiver's ports: TCP `rtspPort`, nqptp's PTP ports (UDP
        319/320, AirPlay 2 only), the classic AirPlay audio range (UDP
        6001-6011, which an AirPlay 2 build still uses when it falls back to
        classic AirPlay for an older sender) and `ephemeralUdpPorts`.

        The NixOS shairport-sync module's own `openFirewall` is deliberately not
        used: it opens TCP 5000, the *classic* RTSP port, while the AirPlay 2
        package installed here defaults to 7000. A no-op while
        `networking.firewall.enable = false` (as on homeserver-edt), and
        load-bearing on a host whose firewall is on (sink-pi).
      '';
    };

    nowPlaying = {
      enable = mkOption {
        type = types.bool;
        default = cfg.desktop;
        description = ''
          Put a fullscreen "now playing" window on the attached display while a
          stream is playing (cover art, track, artist, album, progress). Needs a
          session, so it defaults to `desktop`.
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
        default = cfg.desktop;
        description = ''
          Run UxPlay, so iOS/iPadOS/macOS devices can *mirror* their screen to
          this machine (and stream YouTube video with its HLS support).
          shairport-sync cannot do video at all. Needs a session (it renders
          through X/Xwayland), so it defaults to `desktop`.

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

      vsync = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Synchronise audio to video using the client's timestamps (`-vsync`) —
          UxPlay's default. Turning it off (`-vsync no`) is the documented
          workaround for macOS clients whose timestamps break mirroring: Apple
          changed the `ntp_time` it sends in Sequoia (UxPlay issue 379, "invalid
          ntp_time < gst_video_pipeline_base_time"), and with `-vsync no` the
          client's value is not used. Downside: audio/video sync is then up to
          the client.
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
    assertions = [
      {
        assertion = cfg.desktop || !cfg.nowPlaying.enable;
        message = "services.airplay.nowPlaying needs a graphical session: leave services.airplay.desktop = true, or disable nowPlaying.";
      }
      {
        assertion = cfg.desktop || !cfg.mirror.enable;
        message = "services.airplay.mirror needs a graphical session (UxPlay renders through X/Xwayland): leave services.airplay.desktop = true, or disable mirror.";
      }
    ];

    services.shairport-sync = {
      enable = true;
      package = package;
      # Owned here — see this module's openFirewall description for why the
      # nixpkgs module's equivalent (TCP 5000) is not used.
      openFirewall = false;

      # Written to /etc/shairport-sync.conf; the package is built with
      # --sysconfdir=/etc, which is where the daemon looks by default.
      settings = {
        general = {
          name = cfg.name;
          port = cfg.rtspPort;
          # Desktop: go through pipewire-pulse. The native "pipewire" backend is
          # the alternative, but it hard-fails if the socket isn't up yet,
          # whereas this path is the one the module and most deployments
          # exercise. Headless: ALSA, straight to the card — the point of this
          # mode, and what upstream recommends for a bare system.
          output_backend = if cfg.desktop then "pulseaudio" else "alsa";
        };
        diagnostics.log_verbosity = 1;
      }
      // lib.optionalAttrs (!cfg.desktop) {
        alsa.output_device = cfg.outputDevice;
      };
    };

    # ── shairport-sync: which unit runs it ────────────────────────────────
    #
    # Desktop: the module's system unit is neutered, because it could never
    # reach the session's PulseAudio/PipeWire socket, and a user unit takes over.
    #
    # Headless: the module's system unit is the one that runs, so the only thing
    # to add is the ordering nqptp needs — shairport-sync gives up and exits if
    # nqptp's shared memory is not there within 10 s of it starting.
    systemd.services.shairport-sync = lib.mkMerge [
      (mkIf cfg.desktop {
        wantedBy = lib.mkForce [ ];
      })
      (mkIf (!cfg.desktop) {
        after = [ "nqptp.service" ];
        wants = [ "nqptp.service" ];
      })
    ];

    systemd.user.services.shairport-sync = mkIf cfg.desktop {
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
    systemd.services.nqptp = mkIf cfg.airplay2 {
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
      # RTSP, plus UxPlay's three TCP ports. cfg.rtspPort is in the list rather
      # than a hardcoded 5000/7000 so it always matches the config file.
      allowedTCPPorts = [ cfg.rtspPort ] ++ lib.optionals cfg.mirror.enable mirrorPortRange;
      # nqptp's PTP ports (AirPlay 2 only) and UxPlay's three UDP ports...
      allowedUDPPorts =
        lib.optionals cfg.airplay2 [
          319
          320
        ]
        ++ lib.optionals cfg.mirror.enable mirrorPortRange;
      # ...and AirPlay 1's audio range, which the AirPlay 2 build still uses when
      # it reverts to classic AirPlay, plus the ephemeral ports AirPlay 2 binds
      # for its own streams (see ephemeralUdpPorts).
      allowedUDPPortRanges = [
        {
          from = 6001;
          to = 6011;
        }
      ]
      ++ cfg.ephemeralUdpPorts;
    };

    # ── now-playing display (+ keep-awake while playing) ──────────────────
    #
    # Desktop only: these are the heavy end of the module (pyqt6, GStreamer,
    # UxPlay) and they need a session. Keeping them out of a headless host's
    # closure is most of the reason `desktop` exists.
    environment.systemPackages = lib.optionals cfg.desktop [
      nowPlayingPackage
      mirrorPackage
    ];

    systemd.user.services.airplay-nowplaying = mkIf (cfg.desktop && cfg.nowPlaying.enable) {
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
    systemd.user.services.uxplay = mkIf (cfg.desktop && cfg.mirror.enable) {
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
