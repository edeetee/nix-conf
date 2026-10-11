# What running the sink instrument asks of a Raspberry Pi host, stated once.
#
# The layers around this one, and why it exists:
#
#   sink.nixosModules.piSink      everything that is true because *sink on a Pi*
#   (sink repository)             needs it: the 460800 Bluetooth overlay, BlueALSA,
#                                 the ALSA plugin path, the service tweaks. It knows
#                                 nothing about a machine.
#   modules/nixos/sink-machine.nix  (this file) the machine-wide policy a host that
#                                 runs sink has to state, as options whose defaults
#                                 reproduce hosts/sink-pi exactly, so a shared Pi can
#                                 run sink alongside other systems without two
#                                 conflicting definitions of the same option.
#   hosts/sink-pi/default.nix     this box: hostname, users, WiFi, storage, and the
#                                 instrument's own settings.
#
# The point of the split is composability. The reference host in the sink repository
# is one machine, so it can set `boot.kernelParams`, `swapDevices`, the console, sudo,
# SSH and the governor directly. A host that runs sink *and* something else must be
# able to include the same behaviour without those becoming a takeover, so every value
# here is an option (or a `lib.mkDefault`, which a host can beat) rather than a fact
# baked into an `imports` list. `hosts/sink-pi/README.md`, "Where each piece lives",
# records the decision for each item.
#
# The one deliberate `lib.mkForce` is `boot.kernelParams`, and it is not negotiable:
# `console=ttyAMA0` comes from nixpkgs' sd-image-aarch64 module and ttyAMA0 is the
# PL011 the Pi's Bluetooth chip talks on, so every printk line would be written into
# the HCI command stream. `kernelParams` is a merged list, so the only way to remove
# an entry is to replace the list - hence the defaults from NixOS spelled out below.
{ config, lib, pkgs, ... }:

let
  cfg = config.sinkMachine;
