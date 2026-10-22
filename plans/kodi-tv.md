# Kodi as the whole TV stack, and retiring Jellyfin

Status: **in progress** — the code is written and committed; nothing is deployed
or verified on the box yet. Supersedes `kodi-jellycon.md`, which asked the same
question but left Jellyfin mandatory. The scope here is the narrow one the user
actually has: **one TV, one box, playing local files.** No phones, no off-LAN, no
transcoding. Under that scope Jellyfin has no job in the playback path, and
neither does anything built to be a Jellyfin client.

What landed (2026-10-22, one commit): `modules/nixos/kodi.nix`; Jellyfin, Plezy,
`jellyfin-desktop`, plasma-bigscreen, `tv-session.nix`, the `nixpkgs-bigscreen`
flake input and the four Jellyfin/Bigscreen KDE Connect commands removed. Steps
1–4 of §8 are in the tree; steps 0 (passthrough gate) and 5 (narrow `/mnt/mac`)
are **not done**, because both need the box. Nothing has been deployed.

## 1. What is being replaced, and why it is safe

The TV path today, file to screen:

```
/mnt/hdd/downloads  →  jellyfin (server, scan, HTTP)  →  plezy (Flutter app,
                       overlaid from a newer nixpkgs)      + KWin fullscreen script)
```

Every link after the file is something only this repo does. Kodi deletes all of
them:

| Piece | LOC | Why it exists | Kodi needs it? |
| --- | --- | --- | --- |
| `plezy-overlay.nix` | 29 | pinned plezy predates Jellyfin support; overlay 2.23.0 + a **2 GiB build-time Flutter SDK** | no |
| `plezy-fullscreen.nix` | 68 | KWin script to force plezy fullscreen | no (Kodi is fullscreen natively) |
| `bigscreen-overlay.nix` | 97 | plasma-bigscreen 6.7.5 transcribed onto a 6.6 stack | no |
| `tv-session.nix` | 154 | state file + SDDM relogin to choose Plasma vs Bigscreen at login | no (§3) |
| `jellyfin-desktop` unit | ~14 | direct-play fallback for AC-3/DTS | no (mpv/vlc stay as the fallback) |
| `services.jellyfin` + homepage entries | ~15 | the server | no (§2) |
| `inputs.nixpkgs-bigscreen` | flake input | source tree for the two overlays above | no |

**~375 lines, one flake input and a 2 GiB toolchain** go away, replaced by one
~40-line module. The evidence that this is cheap, checked against the pin:

| Fact | Value |
| --- | --- |
| `pkgs.kodi` | **21.3**, `gpl2Plus`, `unfree = false` — no `allowUnfree` needed |
| addons packaged in `kodiPackages` | **102** |
| `kodiPackages.steam-launcher` | **3.7.11** — "Launch Steam in Big Picture Mode from Kodi" |
| `libretro-*` cores | 2048, mgmt/mgba, nestopia, snes9x, genplus, fuse, gw (RetroPlayer) |
| `kodiPackages.jellycon` / `.jellyfin` | 0.9.1 / 2.0.0 — **not used by this plan** |

Nothing here needs an overlay, a second nixpkgs, or a flake bump.

## 2. Content: there is no library, so there is nothing to migrate

`/mnt/hdd/media` is **96 K** (empty); `modules/nixos/arr.nix` (nixarr) is *not*
imported. The media that exists is the transmission download folder:

```
/mnt/hdd/downloads   62 G, 15 items (films, Silo S03, Modern Family S06, …)
```

So the "library" Jellyfin serves is a download directory, and Kodi's job is: add
one video source, scrape once, done. No server, no scan over the network, no
direct-play-vs-transcode decision to get wrong.

**One existing piece is worth keeping.** `scripts/jellyfin-movie-import.sh`
(untracked as of this writing) hardlinks each film into
`/<library>/Movies/<Title> (<Year>)/<Title> (<Year>).<ext>`, so a scraper gets a
deterministic name instead of `www.UIndex.org - Toy Story 4 2019 REPACK 1080p`.
Its *reason* was Jellyfin's parser, but the artefact is scraper-neutral: Kodi
matches cleaner paths too, and `/mnt/hdd/media/library/` already exists for it
(empty — the script has only been dry-run). Decision D7.

