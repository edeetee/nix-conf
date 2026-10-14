# Plan: declarative KDE Plasma settings (KDE Connect run commands, power/sleep)

**Status:** in progress — implemented and verified in the tree, **not deployed**
(no `nixup` has run). `❓` marks a decision still open; `✔` marks one the code had
to answer anyway, with what was chosen.

**Implementation:** `flake.nix` (input + HM wiring), `hosts/homeserver-edt/home.nix`,
`hosts/homeserver-edt/kde.nix`, `hosts/homeserver-edt/kde-connect-run-commands.nix`,
plus a firewall declaration in `networking.nix` and a pointer comment in
`desktop.nix`. The sections below are kept as the reasoning; where they disagree
with those files, the files are right.

**Goal:** the Plasma settings that today exist *only* as hand-edited state in
`~/.config` on `homeserver-edt` can be read, reviewed and reproduced from this
repo, and survive a re-pairing, a wiped `~/.config`, or a fresh install. The
first two targets are the ones the repo already depends on implicitly:

1. the three **KDE Connect run commands** — one of which is the documented way to
   bring the Jellyfin TV client back after it was quit (`desktop.nix`, the
   "Start it again from the phone (KDE Connect run command)" comment);
2. the **power / sleep keys** in `powerdevilrc`, which are currently set by hand
   and are invisible in git.

**Non-goals:** theming/ricing, panels, wallpaper; managing Plasma on any other
machine (there is none); replacing Plasma; making settings apply at runtime with
no re-login (upstream explicitly does not support that).

---

## 1. What exists today (read off the host, 2026-10-14)

| Setting | Where it lives now | Why it matters | If it is lost |
| --- | --- | --- | --- |
| KDE Connect run commands | `~/.config/kdeconnect/5084597a_631d_4d53_a50c_37d89c3c178e/kdeconnect_runcommand/config`, `[General] commands="@ByteArray({…})"` — `shutdown`, `Jellyfin TV`, `Jellyfin TV (stop)` | the phone-driven start/stop of `jellyfin-desktop` is the recovery path the repo documents | the documented recovery path is gone, and nothing in git says it existed |
| Power / sleep | `~/.config/powerdevilrc`: `[AC][Display] TurnOffDisplayIdleTimeoutSec=-1`, `TurnOffDisplayWhenIdle=false`, `[AC][SuspendAndShutdown] PowerButtonAction=8` | keeps the HDMI output alive (the box is a cast target) and makes the power button a safe "shut down" | silently reverts to Plasma defaults: display blanks on idle, power button action changes |
| Suspend blocking | already declarative — `desktop.nix` (`services.logind.settings.Login`, `systemd.sleep.settings.Sleep`) | the box must stay up | — (untouched by this plan) |

Three facts worth recording because they change the design:

* `~/.config/powermanagementprofilesrc` contains **only**
  `[Migration] MigratedProfilesToPlasma6=powerdevilrc`. The Plasma 6 migration has
  already run, so `powerdevilrc` is now the authoritative file, and that is the
  file `plasma-manager` writes.
* KDE Connect works today with `networking.firewall.enable = false`
  (`networking.nix`). Nothing declares the KDE Connect port range (1714–1764), so
  *if the firewall is ever enabled, KDE Connect dies silently.* Worth fixing in
  passing (§6.5).
* The per-device "Run commands" enable toggle left **no file** on the host: the
  whole persistent state of the feature is the `commands` blob above.

---

## 2. Mechanisms considered

| Option | What it is | Verdict |
| --- | --- | --- |
| **A. `plasma-manager` (a Home Manager module)** | typed Nix options (`programs.plasma.powerdevil.AC.turnOffDisplay.idleTimeout = "never"`) plus a raw `configFile` escape hatch for files with no module (KDE Connect) | **Recommended** — the only option that scales past these two files, and it merges rather than takes over |
| **B. `kwriteconfig6` one-shot in `desktop.nix`** | a `systemd.user.services.kde-settings` oneshot in the existing style (`bt-power-on`) that runs `kwriteconfig6` for each key at login | Credible fallback, ~15 lines, **no new flake input**, verified to reproduce the blob byte-for-byte (§8). No type checking, and it re-asserts only at login |
| C. standalone `home-manager switch` for the user | HM outside the NixOS config | Rejected: a second deploy command on a host whose whole workflow is one `nixup` |
| D. `home.file` symlinks to the store | what most dotfile setups do | Rejected: KDE rewrites configs with `QSaveFile` (temp + rename), so the symlink is replaced and the file drifts with no merge and no conflict detection |

