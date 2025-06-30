{
	description = "Example Darwin system flake";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
		nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-25.05";
		nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

		home-manager = {
			url = "github:nix-community/home-manager/release-25.05";
			inputs.nixpkgs.follows = "nixpkgs";
		};

		nixvim = {
			url = "github:nix-community/nixvim";
			inputs.nixpkgs.follows = "nixpkgs";
		};
		nix-homebrew.url = "github:zhaofengli-wip/nix-homebrew";

		homebrew-core = {
			url = "github:homebrew/homebrew-core";
			flake = false;
		};
		homebrew-cask = {
			url = "github:homebrew/homebrew-cask";
			flake = false;
		};
		deskflow-tap = {
			url = "https://github.com/deskflow/homebrew-tap";
			flake = false;
		};
	};

	outputs = inputs@{ self, nix-darwin, nixpkgs, home-manager, nixvim, homebrew-core, homebrew-cask, nix-homebrew, deskflow-tap, ...}:
		let
			configuration = {user}: { pkgs, ... }: {
				# List packages installed in system profile. To search by name, run:
				# $ nix-env -qaP | grep wget

				environment.variables.EDITOR = "nvim";

				nix-homebrew = {
					enable = true;
					# enableRosetta = true;
					user = user;

					taps = {
						"homebrew/homebrew-core" = homebrew-core;
						"homebrew/homebrew-cask" = homebrew-cask;
						# "deskflow/homebrew-tap" = deskflow-tap;
					};

					autoMigrate = true;
				};

				homebrew = {
					enable = true;
					onActivation = {
						cleanup = "uninstall";
					};
					taps = ["deskflow/homebrew-tap" "homebrew/cask"];
					brews = ["yt-dlp" "uv" "gh" "ffmpeg" ];
					casks = [
						"kitty" 
						"hot" 
						"stats"
						"raycast"
						"ghostty"
						# "monitorcontrol"
						"betterdisplay"
					];
				};


				# Enable Touch ID support
				security.pam.services.sudo_local.touchIdAuth = true;

				# nix.package = pkgs.nix;

				# Necessary for using flakes on this system.
				# nix.settings.experimental-features = "nix-command flakes";

				environment.shellAliases = {
					nixrs = "sudo darwin-rebuild switch --flake ~/dev/nix-conf/darwin/";
					nixe = "v ~/dev/nix-conf/";
					nixcd = "cd ~/dev/nix-conf/";
					ssh="kitty +kitten ssh";
					"'?'"="gh copilot";
				};

				# programs.starship.enable = true;

				# Create /etc/zshrc that loads the nix-darwin environment.
				programs.zsh = {
					enableSyntaxHighlighting = true;
					interactiveShellInit = ''
						eval "$(${pkgs.starship}/bin/starship init zsh)"		
					'';
				};

				# determinate nix
				nix.enable = false;

				# programs.fish.enable = true;
				# nix.gc = {
					# automatic = true;
					# options = "--delete-older-than 30d";
				# };

				nix.extraOptions = ''
		extra-platforms = x86_64-darwin aarch64-darwin
				'';

				system.defaults = {
					NSGlobalDomain = {
						ApplePressAndHoldEnabled = false;
						AppleScrollerPagingBehavior = true;
						AppleShowAllExtensions = true;
						AppleShowAllFiles = true;
						InitialKeyRepeat = 10;
						KeyRepeat = 2;
						NSWindowResizeTime = .05;
					};

					finder = {
						FXDefaultSearchScope = "SCcf";
						FXEnableExtensionChangeWarning = false;
						FXPreferredViewStyle = "clmv";
						FXRemoveOldTrashItems = true;
						NewWindowTarget = "Other";
						NewWindowTargetPath = "file:///Users/edeetee/dev";
					};

					dock = {
						autohide = true;
						mru-spaces = false;
					};
				};


				# Set Git commit hash for darwin-version.
				system.configurationRevision = self.rev or self.dirtyRev or null;

				# Used for backwards compatibility, please read the changelog before changing.
				# $ darwin-rebuild changelog
				system.stateVersion = 4;

				# The platform the configuration will be used on.
				nixpkgs.hostPlatform = "aarch64-darwin";

				system.primaryUser = user;
			};
		in
			{
			# Build darwin flake using:
			# $ darwin-rebuild build --flake .#simple
			darwinConfigurations."Edwards-MacBook-Max" = nix-darwin.lib.darwinSystem {
				modules = [ 
					nix-homebrew.darwinModules.nix-homebrew
					(configuration { user = "edeetee"; })
					nixvim.nixDarwinModules.nixvim 
					../neovim
					../common-configuration.nix
					home-manager.darwinModules.home-manager
					{
						home-manager.useGlobalPkgs = true;
						home-manager.useUserPackages = true;
						home-manager.users.edeetee = import ./home.nix {
							homeDirectory = "/Users/edeetee";
							username = "edeetee";
						};
						home-manager.backupFileExtension = "home-manager-backup";
					}
				];
			};

			darwinConfigurations."Edwards-MacBook-Air" = nix-darwin.lib.darwinSystem {
				modules = [
					nix-homebrew.darwinModules.nix-homebrew
					(configuration { user = "edt"; })
					nixvim.nixDarwinModules.nixvim
					../neovim
					../common-configuration.nix
					home-manager.darwinModules.home-manager
					{
						home-manager.useGlobalPkgs = true;
						home-manager.useUserPackages = true;
						home-manager.users.edt = import ./home.nix { 
							homeDirectory = "/Users/edt";
							username = "edt";
						};
						home-manager.backupFileExtension = "home-manager-backup";
					}
				];
			};


			# Expose the package set, including overlays, for convenience.
			darwinPackages = self.darwinConfigurations."Edwards-MacBook-Max".pkgs;
		};
}
