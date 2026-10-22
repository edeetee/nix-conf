# The Mac's files, available to this box on demand.
#
# One mount, a cifs automount created lazily: nothing is mounted at boot, and the
# first read of the path (VLC, Dolphin, `ls`, a Jellyfin scan) triggers the
# connection. If the Mac is asleep or off that read fails fast and the *next*
# read tries again — so `ls /mnt/mac` is a retry button.
#
# The whole home share is **world-readable** (0444/0755), deliberately: that is
# what lets any local account read it, `jellyfin` above all. Two facts force
# this shape:
#
#   * A cifs mount with `nounix` (macOS does not implement the CIFS Unix
#     extensions) has exactly one owner — `uid=`/`gid=`/`file_mode=`/`dir_mode=`
#     are applied to the whole tree — so per-user access cannot be expressed
#     except through the `other` bits.
#   * The nixpkgs Jellyfin module sets `PrivateUsers=yes`, so jellyfin runs in a
#     user namespace where only its own uid/gid is mapped and this mount's owner
#     renders as `nobody`. Group ownership is invisible to it and only the
#     `other` bits are consulted, which is why `gid=975,file_mode=0640` cannot
#     work here. (Verified on the host with a probe run as uid 146 inside the
#     service's sandbox: owners showed as 65534:65534, 0444/0755 read fine.)
#
# The cost, stated once so it is not a surprise later: everything under the
# Mac's home is readable by every local account, including `~/.ssh` and the sops
# age key at `~/Library/Application Support/sops/age/keys.txt` (which decrypts
# every secret in `secrets.yaml`). Services on this box that are network-facing
# — jellyfin, nginx, homepage-dashboard, transmission (whose RPC is
# unauthenticated and bound to 0.0.0.0), samba-wsdd — can therefore read those
# if they are ever compromised. Narrow this by mounting a subtree instead (the
# `subpath` field below): `fileMode`/`dirMode` of 0600/0700 make it owner-only
# again.
#
# Why the units are declared explicitly instead of using `fileSystems` with
# `x-systemd.automount` in `options`: NixOS turns `fileSystems` entries into its
# own .mount units *and* into /etc/fstab, and nothing in
# nixos/modules/tasks/filesystems.nix understands the systemd-only `x-systemd.*`
# options (it special-cases only x-systemd.growfs/makefs). Declaring both units
# is unambiguous and version-proof.
#
# Deliberately NOT in check-mounts.nix's blockedPaths: that guard exists to stop
# services chowning *shared* mounts, and this mount is expected to be owned by
# edeetee (uid=), not root. Do not add it there, and do not add a
# systemd.tmpfiles rule for its ownership — tmpfiles would chown the mount.
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

          # Symlinks, macOS side: the macOS SMB server exports them as SMB
          # reparse points, and the Linux cifs client does not resolve those
          # targets — `stat`/`readlink` return `EINVAL` either way. `mfsymlinks`
          # decodes the *other* convention (the `XSym` "Minshall+French" files
          # that Samba/smbclient create), so all it changes here is presentation:
          # entries list as symlinks (`l?????????`, no mode, no target) instead of
          # as ordinary broken files. Verified on the host on kernel 6.18 — the
          # target of `~/Downloads/mimoComposer.app/…/BXSwiftUI.framework/BXSwiftUI`
          # is still unreadable with the option enabled.
          # Kept because it is what makes them *look* like symlinks and because
          # it costs nothing; the remaining EINVAL is a client/server mismatch,
          # not a config error. Consequence for Jellyfin: one non-fatal
          # `Error resolving path …` per symlink encountered — it skips the entry
          # and continues, so it is log noise rather than a broken scan.
          "mfsymlinks"

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
      # World-readable on purpose — see the header. Every directory in the mount
      # gets dirMode, every file fileMode, so the whole home is traversable and
      # readable by any local account; the mount stays `ro` regardless.
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

  # IPv4 preferred over IPv6 in getaddrinfo for *every* lookup on this box, which
  # is what keeps a fresh mount from picking the Mac's AAAA record while IPv6 is
  # switched off here (networking.nix) — the address resolves fine, the connect
  # then has no route, and cifs retries into that dead end. Written as precedence
  # rather than pinning `ip=` in the mount options on purpose: the Mac's lease
  # changes, and mount.cifs resolves once per mount, so any address baked into
  # the config is stale the day DHCP hands out a different one. With this, each
  # mount resolves the *name* and prefers the v4 answer.
  environment.etc."gai.conf".text = ''
    precedence ::ffff:0:0/96  100
  '';

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
    # Second half: a *live but dead* mount. The cifs session is built from a
    # resolved address once, at mount time, and then survives every address
    # change — the Mac's DHCP lease, or the IPv6 address this box stopped having
    # when `networking.enableIPv6` went off (see networking.nix). The unit stays
    # `active (mounted)` while every syscall on it blocks for `echo_interval` and
    # then fails: that is "Dolphin freezes when I open the Mac's files".
    # `systemctl restart mnt-mac.mount` does NOT recover it — `umount` returns
    # `target is busy`, because plasmashell/kio/Dolphin hold the directory open,
    # and a GUI keeps polling, so the automount's TimeoutIdleSec never fires and
    # the stale mount is never dropped on its own.
    #
    # So probe it, and detach with `umount -l` when it does not answer: lazy, so
    # it succeeds while busy, and the next open of /mnt/mac re-triggers the
    # automount, which resolves the name again and builds a fresh session. The
    # probe only runs when the mount unit claims to be up, so an idle box (no
    # mount, nothing to check) never gets pulled into connecting.
    script = ''
      for unit in ${lib.concatMapStringsSep " " (u: "'${u}'") automountUnits}; do
        if ! ${config.systemd.package}/bin/systemctl is-active --quiet "$unit"; then
          echo "$unit is not active (failed: start limit), re-arming"
          ${config.systemd.package}/bin/systemctl reset-failed "$unit" "''${unit%.automount}.mount" || true
          ${config.systemd.package}/bin/systemctl start "$unit"
        fi
      done

      set -- ${lib.concatMapStringsSep " " (s: "'${s.mountUnit}' '${s.mountPoint}'") shares}
      while [ "$#" -ge 2 ]; do
        unit="$1"; where="$2"; shift 2
        ${config.systemd.package}/bin/systemctl is-active --quiet "$unit" || continue
        if ! ${pkgs.coreutils}/bin/timeout 30 ${pkgs.coreutils}/bin/stat -c %d "$where" >/dev/null 2>&1; then
          echo "$unit is active but unresponsive, detaching $where"
          ${pkgs.util-linux}/bin/umount -l "$where" || true
          ${config.systemd.package}/bin/systemctl reset-failed "$unit" "''${unit%.mount}.automount" || true
          ${config.systemd.package}/bin/systemctl start "''${unit%.mount}.automount" || true
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
}
