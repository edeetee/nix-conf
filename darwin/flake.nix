{
	description = "Example Darwin system flake";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		nix-darwin.url = "github:LnL7/nix-darwin";
		nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

		nixvim = {
			url = "github:nix-community/nixvim";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = inputs@{ self, nix-darwin, nixpkgs, nixvim, ...}:
		let
			configuration = { pkgs, ... }: {
				# List packages installed in system profile. To search by name, run:
				# $ nix-env -qaP | grep wget

				environment.variables.EDITOR = "nvim";

				# Auto upgrade nix package and the daemon service.
				services.nix-daemon.enable = true;
				# nix.package = pkgs.nix;

				# Necessary for using flakes on this system.
				nix.settings.experimental-features = "nix-command flakes";

				environment.shellAliases = {
					nixrs = "darwin-rebuild switch --flake ~/dev/nix-conf/darwin/";
					ssh="kitty +kitten ssh";
					"'?'"="gh copilot";
				};

				# Create /etc/zshrc that loads the nix-darwin environment.
				programs.zsh = {
					enableSyntaxHighlighting = true;
				};

				# programs.fish.enable = true;
				nix.gc = {
					automatic = true;
					options = "--delete-older-than 30d";
				};

				system.defaults = {
					NSGlobalDomain = {
						ApplePressAndHoldEnabled = false;
						AppleScrollerPagingBehavior = true;
						AppleShowAllExtensions = true;
						AppleShowAllFiles = true;
						InitialKeyRepeat = 15;
						KeyRepeat = 12;
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
				};

				# Set Git commit hash for darwin-version.
				system.configurationRevision = self.rev or self.dirtyRev or null;

				# Used for backwards compatibility, please read the changelog before changing.
				# $ darwin-rebuild changelog
				system.stateVersion = 4;

				# The platform the configuration will be used on.
				nixpkgs.hostPlatform = "aarch64-darwin";
			};
		in
			{
			# Build darwin flake using:
			# $ darwin-rebuild build --flake .#simple
			darwinConfigurations."Edwards-MacBook-Max" = nix-darwin.lib.darwinSystem {
				modules = [ 
					configuration 
					nixvim.nixDarwinModules.nixvim 
					../neovim
					../common-configuration.nix
				];
			};

			# Expose the package set, including overlays, for convenience.
			darwinPackages = self.darwinConfigurations."Edwards-MacBook-Max".pkgs;
		};
}
