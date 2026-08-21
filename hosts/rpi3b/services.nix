# Services for rpi3b
#
# The homeserver runs cockpit/jellyfin/transmission/nginx/homepage — none of
# that belongs here. The only service is the pi-agent harness itself
# (./pi-agent.nix), plus zerotierone which lives in networking.nix to mirror
# the homeserver layout.

{
  imports = [
    ./pi-agent.nix
  ];
}
