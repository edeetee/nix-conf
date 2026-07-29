# AGENTS.md — Guidelines for AI agents (and humans) working on this repo

This is a live NixOS configuration deployed to `homeserver-edt`. Changes pushed
to `main` are pulled and rebuilt on the server. Be careful.

## Critical rules

### 1. Directories with side effects
Some NixOS service modules create systemd-tmpfiles rules that silently chown/chmod
directories. Before setting a service's working directory, data directory, or
root path to an existing shared directory (like `/mnt/hdd`, `/home`, etc.),
**check the module source** for tmpfiles rules.

**Known offenders:**
- `services.filebrowser` — tmpfiles owns `settings.root` to the service user
  with mode `0700`. Never point this at `/mnt/hdd` or any shared mount.
  (See commit `e216ab4` for the incident where it broke Steam/games.)

If you must use a shared path, set `user` and `group` to match the existing
owner so the tmpfiles rule is a no-op, or use a dedicated subdirectory.

### 2. Verify before committing (not after)
**Always run `nix flake check --no-build` before committing.** This evaluates all
configurations (NixOS + Darwin), the formatter, and checks. Do not commit if it fails.

- After creating or renaming files, check they aren't blocked by `.gitignore`:
  ```
  git check-ignore <new-file>   # empty output = not ignored, good
  ```
- If a new file is gitignored, either update `.gitignore` or rename the file.
  (e.g. `hardware-configuration.nix` was globally gitignored, silently excluding
  the new `hosts/homeserver-edt/hardware-configuration.nix` from commits.)
- Verify specific config values with:
  ```
  nix eval .#nixosConfigurations.homeserver-edt.config.<path>
  ```
  e.g. `nix eval .#nixosConfigurations.homeserver-edt.config.boot.kernelParams`
- If adding a new service module, read the upstream module source first.
- Check for `tmpfiles`, `StateDirectory`, `WorkingDirectory`, and any chown/chmod
  behavior in the module.

### 3. Ports and binding
- Services that default to `127.0.0.1` won't be reachable from other machines.
  Check with `ss -tlnp` on the server after deploying.
- Services that default to `0.0.0.0` may need firewall rules.

### 4. Absolute vs relative URLs
- Homepage dashboard requires absolute URLs for service hrefs and widget URLs.
  Relative paths like `/jellyfin` cause NextJS `URL constructor` errors.
- Use the `host` variable (= `homeserver-edt.local`) for hrefs.
- Use `127.0.0.1` for widget URLs (server-side API calls).

### 5. Cockpit quirks
- Cockpit's `Origins` setting must include the exact origin the browser sends
  (scheme, host, port). Without it, WebSocket connections get 403.
- `AllowUnencrypted=true` is needed for plain HTTP access.
- The default NixOS module sets `Origins = https://localhost:9090` which blocks
  all non-localhost access.

### 6. Build-test cycle
- The server is at `homeserver-edt.local` (mDNS via Avahi).
- `nixup` alias = `git pull && sudo nixos-rebuild switch --flake`.
- Always verify services start after rebuild: `systemctl is-active <service>`.
- Check listening ports: `ss -tlnp`.
- Read logs: `journalctl -u <service> -n 50`.

### 7. Shared modules must work on all platforms
`modules/common.nix` is imported by both NixOS and Darwin configurations.
**Never add NixOS-only options to shared modules.** Examples of NixOS-only options
that will error on Darwin:
- `sops.*` (only available when `sops-nix.nixosModules.sops` is imported)
- `boot.*`
- `services.cockpit`, `services.jellyfin`, etc.

If a module needs platform-specific options, either:
- Put it in `modules/nixos/` (imported only by NixOS hosts)
- Guard it with `lib.mkIf`:
  ```nix
  sops = lib.mkIf config.services.cockpit.enable { ... };
  ```
- Add the equivalent Darwin module to the flake (e.g. `sops-nix.darwinModules.sops`)

### 8. Secrets (sops-nix)
- Secrets live in `hosts/homeserver-edt/secrets.yaml` (encrypted).
- Edit with: `sops hosts/homeserver-edt/secrets.yaml`
- Access in NixOS config as: `config.sops.secrets.<name>.path`
- Age keys are derived from SSH host keys. To add a new host:
  ```
  nix-shell -p ssh-to-age --run "ssh-keyscan <host> | ssh-to-age"
  ```
  Then add the key to `.sops.yaml`.

## Repo structure
```
flake.nix                  — inputs, outputs, all machine definitions

hosts/
  homeserver-edt/          — NixOS server config (split into concern-focused modules)
    default.nix            — entrypoint, imports sub-modules
    hardware-configuration.nix
    boot.nix               — kernel, loader, plymouth
    networking.nix         — hostname, avahi, zerotier, ssh, firewall
    desktop.nix            — display manager, plasma, bluetooth
    services.nix           — cockpit, jellyfin, transmission, homepage, nginx
    packages.nix           — system packages, fonts, users, shell

modules/
  common.nix               — shared config (shell, packages, aliases) for all machines
  nixvim/                  — nixvim config
  nixos/                   — reusable NixOS modules
    steam.nix
    samba.nix
    reboot-to-windows.nix
    amd-gpu.nix
    check-mounts.nix       — guards against chown on shared mounts
    arr.nix                 — nixarr (WIP)

lib/
  jj-tools/                — custom jj wrapper + tests

darwin/                    — macOS Darwin config (MacBooks)
.config/                   — managed dotfiles synced via home-manager
.sops.yaml                 — sops-nix secret encryption config
```

## Variables available in configuration.nix
- `host` = `"${config.networking.hostName}.local"` (currently `homeserver-edt.local`)
- `config.networking.hostName` = `"homeserver-edt"`
- `lib.mkForce` — use to override module defaults that conflict