**Option A does not use `home.file`.** `plasma-manager`'s `files.nix` generates a
script from upstream's `script/write_config.py` and wires it as
`home.activation.configure-plasma` (after `writeBoundary`). That script *reads
the existing file, overwrites only the keys it knows, and leaves every other line
alone* — which is why it is safe to point at a `~/.config` that is otherwise
hand-made. `overrideConfig = false` (the default) is a merge, not a takeover.

Consequences that fall out of reading the source, and that drive the decisions:

* With `overrideConfig = false`, `resetFiles` defaults to `[]` unless window rules
  are used, so nothing is deleted. **Enabling `overrideConfig` on this host would
  put `powerdevilrc` in `defaultResetFiles` and delete it** before rewriting only
  the keys we declare (losing `TurnOffDisplayWhenIdle=false` and everything else
  KDE put there). If it is ever wanted, `powerdevilrc` must go into
  `resetFilesExclude` first.
* A key whose value is `null` is **removed** from the file, not left alone.
* Values are escaped in KDE's own format unless `escapeValue = false`. That
  matters below.
* `immutable` (per key, or globally via `immutableByDefault`) appends `[$i]` to
  the key. That is the *only* thing that stops the GUI from changing a value — an
  ordinary key is simply rewritten by System Settings and re-overwritten on the
  next activation.
* On NixOS, HM activation is a **system** unit, `home-manager-edeetee.service`
  (`wantedBy = [ "multi-user.target" ]`, `User=edeetee`,
  `before = systemd-user-sessions.service`), because `startAsUserService`
  defaults to false. So AGENTS.md's "new user units are not started on an
  already-running user manager" does **not** apply here: the unit's `ExecStart`
  changes on every switch, so systemd restarts it and the settings are
  re-applied on each `nixup`.

### 2.1 Prior art — yes, other people do this (checked 2026-10-14)

Not a novel idea, and the parts that matter have been solved already:

* **`plasma-manager` is mainstream.** ~1.2k stars, a NixOS wiki page, and it is
  what the wiki's KDE page recommends for declarative Plasma
  (`nixos.wiki/wiki/KDE`, `nixos.wiki/wiki/Plasma-Manager`). The "I want
  powerdevil AC/battery settings in Nix" question is a recurring discourse
  thread.
* **The power/sleep values in §4 are a well-worn idiom.** `gh search code
  'autoSuspend.action = "nothing"'` and `'turnOffDisplay.idleTimeout = "never"'`
  each hit a dozen-plus public configs, several with both together
  (`xddxdd/nixos-config`, `Gako358/dotfiles`, `DanielTallon/nixed`,
  `chuahou/conf.nix`, `d4ve10/nixos-config`, `ogadra/dotfiles`, …). One of them
  is literally a *server that also runs a graphical session* that must not doze
  off (`heywoodlh/nixos-configs`, the Sunshine host) — the same shape as this
  box.
* **Declaratively writing the KDE Connect run commands is a known trick**, with
  the same `@ByteArray` + escaped-quotes encoding derived independently in at
  least six public configs: `so1ve/nix-config`, `sitolam/sitolamix`,
  `ErrorNoInternet/configuration.nix`, `kucendro/os`, `knoc-off/nixos`,
  `kpbaks/nixos-config` (commented out). Two of them carry a comment explaining
  the Qt `QByteArray`-inside-INI escaping, which is exactly §3.
* **Two styles are in the wild**, and they differ in the way §2 predicts:
  * `xdg.configFile` / `home.file` symlinks (`so1ve`, `sitolam`,
    `ErrorNoInternet` via `hjem`) — simple, but `home.file.force` defaults to
    **false** (`home-manager/modules/lib/file-type.nix`), so once KDE rewrites
    the file (its `QSaveFile` rename replaces the symlink) the next activation
    errors or backs the file up. These users' run commands have to be treated
    as read-only.
  * an activation script that installs a generated file (`kucendro/os`,
    `knoc-off/nixos`) — merges nothing, but survives anything.
