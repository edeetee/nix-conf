# Plezy opens fullscreen — via a KWin script.
#
# Why a script and not a CLI flag or a setting: Plezy is a Flutter app with no
# fullscreen option on its command line and (at 2.23.0) no stored window-state
# key in `shared_preferences.json`, so nothing in its own configuration can say
# "start fullscreen". On Wayland the only layer that can force it is the
# compositor, and KWin's scriptable API is the one that does not require
# hand-writing a `kwinrulesrc` (whose rule enums are undocumented enough that a
# wrong value fails silently).
#
# The script is installed into `$out/share/kwin/scripts` (visible to KWin through
# XDG_DATA_DIRS) and carries `EnabledByDefault: true` in its metadata, so no
# kwinrc key is needed — which matters here: under the Bigscreen session KWin
# writes and reads `~/.config/plasma-bigscreen/kwinrc`, not `~/.config/kwinrc`
# (that directory holds exactly the four files KDE's mediacenter profile owns),
# so a flag written to the ordinary kwinrc would be silently ignored by the TV
# session. Enablement still takes effect at KWin start, i.e. at session start;
# for the *running* session load it once over D-Bus:
#
#   busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
#     loadScript s /run/current-system/sw/share/kwin/scripts/plezy-fullscreen/contents/code/main.js
#   busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting start
#
# (note the lowercase `org.kde.kwin.Scripting`; the capitalised form does not
# exist and answers "No such interface").
#
# The app id was measured, not guessed: `workspace.windowList()` reports
# `com.edde746.plezy` for both the window and its caption.
{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.runCommand "plezy-fullscreen-kwin-script" { } ''
      dir=$out/share/kwin/scripts/plezy-fullscreen
      mkdir -p $dir/contents/code
      cat > $dir/metadata.json <<'JSON'
      {
        "KPlugin": {
          "Id": "plezy-fullscreen",
          "Name": "Plezy fullscreen",
          "Description": "Start com.edde746.plezy fullscreen",
          "License": "MIT",
          "Version": "1.0",
          "EnabledByDefault": true
        },
        "X-Plasma-API": "javascript",
        "X-Plasma-MainScript": "code/main.js"
      }
      JSON
      cat > $dir/contents/code/main.js <<'JS'
      function forceFullscreen(w) {
          try {
              if (!w) {
                  return;
              }
              var id = String(w.resourceClass) + " " + String(w.desktopFileName);
              if (id.indexOf("plezy") !== -1 && !w.fullScreen) {
                  w.fullScreen = true;
              }
          } catch (e) {
          }
      }

      workspace.windowList().forEach(forceFullscreen);
      workspace.windowAdded.connect(forceFullscreen);
      JS
    '')
  ];
}
