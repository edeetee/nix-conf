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

  # ease of use
  services.flatpak.enable = true;

  environment.shellAliases = {
    nixrs = "sudo nixos-rebuild switch --flake ~/dev/nix-conf/";
  };

  # secret service
  services.gnome.gnome-keyring.enable = true;

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
