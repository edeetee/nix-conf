# AGENTS.md — Guidelines for AI agents (and humans) working on this repo

This is a live NixOS configuration deployed to `homeserver-edt` (NixOS 25.11, mDNS at `homeserver-edt.local`). Changes pushed
to `main` are pulled and rebuilt on the server. Be careful.

The nix-conf lives at `~/dev/nix-conf` on both the Mac and the server.
When running pi on the server, `cd ~/dev/nix-conf` first so it loads this file.

## Server quick facts
- SSH: `ssh homeserver-edt.local` (mDNS, zerotier also available)
- **The server sleeps aggressively to save power (it's a ~50W idle box).** It can drop off
the network (mDNS, ZeroTier, ping all fail) within minutes of going idle. If SSH times
out or the host won't resolve, it is almost certainly **asleep, not broken** — wake it
(e.g. controller input / WoL) and retry; a fresh boot takes ~1-2 min before services
are back. Don't burn time debugging connectivity before confirming it's awake.
- Audio: see `hosts/homeserver-edt/AUDIO.md` — PipeWire, rtkit, Wine/Proton latency tuning
- Audio is HDMI out to Sony TV via Navi 21/23 GPU
- Steam launches via `steam-on-demand.service` (controller-triggered)
- AirPlay (audio + screen mirroring): see `hosts/homeserver-edt/AIRPLAY.md`
- Rebuild the fast way: **`nixup`** (see below)

### Deploying: `nixup` and `nixrs`

Defined as shell aliases **on the server only** (`hosts/homeserver-edt/packages.nix`),
so they have to be run there — not on the Mac, not over a non-interactive `ssh`
line (see the gotchas):

```bash
nixup   # git -C ~/dev/nix-conf pull   +   sudo nixos-rebuild switch --flake ~/dev/nix-conf/
nixrs   # just the switch, no pull (use when the tree is already up to date)
```

`nixup` also prints the commits it just pulled (`git log ..@{u}`), which is the
quickest way to see what is about to be deployed. Three things to know before
relying on it:

1. **The server carries local-only commits** (`flake.local`, `deepseek api key`,
   which touch `secrets.yaml` and `modules/common.nix`). `pull.rebase` is set to
   `true` there, so `nixup` rebases those two on top of `origin/main` — that is
   the intended workflow. Never force-update or reset the server's checkout, and
   never push from the server.
2. **New user units are enabled but not started.** `nixos-rebuild switch` does
   not start units that are new for a *user manager that is already running* (it
   only does that on the next login/reboot), and `graphical-session.target` is
   long past by then. A service that was just added therefore sits `inactive
   (dead)` with an empty journal — which looks like a crash but is not. Fix after
   a deploy that added one:

   ```bash
   XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start <unit>      # and/or
   XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
   ```

   (This is why `nixup` alone was not enough for `shairport-sync`,
   `airplay-nowplaying` and `uxplay`.)
3. **`nixup` needs a TTY for sudo.** From an agent's non-interactive `ssh`, run
   the build half only — `nixos-rebuild build --flake .#homeserver-edt` (no root
   needed) validates and warms the store, then ask the user to run `nixup`.

## Critical rules

### 0. Always commit to nix-conf, not just the live server
Runtime changes (pw-metadata, systemctl edits, manual config files) are ephemeral —
they vanish on reboot or service restart. When debugging, it's fine to test live first,
but once you find what works, **always encode it in the nix-conf** and push.
Otherwise the fix is lost and the next agent (or reboot) starts from scratch.

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
- Deploy with **`nixup`** on the server (pull + switch); `nixrs` switches without
  pulling. Both are discussed, with their gotchas, under "Deploying" above —
  note in particular that **new user units need starting by hand**.
- Verify services start after rebuild: `systemctl is-active <service>`. User
  units need it twice: `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user ...`.
- Check listening ports: `ss -tlnp`.
- Read logs: `journalctl -u <service> -n 50`, `journalctl --user -u <service>`.
- Validate a change without root first: `nix flake check --no-build`, then
  `nixos-rebuild build --flake .#homeserver-edt` (builds and warms the store).

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
    packages.nix           — system packages, fonts, users, shell (nixup/nixrs aliases)
    pi-agent/              — pi coding agent (deepseek models/settings)
    AUDIO.md               — PipeWire/Wine latency notes; how the audio stack is tuned
    AIRPLAY.md             — AirPlay audio + screen mirroring + now-playing display
  rpi3b/                   — Raspberry Pi 3B, lean always-on agent host over zerotier
    default.nix            — entrypoint (minimal, no commonModules)
    hardware-configuration.nix — SD root by label (NIXOS_SD)
    networking.nix         — hostname, zerotier (smart-access-rds), ssh, wifi
    services.nix           — reserved for the deepseek harness module (TBD)
    packages.nix           — minimal packages, user
    install.md             — build sdImage on server → flash → deploy
  Note: rpi3b is built on the homeserver (aarch64 via qemu-user emulation),
  never on the Pi itself. Updates are nixos-rebuild --target-host over ssh,
  never a re-flash. See hosts/rpi3b/install.md.

modules/
  common.nix               — shared config (shell, packages, aliases) for all machines
  nixvim/                  — nixvim config
  nixos/                   — reusable NixOS modules
    steam.nix
    samba.nix
    reboot-to-windows.nix
    amd-gpu.nix
    airplay.nix            — AirPlay: shairport-sync (audio), UxPlay (mirroring), now-playing UI
    airplay-nowplaying.py  — the fullscreen now-playing window that airplay.nix wraps
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
