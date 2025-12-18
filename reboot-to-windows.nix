{ config, pkgs, lib, ... }:

let
  reboot-to-windows-script = pkgs.writeShellScriptBin "reboot-to-windows" ''
    #!/usr/bin/env bash
    set -e
    
    # Find Windows Boot Manager entry using efibootmgr
    WINDOWS_ENTRY=$(${pkgs.efibootmgr}/bin/efibootmgr | grep -i "windows" | head -n 1 | sed 's/Boot\([0-9A-F]*\).*/\1/' || true)
    
    if [ -z "$WINDOWS_ENTRY" ]; then
      echo "Error: Could not find Windows Boot Manager entry"
      echo "Available boot entries:"
      ${pkgs.efibootmgr}/bin/efibootmgr
      exit 1
    fi
    
    echo "Setting next boot to Windows (entry $WINDOWS_ENTRY)"
    
    # Set next boot to Windows using efibootmgr
    ${pkgs.efibootmgr}/bin/efibootmgr --bootnext "$WINDOWS_ENTRY"
    
    # Reboot
    ${pkgs.systemd}/bin/systemctl reboot
  '';

  # Auto-reboot service that checks for display and idle status
  auto-reboot-to-windows-script = pkgs.writeShellScriptBin "auto-reboot-to-windows-check" ''
    #!/usr/bin/env bash
    
    # Check if any display is connected
    if ! ${pkgs.xorg.xrandr}/bin/xrandr | grep -q " connected"; then
      echo "No display connected, skipping auto-reboot"
      exit 0
    fi
    
    # Check if any SSH sessions are active
    if ${pkgs.procps}/bin/pgrep -x sshd > /dev/null; then
      SSH_SESSIONS=$(${pkgs.procps}/bin/pgrep -x sshd | wc -l)
      if [ $SSH_SESSIONS -gt 1 ]; then  # More than just the main sshd process
        echo "Active SSH sessions detected, skipping auto-reboot"
        exit 0
      fi
    fi
    
    # Check if any user is logged in via GDM
    if ${pkgs.systemd}/bin/loginctl list-sessions | grep -q "gdm\|seat"; then
      ACTIVE_SESSIONS=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend | grep -v "gdm" | wc -l)
      if [ $ACTIVE_SESSIONS -gt 0 ]; then
        echo "Active user sessions detected, skipping auto-reboot"
        exit 0
      fi
    fi
    
    echo "Display connected, no active sessions. Rebooting to Windows..."
    ${reboot-to-windows-script}/bin/reboot-to-windows
  '';
in
{
  # Install the reboot script
  environment.systemPackages = [ 
    reboot-to-windows-script 
    auto-reboot-to-windows-script
  ];

  # Create a fake "Windows" user that triggers reboot when selected
  users.users.windows = {
    isNormalUser = true;
    description = "Reboot to Windows";
    hashedPassword = "!"; # Locked account - no password login possible
    shell = "${reboot-to-windows-script}/bin/reboot-to-windows";
  };

  # Allow the windows user to run reboot commands without password
  security.sudo.extraRules = [
    {
      users = [ "edeetee" "windows" ];
      commands = [
        {
          command = "${pkgs.efibootmgr}/bin/efibootmgr";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.systemd}/bin/systemctl reboot";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${reboot-to-windows-script}/bin/reboot-to-windows";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Optional: Auto-reboot service (disabled by default)
  # Uncomment to enable automatic reboot to Windows when display is connected
  # and there's no user activity for 30 seconds
  /*
  systemd.services.auto-reboot-to-windows = {
    description = "Auto-reboot to Windows when display connected and idle";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "display-manager.service" ];
    
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${auto-reboot-to-windows-script}/bin/auto-reboot-to-windows-check";
      User = "root";
    };
  };

  systemd.timers.auto-reboot-to-windows = {
    description = "Timer for auto-reboot to Windows check";
    wantedBy = [ "timers.target" ];
    
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
      Unit = "auto-reboot-to-windows.service";
    };
  };
  */
}
