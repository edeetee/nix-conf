# plans/

Design documents for things that are **proposed but not yet built**.

A plan here is expected to be *false until proven otherwise*: it describes the
intended shape of a change, the decisions still open, and the verification that
will show it works. Nothing in `plans/` runs on any host.

Lifecycle:

1. **draft** — written before any code, decisions still open.
2. **in progress** — decisions made, being implemented; the plan doubles as the
   work checklist and is updated as reality disagrees with it.
3. **done** — the change is committed and deployed. Move the durable knowledge
   (how it works, how to operate it, what bit us) into the host docs
   (`hosts/<host>/*.md`, e.g. `AIRPLAY.md`, `AUDIO.md`) and either delete the
   plan or shrink it to a short "what we did and why" note.

Conventions: one file per topic, `Status:` line near the top, decisions in
tables, code as *sketches* (not copy-paste-finished), and an explicit
verification section — the repo rule is "verify before committing, not after".

## Index

| Plan | Status | Summary |
| --- | --- | --- |
| [vaultwarden.md](./vaultwarden.md) | draft | Self-hosted Bitwarden (Vaultwarden), LAN-only, on rpi3b + homeserver-edt, with replication and tested restores. |
| [kde-declarative-settings.md](./kde-declarative-settings.md) | in progress | Moved homeserver-edt's hand-edited Plasma settings (KDE Connect run commands, power/sleep keys) into nix-conf. Implemented and verified; not deployed. |
| [kodi-tv.md](./kodi-tv.md) | draft | Retire Jellyfin and the whole Plezy/Bigscreen client stack: Kodi 21.3 fullscreen inside the Plasma session as the only TV UI, with the Steam Launcher addon (in the pin) for launching games. Deletes ~375 lines and a flake input; one unproven risk (audio passthrough). |
| [kodi-jellycon.md](./kodi-jellycon.md) | superseded | Kodi 21.3 + JellyCon as the TV client, with a decision on whether Jellyfin stays in the TV's path. Superseded by `kodi-tv.md`, which takes that decision (Jellyfin goes) and drops JellyCon. |
| [plasma-bigscreen.md](./plasma-bigscreen.md) | rejected | A second Wayland session (KDE Plasma Bigscreen) as the TV UI, chosen at login by a state file, with a `tv-session` command and TTY/ssh/KDE Connect ways to get back to Plasma. Switcher + Plezy implemented; Bigscreen itself waits on a nixpkgs bump (not in the pin). |
| [cheaper-models.md](./cheaper-models.md) | draft | Cheaper models for the pi agent loop: no *paid* candidate beats DeepSeek Flash's cache-read price at a 3.5M-cached-token/prompt profile (only OpenCode Zen's promo free tiers do), and 12 GB of VRAM cannot hold 140k context. Keep the model, use off-peak pricing, cut turns × context. |
| [local-qwen.md](./local-qwen.md) | draft | Local `Qwen3.6-35B-A3B` Q4 on homeserver-edt: a LAN `llama-server` endpoint for pi on the Mac, plus an unattended task-queue loop on the server. 4-bit only (15 GiB RAM caps the pool at ~24 GB → 16 k context), one task per pi invocation, commits to review branches, GPU gated off during Steam/AirPlay. |
| [tailscale.md](./tailscale.md) | draft | Tailscale as the private network (no public IP, nothing always-on for connectivity), rpi3b as subnet router + exit node, then retire ZeroTier. |