Deliberately **not** added as a Kodi source: `/mnt/mac/*`. It is an on-demand
CIFS automount of a Mac that sleeps; a scan re-arms it and stalls. `TV-MEDIA.md`
already frames Mac media as an explicit "copy it to the HDD when you want it"
job, and that framing survives this plan unchanged.

## 3. Decision: where Kodi runs (the one that shapes everything else)

Three shapes, and the app-launching question decides it:

| Shape | TV feel | Launch Steam / other apps from Kodi | Audio path | Cost |
| --- | --- | --- | --- | --- |
| **A. Fullscreen inside the existing Plasma session** (autostart, `Restart=on-failure`) | Kodi fills the screen; SDDM still autologins to Plasma, which is invisible | **yes** — Steam GamepadUI is a normal window on a compositor that already exists | pipewire-pulse, **identical to today's mpv path** | ~Plasma's RAM stays resident |
| B. Kodi as its own session (`kodi --standalone`, GBM/DRM) | a real TV OS; no desktop at all | **no** — `--standalone` takes the DRM device with no compositor, so a launched GUI app has nowhere to draw | Kodi's own output, possibly direct ALSA — **a new passthrough unknown** | lowest RAM; `video`/`render`/`input` groups; quitting ends the session |
| C. Kodi replaces the Bigscreen shell in `tv-session` | as B, plus a switcher | no | as B | keeps `tv-session.nix` alive |

**Chosen: A.** The reasoning, in the order it matters:

1. **Only A can launch other applications.** B and C are technically the better
   TV OS and are *why* LibreELEC exists — but they give up exactly the feature
   asked about. A keeps the desktop underneath, so the Kodi `steam-launcher`
   addon, `steam-on-demand.service`, `vlc`/`mpv`, and Firefox all still work.
2. **A does not change the audio path.** Kodi plays through pipewire-pulse to
   the HDMI sink, the same route `mpv`/`jellyfin-desktop` already use and the one
   `AUDIO.md` is tuned for. B changes it, and the passthrough question (§6) is
   already the plan's one real unknown without adding a second.
3. **A deletes `tv-session.nix`.** The switcher exists to answer "how do I get
   back to the desktop from the couch". With Plasma always the session, the
   answer is **quit Kodi** — `Restart=on-failure`, not `always`, so a crash
   comes back and a quit stays quit. That is the same reasoning
   `jellyfin-desktop` already uses in `desktop.nix`.
4. A is fully reversible: it is one user unit and one package.

B stays documented as a later step, unscheduled, only if Kodi's look and idle
RAM under Plasma disappoint.

## 4. Shape of the change

```nix
# modules/nixos/kodi.nix  (new, host-agnostic)
{ pkgs, ... }:
let
  kodi = pkgs.kodi.withPackages (kp: with kp; [
    # Steam in Big Picture from Kodi's home screen. Addons are baked in rather
    # than installed through the GUI store: the store writes ~/.kodi/addons,
    # which no rebuild reproduces.
    steam-launcher
  ]);
in
{
  # Kodi's JSON-RPC + web UI. Read by "Official Kodi Remote" (iOS, free, Kodi
  # Foundation) and Kore (Android). Plain HTTP and unauthenticated unless
  # guisettings sets a user, so: a LAN port, never a forwarded one.
  networking.firewall.allowedTCPPorts = [ 8080 ];

  systemd.user.services.kodi-tv = {
    description = "Kodi (TV UI, fullscreen)";
    wantedBy = [ "plasma-plasmashell.service" ];
    after = [ "plasma-plasmashell.service" "pipewire.service" ];
    # Restart=on-failure, deliberately not `always`: a crash comes back, but
    # quitting Kodi has to stay quit so the desktop is usable.
    serviceConfig = {
      Type = "simple";
      ExecStart = "${kodi}/bin/kodi";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
```

Three things this does not capture, in order of risk:

1. **Kodi's settings are GUI state** in `~/.kodi/userdata/guisettings.xml`
   (output device, "start fullscreen", passthrough toggles, the library source).
   No NixOS option exists for any of it. Decision D3: snapshot the file into the
   host doc, or deploy an *if-absent* copy on activation (Kodi rewrites the file
   on exit, so a read-only symlink would fight it).
