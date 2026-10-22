# Default handler for magnet: URLs → the homeserver's Transmission daemon.
#
# Clicking a magnet link anywhere on the Mac (Safari, Chrome, Arc, Raycast, …)
# then adds the torrent with `transmission-remote -a`, the same call the
# `torrents` alias in ../configuration.nix makes. Firefox keeps its own registry
# and needs `network.protocol-handler.external.magnet = true` (and
# `…warn-external.magnet = false`) in about:config before it will delegate.
#
# How the pieces fit:
#   magnet.applescript  — `on open location`, receives the URL from LaunchServices
#   magnet-add.sh       — the actual `transmission-remote -a` + notification
#   this file           — builds the .app bundle from the AppleScript, injects the
#                         CFBundleURLTypes declaration that makes the bundle
#                         eligible to *be* a magnet: handler, ad-hoc signs it,
#                         registers it with LaunchServices and makes it default.
#
# It has to be an AppleScript app rather than a shell-script bundle: a clicked
# URL arrives as a kAEGetURL Apple Event, not as argv (checked — a script bundle
# is launched with no arguments at all). See magnet.applescript.
#
# Undo: pick another handler in Finder → Get Info → "Open with", or
#   osascript -l JavaScript -e 'ObjC.import("CoreServices");
#     $.LSSetDefaultHandlerForURLScheme("magnet", "com.apple.Safari")'
{ config, lib, pkgs, ... }:
let
  appName = "Add to Transmission";
  appPath = "${config.home.homeDirectory}/Applications/${appName}.app";
  bundleId = "nz.edt.magnet-transmission";

  # Rebuild the bundle only when the AppleScript (or this descriptor) changes;
  # rebuilding on every switch would churn the bundle LaunchServices and a Dock
  # pin point at.
  sourceHash = builtins.hashString "sha256" (
    builtins.readFile ./magnet-handler/magnet.applescript
    + bundleId
  );

  plist = "${appPath}/Contents/Info.plist";
  pb = "/usr/libexec/PlistBuddy";
  lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
in
{
  # Not in the nix store on purpose: editing this script takes effect on the next
  # click, with no rebuild of the bundle.
  home.file.".local/bin/magnet-add".source = ./magnet-handler/magnet-add.sh;

  # duti is the dependable way to write the per-user handler: the raw
  # LSSetDefaultHandlerForURLScheme call silently does nothing on current macOS
  # when another app (qBittorrent is installed here) also claims magnet.
  home.packages = [ pkgs.duti ];

  home.activation.magnetHandler = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    APP=${lib.escapeShellArg appPath}
    STAMP="$APP/Contents/Resources/source.sha256"

    if [ "$(/usr/bin/cat "$STAMP" 2>/dev/null)" != "${sourceHash}" ]; then
      echo "magnet handler: building $APP"
      /bin/rm -rf "$APP"
      /bin/mkdir -p "$(/usr/bin/dirname "$APP")"
      /usr/bin/osacompile -o "$APP" ${./magnet-handler/magnet.applescript}

      /usr/bin/printf '%s\n' ${lib.escapeShellArg bundleId} > "$STAMP".tmp
      # CFBundleURLTypes is what makes this bundle a candidate magnet: handler;
      # osacompile does not emit it. PlistBuddy rather than `plutil -json`
      # because the latter is a newer macOS than the Macs this must run on.
      ${pb} -c "Set :CFBundleIdentifier ${bundleId}" ${plist}
      ${pb} -c "Set :CFBundleName ${lib.escapeShellArg appName}" ${plist}
      ${pb} -c "Delete :CFBundleURLTypes" ${plist} >/dev/null 2>&1 || true
      ${pb} -c "Add :CFBundleURLTypes array" ${plist}
      ${pb} -c "Add :CFBundleURLTypes:0 dict" ${plist}
      ${pb} -c "Add :CFBundleURLTypes:0:CFBundleURLName string magnet" ${plist}
      ${pb} -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" ${plist}
      ${pb} -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string magnet" ${plist}

      # Modifying a bundle invalidates its signature; on Apple Silicon an
      # unsigned/edited bundle can be refused by LaunchServices.
      /usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || true
      /bin/mv -f "$STAMP".tmp "$STAMP"

      ${lsregister} -f "$APP"

      # Two attempts, both best-effort: a non-zero exit here would abort the
      # whole home-manager activation, and this is a convenience, not a service.
      # duti writes the LSHandlers record; the direct LS call covers the case
      # where duti's guess at what "magnet" is (scheme vs extension) is wrong.
      ${pkgs.duti}/bin/duti -s ${bundleId} magnet all >/dev/null 2>&1 || true
      /usr/bin/osascript -l JavaScript -e \
        "ObjC.import('CoreServices'); \$.LSSetDefaultHandlerForURLScheme('magnet', '${bundleId}')" \
        >/dev/null 2>&1 || true
    fi
  '';
}
