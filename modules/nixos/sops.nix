# sops-nix secret management — NixOS only
# See .sops.yaml for key configuration
{ ... }:
{
  sops = {
    defaultSopsFile = ../../hosts/homeserver-edt/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}