* **`programs.plasma.configFile` pointed at a `kdeconnect/…` path seems
  unattested** — I found no public example. It is still the nicest option
  because it merges rather than symlinks, but it is the one part of this plan
  without prior art.

Two refinements worth stealing from the prior art, both of which this plan
originally got wrong:

1. **Do not hard-code the phone's id — write into every device directory.**
   `kucendro/os` and `knoc-off/nixos` loop over
   `"$HOME/.config/kdeconnect"/*/` on activation and install the same config
   into each. Re-pairing then needs no repo edit, and it matches the plugin's
   own data model (one directory per paired device). This has to be a shell
   loop, so it is an activation script, not a `configFile` entry.
2. **Derive the command ids instead of pasting KDE's UUIDs.** They are keys in a
   JSON map the phone treats as opaque, so `kucendro/os` generates them as
   `md5(name)` formatted `8_4_4_4_12` (the same underscore shape KDE itself
   writes — compare `a59e8c25_377f_469e_886b_413400a1307e`). That turns the repo
   contents into a plain `name → command` map with no opaque ids.

Note on the directory name: it is the **remote** device's id, not this
machine's. On `homeserver-edt` the directory name matches the `[5084597a_…]`
section of `~/.config/kdeconnect/trusted_devices`, whose `name=` is
`Edward’s iPhone` (the machine's own id is a different value, from the CN of
`~/.config/kdeconnect/certificate.pem`). At least one public config
(`sitolam/sitolamix`) has this backwards in a comment.

### 2.2 The `kuriikwsfilterrc` trap (and an upstream bug it flushed out)

`programs.plasma.enable = true` does **not** mean "write only what I declare".
`modules/search-plugins/web-search-keywords.nix` writes `kuriikwsfilterrc`
unconditionally, and its `default` option is `null` by default. In the writer a
`null` value means *delete the key*, and `_json_value_checks` **raises** when a
key has no value and its immutability differs from the default — which it always
does, because `lib/writeconfig.nix` passes `immutableByDefault` to Python as the
*string* `"false"` and `write_config.py` does `bool(sys.argv[3])`, which is
`True` for any non-empty string.

So a plain `programs.plasma.enable = true` makes the generated `plasma-config`
script **throw**, which under HM's `set -eu` activation aborts everything after
it and leaves the config half-applied. Evaluation cannot see this — nothing in
Nix knows the writer will reject its own output — and it was the dry run in §7
that caught it.

Workaround, with a comment in `kde.nix` saying why:
`searchPlugins.webSearchKeywords.default = "duckduckgo"`, which is what Plasma
resolves to anyway (`runners/webshortcuts/webshortcutrunner.cpp`:
`grp.readEntry("DefaultWebShortcut", QStringLiteral("duckduckgo"))`). The other
four keys that module writes are read nowhere in plasma-workspace 6.6 — they are
Plasma 5 leftovers — so the file it creates is inert.

Worth reporting upstream: `immutableByDefault = false` is passed as `"false"`
and read back as `True`, which makes any `null` value in a non-empty group fatal.
Note `immutableByDefault = true` *masks* the bug (the comparison then matches),
which is relevant because that is the other way §6.3 could go.

---

## 3. Verified: the `@ByteArray` escaping (the one thing that would have bitten us)

The KDE Connect blob is not plain JSON:

```
commands="@ByteArray({\"a59e8c25_…\":{\"command\":\"shutdown now\",\"name\":\"shutdown\"},…})"
```

i.e. an `@ByteArray(…)` prefix, an outer pair of quotes, and `\"` around every
key and value. `plasma-manager`'s default escaping escapes `\` as `\\`, so the
naive version double-escapes the backslashes and KDE Connect loses all three
commands. Verified three ways on this machine:

1. `kwriteconfig6` does not re-escape, and creates intermediate directories:

   ```
   $ kwriteconfig6 --file /tmp/pmtest/nested/dir/one --group G --key k '@ByteArray({"a":"b"})'
   $ cat /tmp/pmtest/nested/dir/one
   [G]
   k=@ByteArray({"a":"b"})
   ```

2. KDE's own value round-trips unchanged through `kreadconfig6` → `kwriteconfig6`
   (so the on-disk text *is* the value, and option B can reproduce it verbatim).

