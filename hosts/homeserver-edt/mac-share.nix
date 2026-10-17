# The Mac's files, available to this box on demand.
#
# Two mounts, both cifs automounts created lazily: nothing is mounted at boot,
# and the first read of a path (VLC, Dolphin, `ls`, a Jellyfin scan) triggers the
# connection. If the Mac is asleep or off that read fails fast and the *next*
# read tries again — so `ls /mnt/mac` is a retry button.
#
#   /mnt/mac         the whole home share, owner-only (edeetee on this host)
#   /mnt/mac-movies  ~/Movies only, world-readable so the *jellyfin* user can
#                    read it without handing that service the whole home
#
# Two mounts rather than one because a cifs mount has exactly one owner: with
# `nounix` (macOS does not implement the CIFS Unix extensions) ownership and
# modes come entirely from `uid=`/`gid=`/`file_mode=`/`dir_mode=`, so a single
# mount cannot be "edeetee's, except this one subtree is also jellyfin's".
#
# Why the second mount is world-readable instead of group-readable for
# `jellyfin` (gid 975): the nixpkgs Jellyfin module sets `PrivateUsers=yes`, so
# jellyfin runs in a user namespace where only its own uid/gid is mapped and
# every other owner shows up as `nobody`/`nogroup`. Group ownership of the mount
# is therefore invisible to it, and only the *other* permission bits are
# consulted. `gid=975,file_mode=0640` would not work; `file_mode=0444` does.
# The exposure is bounded by what is mounted: Movies, not `~/.ssh` and not the
# sops age key in `~/Library/Application Support/sops/age/keys.txt`.
#
# Why the units are declared explicitly instead of using `fileSystems` with
# `x-systemd.automount` in `options`: NixOS turns `fileSystems` entries into its
# own .mount units *and* into /etc/fstab, and nothing in
# nixos/modules/tasks/filesystems.nix understands the systemd-only `x-systemd.*`
# options (it special-cases only x-systemd.growfs/makefs). Declaring both units
# is unambiguous and version-proof.
#
# Deliberately NOT in check-mounts.nix's blockedPaths: that guard exists to stop
# services chowning *shared* mounts, and these mounts are expected to be owned by
# edeetee (uid=), not root. Do not add them there, and do not add a
# systemd.tmpfiles rule for their ownership — tmpfiles would chown the mount.
#
# See also: TV-MEDIA.md (the workflow), and the "files from the Mac" section
# there for the no-mount alternative (`vlc smb://…` straight off the share).
{ config, pkgs, lib, ... }:
let
  # The Mac's mDNS name (`scutil --get LocalHostName` on the Mac, plus .local).
  # Avahi resolves this on this host (networking.nix sets `nssmdns4 = true`).
  macHost = "Edwards-MacBook-Max.local";

  # macOS shares each user's home directory as a share named after the short
  # username, and once every folder is made shareable it also offers the whole
  # volume as "Macintosh HD". Using the home share means the mounts below can
  # point at one *subtree* of it — `what=` takes a path inside the share — with
  # no per-folder setup on the Mac. Verified with `smbclient -L` against this
  # host: it advertises `edeetee`, `Macintosh HD`, `TF24`, `into_the_vortex`,
  # `Edward Taylor’s Public Folder` and `IPC$`.
  shareName = "edeetee";

  credentials = config.sops.secrets.mac-smb-credentials.path;

  # systemd's escaped name for a mount point, without the unit-type suffix:
  # "/mnt/mac-movies" -> "mnt-mac\x2dmovies". nixpkgs has exactly this as
  # `escapeSystemdPath` (nixos/lib/utils.nix) but does not re-export it as
  # `lib.escapeSystemdPath`, and the heal timer below needs the unit names, so it
  # is spelled out here. Suffixes are added by the caller (`.mount`,
  # `.automount`) — appending `.mount` here and then `.automount` in the timer
  # yielded "mnt-mac.mount.automount", which no unit is called.
  #
  # Order matters, and is the same as in systemd-escape: escape the hyphens the
  # path already contains first, then turn the separators into hyphens. Doing it
  # the other way round escapes the separators too ("mnt\x2dmac").
  escapedUnitFor =
    path:
    lib.replaceStrings [ "/" ] [ "-" ] (
      lib.removePrefix "/" (lib.replaceStrings [ "-" ] [ "\\x2d" ] path)
    );

  mkShare =
    {
      mountPoint,
      subpath ? "",
      description,
      fileMode,
      dirMode,
    }:
    {
      inherit mountPoint;
      mountUnit = "${escapedUnitFor mountPoint}.mount";
      automountUnit = "${escapedUnitFor mountPoint}.automount";

      mount = {
        description = "${description} (${shareName}${subpath} on ${macHost})";
        what = "//${macHost}/${shareName}${subpath}";
        where = mountPoint;
        type = "cifs";
        options = lib.concatStringsSep "," [
          "credentials=${credentials}"

          # Ownership for `nounix` SMB: edeetee owns the mount (Dolphin, VLC),
          # and `fileMode`/`dirMode` decide who else may read. Kept per-share
          # rather than global because that is the whole point of the split.
          "uid=${toString config.users.users.edeetee.uid}"
          "gid=${toString config.users.groups.users.gid}"
          "file_mode=${fileMode}"
          "dir_mode=${dirMode}"
          "iocharset=utf8"

          # Read-only. Nothing on this host has any business writing into the
          # Mac's home, and a stray process writing over SMB is a data-loss risk
          # with nothing to gain. Drop it if you ever want to push files back.
          "ro"

          # `soft` returns errors when the Mac disappears instead of blocking the
          # calling process forever (a `hard` mount hangs a Jellyfin scan thread
          # until the Mac comes back). `echo_interval=10` shortens how long an
          # unresponsive server takes to be noticed (default 60s; reconnection
          # itself is attempted at twice this value).
          "soft"
          "echo_interval=10"

          "_netdev" # never fsck / treat as network in ordering
        ];
        # No wantedBy: the automount unit below pulls this in on first access.
        # That is what keeps the Mac out of the boot path.
      };

      automount = {
        where = mountPoint;
        wantedBy = [ "multi-user.target" ];
        automountConfig = {
          DirectoryMode = "0755"; # also creates the mount point
          # Throw the mount away after 5 minutes idle. This is the most important
          # option here: it turns "stale mount pointing at a Mac that has been
          # asleep for an hour" into "fresh connection on next access", instead
          # of relying on the kernel's reconnect heuristics.
          TimeoutIdleSec = "300";
        };
      };
    };

  shares = [
    (mkShare {
      mountPoint = "/mnt/mac";
      description = "Mac home share";
      # Because this is the whole home directory, owner-only is deliberate:
      # edeetee reads everything, and no other local user can. Widen these and
      # everything in the home — `~/.ssh`, the sops age key — becomes readable by
      # every service account on this box (jellyfin, nginx, homepage-dashboard,
      # transmission, samba-wsdd), several of which are network-facing.
      fileMode = "0600";
      dirMode = "0700";
    })
    (mkShare {
      mountPoint = "/mnt/mac-movies";
      subpath = "/Movies"; # must exist on the Mac, or the mount fails
      description = "Mac Movies folder, readable by jellyfin";
      # World-readable on purpose: `PrivateUsers=yes` on jellyfin means only the
      # `other` bits apply to it (see the header). Write bits are moot under the
      # global `ro`, and left off so the intent is unambiguous.
      fileMode = "0444";
      dirMode = "0755";
    })
  ];

  automountUnits = map (s: s.automountUnit) shares;
