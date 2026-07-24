# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').

{
  config,
  pkgs,
  lib,
  ...
}:
let
  host = "${config.networking.hostName}.local";
in
{
  ## DO NOT CHANGE, used for backwards compatibility and upgrade logic
  system.stateVersion = "23.11"; # Did you read the comment?

  # Build-time guard: block known-dangerous service configs
  assertions = let
    blockedPaths = [ "/mnt/hdd" "/mnt/windows" "/home" ];
  in [{
    assertion = !(config.services.filebrowser.enable or false)
      || !(builtins.elem (config.services.filebrowser.settings.root or "") blockedPaths);
    message = ''
      REFUSED: services.filebrowser.settings.root is a shared mount point!
      FileBrowser's module chowns its root, breaking other services.
      See AGENTS.md and commit e216ab4.
    '';
  }];

  # Runtime guard: check mount ownership on every boot, fail+motd if wrong.
  systemd.services.check-mounts = {
    description = "Verify ownership of shared mount points";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = let
      check = path: pkgs.writeShellScript "check-${builtins.baseNameOf path}" ''
        owner=$(stat -c '%U:%G' ${path} 2>/dev/null)
        if [ "$owner" != "root:root" ]; then
          echo "CRITICAL: ${path} is owned by $owner, expected root:root!" >&2
          echo "Some service hijacked this mount point. Fix with: sudo chown root:root ${path}" >&2
          exit 1
        fi
      '';
    in ''
      set -e
      ${check "/mnt/hdd"}
      ${check "/mnt/windows"}
    '';
  };

  # Use the systemd-boot EFI boot loader.
  boot = {
    consoleLogLevel = 0;
    initrd.verbose = false;
    plymouth.enable = true;
    kernelParams = [
      "quiet"
      "splash"
      "loglevel=3"
      "vga=current"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
    ];

    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      systemd-boot.configurationLimit = 5;
      timeout = 1;
    };
  };

  # ease of use
  services.flatpak.enable = true;

  environment.shellAliases = {
    nixrs = "sudo nixos-rebuild switch --flake ~/dev/nix-conf/";
    nixup = "git -C ~/dev/nix-conf pull --quiet && git -C ~/dev/nix-conf --no-pager log --oneline ..@{u} 2>/dev/null && sudo nixos-rebuild switch --flake ~/dev/nix-conf/";
  };

  # Bluetooth — needed for DualShock controllers
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Force Bluetooth adapter power on after KDE login, since KDE/Bluedevil
  # can save a powered-off state at shutdown (bluetoothd stops before KDE
  # saves its state, so it records "off" regardless of actual usage).
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

  networking = {
    networkmanager.enable = true; # Easiest to use and most distros use this by default.
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    hostName = "homeserver-edt";

    # Wake-on-LAN — no longer needed
    # interfaces = {
    #   wlp5s0 = {
    #     wakeOnLan.enable = true;
    #   };
    # };
  };

  time.timeZone = "Pacific/Auckland";

  #services.devmon.enable = true;
  #services.gvfs.enable = true;
  services.udisks2.enable = true;

  nix.optimise.automatic = true;
  nix.settings.experimental-features = "nix-command flakes";

  # Enable the X11 windowing system.
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "edeetee";
    };

    sddm.enable = true;
  };

  services.desktopManager.plasma6.enable = true;

  services.zerotierone = {
    enable = true;
    joinNetworks = [
      "56374ac9a48a755c"
    ];
  };

  ## Enable wake on bluetooth controllers
  services.udev.extraRules = ''
    # Enable wake for all Bluetooth USB controllers
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="e0", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
  '';

  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.userServices = true;
    publish.addresses = true;
    publish.domain = true;
    nssmdns4 = true;
    nssmdns6 = true;
    openFirewall = true;
    publish.workstation = true; # ADDED TO DESKTOP MACHINES
  };

  # security.polkit.extraConfig = ''
  #   		polkit.addRule(function(action, subject) {
  #   				if (action.id == "org.freedesktop.login1.suspend" ||
  #   						action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
  #   						action.id == "org.freedesktop.login1.hibernate" ||
  #   						action.id == "org.freedesktop.login1.hibernate-multiple-sessions")
  #   				{
  #   				return polkit.Result.NO;
  #   				}
  #   				});
  #   	'';

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.edeetee = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "video"
      "networkmanager"
      "render"
    ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
    ];
  };

  services.cockpit = {
    enable = true;
    port = 9090;
    settings = {
      WebService = {
        AllowUnencrypted = true;
        Origins = lib.mkForce "http://${host}:* https://${host}:* http://localhost:* https://localhost:*";
      };
    };
  };

  services.jellyfin.enable = true;

  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    settings = {
      download-dir = "/mnt/hdd/downloads";
      incomplete-dir = "/mnt/hdd/downloads/.incomplete";
      rpc-whitelist = "127.0.0.1,192.168.*.*";
      rpc-port = 9091;
      rpc-bind-address = "0.0.0.0";
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/hdd/downloads 0775 edeetee users -"
    "d /mnt/hdd/downloads/.incomplete 0775 edeetee users -"
  ];

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    openFirewall = true;
    services = [
      {
        "Media" = [
          {
            "Jellyfin" = {
              icon = "jellyfin.svg";
              href = "http://${host}:8096";
              description = "Media server";
              widget = {
                type = "jellyfin";
                url = "http://127.0.0.1:8096";
              };
            };
          }
        ];
      }
      {
        "System" = [
          {
            "Cockpit" = {
              icon = "cockpit.svg";
              href = "http://${host}:9090";
              description = "Server management";
            };
          }
        ];
      }
      {
        "Downloads" = [
          {
            "Transmission" = {
              icon = "transmission.svg";
              href = "http://${host}:9091";
              description = "Torrent client";
              widget = {
                type = "transmission";
                url = "http://127.0.0.1:9091";
              };
            };
          }
        ];
      }
    ];
    widgets = [
      {
        resources = {
          cpu = true;
          memory = true;
          disk = "/";
        };
      }
      {
        datetime = {
          locale = "en-NZ";
        };
      }
    ];
    bookmarks = [
      {
        "System" = [
          {
            "Cockpit" = [{abbr = "CP"; href = "http://${host}:9090";}];
          }
        ];
      }
      {
        "Media" = [
          {
            "Jellyfin" = [{abbr = "JF"; href = "http://${host}:8096";}];
          }
        ];
      }
      {
        "Downloads" = [
          {
            "Transmission" = [{abbr = "TR"; href = "http://${host}:9091";}];
          }
        ];
      }
    ];
  };

  # Reverse proxy homepage on port 80
  services.nginx = {
    enable = true;
    virtualHosts."_" = {
      listen = [{addr = "0.0.0.0"; port = 80;}];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8082";
        proxyWebsockets = true;
      };
    };
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    rocmPackages.rocm-smi
    nvtopPackages.amd
    pkgsRocm.blender
    jellyfin-desktop
  ];

  fonts = {
    packages = with pkgs; [
      julia-mono
    ];
    fontconfig.defaultFonts = {
      monospace = [ "Julia Mono" ];
    };
  };

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall = {
    enable = false;
    allowedUDPPorts = [ 9 ];
  };

  programs.nix-ld.enable = true;

  #  environment.variables = {
  #      NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
  #        pkgs.stdenv.cc.cc
  #      ];
  #      NIX_LD = lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker";
  #  };

  programs.nixvim.defaultEditor = true;

  programs.tmux = {
    enable = true;
    keyMode = "vi";
    plugins = [
      pkgs.tmuxPlugins.catppuccin
      pkgs.tmuxPlugins.continuum
    ];
  };

  users.defaultUserShell = pkgs.zsh;

  programs.zsh = {
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
  };

  boot.supportedFilesystems = [ "ntfs" ];

  #auto delete

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

}
