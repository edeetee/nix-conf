# Services for rpi3b
#
# The homeserver runs cockpit/jellyfin/transmission/nginx/homepage — none of
# that belongs here. zerotierone lives in networking.nix to mirror the
# homeserver layout.
#
# The deepseek agent harness (dsh, deepseek-ai/deepseek-harness) will be
# imported here as its own module. The LAN overlay is validated and lives at
# darwin/pi-agent/dsh/lan.patch.yml — it moves over unchanged (host 0.0.0.0,
# port 9000). Run command (see that dir's README for full notes):
#   node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web \
#     --patch darwin/pi-agent/dsh/lan.patch.yml --no-open
# For now this file is intentionally empty.

{
}
