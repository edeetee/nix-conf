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

		
# Select internationalisation properties.

# Enable the X11 windowing system.
		services.xserver = {
				enable = true;
				displayManager.gdm.enable = true;
				displayManager.gdm.autoSuspend = false;

				desktopManager.gnome.enable = true;
		};

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
				extraGroups = [ "wheel" "video" "networkmanager"]; # Enable ‘sudo’ for the user.
						packages = with pkgs; [
						];
		};

# List packages installed in system profile. To search, run:
# $ nix search wget
		environment.systemPackages = with pkgs; [
				vim
						wget
						git
						rocmPackages.rocm-smi
						tmux
						nvtop-amd
						blender-hip
		];

		fonts = {
			packages = with pkgs; [
				julia-mono
			];
			fontconfig.defaultFonts = {
				monospace = ["Julia Mono"];
			};
		};

# https://github.com/nix-community/nixvim/tree/main
		programs.nixvim = {
				enable = true;
				defaultEditor = true;


				colorschemes.gruvbox.enable = true;
				options = {
						number = true;
						relativenumber = true;
						tabstop = 4;
						shiftwidth = 4;
						smartindent = true;
				};

				keymaps = [{
						key = " ";
						mode = "n";
						action = "<Nop>";
				}];


				globals.mapleader = " ";

				plugins = {
						lightline.enable = true;
						lsp = {
								enable = true;
								servers = {
										nil_ls.enable = true;
										rust-analyzer = {
												enable = true;
												installCargo = true;
												installRustc = true;
										};
										bashls.enable = true;
										ruff-lsp.enable = true;
								};
						};
						coq-nvim = {
								enable = true;
								autoStart = true;
								alwaysComplete = true;
						};
						persistence.enable = true;
						floaterm.enable = true;
						goyo.enable = true;
						noice.enable = true;
						which-key.enable = true;
						neogit.enable = true;
						nvim-tree = {
							enable = true;
							openOnSetup = true;
						};
						telescope.enable = true;
						#dashboard.enable = true;
						copilot-vim.enable = true;
						conform-nvim = {
								formatOnSave = {
										lspFallback = true;
										timeoutMs = 500;
								};
						};
				};

		};



# Some programs need SUID wrappers, can be configured further or are
# started in user sessions.
# programs.mtr.enable = true;
# programs.gnupg.agent = {
#   enable = true;
#   enableSSHSupport = true;
# };

# List services that you want to enable:

# Enable the OpenSSH daemon.
		services.openssh = {
				enable = true;
				settings = {
						PasswordAuthentication = false;
						KbdInteractiveAuthentication = false;
				};	
# require public key authentication for better security
		};

# Open ports in the firewall.
# networking.firewall.allowedTCPPorts = [ ... ];
# networking.firewall.allowedUDPPorts = [ ... ];
# Or disable the firewall altogether.
		networking.firewall.enable = false;

# Copy the NixOS configuration file and link it from the resulting system
# (/run/current-system/configuration.nix). This is useful in case you
# accidentally delete configuration.nix.
# system.copySystemConfiguration = true;

# This value determines the NixOS release from which the default
# settings for stateful data, like file locations and database versions
# on your system were taken. It‘s perfectly fine and recommended to leave
# this value at the release version of the first install of this system.
# Before changing this value read the documentation for this option
# (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
		system.stateVersion = "23.11"; # Did you read the comment?


#MY EDITS
				programs.nix-ld.enable = true;

#  environment.variables = {
#      NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
#        pkgs.stdenv.cc.cc
#      ];
#      NIX_LD = lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker";
#  };
		
		
		programs.zsh = {
			enable = true;
			enableCompletion = true;
			autosuggestions.enable = true;
			syntaxHighlighting.enable = true;

			shellAliases = {
    			ll = "ls -l";
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

		nix.gc = {
				automatic = true;
				randomizedDelaySec = "14m";
				options = "--delete-older-than 10d";
		};

		boot.initrd.kernelModules = ["amdgpu"];
		services.xserver.videoDrivers = [ "amdgpu" ];
		hardware.opengl.extraPackages = with pkgs; [
				rocm-opencl-icd
						rocm-opencl-runtime
		];

		boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

		hardware.opengl.driSupport = true;
# For 32 bit applications
		hardware.opengl.driSupport32Bit = true;
		hardware.opengl.enable = true;

#auto delete
		nix.settings.auto-optimise-store = true;

# HIP for amd
		systemd.tmpfiles.rules = [
				"L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
						"d /mnt/render 0770 render video - -"
		];

#NETWORK SHARE

		users.users.render = {
				isNormalUser = true;
				extraGroups = [ "video" "networkmanager"]; # Enable ‘sudo’ for the user.
						packages = with pkgs; [
						];
		};

		services.samba-wsdd = {
# make shares visible for Windows clients
				enable = true;
# openFirewall = true;
		};

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
						hosts allow = 192.168.1. 127.0.0.1 localhost
						hosts deny = 0.0.0.0/0
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
				};
		};

}