2. **The video source** (`/mnt/hdd/downloads`) and the scraper choice are also
   GUI state, in `~/.kodi/userdata/sources.xml` + the addon's own settings.
3. **`kodi -fs`/`--fullscreen`**: verify the flag in `kodi --help` on the box;
   if absent, "Start fullscreen" in Settings ▸ System is the one-time fix. Do not
   guess it into the unit.

## 5. Files touched

| File | Change |
| --- | --- |
| `modules/nixos/kodi.nix` | **new** — package with addons + `kodi-tv` user unit + port 8080 |
| `hosts/homeserver-edt/default.nix` | import it; drop `./tv-session.nix`, `./bigscreen-overlay.nix`, `./plezy-overlay.nix`, `./plezy-fullscreen.nix` |
| `hosts/homeserver-edt/services.nix` | **delete** `services.jellyfin`; delete the Jellyfin homepage service + bookmark (leave Cockpit/Transmission; "Media" group disappears) |
| `hosts/homeserver-edt/packages.nix` | drop `jellyfin-desktop`, `plezy` |
| `hosts/homeserver-edt/desktop.nix` | delete the `jellyfin-desktop` user unit and its comment block; keep mpv/vlc |
| `flake.nix` | drop the `nixpkgs-bigscreen` input, its `specialArgs`, and the §9.1 comment block (lines ~5-10) |
| `hosts/homeserver-edt/kde-connect-run-commands.nix` | drop `Swap TV UI`, `TV mode (restart)`, `Desktop mode (restart)`, `Jellyfin TV (stop)`, `(start)`; add `TV UI` = `systemctl --user start kodi-tv` and `Desktop` = `systemctl --user stop kodi-tv` |
| `hosts/homeserver-edt/unified-remote.nix` | header comment only: the arrows now drive Kodi's own keyboard handling, not the Bigscreen shell. The uinput chain and mpv-mpris stay |
| `hosts/homeserver-edt/mac-share.nix` | see §7 — the world-readable mount can narrow to owner-only |
| `hosts/homeserver-edt/networking.nix` | comment only: the IPv6-disable block was motivated by Jellyfin's 100 s TMDb timeouts. Do **not** revert it in this change (it also carries the `lo` and `wlp5s0` overrides, and reverting is its own risky deploy) |
| `hosts/homeserver-edt/TV-MEDIA.md` | rewrite §1 (no Jellyfin Desktop, no Plezy, no Bigscreen) around Kodi + the remote + AirPlay |
| `hosts/homeserver-edt/AUDIO.md` | a short "Kodi passthrough" section once verified |
| `plans/plasma-bigscreen.md` | status → **rejected**, one line pointing here |
| `plans/kodi-jellycon.md` | status → **superseded by this file** |
| `plans/README.md` | index row |
| `modules/nixos/arr.nix` | decision D4: nixarr's shape assumes Jellyfin; delete it or keep it as aspiration |
| `scripts/jellyfin-movie-import.sh` | **untracked** — rename to `scripts/movie-import.sh` and commit, or drop it. Its output tree helps any scraper, so D7 leans keep-and-rename; the `# Jellyfin` rationale in its header needs rewriting either way |
| `AGENTS.md` | repo-structure line for `services.nix` and the `homeserver-edt/` listing still name jellyfin |
| `hosts/rpi3b/services.nix` | one comment mentions the homeserver running jellyfin — cosmetic |

Order matters: the four deletions in `default.nix`/`flake.nix` are one deploy and
must be **last** (§8). Everything before that is additive.

## 6. The one unknown: audio passthrough

`AUDIO.md` is tuned for Wine→pipewire-pulse→HDMI, and mpv's advantage there is
that it *decodes to PCM* and follows the default sink. Kodi's bitstreaming
passthrough is a different code path. Under shape A the sink is the same one
mpv uses, which is why A is the lower-risk choice, but it is still unverified.

Set once in Kodi (Settings ▸ System ▸ Audio): output device = the HDMI/PipeWire
sink, **allow passthrough**, enable AC3 / EAC3 / DTS / TrueHD. Then prove it on
a DD5.1 title — `/mnt/hdd/downloads` already has several
(`Moana 2016 … DTS`, `Modern.Family.S06 … DD5.1`, `Toy Story 4 … DDP 7 1`) — and
check the sink shows `iec958`/passthrough rather than PCM:

