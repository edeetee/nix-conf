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
| [plasma-bigscreen.md](./plasma-bigscreen.md) | draft | A second Wayland session (KDE Plasma Bigscreen) as the TV UI, chosen at login by a state file, with a `tv-session` command and TTY/ssh/KDE Connect ways to get back to Plasma. |
| [cheaper-models.md](./cheaper-models.md) | draft | Cheaper models for the pi agent loop: no hosted candidate beats DeepSeek Flash's cache-read price at a 3.5M-token-cached-token/prompt profile, and 12 GB of VRAM cannot hold 140k context. Keep the model, use off-peak pricing, cut turns × context. |
| [tailscale.md](./tailscale.md) | draft | Tailscale as the private network (no public IP, nothing always-on for connectivity), rpi3b as subnet router + exit node, then retire ZeroTier. |