in
{
  options.sinkMachine = {
    enable = lib.mkEnableOption "the machine policy that running the sink instrument needs";

    wifiCountry = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "NZ";
      description = ''
        WiFi regulatory domain, emitted as the kernel's
        `cfg80211.ieee80211_regdom` parameter. The host has to pass the country it
        uses in `networking.wireless` here, because replacing `kernelParams` (to
        remove `console=ttyAMA0`) means this module owns the whole list.
      '';
    };

    consoleAutologin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Give the instrument's user a passwordless shell on the local console, so a
        box with a broken network can be diagnosed with an HDMI screen and a USB
        keyboard instead of by pulling the card out. SSH is unaffected and stays
        key-only. A host that wants a different console login sets
        `services.getty.autologinUser` itself; this is only a `mkDefault`.
      '';
    };

    passwordlessSudo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Put the instrument's user in `wheel` and let it sudo without a password.
        That is the privileged path a container-built deploy activates the system
        through (`nix/switch.sh` switches over `sink@` with `--sudo`); without it
        the only way to update a running box is to reflash it. Turn it off on a box
        that is deployed to as root only.
      '';
    };

    zramSwap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Compressed RAM swap. Evaluating a NixOS configuration on a 1 GB board is
        the classic way to run out of memory.
      '';
    };

    swapFileSize = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 1024;
      example = 512;
      description = ''
        Size in MiB of `/swapfile`, the ordinary swap a 1 GB board needs on top of
        zram. Null defines no swap device at all (a host with its own swap
        partition says so here).
      '';
    };

    cpuGovernor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "performance";
      description = ''
        CPU frequency governor. A governor that ramps up lazily is a source of
        audio dropouts on a slow board, so this is not cosmetic on an instrument.
        Null leaves the kernel's choice alone.
      '';
    };

    statusPort = lib.mkOption {
      type = lib.types.port;
      default = 47811;
      description = ''
        TCP port of the instrument's read-only JSON status socket, which is what
        `sink tui --remote <host>:<port>` reads. The port is fixed in
        `services.sink`'s `ExecStart` (`--status-port 47811`), so changing it here
        without changing that would only open the wrong hole.
      '';
    };

    bootReport = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Mount the SD image's FAT firmware partition read-write at boot and write a
        boot report into it. The journal lives on the ext4 root, which macOS cannot
        read, so this is what makes "pull the card and look" a real debugging path
        for a box that never appears on the network - which matters most exactly
        when the network is the thing that broke. Only applies to hosts built from
        nixpkgs' SD-image module; ignored elsewhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # NixOS' sd-image-aarch64 module adds `console=ttyAMA0` to this merged list,
      # and ttyAMA0 is the PL011 the Bluetooth chip talks on: /proc/consoles lists
      # it as enabled and writable, the boot log says "printk: console [ttyAMA0]
      # enabled", and every kernel message would land in the HCI command stream.
      # `loglevel=4` keeps that port quieter still, while journald records kernel
      # messages regardless. `nohibernate`, `root=fstab` and the `lsm` list are
      # NixOS' own values, re-spelled because mkForce replaces the whole list.
      boot.kernelParams = lib.mkForce (
        [
          "console=ttyS0,115200n8"
          "console=tty0"
        ]
        ++ lib.optional (cfg.wifiCountry != null) "cfg80211.ieee80211_regdom=${cfg.wifiCountry}"
        ++ [
          "nohibernate"
          "root=fstab"
          "loglevel=4"
          "net.ifnames=0"
          "lsm=landlock,yama,bpf"
        ]
      );

      # The instrument's status port. NixOS' firewall is on by default with only
      # ssh open, which is why the remote view *timed out* (packets dropped) rather
      # than being refused. Read-only by construction: the server has no code path
      # that writes to the instrument, so a viewer can watch but cannot play.
      networking.firewall.allowedTCPPorts = [ cfg.statusPort ];

      # Deploys built in the Linux container arrive as *unsigned* store paths, and
      # the daemon refuses those from an untrusted client - the first such deploy
      # failed with "cannot add path ... because it lacks a signature by a trusted
      # key". Naming the deploy user here is the documented fix, and it is why a
      # container-built switch can work over sink@ and not only over root@. (`root`
      # is already in nixpkgs' default, so only the instrument's user is added.)
      nix.settings.trusted-users = [ config.services.sink.user ];
    }

    # Everything a host is likely to own itself is a mkDefault, so a shared host
    # can state its own policy and win instead of colliding with this module.
    {
      services.openssh = {
        enable = lib.mkDefault true;
        settings = {
          PasswordAuthentication = lib.mkDefault false;
          # "no" would break key-based deploys; this allows keys and nothing else.
          PermitRootLogin = lib.mkDefault "prohibit-password";
        };
      };
    }

    (lib.mkIf cfg.passwordlessSudo {
      users.users.${config.services.sink.user}.extraGroups = [ "wheel" ];
      security.sudo.wheelNeedsPassword = lib.mkDefault false;
    })

    (lib.mkIf cfg.consoleAutologin {
      services.getty.autologinUser = lib.mkDefault config.services.sink.user;
    })

    (lib.mkIf cfg.zramSwap {
      zramSwap.enable = true;
    })

    (lib.mkIf (cfg.swapFileSize != null) {
      swapDevices = [ { device = "/swapfile"; size = cfg.swapFileSize; } ];
    })

    (lib.mkIf (cfg.cpuGovernor != null) {
      powerManagement.cpuFreqGovernor = cfg.cpuGovernor;
    })

    # The boot report needs the FAT firmware partition mounted, which is the one
    # thing in the sink repository's host that did not actually work. nixpkgs'
    # sd-image.nix defines /boot/firmware with `noauto` (nothing reads it at
    # runtime on a stock image) and `nofail`. The reference host redefined the
    # filesystem to add `rw`, but `options` is a list and lists *merge*, so the
    # `noauto` survived: `nix eval ...fileSystems."/boot/firmware".options` gave
    # ["rw" "nofail" "umask=0022" "nofail" "noauto"] and /etc/fstab kept it, the
    # partition was never mounted, and every report quietly went to the root
    # filesystem instead of the FAT partition macOS can read. mkForce is the only
    # way to remove an entry from a merged list option.
    (lib.mkIf (cfg.bootReport && config ? sdImage) {
      fileSystems."/boot/firmware".options = lib.mkForce [ "rw" "nofail" "umask=0022" ];

      # The earliest possible marker. If the box never reaches multi-user, the late
      # report below is never written and "nothing on the card" would be ambiguous:
      # the kernel might never have started, or it might have hung later. `after
      # local-fs.target` is what makes the firmware partition mounted by the time
      # this runs - `before sysinit.target` alone does not imply it, because
      # sysinit.target is ordered after local-fs.target rather than the other way
      # round.
      systemd.services.sink-boot-report-early = {
        description = "Record on the firmware partition that the boot got this far";
        wantedBy = [ "sysinit.target" ];
        before = [ "sysinit.target" ];
        after = [ "local-fs.target" ];
        path = [ pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          dest=/boot/firmware
          [ -d "$dest" ] || exit 0
          echo "sink: reached sysinit at $(date -Is) on kernel $(uname -r)" > "$dest/sink-booted.txt"
          sync
        '';
      };

      systemd.services.sink-boot-report = {
        description = "Write a boot report to the firmware partition";
        wantedBy = [ "multi-user.target" ];
        # Ordered after the things worth reporting on, but not conditional on them
        # succeeding - a failed WiFi association is precisely the interesting case.
        after = [ "sink.service" "wpa_supplicant.service" ];
        path = with pkgs; [
          coreutils
          iproute2
          iw
          util-linux
          procps
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          set -u
          dest=/boot/firmware
          [ -d "$dest" ] || exit 0
          [ -f "$dest/sink-report.txt" ] && cp -f "$dest/sink-report.txt" "$dest/sink-report-previous.txt"
          {
            echo "sink boot report -- $(date -Is)"
            echo
            echo "## system"
            uname -a
            uptime
            echo "temperature (millidegC): $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo n/a)"
            echo "cmdline: $(cat /proc/cmdline)"
            echo
            echo "## network"
            ip -brief addr
            ip route
            echo
            echo "## wireless"
            iw dev
            iw dev wlan0 link
            rfkill list
            echo
            echo "## wireless driver"
            dmesg | grep -iE "brcmfmac|brcm|cfg80211|wlan" | tail -40
            echo
            echo "## wpa_supplicant"
            journalctl -b -u wpa_supplicant.service --no-pager -n 40
            echo
            echo "## sink"
            systemctl status sink.service --no-pager -l | head -30
            journalctl -b -u sink.service --no-pager -n 40
            echo
            echo "## audio"
            # /proc/asound/pcm carries the same PCM list `aplay -l` prints, without
            # dragging alsa-utils (and through it alsa-plugins, ffmpeg, sdl3 and
            # pipewire) into the build closure of a board that will never use any
            # of them.
            cat /proc/asound/pcm 2>/dev/null || true
            cat /proc/asound/cards
          } > "$dest/sink-report.txt" 2>&1
          # Only this file, not everything the boot has written: a bare `sync` here
          # flushes the ext4 root and the journal too, which is seconds of SD card
          # time spent on the critical path of multi-user.target for a file nobody
          # reads until something has gone wrong.
          sync -d "$dest/sink-report.txt"
        '';
      };

      # Again a couple of minutes later, so a slow association or a restarting
      # service still ends up in the report.
      systemd.timers.sink-boot-report = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          Unit = "sink-boot-report.service";
        };
      };
    })
  ]);
}
