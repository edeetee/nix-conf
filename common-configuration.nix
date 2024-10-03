{ config, pkgs, lib, ... }:
{
      environment.systemPackages =
        [ 
            # pkgs.vim
            pkgs.nixfmt
            pkgs.nil
        ];
}