in
{
  # Pulls in cifs-utils (via system.fsPackages) and the cifs module. That
  # automatic wiring is triggered by `boot.supportedFilesystems`, which we
  # cannot get from a `fileSystems.<name>.fsType` here because the mounts are
  # declared as systemd units instead.
  boot.supportedFilesystems = [ "cifs" ];
  boot.kernelModules = [ "cifs" ];

  # A mount.cifs credentials file, i.e. three lines:
  #
  #   username=edeetee
  #   password=<the Mac's SMB password>
  #   domain=WORKGROUP
  #
  # Added on the host that can decrypt it:  sops hosts/homeserver-edt/secrets.yaml
  # sops-nix writes it root-owned 0400 at /run/secrets/, which is what the
  # (root) mount units need. One file serves both mounts.
  sops.secrets.mac-smb-credentials = {
    mode = "0400";
  };

  systemd.mounts = map (s: s.mount) shares;
  systemd.automounts = map (s: s.automount) shares;

  # The one hole in automount semantics (systemd issue #16811: automount units
  # have no Restart=). If a .mount unit fails repeatedly within the default
  # start-limit window — 5 starts / 10s, easily reached by something enumerating
  # the path while the Mac is asleep — systemd propagates "start limit hit" to
  # the automount unit, which then goes FAILED and tears down the autofs point.
  # After that the mount point is a plain empty directory and *nothing* will ever
  # mount it again: accesses cannot retry, because the thing that retries is gone.
  #
  # This timer is the missing Restart=, and is what makes "it reconnects
  # whenever something tries to read it" actually hold. It covers every share
  # above, so a new one only has to be added to `shares`.
  systemd.services.mac-share-heal = {
    description = "Re-arm the Mac share automounts if systemd gave up on them";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      for unit in ${lib.concatMapStringsSep " " (u: "'${u}'") automountUnits}; do
        if ! ${config.systemd.package}/bin/systemctl is-active --quiet "$unit"; then
          echo "$unit is not active (failed: start limit), re-arming"
          ${config.systemd.package}/bin/systemctl reset-failed "$unit" "''${unit%.automount}.mount" || true
          ${config.systemd.package}/bin/systemctl start "$unit"
        fi
      done
    '';
  };

  systemd.timers.mac-share-heal = {
    description = "Check the Mac share automounts are still armed";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
    };
  };

  # TEMPORARY diagnostic (remove after answering "can jellyfin read the share").
  # Runs as jellyfin with the same sandbox options that matter for filesystem
  # access, so it sees exactly what the service sees — including its
  # PrivateUsers uid mapping and ProtectSystem mount namespace.
  systemd.services.mac-probe = {
    description = "Probe the Mac share as the jellyfin user";
    serviceConfig = {
      Type = "oneshot";
      User = "jellyfin";
      Group = "jellyfin";
      PrivateUsers = true;
      PrivateTmp = true;
      ProtectSystem = true;
      ProtectProc = "invisible";
      UMask = "0077";
      PrivateDevices = false;
    };
    script = ''
      echo "== id"; id
      echo "== stat"
      stat -c '%a %u:%g %n' /mnt /mnt/mac /mnt/mac-movies 2>&1
      echo "== read test"
      if ls /mnt/mac-movies >/dev/null 2>&1; then echo "mac-movies: READ OK"; else echo "mac-movies: FAIL"; fi
      if ls /mnt/mac >/dev/null 2>&1; then echo "mac: READ OK"; else echo "mac: FAIL"; fi
      echo "== first entries"; ls /mnt/mac-movies 2>&1 | head -3
      echo "== mount"; ${pkgs.util-linux}/bin/findmnt -no SOURCE,OPTIONS /mnt/mac-movies 2>&1
      echo "== jellyfin libraries on disk"
      for f in /var/lib/jellyfin/root/default/*/options.xml; do
        echo "--- $f"
        grep -o '<Path>[^<]*</Path>' "$f" 2>&1
      done
      echo "== media folders from data dir"
      ls /var/lib/jellyfin/root/default/ 2>&1
    '';
  };

  systemd.timers.mac-probe = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
    };
  };
}