```bash
ssh homeserver-edt.local 'pactl list sinks | grep -iE "iec958|a52|dts"'
ssh homeserver-edt.local 'pw-top -b -n 2'
```

Keep `mpv` and `vlc` installed regardless: they are the known-good fallback and
they are not Jellyfin pieces.

## 7. Unlocked: the Mac share can stop being world-readable

`mac-share.nix` mounts the Mac's SMB share `uid=1000,file_mode=0444,dir_mode=0755`
— world-readable — and the header says why: `services.jellyfin` sets
`PrivateUsers=yes`, so a `nounix` cifs mount's owner renders as `nobody` to
jellyfin and only the `other` bits are ever consulted. The stated price is that
`~/.ssh` and the sops age key on the Mac are readable by **every service account
on this box**.

Kodi runs as `edeetee` (uid 1000) with no `PrivateUsers`, so **the forcing
condition disappears**. This plan therefore narrows the mount to
`file_mode=0400,dir_mode=0700` in the same series. That is a real, checkable
reduction in exposure bought by deleting a service — worth doing deliberately,
and worth doing after the Jellyfin removal rather than with it (§8), so a mount
failure cannot be confused with a Kodi failure.

## 8. Migration series (one deploy per step, rollback at every point)

| # | Step | Rollback |
| --- | --- | --- |
| 0 | **Passthrough gate.** `nix shell nixpkgs#kodi` from the running Plasma session, add `/mnt/hdd/downloads`, play a DD5.1 title, check `pactl`/`pw-top` | nothing committed |
| 1 | Add `modules/nixos/kodi.nix`, import it. Kodi appears in the app list; Jellyfin untouched | revert one import |
| 2 | Turn on `kodi-tv` at login (the `wantedBy` above). Live with it a week | `systemctl --user stop kodi-tv`; `systemctl --user start jellyfin-desktop` still works |
| 3 | Delete the **client** stack: plezy pkg + overlays + fullscreen script, `jellyfin-desktop` pkg/unit, `tv-session.nix`, `bigscreen-overlay.nix`, the `nixpkgs-bigscreen` input, the stale KDE Connect commands | `git revert` — the server is still running and plezy is one attribute |
| 4 | Delete **Jellyfin**: `services.jellyfin`, homepage entries, package refs | `git revert`; note `/var/lib/jellyfin` is left on disk (root-owned) until removed by hand |
| 5 | Narrow `/mnt/mac` to `0400/0700` | revert one line |

Step 3 before step 4 is deliberate: it proves the TV never needed the server
while the server is still there to prove it *with*. That is the measurement the
older plan wanted and never took.

## 9. Verification

```bash
nix flake check --no-build
nixos-rebuild build --flake .#homeserver-edt      # on the server, no switch
```

Then on the box, in order:

1. `kodi --version` → 21.3; `--help` shows the fullscreen flag (§4.3); Settings ▸
   Add-ons ▸ My add-ons lists **Steam Launcher**.
2. Boot → Plasma autologins → Kodi is fullscreen. `systemctl --user stop kodi-tv`
   → the desktop is there and stays there after a reboot.
3. A title from `/mnt/hdd/downloads` plays, artwork and metadata scraped.
4. **Passthrough** (§6) on a DD5.1 title.
5. **Official Kodi Remote** (iOS) pairs with `homeserver-edt.local:8080` and can
   browse the library and seek. Unified Remote arrows still navigate (§5).
6. **Steam from Kodi**: the Steam Launcher addon starts GamepadUI and the window
   appears over Kodi. Confirm whether Kodi keeps the audio sink while Steam runs;
   if it does, use the addon's "close Kodi first" option (this is the one thing in
   the plan that may need a setting rather than a rebuild). Also confirm the
   existing controller-triggered `steam-on-demand` still comes up over Kodi.
7. One retro core launches a ROM through RetroPlayer (proves the libretro addons
   are wired, optional).
8. Nothing on 8096: `ss -tlnp | grep -E '8096|8080'` shows only 8080.

## 10. Costs, stated plainly

