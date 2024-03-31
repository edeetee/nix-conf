# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:
{

# Use the systemd-boot EFI boot loader.
	boot.loader.systemd-boot.enable = true;
	boot.loader.efi.canTouchEfiVariables = true;
	boot.loader.systemd-boot.configurationLimit = 5;

	networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.
		networking.nameservers = ["1.1.1.1" "8.8.8.8"];
	networking.hostName = "nixos-desktop";
	time.timeZone = "Pacific/Auckland";

#services.devmon.enable = true;
#services.gvfs.enable = true; 
	services.udisks2.enable = true;

# Enable the X11 windowing system.
	services.xserver = {
		enable = true;
#displayManager.gdm.enable = true;
#displayManager.gdm.autoSuspend = false;

#desktopManager.gnome.enable = true;
	};

	services.zerotierone = {
		enable = true;
		joinNetworks = [
			"56374ac9a48a755c"
		];
	};

	programs.direnv.enable = true;

	services.avahi.enable = true;
	services.avahi.publish.enable = true;
	services.avahi.publish.userServices = true;
	services.avahi.publish.addresses = true;
	services.avahi.publish.domain = true;
	services.avahi.nssmdns4 = true;
	services.avahi.publish.workstation = true; # ADDED TO DESKTOP MACHINES


		security.polkit.extraConfig = ''
		polkit.addRule(function(action, subject) {
				if (action.id == "org.freedesktop.login1.suspend" ||
						action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
						action.id == "org.freedesktop.login1.hibernate" ||
						action.id == "org.freedesktop.login1.hibernate-multiple-sessions")
				{
				return polkit.Result.NO;
				}
				});
	'';

# Define a user account. Don't forget to set a password with ‘passwd’.
	users.users.edeetee = {
		isNormalUser = true;
		extraGroups = [ "wheel" "video" "networkmanager" "gdm"]; # Enable ‘sudo’ for the user.
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
			nvtop-amd
			blender-hip
			screen
	];


	fonts = {
		packages = with pkgs; [
			julia-mono
		];
		fontconfig.defaultFonts = {
			monospace = ["Julia Mono"];
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
	networking.firewall.enable = false;



## DO NOT CHANGE, used for backwards compatibility and upgrade logic
	system.stateVersion = "23.11"; # Did you read the comment?

	programs.nix-ld.enable = true;

#  environment.variables = {
#      NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
#        pkgs.stdenv.cc.cc
#      ];
#      NIX_LD = lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker";
#  };

	programs.nixvim.defaultEditor = true;

	programs.zsh = {
		enable = true;
		enableCompletion = true;
		autosuggestions.enable = true;
		syntaxHighlighting.enable = true;

		shellAliases = {
			l = "${pkgs.eza}/bin/eza --icons";
			ll = "l -l";
			update = "sudo nixos-rebuild switch";
			v = "nvim";
		};
		promptInit = ''
			eval "$(${pkgs.starship}/bin/starship init zsh)"
			'';


	};
	users.defaultUserShell = pkgs.zsh;

	nix.settings.experimental-features = "nix-command flakes";

	boot.supportedFilesystems = [ "ntfs" ];

	nixpkgs.config.allowUnfree = true;

#auto delete
	nix.settings.auto-optimise-store = true;
	nix.gc = {
		automatic = true;
		randomizedDelaySec = "14m";
		dates = "weekly";
		options = "--delete-older-than 30d";
	};


	boot.binfmt.emulatedSystems = [ "aarch64-linux" ];


#NETWORK SHARE

	users.users.render = {
		isNormalUser = true;
		extraGroups = [ "video" "networkmanager"]; # Enable ‘sudo’ for the user.
			packages = with pkgs; [
			];
	};



	services.flamenco.enable = true;

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
		securityType = "user";
		extraConfig = ''
			workgroup = WORKGROUP
			server string = smbnix
			netbios name = smbnix
			security = user 
#use sendfile = yes
#max protocol = smb2
# note: localhost is the ipv6 localhost ::1
#hosts allow = 192.168.1. 127.0.0.1 localhost
#hosts deny = 0.0.0.0/0
			guest account = render
			map to guest = bad user
			'';
		shares = {
			public = {
				path = "/mnt/render";
				browseable = "yes";
				"read only" = "no";
				"guest ok" = "yes";
				"create mask" = "0666";
				"directory mask" = "0777";
				"force user" = "render";
#      "force group" = "groupname";
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
