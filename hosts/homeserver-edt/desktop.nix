# Desktop / display / audio / bluetooth for homeserver-edt
{ pkgs, ... }:
{
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "edeetee";
    };
    sddm.enable = true;
  };

  services.desktopManager.plasma6.enable = true;

  # ── Never suspend ──────────────────────────────────────────────────────
  # This machine runs server services (Jellyfin, Cockpit, transmission, ...)
  # and must stay up. Suspending (KDE Plasma's default idle-suspend) drops the
  # WiFi and, on resume, triggers Avahi to re-probe its hostname and spuriously
  # rename homeserver-edt.local -> homeserver-edt-2.local, breaking mDNS.
  # Block suspend/hibernate at the logind level so no trigger can sleep it.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowSuspendThenHibernate = "no";
    AllowHybridSleep = "no";
  };

  # Bluetooth — needed for DualShock controllers
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Force Bluetooth adapter power on after KDE login (KDE/Bluedevil can save a
  # powered-off state at shutdown).
  systemd.user.services.bt-power-on = {
    description = "Force Bluetooth power on after KDE login";
    after = [ "plasma-plasmashell.service" ];
    wantedBy = [ "plasma-plasmashell.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bluez}/bin/btmgmt power on";
      RemainAfterExit = true;
    };
  };

  # Enable wake for all Bluetooth USB controllers
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="e0", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
  '';

  security.rtkit.enable = true;

  # ── Audio: PipeWire with low-latency tuning ─────────────────────────

  services.pipewire = {
    enable = true;
    audio.enable = true;
    pulse.enable = true;
    # Keep the HDMI sink (and its ALSA device) open while no stream is
    # playing. The default 5s suspend-on-idle causes the AMD HDMI link to
    # drop and re-sync, which the TV renders as a constant "spitting" noise
    # at full volume when VLC is paused.
    wireplumber.extraConfig."92-disable-suspend" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            { "node.name" = "~alsa_output.*"; }
          ];
          actions = {
            update-props = {
              "session.suspend-timeout-seconds" = 0;
            };
          };
        }
      ];
    };
    extraConfig.pipewire = {
      "92-low-latency" = {
        "context.properties" = {
          "default.clock.quantum" = 1024;
          "default.clock.min-quantum" = 32;
          "default.clock.max-quantum" = 1024;
        };
      };
    };
    extraConfig.pipewire-pulse = {
      "92-low-latency" = {
        "pulse.properties" = {
          # 256/48000 (~5.3ms) is the PipeWire default. 128/48000 was too
          # aggressive for consumer apps (VLC) and caused underrun/crackle.
          "pulse.min.req" = "256/48000";
          "pulse.min.quantum" = "256/48000";
        };
      };
    };
  };

  # Tell Wine/Steam's PulseAudio driver to use lower latency
  # Default is ~200ms. 60ms is the Proton community standard — any lower
  # and winepulse.drv can't refill buffers reliably, causing pops.
  # See: https://github.com/ValveSoftware/Proton/issues/1209
  environment.variables.PULSE_LATENCY_MSEC = "60";
}