3. Running upstream's `script/write_config.py` against a copy of the live file:

   | Input | Result |
   | --- | --- |
   | rebuilt value, `escapeValue = false` | **byte-identical** to the live file |
   | same value, `escapeValue = true` (the default) | `@ByteArray({\\"a59e…\\":…` — corrupted |

The value can be *generated* from structured Nix instead of pasted as an opaque
string, and that also reproduces KDE's bytes exactly:

```nix
# Commands as a plain name -> shell command map. The ids KDE Connect keys them
# by are opaque to the phone, so derive them from the name (the prior art does
# this; md5 formatted 8_4_4_4_12, the same underscore shape KDE itself writes)
# rather than pasting UUIDs into the repo.
commands = {
  "shutdown"           = "shutdown now";
  "Jellyfin TV"        = "systemctl --user start jellyfin-desktop";
  "Jellyfin TV (stop)" = "systemctl --user stop jellyfin-desktop";
};

mkId = name: let h = builtins.hashString "md5" name; s = builtins.substring;
  in "${s 0 8 h}_${s 8 4 h}_${s 12 4 h}_${s 16 4 h}_${s 20 12 h}";

commandsJson = builtins.toJSON (
  lib.mapAttrs' (name: command: lib.nameValuePair (mkId name) { inherit name command; }) commands
);

# Exactly what KDE Connect writes: quoted @ByteArray, inner JSON quotes escaped.
runCommandsValue =
  "\"@ByteArray("
  + lib.replaceStrings [ "\"" ] [ "\\\"" ] commandsJson
  + ")\"";
```

Caveat for whoever verifies this: `builtins.toJSON` sorts attribute names, so the
keys come out in sorted order rather than the order KDE inserted them, and the
ids change from the ones on the host today. Both are cosmetic for a JSON *map* —
but they mean the check is a JSON-level comparison, **not** `diff` (see §7).

---

## 4. Implementation sketch

### 4.1 `flake.nix` — new input

```nix
plasma-manager = {
  url = "github:nix-community/plasma-manager";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
};
```

### 4.2 `flake.nix` — wire HM into *this host only*

```nix
nixosConfigurations.homeserver-edt = nixpkgs.lib.nixosSystem {
  modules = commonModules ++ [
    ./hosts/homeserver-edt
    # …existing modules…
    home-manager.nixosModules.home-manager
    {
      # One nixpkgs instantiation instead of two.
      home-manager.useGlobalPkgs = true;
      # NixOS-native package handling — see the note below: the default (false)
      # was the wrong choice for this host.
      home-manager.useUserPackages = true;
      home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ];
    }
  ];
};
```

The first draft of this plan said to keep `useUserPackages = false`. **That was
wrong, in a way worth recording.** With `false`,
`submoduleSupport.externalPackageInstall` is false, so HM's `installPackages`
activation step installs `home-manager-path` **into the user's
`~/.nix-profile`** — on this host a nix-env profile that still holds a
hand-installed `nixops-1.7` and has no `manifest.json`, so it takes the
`nix-env -i` branch and `exit 1`s if anything conflicts. A `nixup` would
imperatively rewrite a years-old profile that is not ours, which is the opposite
of the point.

With `useUserPackages = true` those packages go through
`users.users.edeetee.packages` → `/etc/profiles/per-user/edeetee`, built by
NixOS at switch time, and the only activation step left is the guarded
`nixProfileRemove home-manager-path` cleanup — a no-op here (no `manifest.json`;
`nix-env -q` does not list it). `environment.profiles` is identical before and
after, so **`$PATH` does not change at all**: `/etc/profiles/per-user/$USER` was
already in it.

**Do not put `home-manager.nixosModules.home-manager` in `commonModules`.** That
list is also fed to `mkDarwin`, and Darwin already wires HM through
`home-manager.darwinModules.home-manager` (a *different* module) — adding the
NixOS one there breaks every Mac. `rpi3b` imports neither, and must not gain HM.

### 4.3 `hosts/homeserver-edt/home.nix` + `kde.nix` (new, mirrors `darwin/home.nix`)

```nix
# home.nix — the Home Manager entrypoint for this host
{ ... }:
{
  home-manager.users.edeetee = { ... }: {
    # One-time choice, same as darwin/home.nix. home.username /
    # home.homeDirectory are filled in from users.users.edeetee by the HM
    # NixOS module; do not set them here.
    home.stateVersion = "25.05";
    imports = [ ./kde.nix ];
  };
}
```