| Cost | Detail |
| --- | --- |
| **Kodi is not in the binary cache here** | `cache.nixos.org` returns 404 for `kodi-21.3` and `kodi-jellycon-0.9.1`; `nix build --dry-run` wants **19 derivations built from source**. Expect a 20–40 min first build on the 12-core box, and the same on any pin bump that touches kodi/kodiPackages. The Mac cannot help (no x86_64-linux builder). This is the one thing that is genuinely *worse* than the current stack, which installs from cache |
| **GUI-state config** | settings/sources/scrapers live in `~/.kodi/`, so the box is less reproducible than now. Snapshot (§4.1) or accept |
| **Plasma stays resident** | shape A keeps the desktop underneath Kodi. Acceptable on a box that already runs it; this is the argument for B later, not now |
| **Watch state resets** | Jellyfin's resume points live in its DB and are lost. One TV, one viewer — low value, but say it out loud |
| **Scraping messy names** | the downloads are scene names (`www.SceneTime.com - Wallace and Gromit …`); Kodi's scrapers handle these, but expect a few manual matches |
| **Still no CEC** | unchanged: no `/dev/cec*` on RDNA2, no Pulse-Eight dongle. The phone remains the remote |

## 11. Decisions taken during implementation

The open decisions above were resolved while writing the code; recorded here so
the next reader does not reopen them by accident.

| # | Decision | Where it landed |
| --- | --- | --- |
| D1 | Session shape **A** — fullscreen inside Plasma | `modules/nixos/kodi.nix` header explains why (compositor for `steam-launcher`, pipewire-pulse for audio) |
| D2 | **Always autostart**, no state file; `Restart=on-failure` | same file; `stop` is the way to the desktop |
| D3 | **Not implemented yet** — there is nothing to snapshot before Kodi has run once | module header names D3 as the follow-up |
| D4 | `arr.nix` **kept**, with a header saying its Jellyfin half is stale | `modules/nixos/arr.nix` |
| D5 | Homepage **kept**, serving Cockpit + Transmission; the Media group is gone | `services.nix` |
| D6 | **Both** Steam entry points (addon baked into the module, `steam-on-demand` untouched) | `kodi.nix`, `modules/nixos/steam.nix` |
| D7 | `scripts/jellyfin-movie-import.sh` **left alone** (untracked, another session's work); still named for Jellyfin | TV-MEDIA.md §1 recommends pointing Kodi at its output too |

Still open in the plan's sense: step 5, narrowing `/mnt/mac` to `0400/0700`. It is
deliberately a separate deploy, and `mac-share.nix` had unrelated in-flight edits
when this landed.

## 12. Open decisions

1. **D1 — session shape.** Decided in §3: fullscreen inside Plasma. Revisit B only
   if Kodi's idle RAM or the "a desktop is running" feel becomes annoying.
2. **D2 — is `kodi-tv` autostart always on?** §8 step 2 says yes, because the box
   is a TV. The alternative is a state file like `tv-session`'s — rejected: it
   reintroduces the machinery this plan exists to delete when "quit Kodi" already
   answers the question.
3. **D3 — Kodi settings: snapshot into the repo, or activation-copy if absent?**
   Leaning if-absent copy for `guisettings.xml`/`sources.xml` plus a doc snapshot.
4. **D4 — `modules/nixos/arr.nix`**: delete (nixarr assumes Jellyfin) or keep as
   aspiration? It is not imported, so deleting is free.
5. **D5 — homepage dashboard**: keep it serving Cockpit + Transmission with no
   Media group, or retire it too? Out of scope here; noted because it stops being
   a media dashboard.
6. **D6 — Steam entry point**: the Kodi addon, the controller-triggered
   `steam-on-demand`, or both? Leaning both, addon first, since the addon is what
   makes Kodi feel like a launcher.
7. **D7 — `scripts/jellyfin-movie-import.sh`**: it is untracked, so nothing breaks
   by ignoring it — but a `Movies/<Title> (<Year>)` hardlink tree is exactly what
   makes Kodi's scraper deterministic, and hardlinking keeps Transmission
   seeding. Leaning: rename to `movie-import.sh`, commit, point Kodi at
   `/mnt/hdd/media/library` **in addition to** `/mnt/hdd/downloads`.
