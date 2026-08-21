# Pi coding agent — minimal module for rpi3b
#
# Mirrors modules/nixos/pi.nix on the homeserver, minus sops: a fresh Pi
# can't decrypt repo secrets until its SSH host key is added to .sops.yaml,
# so the API key is provisioned out-of-band once instead:
#
#   sudo install -o edeetee -g users -m 0400 /tmp/deepseek-key /run/secrets/deepseek-api-key
#
# Upgrade path to match the server: add the Pi's age key (from its host key)
# to .sops.yaml, create the secret, then switch to
# `config.sops.secrets.deepseek-api-key` like modules/nixos/pi.nix does.

{ config, pkgs, lib, ... }:
let
  nixConfDir = "/home/edeetee/dev/nix-conf";
  piAgentDir = "${nixConfDir}/hosts/rpi3b/pi-agent";
in
{
  # Make DEEPSEEK_API_KEY available in all login shells. Same
  # /etc/profile.local hook trick as the homeserver (NixOS doesn't source
  # /etc/profile.d otherwise).
  environment.etc."profile.d/deepseek-api-key.sh" = {
    text = ''
      export DEEPSEEK_API_KEY="$(< /run/secrets/deepseek-api-key)"
    '';
    mode = "0444";
  };
  environment.etc."profile.local" = {
    text = ''
      for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done
    '';
    mode = "0444";
  };

  # Config files symlinked from the repo (edits write back and sync via git).
  # Runtime state (sessions/, auth.json, models-store.json, npm/, installed
  # extensions) lives in the real ~/.pi/agent dir, never in the repo — same
  # pattern as darwin/home.nix on the Mac.
  systemd.tmpfiles.rules = [
    "L+ /home/edeetee/.pi/agent/settings.json - edeetee users - ${piAgentDir}/settings.json"
    "L+ /home/edeetee/.pi/agent/models.json - edeetee users - ${piAgentDir}/models.json"
  ];

  # Install pi globally via npm. Runs once per boot if pi is not yet installed.
  # (Same pattern as the homeserver's pi.nix.)
  systemd.services.pi-install = {
    description = "Install Pi coding agent globally via npm";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.nodejs pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "edeetee";
      Group = "users";
      Environment = [
        "HOME=/home/edeetee"
        "npm_config_prefix=/home/edeetee/.npm-global"
        "npm_config_ignore_scripts=true"
      ];
      ExecCondition = ''${pkgs.bash}/bin/bash -c "! command -v pi &>/dev/null"'';
      ExecStart = "${pkgs.nodejs}/bin/npm install -g @earendil-works/pi-coding-agent";
      RemainAfterExit = true;
    };
  };
}
