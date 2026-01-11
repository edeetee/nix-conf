{ config, pkgs, lib, ... }:
{
    # SHELL CONFIGURATION
	environment.systemPackages =
		with pkgs; [ 
			nixfmt-classic
			nil
			nodejs
			bun
			git-lfs
			docker-compose
			docker
			yarn
			go
			jujutsu
			lazyjj
			jjui
			git-absorb
			ripgrep
			uv
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
			stack-pr = "uv tool run stack-pr";
	};

	environment.interactiveShellInit = ''
		export GOPATH="$HOME/go"
		export PATH="$GOPATH/bin:$PATH"

		function gop() {
			git push origin "HEAD:$1"
		}

		function gopf() {
			git push --force-with-lease origin "HEAD:$1"
		}

		function gopnv() {
			git push --no-verify origin "HEAD:$1"
		}

		function gopfnv() {
			git push --force-with-lease --no-verify origin "HEAD:$1"
		}
	'';

	programs.direnv.enable = true;

	programs.zsh = {
		enable = true;
		enableCompletion = true;

		promptInit = ''
			eval "$(${pkgs.starship}/bin/starship init zsh)"
			PATH="$HOME/.cargo/bin:$PATH"
			source <(COMPLETE=zsh jj)
			'';
	};

	# NIX CONFIGURATION
	# nix.settings.auto-optimise-store = true;

	nixpkgs.config.allowUnfree = true;
}
