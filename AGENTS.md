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

### Deploying from the Mac

All three of these build *and* switch on the server. That is not a preference:
the Mac is aarch64-darwin with no x86_64-linux builder (`nix.linux-builder` is
off, `/etc/nix/machines` does not exist), so `--build-host` is mandatory and a
plain `nixos-rebuild switch --target-host …` fails at the build.

| From | Password | What it is |
| --- | --- | --- |
| `ssh -t homeserver-edt.local 'zsh -ic nixup'` | typed (TTY) | the server's own alias; `-t` is what gives sudo a terminal |
| `push-server` (Darwin alias) | prompted once, piped to remote sudo | `nixos-rebuild switch --build-host … --target-host … --ask-sudo-password`; the alias needs a `darwin-rebuild switch` on the Mac first, but the command itself works today |
| `./scripts/deploy-server.sh` | none | pushes, pulls as `edeetee`, pre-flights the sops secrets, then runs the NOPASSWD'd `nixos-deploy` — the one that works from scripts and agents |

The last two depend on `hosts/homeserver-edt/deploy.nix`, which is what grants the
passwordless rule, so the **first** deploy of that module has to go through
`nixup` on the server. Read the SECURITY note in that module before keeping it: a
NOPASSWD rule for something that installs a configuration out of a user-writable
directory is passwordless root for `edeetee`.

`deploy-server.sh` also runs a pre-flight: every `sops.secrets.<name>` declared in
the checkout must exist in `hosts/homeserver-edt/secrets.yaml`. sops-nix catches
that while *building* `manifest.json`, i.e. before anything is switched, so the
failure is harmless — but it costs a full evaluation and the message is opaque
(`the key 'x' cannot be found`).

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
- Edit with: `sops hosts/homeserver-edt/secrets.yaml` — **on the server.** See
  "Editing from a Mac" below for why, and what to run instead.
- Access in NixOS config as: `config.sops.secrets.<name>.path`
- Age keys are derived from SSH host keys. To add a new host:
  ```
  nix-shell -p ssh-to-age --run "ssh-keyscan <host> | ssh-to-age"
  ```
  Then add the key to `.sops.yaml`, and run `sops updatekeys <file>` on a host
  that can already decrypt it. Editing an existing file *preserves* its
  recipients (they are read from the file's metadata), so `updatekeys` is only
  needed after `.sops.yaml` changes — verified against sops 3.12.2.

### Editing from a Mac

`secrets.yaml` is effectively **server-owned**, for two reasons that both have
to be understood before touching it from a laptop:

1. The committed file's metadata lists only the server's keys, so a laptop
   cannot decrypt the repo copy at all.
2. The server carries local-only commits on this file (`deepseek api key`,
   `flake.local`) that add keys the repo copy does not have — and sops-nix reads
   the *server's* working copy. Committing an edit on the laptop and pushing it
   makes the next `nixup` rebase collide on an encrypted file, which cannot be
   merged by hand.

So use:

```
./scripts/secrets-edit.sh
```

— it fetches the server's copy over ssh, opens `sops` on it, pushes it back,
validates that the server can still decrypt it, and commits it there (where the
local-only commits live, so nothing has to be reconciled).

The laptop's age key was added 2026-10-14 (recipient `&macbook-max` in
`.sops.yaml`) and lives where sops actually looks on macOS:

```
~/Library/Application Support/sops/age/keys.txt
```

**Not** `~/.config/sops/age/keys.txt` — sops resolves the key file through Go's
`os.UserConfigDir()`, which on darwin is `~/Library/Application Support`. (The
server is Linux, so there the same convention *does* mean
`~/.config/sops/age/keys.txt`.) Setting `SOPS_AGE_KEY_FILE` also works if a
non-default path is ever needed.

### 9. Diagnose over ssh; a deploy is not a debugging tool

Questions about live state are answered by reading the box, not by changing it.
Everything below is read-only and costs one `ssh`, not a build:

```bash
ssh homeserver-edt.local 'journalctl -u <svc> --since "-30min" --no-pager -o cat'
ssh homeserver-edt.local 'systemctl show <svc> -p User -p PrivateUsers -p ProtectSystem'
ssh homeserver-edt.local 'stat -c "%a %u:%g %n" <path>; findmnt -no OPTIONS <path>'
ssh homeserver-edt.local 'timeout 10 ls <path>; curl -4 -m 10 -sS -o /dev/null -w "%{http_code}\n" https://<host>/'
```

- **Never add a temporary unit or module to run a command as another user.**
  That is a build + switch on a live box for what `sudo -u`, the service's own
  log, or its UI would answer. Worse, the commit lands on `origin/main`, so the
  next `nixup` installs it even if the deploy you meant to use it for was
  aborted — and removing it costs another cycle. (Happened: a `TEMP:` probe in
  `mac-share.nix` was committed, the deploy was interrupted, and the cleanup
  became a revert commit.)