```nix
# kde.nix — the only file (besides home.nix) that talks about Plasma
{ lib, pkgs, ... }:
let
  # … commands / mkId / commandsJson / runCommandsValue from §3 …

  runCommandsFile = pkgs.writeText "kdeconnect-runcommand-config" ''
    [General]
    commands="${runCommandsValue}"
  '';
in
{
  # Typed and *merged* into the live file: power/sleep.
  programs.plasma = {
    enable = true;

    # System Settings ▸ Power Management, AC only (this box has no battery).
    # Values map to the ints Plasma stores: "shutDown" -> 8, "never" -> -1.
    powerdevil.AC = {
      powerButtonAction = "shutDown";        # PowerButtonAction=8
      turnOffDisplay.idleTimeout = "never";  # TurnOffDisplayIdleTimeoutSec=-1
      # ❓ autoSuspend.action = "nothing"    # see §6.2 — do NOT add yet
    };
  };

  # No plasma-manager module exists for KDE Connect (upstream tracks it in issue
  # #398 as "per-device databases for custom commands"), and the config is keyed
  # by the *paired device*, so write it into every device directory on each
  # activation instead of naming one id (§2.1). `run` and `$DRY_RUN_CMD` are
  # provided by HM's activation script (lib/bash/home-manager.sh).
  home.activation.kdeconnectRunCommands = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    kdeDir="$HOME/.config/kdeconnect"
    if [ -d "$kdeDir" ]; then
      for dev in "$kdeDir"/*/; do
        [ -d "$dev" ] || continue
        run mkdir -p "''${dev}kdeconnect_runcommand"
        run install -m644 ${runCommandsFile} "''${dev}kdeconnect_runcommand/config"
      done
    fi
  '';
}
```

This replaces that one file wholesale, which is fine today (it holds nothing but
`[General] commands`) and is what the prior art does — but it is *not* a merge,
so if KDE Connect ever grows a second key in there, revisit. The alternative,
`programs.plasma.configFile."kdeconnect/<id>/…".General.commands = { value =
runCommandsValue; escapeValue = false; }`, merges instead but forces a
hard-coded device id back into the repo; keep it in mind if the loop ever causes
trouble.

`TurnOffDisplayWhenIdle=false`, which is on disk today, is *not* written by
`plasma-manager` and is preserved by the merge. It must stay consistent with
`TurnOffDisplayIdleTimeoutSec=-1`; do not let `overrideConfig` eat it (§2).

As implemented, `kde.nix` also carries one extra line —
`searchPlugins.webSearchKeywords.default = "duckduckgo"` — which is not a setting
we want but the workaround to the writer bug in §2.2, and a second file
(`kde-connect-run-commands.nix`) holds the blob so it can be evaluated on its
own. Neither changes the design above.

### 4.4 What is deliberately *not* declared

