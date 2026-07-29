# Guard against services that silently chown shared mount points.
# See AGENTS.md rule #1 for context.
{ config, pkgs, lib, ... }:
let
  blockedPaths = [ "/mnt/hdd" "/mnt/windows" "/home" ];
in
{
  # Build-time guard: block known-dangerous service configs
  assertions = [{
    assertion = !(config.services.filebrowser.enable or false)
      || !(builtins.elem (config.services.filebrowser.settings.root or "") blockedPaths);
    message = ''
      REFUSED: services.filebrowser.settings.root is a shared mount point!
      FileBrowser's module chowns its root, breaking other services.
      See AGENTS.md and commit e216ab4.
    '';
  }];

  # Runtime guard: check mount ownership on every boot
  systemd.services.check-mounts = {
    description = "Verify ownership of shared mount points";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = let
      check = path: pkgs.writeShellScript "check-${builtins.baseNameOf path}" ''
        owner=$(stat -c '%U:%G' ${path} 2>/dev/null)
        if [ "$owner" != "root:root" ]; then
          echo "CRITICAL: ${path} is owned by $owner, expected root:root!" >&2
          echo "Some service hijacked this mount point. Fix with: sudo chown root:root ${path}" >&2
          exit 1
        fi
      '';
    in ''
      set -e
      ${check "/mnt/hdd"}
      ${check "/mnt/windows"}
    '';
  };
}
