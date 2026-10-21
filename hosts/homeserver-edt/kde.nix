# Plasma settings this host owns, declared instead of hand-edited.
#
# Both live in ~/.config and were previously only set by clicking around in
# System Settings — invisible to git, gone on a wipe, and in the KDE Connect
# case the only record of how to start the Jellyfin TV client from the phone
# (see desktop.nix).
#
# Two different mechanisms, for a reason:
#
#   * power/sleep goes through plasma-manager's typed options, which *merge*
#     into the live file — it rewrites only the keys named here and leaves the
#     rest of ~/.config alone, which is why pointing it at a hand-made config
#     directory is safe;
#   * KDE Connect has no plasma-manager module, and its config is keyed by the
#     paired device, so it is written as a file into every device directory.
#
# Deliberately NOT declared here, because each one is a behaviour change rather
# than a reproduction of what is on the disk today (see
# plans/kde-declarative-settings.md §6):
#
#   * powerdevil.AC.autoSuspend.action — "never suspend" is already enforced at
#     the logind level in desktop.nix, and whether this box sleeps at all is
#     disputed (AGENTS.md says it sleeps aggressively, desktop.nix says never
#     — plans/vaultwarden.md §1 flags the same contradiction). Settle it once
#     before asserting it at a second layer.
#   * powerdevil.AC.dimDisplay — KDE's default (dim on idle) currently stands.
#   * immutableByDefault — that is what *enforces* a value against the GUI;
#     these are merely declared for now.
{ lib, pkgs, ... }:
let
  runCommands = import ./kde-connect-run-commands.nix { inherit lib; };

  runCommandsFile = pkgs.writeText "kdeconnect-runcommand-config" runCommands.file;
in
{
  # System Settings ▸ Power Management. AC only: this box has no battery.
  # The values map to the ints Plasma stores ("shutDown" -> 8, "never" -> -1)
  # and reproduce what is on the disk today:
  #   [AC][Display]            TurnOffDisplayIdleTimeoutSec=-1
  #   [AC][SuspendAndShutdown] PowerButtonAction=8
  # TurnOffDisplayWhenIdle=false is not written here; plasma-manager leaves
  # that key alone, and it has to stay consistent with the -1 above.
  programs.plasma = {
    enable = true;

    powerdevil.AC = {
      powerButtonAction = "shutDown";
      turnOffDisplay.idleTimeout = "never";
    };

    # plasma-manager writes kuriikwsfilterrc unconditionally, and this module's
    # option defaults to null. That is not merely a no-op: upstream's writer
    # treats a null value as an error when the key's immutability is not the
    # default, and it is handed `immutableByDefault` as the *string* "false"
    # (lib/writeconfig.nix) which Python's bool() reads as True — so the
    # activation script throws and all of HM activation fails.
    #
    # Pinning it to the value Plasma resolves to anyway keeps the file inert:
    # webshortcutrunner.cpp does readEntry("DefaultWebShortcut", "duckduckgo").
    # The other four keys the module writes (EnableWebShortcuts,
    # KeywordDelimiter, PreferredWebShortcuts, UsePreferredWebShortcutsOnly) are
    # read nowhere in plasma-workspace 6.6 — they are Plasma 5 leftovers.
    # Do not delete this line without re-reading both of those.
    searchPlugins.webSearchKeywords.default = "duckduckgo";
  };

  # KWin script that forces Plezy fullscreen (plezy-fullscreen.nix). KWin reads
  # its enabled-scripts list from kwinrc at startup, so this takes effect at the
  # next session start; `plezy-fullscreen.nix` documents the one-off D-Bus call
  # that applies it to a running session.
  programs.plasma.configFile.kwinrc.Plugins.plezy-fullscreenEnabled = true;

  # KDE Connect run commands, into every paired device's directory.
  #
  # That directory is the *remote* device's id, so hard-coding one would mean a
  # repo edit after every re-pair; looping costs the same and does not rot. A
  # device paired mid-session is picked up on the next activation — Nix cannot
  # read the filesystem at eval time, so this has to be a script. Note it
  # replaces that one file wholesale, which is fine today: it holds nothing but
  # [General] commands.
  #
  # `run` comes from HM's activation script (lib/bash/home-manager.sh) and is a
  # no-op in dry-run.
  home.activation.kdeconnectRunCommands = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    kdeDir="$HOME/.config/kdeconnect"
    if [ -d "$kdeDir" ]; then
      for dev in "$kdeDir"/*/; do
        [ -d "$dev" ] || continue
        run mkdir -p "''${dev}kdeconnect_runcommand"
        run install -m644 ${runCommandsFile} "''${dev}kdeconnect_runcommand/config"
      done
    fi
  '';
}
