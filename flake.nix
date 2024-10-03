{
	inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
	inputs.flamenco.url = "path:/home/edeetee/dev/flamenco-nix";
	inputs.nixvim = {
		url = "github:nix-community/nixvim";
		inputs.nixpkgs.follows = "nixpkgs";
	};
	inputs.comfyui.url = "path:/home/edeetee/dev/comfyui-nix";

	outputs = 
	{ self, nixpkgs, nixvim, flamenco, comfyui, ... }@attrs: 
	let

		flake-conf = {pkgs, ...}: 
		let
			optiphonic-comfyui = pkgs.writeShellScriptBin "optiphonic-comfyui" ''
				#!/usr/bin/env bash
				${pkgs.udisks}/bin/udisksctl mount -b /dev/disk/by-label/OPTIPHONIC
				OPTIPHONIC=$(${pkgs.util-linux}/bin/lsblk /dev/sdb1 -o mountpoints -lpn)
				${comfyui.packages.${pkgs.stdenv.hostPlatform.system}.comfyui}/bin/comfyui $OPTIPHONIC/AI/ComfyUI --listen 0.0.0.0
			'';
		in
		{
			environment.shellAliases = {
				nrebuild = "${self}/rebuild.sh";
			};

			# systemd.services.comfyui = {
			# 	description = "Mount OPTIPHONIC drive and run ComfyUI";
			# 	after = [ "network.target" ];
			# 	wantedBy = [ "multi-user.target" ];
			# 	serviceConfig = {
			# 		Type = "simple";
			# 		ExecStart = "${optiphonic-comfyui}/bin/optiphonic-comfyui";
			# 		ExecStop = "${pkgs.udisks}/bin/udisksctl unmount -b /dev/disk/by-label/OPTIPHONIC";
			# 	};
			# };

		};
	in 
	{


		nixosConfigurations.nixos-desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			specialArgs = { inherit attrs; };
			modules = [ 
				./configuration.nix 
				nixvim.nixosModules.nixvim 
				./ati-server-hardware-configuration.nix 
				flamenco.nixosModules.flamenco 
				./neovim
				flake-conf
			];
		};
	};
}
