{
  config,
  pkgs,
  lib,
  ...
}:

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
    password = ""; # Empty password - passwordless login
    home = "/var/empty";
    createHome = false;
    uid = 1001; # Ensure UID is >= 1000 for GDM to show it
  };

  # Configure AccountsService to show the windows user
  # environment.etc."gdm/custom.conf".text = ''
  #   [daemon]
  #   # Show the windows user in GDM
  # '';

  security.pam.services.gdm-password.rules.auth.windows = {
    enable = true;
    order = config.security.pam.services.gdm-password.rules.auth.unix.order - 50;
    control = "sufficient";
    modulePath = "${config.security.pam.package}/lib/security/pam_succeed_if.so";
    args = [
      "user"
      "="
      "windows"
    ];
  };

  # Configure GDM to allow passwordless login for windows user
  # This makes GDM accept empty password for the windows user
  security.pam.services.gdm-password.text = lib.mkBefore ''
    auth sufficient pam_succeed_if.so user = windows
    account sufficient pam_succeed_if.so user = windows
    password sufficient pam_succeed_if.so user = windows
    session sufficient pam_succeed_if.so user = windows
  '';

  security.pam.services.gdm-autologin.text = lib.mkBefore ''
    auth sufficient pam_succeed_if.so user = windows
    account sufficient pam_succeed_if.so user = windows
    session sufficient pam_succeed_if.so user = windows
  '';

  # Create a custom session for the windows user that immediately reboots
  services.displayManager.sessionPackages = [
    (pkgs.writeTextFile {
      name = "reboot-to-windows-session";
      destination = "/share/wayland-sessions/reboot-to-windows.desktop";
      text = ''
        [Desktop Entry]
        Name=Reboot to Windows
        Comment=Reboot to Windows
        Exec=${pkgs.sudo}/bin/sudo ${reboot-to-windows-script}/bin/reboot-to-windows
        Type=Application
      '';
      passthru.providedSessions = [ "reboot-to-windows" ];
    })
  ];

  # Make the reboot-to-windows session the default for the windows user
  # This way when the user is selected, it automatically uses this session
  systemd.tmpfiles.rules = [
    "d /var/lib/AccountsService/users 0775 root root -"
    "f /var/lib/AccountsService/users/windows 0600 root root - -"
  ];

  # Write AccountsService configuration for the windows user
  environment.etc."AccountsService/users/windows".text = ''
    [User]
    Session=reboot-to-windows
    SystemAccount=false
  '';

  # Allow the windows user to run reboot commands without password
  security.sudo.extraRules = [
    {
      users = [
        "edeetee"
        "windows"
      ];
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
