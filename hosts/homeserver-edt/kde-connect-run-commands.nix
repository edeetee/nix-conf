# The KDE Connect "run commands" this box offers to a paired phone.
#
# Split out from kde.nix because it is the one setting with no plasma-manager
# option (upstream tracks an app module in issue #398) and with a format that
# has to be got exactly right, so it is worth being able to evaluate on its own:
#
#   nix eval --raw --impure --expr 'let f = builtins.getFlake (toString ./.); in
#     (import ./hosts/homeserver-edt/kde-connect-run-commands.nix
#       { lib = f.inputs.nixpkgs.lib; }).value'
#
# Why it is not just JSON: kdeconnect keeps these in a KConfig file under the
# *remote device's* directory (~/.config/kdeconnect/<device-id>/, the id that
# appears in trusted_devices), as a Qt byte-array literal holding JSON, itself
# embedded in an INI string value. KDE writes it like this:
#
#   commands="@ByteArray({\"uuid\":{\"command\":\"...\",\"name\":\"...\"}})"
#
# i.e. a quoted @ByteArray(...) whose every inner quote is backslash-escaped.
# This file is installed into each device directory by kde.nix. If it ever goes
# back through plasma-manager's `configFile` instead, it needs
# `escapeValue = false`: KDE's own escaping must *not* be applied on top of
# this value, and the default escaping doubles the backslashes — at which point
# the phone sees no commands at all.
{ lib }:
let
  # name -> shell command. Ids are derived below rather than pasted in: the
  # phone treats them as opaque keys, and hand-copied UUIDs are how this kind of
  # file rots.
  commands = {
    "shutdown" = "shutdown now";
    "Jellyfin TV" = "systemctl --user start jellyfin-desktop";
    "Jellyfin TV (stop)" = "systemctl --user stop jellyfin-desktop";
  };

  # KDE's own ids have the shape 8_4_4_4_12 below an md5, e.g.
  # a59e8c25_377f_469e_886b_413400a1307e.
  mkId =
    name:
    let
      h = builtins.hashString "md5" name;
      s = builtins.substring;
    in
    "${s 0 8 h}_${s 8 4 h}_${s 12 4 h}_${s 16 4 h}_${s 20 12 h}";

  json = builtins.toJSON (
    lib.mapAttrs' (
      name: command:
      lib.nameValuePair (mkId name) {
        inherit name command;
      }
    ) commands
  );

  # The exact value KDE Connect stores: a quoted @ByteArray whose inner quotes
  # are backslash-escaped.
  value = "\"@ByteArray(${lib.replaceStrings [ "\"" ] [ "\\\"" ] json})\"";
in
{
  inherit commands json value;

  # The whole file, ready to install into each device directory.
  file = ''
    [General]
    commands=${value}
  '';
}
