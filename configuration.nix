# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').

{
  config,
  pkgs,
  lib,
  ...
}:
{
  ## DO NOT CHANGE, used for backwards compatibility and upgrade logic
  system.stateVersion = "23.11"; # Did you read the comment?

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

  environment.shellAliases = {
    nixrs = "sudo nixos-rebuild switch --flake ~/dev/nix-conf/";
  };

  networking = {
    networkmanager.enable = true; # Easiest to use and most distros use this by default.
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    hostName = "homeserver-edt";

    # not working I think
    interfaces = {
      wlp5s0 = {
        # wlp5s0 wlxd83bbf2a226d
        wakeOnLan.enable = true;
      };
    };
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

    gdm.enable = true;
  };

  services.desktopManager.gnome.enable = true;

  services.zerotierone = {
    enable = true;
    joinNetworks = [
      "56374ac9a48a755c"
    ];
  };

  # jellyfin
  # services.jellyfin = {
  #   enable = true;
  #   openFirewall = true;
  # };
  # services.seerr = {
  #   enable = true;
  #   openFirewall = true;
  # };
  # services.sonarr = {
  #   enable = true;
  #   openFirewall = true;
  # };
  # services.radarr = {
  #   enable = true;
  #   openFirewall = true;
  # };

  ## Enable wake on bluetooth controllers
  services.udev.extraRules = ''
    # Enable wake for all Bluetooth USB controllers
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="e0", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
  '';

  ## start steam in gamepad mode when the mode button is pressed on the controller
  services.triggerhappy = {
    enable = true;
    # bindings = [
    #   {
    #     keys = [ "BTN_MODE" ];
    #     cmd = "${lib.getExe pkgs.steam} -gamepadui";
    #   }
    # ];
    user = "root";
    extraConfig = ''
      # Start Steam in Gamepad Mode when the mode button is pressed on the controller
      BTN_MODE 1 systemctl --machine=edeetee@.host --user start steam-on-demand.service
    '';
  };

  systemd.user.services.steam-on-demand = {
    enable = true;
    # Description = "Steam Gamepad UI (on-demand)";

    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.steam} -gamepadui";
      User = "edeetee";
      Environment = "DISPLAY=:0";
    };
  };

  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.userServices = true;
    publish.addresses = true;
    publish.domain = true;
    nssmdns4 = true;
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
      "gdm"
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

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
    gamescopeSession.enable = true;
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

  #NETWORK SHARE

  users.users.render = {
    isNormalUser = true;
    # isSystemUser = true;
    group = "render";
    extraGroups = [
      "video"
      "networkmanager"
      "gdm"
      "wheel"
    ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
    ];
  };

  users.groups.render = {
  };

  # services.flamenco = {
  #   enable = true;
  #   role = [
  #     "manager"
  #     "worker"
  #   ];
  #   user = "render";
  #   listen = {
  #     ip = "";
  #     port = 8080;
  #   };
  #   managerConfig = {
  #     shared_storage_path = "/mnt/render";
  #     variables."blenderArgs".values = [
  #       {
  #         platform = "all";
  #         value = ''-b -y --python-expr "import bpy; c = bpy.context.preferences.addons[\"cycles\"]; cp = c.preferences; cp.compute_device_type = \"HIP\"; print(cp.compute_device_type); cp.get_devices(); [print(x[\"name\"], x[\"use\"]) for x in cp.devices]; print(bpy.data.scenes[0].render.engine); (obj.select_set(True) for obj in bpy.context.scene.objects); bpy.ops.object.simulation_nodes_cache_bake(selected=True)"'';
  #       }
  #     ];
  #   };
  # };

  # systemd.services.comfyui = {
  # 	wantedBy = [ "multi-user.target" ];
  # 	after = [ "network.target" ];
  # 	serviceConfig = {
  # 		Type = "simple";
  # 		ExecStart = "${pkgs.comfyui}/bin/comfyui";
  # 	};
  # };

  services.samba-wsdd = {
    # make shares visible for Windows clients
    enable = true;
    # openFirewall = true;
  };

  # systemd.tmpfiles.rules = [
  # 	"d /mnt/OPTIPHONIC 1777 edeetee users -"
  # ];

  # fileSystems."/mnt/OPTIPHONIC" = {
  # 	fsType = "exfat";
  # 	device = "/dev/disk/by-uuid/80A1-F7DE";
  # 	options = [
  # 		"x-systemd.automount"
  # 		"nofail"
  # 		"user"
  # 		"rw"
  # 		"umask=1000"
  # 		"gid=100"
  # 	];
  # };

  # system.activationScripts = {
  # 	optiphonic_mount.text = ''
  # 		chown -R :users /mnt/OPTIPHONIC
  # 		# chmod 775 /mnt/OPTIPHONIC
  # 		'';
  # };

  services.samba = {
    enable = true;

    nmbd.enable = false;

    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "smbnix";
        # "netbios name" = "smbnix";
        "security" = "user";
        #use sendfile = yes
        #max protocol = smb2
        # note: localhost is the ipv6 localhost ::1
        #"hosts allow" = "192.168.1. 192.168.0. 127.0.0.1 localhost";
        #hosts deny = 0.0.0.0/0
        "guest account" = "render";
        "map to guest" = "bad user";

        # Performance
        "socket options" = "TCP_NODELAY SO_SNDBUF=131072 SO_RCVBUF=131072";
        "use sendfile" = "yes";
        "min receivefile size" = 16384;
        "aio read size" = 16384;
        "aio write size" = 16384;
      };

      public = {
        path = "/mnt/render";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0666";
        "directory mask" = "0777";
        "force user" = "render";
        "force group" = "render";
      };
      optiphonic = {
        path = "/mnt/OPTIPHONIC/";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "edeetee";
        "force group" = "edeetee";
      };
      edeetee = {
        path = "/home/edeetee";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "edeetee";
        "force group" = "wheel";
      };
      windows = {
        path = "/mnt/windows";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
      };

    };
  };

}