`dimDisplay` is currently unset (so KDE's defaults apply), `autoSuspend` is
unset, and `general.pausePlayersOnSuspend` is unset. Each of those is a
behaviour change if written, so each is a ❓ below rather than a silent decision.
The only extra thing declared beyond the two settings is the inert
`webSearchKeywords.default` from §2.2, which is there to keep activation working
rather than to change anything.

---

## 5. Blast radius, honestly

| Risk | Assessment | Mitigation |
| --- | --- | --- |
| HM takes over the server's `~/.config` | Low at present: `plasma-manager` merges the files it names and nothing else, and the dry run (§7) shows exactly which files it touches | review every future addition to `home.nix`; keep it Plasma-only |
| HM takes over the user profile / `$PATH` | ✔ Avoided by `useUserPackages = true` (§4.2): packages go to `/etc/profiles/per-user/edeetee` via NixOS, and `environment.profiles` is unchanged | check `nix-env -q --profile ~/.nix-profile` after the first switch |
| New files appearing in `$HOME` | HM's own five (`.cache/.keep`, `.local/state/.keep`, `.config/environment.d/10-home-manager.conf`, `.config/systemd/user/tray.target`) plus two empty rc files Plasma did not have (`kcminputrc`, `ksplashrc`) and `kuriikwsfilterrc` — all inert, all verified by dry run | accepted |
| Activation failure on switch | The unit is `wantedBy multi-user.target`, so a failure is logged rather than blocking boot — but under `set -eu` a throw leaves the config half-applied, which is how §2.2 nearly shipped | `systemctl status home-manager-edeetee.service`, `journalctl -u …` |
| A second moving part in every update | `plasma-manager` trunk tracks HM's unstable branch; both are pinned in `flake.lock`, but `nix flake update` can land an incompatible pair | treat a `plasma-manager`-related eval failure after `nix flake update` as expected, not mysterious |
| Building on the Mac | The Mac has no Linux builder (`nix config show`: `extra-platforms = x86_64-darwin`, `builders = @/etc/nix/machines`), so the NixOS config cannot be *built* here | `nix flake check --no-build` (evaluates, satisfies the repo rule) + `nixos-rebuild build` on the server |
| KDE Connect re-pairing | The commands live in a per-device directory: a new phone = a new id = an empty list | §6.4 |
| Firewall | KDE Connect's 1714–1764 range worked only because the firewall is off | ✔ declared in `networking.nix` (§6.5) |

---

## 6. Decisions

### 6.1 ❓ A (`plasma-manager`) or B (`kwriteconfig6` oneshot)

**Recommend A**, with B kept as a documented fallback (§8) rather than a
preamble. A is the only option that gives typed, reviewable settings and a path
to everything else (shortcuts, session, screen locker, panels) — and this repo
has already accepted HM on the Darwin side, so the new thing here is HM's
presence *on the server*, not HM itself. It is also the mainstream choice
(§2.1). B is genuinely attractive on a host with a hand-made `~/.config` and
exactly two files to manage, so if the review of §5 makes anyone uneasy, take B
and revisit A when a third setting appears.

Either way the KDE Connect half is most likely an activation script looping over
the device directories (§2.1, §4.3), because that is what makes re-pairing a
non-event. The plan is therefore really "plasma-manager *plus* a small script",
not one or the other.

### 6.2 ❓ Do we declare "never auto-suspend" at the Plasma layer too?

`plans/vaultwarden.md` §1 already flags the contradiction between AGENTS.md ("the
server sleeps aggressively") and `desktop.nix` ("Never suspend", blocked at the
logind level). Declaring `powerdevil.AC.autoSuspend.action = "nothing"` picks a
side at a *second* layer. **Recommend: not yet.** Encode only what is on disk
today (display always on, power button = shut down), and settle "does this box
sleep" once, in one plan, before asserting it in two places.

### 6.3 ❓ Immutable keys?

`immutableByDefault = true`, or `immutable = true` per key, makes System Settings
show the value greyed out and unable to write it. For a box that must not be
made to sleep by a stray GUI click this is attractive; it is also the difference
between "declared" and "enforced". **Recommend: start mutable (the default), then
make the two powerdevil keys immutable** once we know System Settings still
behaves. Do not make the KDE Connect blob immutable: KDE Connect itself rewrites
that file, and `[$i]` there risks confusing it for no gain.

### 6.4 ✔ The device id — settled by the per-device loop

Implemented as the "every device directory" loop (§2.1, §4.3) plus ids derived as
`md5(name)` (§3), not the hard-coded `phoneId` this section originally proposed.
No repo edit after a re-pair, and no opaque UUIDs in the tree.

What it costs: the ids on the phone change once (verified: same three
name/command pairs, different keys), and the config is written by a script rather
than scanned at eval time — Nix cannot read the filesystem. A phone paired
mid-session is picked up on the next activation; otherwise the phone's list is
refreshed when it asks for it.

### 6.5 ✔ Declare KDE Connect's port range

Done in `networking.nix` (`allowedTCPPortRanges`/`allowedUDPPortRanges` =
1714–1764, with a comment): no effect today, but KDE Connect no longer depends on
the firewall staying off.

### 6.6 ❓ `dimDisplay`

Unset today, so KDE's default (dimming, with its own timeout) applies. On a
TV-attached, always-on cast target, dimming is arguably wrong. Writing
`AC.dimDisplay.enable = false` adds `DimDisplayWhenIdle=false` and
`DimDisplayIdleTimeoutSec=-1`. **Ask before writing it** — it is a visible change,
not a reproduction.

### 6.7 ❓ `home.stateVersion`

HM's `stateVersion` is a one-time, permanent choice. `darwin/home.nix` uses
`"25.05"`; the nixpkgs input is unstable (the host runs `26.05.…`).
**Recommend `"25.05"`** for consistency with the Darwin side (an older
`stateVersion` only preserves older defaults; a newer one than the HM release is
the risky direction).

---

## 7. Verification

The repo rule is "verify before committing, not after", and the interesting
output here is *file bytes* — which evaluation alone cannot check, because the
thing that decides whether a byte string is acceptable is upstream's Python
writer (§2.2).

### Done, 2026-10-14, on the Mac (nothing deployed)

1. `nix flake check --no-build` passes with HM + plasma-manager wired in.
2. `nix eval …programs.plasma.powerdevil.AC` → `powerButtonAction = 8`,
   `turnOffDisplay.idleTimeout = -1`: the typed options map to the ints Plasma
   stores, and match the host.
3. `…programs.plasma.overrideConfig` = false, `resetFiles` = `[]`,
   `immutableByDefault` = false → nothing is deleted on activation.
4. **Dry run of the writer** against copies of the host's real rc files
   (`kdeglobals`, `kglobalshortcutsrc`, `ksmserverrc`, `powerdevilrc`), feeding it
   `nix eval …programs.plasma.configFile` and invoking it exactly as the generated
   `plasma-config` script does — `python3 write_config.py data.json "" "false"`:
   * writer exit **0** (after the §2.2 pin; before it, exit 1 with a traceback);
   * `powerdevilrc`, `kdeglobals`, `kglobalshortcutsrc`, `ksmserverrc` come back
     **byte-identical** — `TurnOffDisplayWhenIdle=false` survives, and the two
     keys we declare already hold those values;
   * it *creates* `kuriikwsfilterrc` (inert, §2.2) and empty `kcminputrc`,
     `ksplashrc`.
5. **The generated KDE Connect file** vs the live one: same shape
   (`[General]` + `commands="@ByteArray(\"…\")"`), and the same three
   name/command pairs after `json.loads`. Only the ids differ, by design (§3).
6. Baseline diff against `HEAD` (`git archive HEAD` into a scratch dir, then
   `nix eval` both): `environment.systemPackages` and `environment.profiles`
   unchanged; `users.users.edeetee.packages` gains only HM's
   `home-manager-path`; `home.profileDirectory` =
   `/etc/profiles/per-user/edeetee`; the firewall ranges are the only other
   system-level delta.
7. `git check-ignore` on the new files → not ignored.

### Still to do, on the server (deploy time)

8. Copy the live files to `/tmp` first (`powerdevilrc` and every
   `kdeconnect/<id>/kdeconnect_runcommand/config`) — that is the rollback.
9. `nixos-rebuild build --flake ~/dev/nix-conf` (no root) to warm the store, then
   ask the user to run `nixup` (sudo needs a TTY).
10. `systemctl status home-manager-edeetee.service`;
    `journalctl -u home-manager-edeetee -n 50` — a failure here means a partial
    application, so read it rather than assuming.
11. `cat ~/.config/powerdevilrc`, and `kreadconfig6 --file … --group General
    --key commands` in each device dir, compared with the pre-change values at
    the JSON level.
12. KDE Connect reads the list at its own pace: if the phone still shows the old
    commands, restart the daemon — it is a KDE autostart user unit here,
    `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart 'app-org.kde.kdeconnect.daemon@autostart.service'`.
13. If the power settings did not take effect, `plasma-powerdevil` is the live
    user unit
    (`XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart plasma-powerdevil`).
    A re-login is the documented fallback — upstream lists "real-time updates
    without logging out and back in" as not well supported.
14. On the phone: KDE Connect → the device → **Run commands** → three entries,
    same names; run "Jellyfin TV" and confirm
    `systemctl --user status jellyfin-desktop` goes active.
15. No collateral damage: `nix-env -q --profile ~/.nix-profile` still lists only
    `nixops-1.7`, `$PATH` unchanged, `~/.zshrc` untouched, and the session's own
    user units (`jellyfin-desktop`, `bt-power-on`, the AirPlay services) are
    still running.
16. Rollback: `git revert <sha> && nixup`; restore the `/tmp` copies if a KDE key
    was removed. Note the activation is idempotent, so a revert needs no manual
    cleanup beyond that.

---

## 8. Appendix: option B, if A is rejected

Both settings are reproducible with the tool KDE itself uses — verified in §3
(no re-escaping, creates intermediate directories) and again for the nested
`[AC][Display]` grouping:

```nix
# in desktop.nix, next to bt-power-on.  Same shape as the prior art's activation
# scripts (kucendro/os, knoc-off/nixos), and independent of how plasma-manager
# would have written the same values.
systemd.user.services.kde-settings = {
  description = "Re-assert the Plasma settings this host owns";
  after = [ "plasma-plasmashell.service" ];
  wantedBy = [ "plasma-plasmashell.service" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = pkgs.writeShellScript "kde-settings" ''
      set -eu
      # nb: kwriteconfig6 lives in kdePackages.kconfig, not plasma-workspace.
      kw() { ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 "$@"; }
      # Repeated --group makes the nested [AC][Display] section (verified).
      # Absolute --file: relative names resolve under $XDG_CONFIG_HOME, which is
      # not set in a systemd unit's environment.
      kw --file "$HOME/.config/powerdevilrc" --group AC --group Display \
         --key TurnOffDisplayIdleTimeoutSec -- -1   # '--' so -1 is not read as an option
      kw --file "$HOME/.config/powerdevilrc" --group AC --group SuspendAndShutdown \
         --key PowerButtonAction 8
      # Every paired device, so re-pairing needs no repo edit (§2.1).
      for dev in "$HOME/.config/kdeconnect"/*/; do
        [ -d "$dev" ] || continue
        mkdir -p "''${dev}kdeconnect_runcommand"
        install -m644 ${runCommandsFile} "''${dev}kdeconnect_runcommand/config"
      done
    '';
  };
};
```

The cost is that it re-asserts only at login, has no types or assertions, and
leaves every key editable in the GUI; the benefit is that it adds no flake input
and touches nothing outside the two files. (The sketch assumes `desktop.nix`
gains `lib` in its arguments, and the generated `runCommandsFile` is hoisted into
its `let` block.) Note this variant needs no `kwriteconfig6` for the KDE Connect
half at all — a file write is a file write; `kwriteconfig6` is only here for the
power keys.

---

## Sources

* `plasma-manager` — <https://github.com/nix-community/plasma-manager>
  (`modules/files.nix`, `modules/powerdevil.nix`, `modules/hotkeys.nix`,
  `lib/types.nix`, `lib/writeconfig.nix`, `script/write_config.py`, `README.md`)
* KDE Connect module status (unimplemented, "per-device databases for custom
  commands") — <https://github.com/nix-community/plasma-manager/issues/398>
* Home Manager: activation unit and `useGlobalPkgs`/`useUserPackages`
  (`nixos/default.nix`, `nixos/common.nix`), `home.username`/`homeDirectory`
  inference, `home.file.force` defaulting to false (`modules/lib/file-type.nix`),
  and the `run` helper used above (`lib/bash/home-manager.sh`, sourced into the
  activation script by `modules/home-environment.nix`)
* PowerDevil settings reference —
  <https://docs.kde.org/stable_kf6/en/powerdevil/kcontrol/powerdevil/>
* Prior art, KDE Connect run commands declared in Nix — `so1ve/nix-config`,
  `sitolam/sitolamix`, `ErrorNoInternet/configuration.nix`,
  `kucendro/os` (also the md5 ids and the per-device loop), `knoc-off/nixos`,
  `kpbaks/nixos-config`. Found with `gh search code 'kdeconnect_runcommand/config'`.
* Prior art, the power/sleep values — `gh search code 'autoSuspend.action = "nothing"'`
  and `'turnOffDisplay.idleTimeout = "never"'` (`xddxdd/nixos-config`,
  `Gako358/dotfiles`, `DanielTallon/nixed`, `chuahou/conf.nix`,
  `d4ve10/nixos-config`, `ogadra/dotfiles`, `heywoodlh/nixos-configs`, …).
  NixOS wiki: <https://nixos.wiki/wiki/Plasma-Manager>, <https://nixos.wiki/wiki/KDE>.
* Observed on `homeserver-edt` 2026-10-14: Plasma/KWin 6.6.4,
  `plasma-powerdevil` (user unit) active, kdeconnectd running as
  `app-org.kde.kdeconnect.daemon@autostart.service`,
  `home-manager-*.service` absent.
