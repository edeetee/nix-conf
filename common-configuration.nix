{ config, pkgs, lib, ... }:
{
    # SHELL CONFIGURATION
	environment.systemPackages =
		with pkgs; [ 
			nixfmt
			nil
			nodejs
			bun
			git-lfs
			docker-compose
			docker
			yarn
			go
			jujutsu
		];
	
	fonts.packages = with pkgs; [
			julia-mono
	];

	environment.shellAliases = {
			l = "${pkgs.eza}/bin/eza --icons";
			ll = "l -l";
			v = "nvim";
			gemcli = "npx https://github.com/google-gemini/gemini-cli";
			gcam = "git commit -a -m";
			gp = "git push";
			gpf = "git push --force-with-lease";
			gpnv = "git push --no-verify";
			gpfnv = "git push --force-with-lease --no-verify";
	};

	environment.interactiveShellInit = ''
		export GOPATH="$HOME/go"
		export PATH="$GOPATH/bin:$PATH"

		function gpp() {
			git push origin "HEAD:$1"
		}

		function gppf() {
			git push --force-with-lease origin "HEAD:$1"
		}

		function gppnv() {
			git push --no-verify origin "HEAD:$1"
		}

		function gppfnv() {
			git push --force-with-lease --no-verify origin "HEAD:$1"
		}
	'';

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
