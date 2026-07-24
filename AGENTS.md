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

### 2. Verify before pushing
- Run `nix flake check --no-build` locally before committing.
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

## Repo structure
```
configuration.nix          — main NixOS config (homeserver-edt)
common-configuration.nix   — shared config (shell, packages, aliases)
flake.nix                  — inputs, outputs, all machine definitions
nixos/                     — NixOS-specific modules (steam, samba)
darwin/                    — macOS Darwin config (MacBooks)
neovim/                    — nixvim config
.config/                   — managed dotfiles synced via home-manager
```

## Variables available in configuration.nix
- `host` = `"${config.networking.hostName}.local"` (currently `homeserver-edt.local`)
- `config.networking.hostName` = `"homeserver-edt"`
- `lib.mkForce` — use to override module defaults that conflict
