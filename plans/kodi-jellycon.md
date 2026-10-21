# Kodi as the TV client (JellyCon / Jellyfin for Kodi), and whether Jellyfin stays

Status: **draft** — nothing built. Three decisions are open (§6), and one of them
(whether Jellyfin is retired) is the user's call, not a technical one.

## 1. Why this is on the table

The TV stack as it stands is a chain of pushed-forward pieces: a Plasma Bigscreen
6.7.5 shell overlaid onto a pinned Plasma 6.6.4 (§9.1 of
`plasma-bigscreen.md`), a Flutter client (`plezy`) overlaid from a newer nixpkgs
with a 2 GiB build-time Flutter SDK, and a KWin script forcing fullscreen. It
works, and it was the fastest way to a TV UI on this box — but each link is
something only this repo does, and the phone remote-control question it was
supposed to answer is still unproven.

Kodi is the boring answer to the same question: a real 10-foot UI, the media
player whose video/audio path people compare everything else to, gamepad and
CEC support as first-class features, and a remote-control API that a phone app
(Kore) has spoken for a decade.

Already available in the **pinned** nixpkgs — no overlay needed:

| Fact | Value |
| --- | --- |
| `pkgs.kodi` | **21.3** |
| `pkgs.kodiPackages.jellycon` | **0.9.1** |
| `pkgs.kodiPackages.jellyfin` (Jellyfin for Kodi) | **2.0.0** |
| addons packaged in `kodiPackages` | 102 |
| composable | `kodi.withPackages (kp: [ kp.jellycon ])` — `passthru.withPackages`/`passthru.packages` verified |

## 2. Do we still need Jellyfin at all?

Two different questions hide in that one.

**Can Kodi play without a server?** Yes, and that is what makes the question
interesting. Media on this box is already local or on a plain share:

| Location | Who writes it | Kodi can read it as |
| --- | --- | --- |
| `/mnt/hdd/downloads` | transmission (`services.nix`) | a local path |
| `/mnt/hdd/media` | intended by `modules/nixos/arr.nix` (nixarr) — **that module is not imported today**, so treat it as aspiration | local path |
| `/mnt/mac/<folder>` | the Mac's SMB share (`mac-share.nix`) | a local path (automount) or `smb://` |

So a Kodi-only setup is: add those as video sources, let Kodi's scrapers build
the library, done. No server, no transcoding, no library scans over CIFS.

**What does Jellyfin give that Kodi does not?**

| Jellyfin feature | Kept by | Notes |
| --- | --- | --- |
| Metadata library that several devices share | Kodi + JellyCon (or Jellyfin for Kodi) | keeps one scrape, not two |
| Phone/iPad playback, incl. outside the LAN | **only Jellyfin** | Kodi has no remote clients |
| Transcoding for clients that can't direct-play | only Jellyfin | this box has the RDNA2 GPU for it |
| Per-device watch state | Jellyfin (Kodi+JellyCon reports progress back) | Kodi-native library keeps its own state per box |
| A web UI reachable from anywhere on the LAN | only Jellyfin | |

Recommendation: **keep Jellyfin, but stop treating it as the TV's problem.**
It costs almost nothing (already running), it is what the phones use, and it is
the only piece that can transcode. The TV should not depend on it for playback
quality, and with the right addon mode it need not depend on it for content
either:

| Addon | Model | Playback path | Server down |
| --- | --- | --- | --- |
| **JellyCon** (0.9.1) | thin frontend: browse/play from the server, Kodi keeps no copy | Kodi's player, streaming from Jellyfin | library vanishes |
| **Jellyfin for Kodi** (2.0.0) | syncs metadata into Kodi's own DB | Kodi's player; with **direct paths** it plays the file itself | keeps working (stale metadata) |

That asymmetry *is* the retirement path: if you ever want Jellyfin gone from the
TV's critical path, run Jellyfin-for-Kodi with direct paths (or drop the addons
and scrape natively) and the server becomes optional. Nothing about installing
Kodi today forces that decision.

## 3. Shape

```nix
# modules/nixos/kodi.nix (new, reusable)
{ pkgs, ... }:
{
  environment.systemPackages = [
    # Addons are baked in rather than installed through Kodi's GUI store: the
    # GUI route writes into ~/.kodi/addons, which no rebuild reproduces.
    (pkgs.kodi.withPackages (kp: with kp; [
      jellycon
      # jellyfin          # only if Jellyfin-for-Kodi (DB sync) is chosen — §2
    ]))
  ];
}
```

Then three separate concerns, in order of risk:

1. **Where Kodi runs.** Three options (§6.1): its own Wayland session like
   LibreELEC does (`kodi --standalone`, selected through `tv-session`), a windowed
   app inside Bigscreen, or fullscreen under the existing Plasma session. The
   session option is the one that behaves like a TV OS; it is also the one that
   needs the audio device and the display mode set up front.
