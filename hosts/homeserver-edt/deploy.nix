# Deploying this configuration from another machine, without a password prompt.
#
# `nixup` (packages.nix) is a shell alias *on this host*: it runs
# `sudo nixos-rebuild switch`, so it needs a TTY to type the sudo password into.
# That makes it unusable from another machine — or from an agent working on one.
# This module adds the missing piece: a root-only wrapper around the switch,
# allowed by a single narrow NOPASSWD sudo rule, so
#
#   scripts/deploy-server.sh          # on the Mac
#
# can push, pull and switch end to end.
#
# SECURITY, read before keeping this. A NOPASSWD rule for a command that
# installs a configuration from a *user-writable* directory is equivalent to
# passwordless root for that user: the wrapper is an immutable store path, but
# the flake it installs (/home/edeetee/dev/nix-conf) is owned by edeetee, so
# anyone who can ssh as edeetee can become root by editing the configuration
# and running `sudo nixos-deploy`. This is a single-user box and the trade is
# deliberate; if it is not wanted, delete this module and use `push-server`
# from the Mac instead — that prompts for the password and needs no sudoers
# change. The narrow-looking alternative (matching nixos-rebuild's arguments in
# sudoers) does not help: sudoers argument matching is bypassable with `-u` and
# wildcards, and the escalation above is inherent, not in the argument list.
#
# The pull is deliberately NOT part of this wrapper: it runs as root, and git
# on a repository owned by edeetee trips git's dubious-ownership check (and
# would leave root-owned objects in the checkout). Callers pull as edeetee
# first — scripts/deploy-server.sh does, and so does `nixup`.
{ config, pkgs, ... }:
let
  # config.system.build.nixos-rebuild, not pkgs.nixos-rebuild: this is the exact
  # nixos-rebuild the running system ships, so it takes the same arguments
  # `nixup` uses.
  nixos-deploy = pkgs.writeShellScriptBin "nixos-deploy" ''
    set -euo pipefail
    exec ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch --flake /home/edeetee/dev/nix-conf/
  '';
in
{
  environment.systemPackages = [ nixos-deploy ];

  security.sudo.extraRules = [
    {
      users = [ "edeetee" ];
      commands = [
        {
          command = "${nixos-deploy}/bin/nixos-deploy";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
