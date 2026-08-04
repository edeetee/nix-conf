# Pi coding agent — NixOS module for homeserver-edt
# Installs pi and configures it with DeepSeek API key from sops
{ config, pkgs, lib, ... }:
let
  nixConfDir = "/home/edeetee/dev/nix-conf";
  piAgentDir = "${nixConfDir}/hosts/homeserver-edt/pi-agent";
in
{
  # Expose DeepSeek API key from sops secret as an environment variable
  sops.secrets.deepseek-api-key = {
    owner = "edeetee";
    group = "users";
  };

  # Make DEEPSEEK_API_KEY available in all login shells.
  # NixOS /etc/profile only sources /etc/profile.local, not profile.d, so we
  # create that hook and put the actual export in profile.d.
  environment.etc."profile.d/deepseek-api-key.sh" = {
    text = ''
      export DEEPSEEK_API_KEY="$(< ${config.sops.secrets.deepseek-api-key.path})"
    '';
    mode = "0444";
  };
  environment.etc."profile.local" = {
    text = ''
      for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done
    '';
    mode = "0444";
  };

  # Out-of-store symlink so pi can write settings back (e.g. /settings changes)
  systemd.tmpfiles.rules = [
    "L+ /home/edeetee/.pi/agent - edeetee users - ${piAgentDir}"
  ];

  # Install pi globally via npm. Runs once per boot if pi is not yet installed.
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