2. **Audio passthrough.** Kodi's settings are GUI state in
   `~/.kodi/userdata/guisettings.xml` — there is no NixOS option for them, and
   they are the whole point of this box's audio work (`AUDIO.md`). Set once by
   hand: output device = the HDMI/PipeWire sink, *enable passthrough*, enable
   AC3 / EAC3 / DTS / TrueHD. Then snapshot the file into the repo (or
   `xdg.configFile` it) so a wipe does not lose it. Verify with a DD5.1 title and
   `pw-top`/`pactl list sinks` — the sink must show `iec958`/passthrough, not PCM.
3. **Phone remote.** Kodi's own webserver + **Kore** (free). Needs
   Settings ▸ Services ▸ Control ▸ "Allow remote control via HTTP". That is
   *not* the Jellyfin app; it is a different app, with its own library UI.

## 4. Files touched

| File | Change |
| --- | --- |
| `modules/nixos/kodi.nix` | new — package with addons, per §3 |
| `hosts/homeserver-edt/default.nix` | import it |
| `hosts/homeserver-edt/tv-session.nix` | a third mode (`kodi`) if §6.1 picks a session |
| `hosts/homeserver-edt/TV-MEDIA.md` | a section on the Kodi path once it works |
| `hosts/homeserver-edt/packages.nix` | drop `plezy` if it is retired; keep `jellyfin-desktop` until the Kodi path is proven |

## 5. Verification

```bash
nix flake check --no-build
nixos-rebuild build --flake .#homeserver-edt        # on the server, no switch
```

Then on the box, in order:

1. `kodi --version` and that the addons are visible (Settings ▸ Add-ons ▸ My add-ons).
2. JellyCon connects to `http://localhost:8096`, the account's libraries appear,
   and a title plays.
3. **Direct play, not transcode:** while playing, Jellyfin ▸ Dashboard ▸ Active
   sessions must show *Direct play* / *Direct stream*, not transcode.
4. **Passthrough:** the HDMI sink is in passthrough mode for a DD5.1 title
   (`pw-top` or `pactl list sinks | grep -i iec958`), and the Sony shows the
   surround format.
5. Kore pairs and can navigate, pause, seek.
6. Pull the network from Jellyfin (stop the service) while playing a
   JellyCon-sourced title: playback of the already-open file should continue;
   a *new* title should fail. That is the measured difference between JellyCon
   and Jellyfin-for-Kodi, and the input to §6.2.

## 6. Open decisions

1. **Where Kodi runs** — own session (`kodi --standalone`, most TV-like, competes
   with `homeserver-tv`/Bigscreen), app inside Bigscreen (keeps one shell, loses
   the "TV OS" feel and Kodi's own gamepad handling may fight Bigscreen's
   `inputhandler`), or fullscreen under Plasma (simplest, least TV-like).
2. **JellyCon vs Jellyfin for Kodi** — §2's table. JellyCon first (no local
   sync, no CIFS scans). Switch to Jellyfin-for-Kodi + direct paths only if the
   server-dependence or a stale library becomes the annoyance.
3. **Is Jellyfin retired?** Not recommended: it is the only path for phone/iPad
   playback and the only transcoder. What *is* recommended is retiring things
   that exist only because the TV needed a client: `plezy`, `plezy-overlay.nix`,
   `plezy-fullscreen.nix`, and possibly the Bigscreen overlay (§9.1 of
   `plasma-bigscreen.md`) if Kodi's own UI replaces it. That decision is worth
   making deliberately, after the Kodi path is proven, not before.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Kodi config is GUI state, so the box is not reproducible | snapshot `~/.kodi/userdata/{guisettings,sources,advancedsettings}.xml` into the repo; accept the rest |
| Audio passthrough on AMD HDMI + PipeWire may not "just work" the way mpv does | `AUDIO.md` already documents the sink behaviour (`node.pause-on-idle`); verify with `pw-top` before declaring victory; keep `jellyfin-desktop` (mpv) as the known-good fallback |
| The display currently reports **1280x720** (seen in Plezy's log), so a TV UI may look soft | fix the mode in the session before judging Kodi's rendering |
| `/mnt/mac` is an on-demand CIFS automount; a Kodi library scan can re-arm it and stall | JellyCon avoids local scans entirely; if native library is chosen, scan `/mnt/hdd` first and treat `/mnt/mac` as an explicit "sync to HDD" job (TV-MEDIA.md already says this) |
| Two shells competing (Bigscreen + Kodi) | §6.1 decides one owner of the TV session; do not run both |
| `kodiPackages` addon versions track Kodi 21 — a future Kodi bump may drop JellyCon | both are in the pin and both are packaged; a pin bump is the same class of change as any other |
