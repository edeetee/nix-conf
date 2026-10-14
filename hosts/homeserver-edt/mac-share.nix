# The Mac's files, available to this box on demand.
#
# Mounts a macOS SMB share at /mnt/mac, created lazily: nothing is mounted at
# boot, and the first read of the path (VLC, Dolphin, `ls`, a Jellyfin scan)
# triggers the connection. If the Mac is asleep or off that read fails fast and
# the *next* read tries again — so `ls /mnt/mac` is a retry button.
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

  # Must match the Shared Folder name in macOS Settings → General → Sharing →
  # File Sharing (the name, not the path).
  shareName = "Media";

  mountPoint = "/mnt/mac";

  credentials = config.sops.secrets.mac-smb-credentials.path;
in
{
  # Pulls in cifs-utils (via system.fsPackages) and the cifs module. That
  # automatic wiring is triggered by `boot.supportedFilesystems`, which we
  # cannot get from a `fileSystems.<name>.fsType` here because the mount is
  # declared as a systemd unit instead.
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
  # (root) mount unit needs.
  sops.secrets.mac-smb-credentials = {
    mode = "0400";
  };

  systemd.mounts = [
    {
      description = "Mac share (${shareName} on ${macHost})";
      what = "//${macHost}/${shareName}";
      where = mountPoint;
      type = "cifs";
      options = lib.concatStringsSep "," [
        "credentials=${credentials}"

        # macOS' SMB server does not implement the CIFS Unix extensions, so
        # ownership and permissions come from these options, not the server.
        # 0644/0755 makes the files world-readable, which is what lets the
        # `jellyfin` user (a different uid) read them.
        "uid=${toString config.users.users.edeetee.uid}"
        "gid=${toString config.users.groups.users.gid}"
        "file_mode=0644"
        "dir_mode=0755"
        "iocharset=utf8"

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
    }
  ];

  systemd.automounts = [
    {
      where = mountPoint;
      wantedBy = [ "multi-user.target" ];
      automountConfig = {
        DirectoryMode = "0755"; # also creates /mnt/mac
        # Throw the mount away after 5 minutes idle. This is the most important
        # option here: it turns "stale mount pointing at a Mac that has been
        # asleep for an hour" into "fresh connection on next access", instead of
        # relying on the kernel's reconnect heuristics.
        TimeoutIdleSec = "300";
      };
    }
  ];

  # The one hole in automount semantics (systemd issue #16811: automount units
  # have no Restart=). If the .mount unit fails repeatedly within the default
  # start-limit window — 5 starts / 10s, easily reached by something enumerating
  # the path while the Mac is asleep — systemd propagates "start limit hit" to
  # the automount unit, which then goes FAILED and tears down the autofs point.
  # After that /mnt/mac is a plain empty directory and *nothing* will ever mount
  # it again: accesses cannot retry, because the thing that retries is gone.
  #
  # This timer is the missing Restart=, and is what makes "it reconnects
  # whenever something tries to read it" actually hold.
  systemd.services.mac-share-heal = {
    description = "Re-arm the Mac share automount if systemd gave up on it";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      if ! ${config.systemd.package}/bin/systemctl is-active --quiet mnt-mac.automount; then
        echo "mnt-mac.automount is not active (failed: start limit), re-arming"
        ${config.systemd.package}/bin/systemctl reset-failed mnt-mac.automount mnt-mac.mount || true
        ${config.systemd.package}/bin/systemctl start mnt-mac.automount
      fi
    '';
  };

  systemd.timers.mac-share-heal = {
    description = "Check the Mac share automount is still armed";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
    };
  };
}