- **When the answer is behind a permission boundary, ask for the one command.**
  `/var/lib/jellyfin` and `secrets.yaml` are 0700/root-only; `sudo -n -l` on the
  host grants NOPASSWD for exactly `nixos-deploy`, `efibootmgr` and
  `systemctl reboot`, so anything else needs the user — which is a message, not
  a config change.
- **The one real exception is a service's own sandbox** (`PrivateUsers`,
  `ProtectSystem`, mount namespaces), when you need to reproduce *its* view of
  the filesystem. Say why you need it, keep it to one deploy, and remove it in
  the same session.
- **Logs usually already answered it.** Jellyfin's `The specified path does not
  exist: /mnt/mac/Downloads` and `Library folder /mnt/mac is inaccessible or
  empty` named the exact path and failure with no privileged inspection at all.
- **A networking change can kill the deploy that applies it.** Deploys run over
  `ssh homeserver-edt.local`, and macOS prefers AAAA for that name, so disabling
  IPv6 mid-switch cut the deploy's own connection: the rebuild finished, the
  client sat until the 900 s tool timeout, and it looked like a hang. Before
  deploying anything that touches `networking.*`, either prove the current
  transport is IPv4 (`ssh -4 …`) or expect to reconnect and verify afterwards.
  The same class of thing applies to firewall and interface changes.

## Repo structure
```
flake.nix                  — inputs, outputs, all machine definitions

hosts/
  homeserver-edt/          — NixOS server config (split into concern-focused modules)
    default.nix            — entrypoint, imports sub-modules
    hardware-configuration.nix
    boot.nix               — kernel, loader, plymouth
    networking.nix         — hostname, avahi, zerotier, ssh, firewall
    desktop.nix            — display manager, plasma, bluetooth, jellyfin TV client
    services.nix           — cockpit, jellyfin, transmission, homepage, nginx
    packages.nix           — system packages, fonts, users (pinned uid), shell (nixup/nixrs)
    mac-share.nix          — the Mac's SMB share as an on-demand cifs automount at /mnt/mac
    pi-agent/              — pi coding agent (deepseek models/settings)
    AUDIO.md               — PipeWire/Wine latency notes; how the audio stack is tuned
    AIRPLAY.md             — AirPlay audio + screen mirroring + now-playing display
    TV-MEDIA.md            — casting to the TV, the phone remote, playing Mac files
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
  sink-pi/                 — Raspberry Pi 3B+, the sink MIDI instrument
    default.nix            — the machine: hostname, users, wifi, storage, instrument settings
    local.nix              — the WiFi network (placeholders committed, edited in place)
    authorized_keys.txt    — who may SSH in (sink + root)
    README.md              — two-repo workflow, deploy/image commands, design ownership
  Note: sink-pi is a SPLIT FLAKE: the configuration lives in sink-pi/flake.nix,
  which carries the private `~/dev/sink` input, while the top-level flake has no
  reference to it (Nix resolves every flake input for every evaluation, so an
  input at the top level would make homeserver-edt need the private repository).
  scripts/sink-pi-{switch,image}.sh pass `--dir sink-pi` to the sink container
  recipe (whole repo mounted, built as git+file:///src?dir=sink-pi#...). Builds
  happen on the Mac, never on the Pi. See hosts/sink-pi/README.md.

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
    sink-machine.nix       — machine policy for running the sink instrument on a shared Pi
    arr.nix                 — nixarr (WIP)

lib/
  jj-tools/                — custom jj wrapper + tests

sink-pi/                   — split flake for the instrument box (see hosts/sink-pi)
  flake.nix                — inputs.sink (private) lives HERE, not at the top level
  flake.lock               — this box's own pin (nixpkgs nixos-26.05)

scripts/
  sink-pi-switch.sh        — deploy sink-pi: container build + delta copy to the Pi
  sink-pi-image.sh         — build the sink-pi SD image through the sink container recipe
  secrets-edit.sh          — edit homeserver-edt secrets from a machine that isn't the server

plans/                     — design docs for proposed (not yet built) changes
  README.md                — lifecycle + index of plans
  vaultwarden.md           — self-hosted Bitwarden (Vaultwarden), LAN-only, replicated

darwin/                    — macOS Darwin config (MacBooks)
.config/                   — managed dotfiles synced via home-manager
.sops.yaml                 — sops-nix secret encryption config
```

## Variables available in configuration.nix
- `host` = `"${config.networking.hostName}.local"` (currently `homeserver-edt.local`)
- `config.networking.hostName` = `"homeserver-edt"`
- `lib.mkForce` — use to override module defaults that conflict
