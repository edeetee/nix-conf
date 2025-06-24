{ config, pkgs, lib, ... }:
{
    # SHELL CONFIGURATION
	environment.systemPackages =
		[ 
			pkgs.nixfmt
			pkgs.nil
		];

	environment.shellAliases = {
			l = "${pkgs.eza}/bin/eza --icons";
			ll = "l -l";
			v = "nvim";
	};

	programs.direnv.enable = true;

	programs.zsh = {
		enable = true;
		enableCompletion = true;

		promptInit = ''
			eval "$(${pkgs.starship}/bin/starship init zsh)"
			'';
	};

	# NIX CONFIGURATION
	# nix.settings.auto-optimise-store = true;

	nixpkgs.config.allowUnfree = true;
}
