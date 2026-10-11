# Plan: self-hosted Vaultwarden (LAN-only) replacing Bitwarden cloud

**Status:** draft — nothing implemented. Decisions marked ❓ need an answer before
code lands.

**Goal:** own the password vault. A Vaultwarden server reachable only on the home
LAN, whose data exists on **both** `homeserver-edt` and `rpi3b`, survives any
`nixos-rebuild`, and can be promoted on either node after a tested restore. Then
migrate off Bitwarden cloud.

**Non-goals:** public exposure / port forwarding, active-active clustering,
SSO/OIDC, multi-tenant orgs.

---

## 1. Constraints (from this repo, not invented)

| Constraint | Where it comes from | Consequence for this design |
| --- | --- | --- |
| No inbound from the internet | user requirement | No ACME HTTP-01/TLS-ALPN. Cert must come from **DNS-01**. |
| Web vault needs a secure context | browsers block WebCrypto on plain HTTP (only `localhost` is exempt) | HTTPS + a real hostname, not `http://192.168.1.x`. |
| Bitwarden clients validate the TLS chain | mobile/desktop clients | A private CA is a liability on Android; use a publicly-trusted cert. |
| `networking.firewall.enable = false` on both hosts | `hosts/*/networking.nix` | "LAN-only" must be enforced by **binding** + DNS, not by a firewall. Must be deliberate. |
| `homeserver-edt` may drop off the network when idle | `AGENTS.md` §server quick facts | Do **not** put the only copy on it, and do not depend on it being awake to sync. |
| …but `desktop.nix` blocks suspend at the logind level | `hosts/homeserver-edt/desktop.nix` | ❓ These contradict each other. One is stale. Confirm which before choosing the primary (§2.3). |
| `rpi3b` is the always-on box | `hosts/rpi3b/default.nix` | Natural home for the authoritative instance. |
| `rpi3b` = 1 GB RAM, SD root, 2.4 GHz WiFi / 100 Mbit eth | `hosts/rpi3b/install.md` | Vaultwarden itself is fine (~50 MB RSS). SD wear and SD failure are the risks — they are handled by replication, not by hoping. |
| `rpi3b` config has **no sops** | `flake.nix` (rpi3b imports no `sops-nix` module) | Prerequisite work if the primary lives there (§4.4). |
| Vaultwarden's state dir is derived from `system.stateVersion` | `nixos/modules/services/security/vaultwarden/default.nix` | Both hosts are `23.11` ⇒ data dir is **`/var/lib/bitwarden_rs`**. A future stateVersion bump silently relocates it (§5). |
| `services.vaultwarden.backupDir` gets a module-owned tmpfiles rule | same module (AGENTS rule #1) | Backup dir must be a **dedicated subdirectory** (e.g. `/mnt/hdd/vaultwarden/backup`), never `/mnt/hdd` itself. |
| `/mnt/hdd` is `nofail` | `hosts/homeserver-edt/hardware-configuration.nix` | Anything writing there needs `RequiresMountsFor`, or it silently writes into the root fs (§5). |

Pinned versions available now: `vaultwarden` **1.35.8** (sqlite/mysql/postgresql
outputs), `litestream` **0.5.11** with a NixOS module (`services.litestream`),
`security.acme` with `dnsProvider`/`environmentFile`/`credentialFiles`, and
`services.keepalived` + `services.restic` if wanted later.

---

## 2. Decisions

### 2.1 ❓ Domain & certificate

| Option | Verdict |
| --- | --- |
| **A. Real cert, LE + DNS-01, hostname under a domain you already own** (`vault.edt.nz`) | **Recommended.** DNS-01 only proves DNS control — the A record may point at a private IP, so nothing is exposed. Zero client setup, works on iOS *and* Android. Cost: DNS provider API token in sops, and the name is publicly resolvable to a `192.168.1.x` address (mild info leak; make the A record the LAN IP deliberately, see §2.2). |
| B. Private CA (`step-ca`/`mkcert`) + install root CA everywhere | Rejected. Android apps commonly ignore user-installed CAs; you would be debugging device trust forever. |
| C. Self-signed (`ROCKET_TLS` or nginx self-signed) | Rejected, same reason, plus it is explicitly "testing only" upstream. |
| D. `.home.arpa` / `*.lan` | Not LE-issuable ⇒ falls back to B/C. No. |

Questions: which DNS host serves `edt.nz`, and does it have an API token for
lego (Cloudflare, Route53, Gandi, deSEC, rfc2136…)? `vault.edt.nz` is free.

### 2.2 ❓ DNS shape

* **A. Public `A vault.edt.nz → 192.168.1.<primary>`** — simplest, works on every
  device on the LAN with no local DNS work. Off-LAN devices resolve and fail,
  which is exactly the desired "sync only at home" behaviour.
* **B. No public record; add a local override** on whatever serves DNS at home
  (router / AdGuard / Pi-hole). Better privacy, needs local DNS control.
* **C. Public record + local override** (`A → primary`) — belt and braces.

Recommend **A**, switch to **C** later if a local DNS server ever exists.

### 2.3 ❓ Which node is primary

| Option | Pros | Cons |
| --- | --- | --- |
| **1. Primary = `rpi3b`** (always on) | Sync always works at home, independent of the homeserver's sleep behaviour. Litestream pushes every change to the homeserver's `/mnt/hdd` whenever it is awake; gaps are caught up automatically. | SD card is the live disk for a vault. Mitigated by continuous replication + snapshots + a tested promotion (§7). Needs sops added to the Pi. |
| 2. Primary = `homeserver-edt` (fast SSD, beefier) | Best hardware for the live DB. | If the box really does sleep within minutes of idling, "sync before leaving the house" becomes unreliable. Clashes with the reason you use a vault. |

**Recommend 1**, and treat the homeserver as the durable store + standby. This
also inverts nicely: the always-on machine serves, the sleeping machine stores.

### 2.4 ❓ Database backend

**SQLite (module default) — recommended for a 2-node LAN.** It is a single file we
can ship to the other node and restore with one command, which is what "run on
many servers for backup" actually needs. MySQL/Postgres only buys stateless
multi-replica deployments where the DB still lives on one host; it would add a
DB server on the Pi and *reduce* portability.

### 2.5 Replication: Litestream, not active-active

Vaultwarden has no multi-master mode. Two writers, or two nodes with divergent
SQLite files, means the last sync silently wins and items disappear. Options
considered: shared MariaDB Galera cluster (way too much machinery for two boxes),
PostgreSQL + streaming replication (heavier than needed, and Postgres on a 1 GB
Pi), K8s chart with `replicas: 10` (the "HA" the chart advertises is about
sessions, not durability). **Chosen: one writer at a time, continuous replication
to the peer, promotion is a documented, tested act.** See §7.

---

## 3. Architecture

```
   phones / laptops / browser extensions
                 │  https://vault.edt.nz   (DNS A → 192.168.1.<primary>)
                 ▼
 ┌───────────────────────── LAN 192.168.1.0/24 only ───────────────────────────┐
 │                                                                            │
 │  PRIMARY = rpi3b (always on)        STANDBY = homeserver-edt (often down)   │
 │  ┌───────────────────────────┐      ┌────────────────────────────────────┐  │
 │  │ nginx :443 (ACME DNS-01)  │      │ nginx :443  (same cert, same URL)  │  │
 │  │   └──▶ vaultwarden :8222  │      │   └──▶ vaultwarden :8222           │  │
 │  │        /var/lib/          │      │        started only when          │  │
 │  │        bitwarden_rs/      │      │        /var/lib/vaultwarden-active │  │
 │  └─────────────┬─────────────┘      │        exists (promotion)          │  │
 │                │                    └────────────────▲───────────────────┘  │
 │                │  litestream replicate (sftp, ~1 s)    │                     │
 │                └─────────────────────────────────────┘                     │
 │                │                                                           │
 │                ▼  /mnt/hdd/vaultwarden/ltx      (replica, near-zero RPO)   │
 │                   /mnt/hdd/vaultwarden/snapshots/ (dated, pruned)          │
 │                weekly restore drill → integrity_check + user count         │
 └────────────────────────────────────────────────────────────────────────────┘
```

Layers (RPO/RTO):

| Layer | Location | RPO | Protects against |
| --- | --- | --- | --- |
| Live SQLite (`/var/lib/bitwarden_rs`) | primary (SD or SSD) | — | nothing, this is the thing we protect |
| Litestream replica (`/mnt/hdd/vaultwarden/ltx`) | homeserver | seconds (when awake) | SD/disk death on the Pi, bad upgrade, `rm` |
| Nightly `.backup` snapshot + `rsa_key.pem` + attachments | `/mnt/hdd/vaultwarden/backup` (module) and dated copies | 1 day | replica corruption, "the replica is unreadable too" |
| Second physical device | the other node's own disk | see above | one box dying = both copies gone |
| ❓ offsite/offline | not planned; LAN-only by request | — | fire/theft/ransomware |

Three copies, two devices, **no offsite leg**. Note it, decide later (§10, phase 4).

---

## 4. Implementation

### 4.1 New shared module — `modules/nixos/vaultwarden.nix`

One module, both hosts, `role` picks the behaviour. Same `domain` everywhere is
what makes failover invisible to clients.

```nix
# modules/nixos/vaultwarden.nix
{ config, pkgs, lib, ... }:
let
  cfg = config.services.vaultwarden-server;

  # services.vaultwarden derives StateDirectory from system.stateVersion:
  #   23.11 (both hosts today) ⇒ /var/lib/bitwarden_rs
  #   ≥ 24.11                 ⇒ /var/lib/vaultwarden
  dataDir = "/var/lib/bitwarden_rs";   # keep in sync with the tripwire in §5
in
{
  options.services.vaultwarden-server = {
    enable = lib.mkEnableOption "Vaultwarden (LAN-only, replicated)";
    domain = lib.mkOption { type = lib.types.str; example = "vault.edt.nz"; };
    role   = lib.mkOption { type = lib.types.enum [ "primary" "standby" ]; default = "primary"; };
    lanAddress = lib.mkOption { type = lib.types.str; example = "192.168.1.24"; };
    backupDir  = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;
      dbBackend = "sqlite";
      domain = cfg.domain;                       # module prepends https://
      backupDir = cfg.backupDir;                 # sqlite only (module assertion)
      environmentFile = config.sops.templates."vaultwarden.env".path;

      config = {
        # Settings live HERE, not in the admin panel's config.json — otherwise
        # config.json diverges between nodes and silently overrides env on one box.
        SIGNUPS_ALLOWED      = false;   # true only for the first-run bootstrap
        INVITATIONS_ALLOWED  = false;
        SHOW_PASSWORD_HINT   = false;
        WEB_VAULT_ENABLED    = true;
        # needs outbound to push.bitwarden.com; see §6
        PUSH_ENABLED         = true;
      };
    };

    # We keep the module's nginx vhost (it wires up the websocket locations)
    # and only add the cert + the LAN-only bind.
    services.vaultwarden.configureNginx = true;
    security.acme = {
      acceptTerms = true;
      defaults.email = "dev@edt.nz";
    };
    security.acme.certs.${cfg.domain} = {
      dnsProvider = "cloudflare";                     # ❓ provider
      environmentFile = config.sops.templates."acme.env".path;
      # group = "nginx";                              # if nginx can't read the key
    };
    services.nginx.virtualHosts.${cfg.domain}.listenAddresses = [ cfg.lanAddress ];

    # ADMIN_TOKEN etc. never touch the nix store.
    sops.templates."vaultwarden.env".content = ''
      ADMIN_TOKEN=${config.sops.placeholder.vaultwarden-admin-token}
    '';
    sops.templates."acme.env".content = ''
      CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-dns-api-token}
    '';

    # … role-specific units in 4.2 / 4.3
  };
}
```

Notes / gotchas baked in above:

* `security.acme.acceptTerms` + `defaults.email` are required; `dnsPropagationCheck`
  stays at its default `true` (the box needs working DNS to LE at renewal time —
  it has it).
* `enableACME` on the vhost is what nginx uses to consume
  `security.acme.certs.<domain>`; the module already sets `forceSSL`.
* Verify in the first build: the module sets `ROCKET_ADDRESS = "127.0.0.1"`
  and `ROCKET_PORT` (default 8222) itself when `configureNginx` is on, so nginx
  is the only listener. Do **not** also set them in `config` — a conflicting
  definition is a build error, and because the module's port is a `mkDefault`
  our plain value would win silently. Confirm with `nix eval` (§9).
* `config.sops.placeholder."<name>"` requires a matching `sops.secrets."<name>"`
  declaration. The rendered template is root-owned `0400` by default — fine, since
  systemd reads `EnvironmentFile` before dropping privileges and the ACME unit
  runs as `acme`… which is *not* fine for the ACME one: give the acme template
  `owner = "acme"`, or use the secret file directly for `environmentFile`.

### 4.2 Primary role

```nix
services.litestream = {
  enable = true;
  settings = {
    dbs = [{
      path = "${dataDir}/db.sqlite3";
      # litestream 0.5 allows exactly one entry here (two or more is a startup
      # error), so peer + local replicas would have to be separate units.
      replicas = [{
        url = "sftp://vault@homeserver-edt.local:22/mnt/hdd/vaultwarden/ltx";
        sync-interval = "1s";
      }];
    }];
  };
};

# litestream 0.5 writes a _litestream_seq table into the DB and needs to read
# it, so the vaultwarden state dir must be group-traversable (module default is
# 0700 — see the nixos test for services.litestream, which documents exactly this).
systemd.services.vaultwarden.serviceConfig.StateDirectoryMode = lib.mkForce "0770";
users.users.litestream.extraGroups = [ "vaultwarden" ];
systemd.services.litestream = {
  after = [ "vaultwarden.service" ];
  wants = [ "vaultwarden.service" ];
};
# homeserver-edt sleeps: don't let a push failure wedge replication, and don't
# let it exit — Restart=always is already set by the module.
```

The `sftp://` replica needs an SSH key + `known_hosts` for the dedicated
`vault` account on the homeserver, readable by the `litestream` user
(`isSystemUser = true` ⇒ `home` is not `/var/lib/litestream`; set
`systemd.services.litestream.environment.HOME` explicitly and keep the key in
`/var/lib/litestream/.ssh`). **Verify this in phase 2 — if it fights back, fall
back to plan B: keep a `file` replica on the Pi and have a Pi-side timer
`rsync` it to the homeserver, sending a WoL magic packet first if the homeserver
is unreachable (`networking.firewall.allowedUDPPorts = [ 9 ]` and the udev
`power/wakeup` rule in `desktop.nix` are already in place for this).** Plan B is
strictly simpler and has no key-on-a-server-that-sleeps problem; it costs
granularity (15 min instead of ~1 s).

### 4.3 Standby role

Nothing here overwrites a live DB while it is running. The standby is *installed*
but only runs when promoted:

```nix
# Installed, configured, same domain/cert — but only starts when deliberately
# activated, including across reboots.
systemd.services.vaultwarden.unitConfig.ConditionPathExists = "/var/lib/vaultwarden-active";
systemd.tmpfiles.rules = [ "d /var/backup/vaultwarden 0700 vaultwarden vaultwarden -" ];

# Pull the replica + static data from the Pi whenever the homeserver is awake.
systemd.services.vaultwarden-pull = {
  description = "Pull the Vaultwarden replica from the primary";
  after = [ "network-online.target" ]; wants = [ "network-online.target" ];
  serviceConfig = {
    Type = "oneshot";
    User = "vaultwarden";
    # litestream to restore the replica file, rsync for the static data
    path = [ pkgs.litestream pkgs.rsync pkgs.sqlite ];
    # restore db.sqlite3 from the replica, then rsync attachments/ sends/
    # rsa_key.pem — rsa_key.pem MUST match or every client is forced to re-login
  };
};
systemd.timers.vaultwarden-pull.timerConfig = { OnCalendar = "*:0/15"; Persistent = true; };
systemd.services.vaultwarden-pull.unitConfig.RequiresMountsFor = "/mnt/hdd";
```

### 4.4 Prerequisite: sops on `rpi3b`

`modules/nixos/sops.nix` hardcodes `defaultSopsFile = ../../hosts/homeserver-edt/secrets.yaml`.
If the primary is the Pi:

1. `ssh-keyscan rpi3b.local | nix-shell -p ssh-to-age --run "ssh-to-age"` (or read
   `/etc/ssh/ssh_host_ed25519_key.pub` on the Pi), add `&rpi3b` to `.sops.yaml`.
2. Add a creation rule for `hosts/rpi3b/secrets.yaml`; `sops updatekeys`.
3. Generalise the module: `defaultSopsFile = ../../hosts/${config.networking.hostName}/secrets.yaml;`
4. Import `sops-nix.nixosModules.sops` in `flake.nix`'s `rpi3b` list, plus
   `./modules/nixos/sops.nix` in `hosts/rpi3b/default.nix`.
5. Add `vaultwarden-admin-token` (an **argon2-hashed** token; hashing it means the
   plaintext is never in the env file, and the hash can live in git if we prefer)
   and `cloudflare-dns-api-token`.

### 4.5 Wiring, and nice-to-haves

* `hosts/rpi3b/default.nix` — import the new module + `./vaultwarden.nix` host
  params. The Pi deliberately avoids `commonModules`; this module must not pull
  nixvim/docker/postgres in (it does not).
* `hosts/homeserver-edt/default.nix` — import it with `role = "standby"`.
* Homepage dashboard: add a `Vaultwarden` tile using `http://${host}:<port>` →
  ❓ the LAN bind means the homeserver's dashboard can only link to the Pi when
  the Pi is the primary. Link to `https://vault.edt.nz` instead (absolute URL,
  per AGENTS rule #4).
* Optional hardening (phase 4): `services.keepalived` with a VIP
  (`192.168.1.50`, unicast peers, wired ethernet on the Pi) so promotion does not
  require touching DNS at all; `services.restic.backups` with an encrypted repo on
  the Pi + one on `/mnt/hdd`; enabling `networking.firewall` on both hosts (a bigger
  change — every other service on the homeserver needs its ports opened).

---

## 5. "Don't let a rebuild wipe the vault"

What actually protects the data, and what does not:

1. **`/var/lib/bitwarden_rs` is outside the nix store.** `nixos-rebuild switch`,
   `nix.gc`, rollbacks and store optimise cannot touch it. That is the boring but
   main guarantee.
2. **The real hazard is the path moving.** `services.vaultwarden` picks
   `bitwarden_rs` vs `vaultwarden` from `system.stateVersion`. Both hosts sit at
   `23.11` while nixpkgs is 25.11, so the day someone "tidies up" the
   stateVersion, Vaultwarden starts against a fresh empty directory and looks
   wiped. Add a build-time tripwire (this repo already does this for mounts, in
   `modules/nixos/check-mounts.nix`):

   ```nix
   assertions = [{
     assertion = lib.versionOlder config.system.stateVersion "24.11";
     message = ''
       system.stateVersion was bumped to >= 24.11.
       services.vaultwarden derives StateDirectory from it, so the data directory
       silently moves /var/lib/bitwarden_rs -> /var/lib/vaultwarden and
       Vaultwarden starts with an EMPTY database.

       Migrate first:
         systemctl stop vaultwarden
         mv /var/lib/bitwarden_rs /var/lib/vaultwarden
       then delete this assertion.  See plans/vaultwarden.md §5.
     '';
   }];
   ```
3. **`/mnt/hdd` is `nofail`.** A unit writing there must set
   `RequiresMountsFor = "/mnt/hdd"`, otherwise the backup quietly lands on the root
   filesystem and disappears behind the later mount. (Same bug class as the
   `transmission` comment in `hosts/homeserver-edt/services.nix`.)
4. **AGENTS rule #1 applies to `backupDir`.** The vaultwarden module ships its own
   tmpfiles rule that chowns `backupDir` to `vaultwarden`. Keep it a dedicated
   subdirectory (`/mnt/hdd/vaultwarden/backup`), never `/mnt/hdd`, so the
   `check-mounts` guard keeps passing. Extend `check-mounts.nix` with the new
   paths if they gain owners.
5. **Deleting a secret is not a wipe, but it breaks logins.** `rsa_key.pem` must
   travel with every copy; losing it invalidates sessions (recoverable, annoying).
6. **Backups are only real if something reads them.** A weekly restore drill on
   the standby — restore into a scratch dir, `PRAGMA integrity_check`, count
   `users` rows, present `rsa_key.pem` — and fail the unit loudly so
   `systemctl --failed` (and therefore Cockpit/Homepage) shows it. No SMTP here,
   so the unit status *is* the alarm; consider making the drill write a timestamp
   file the dashboard can age-check.
7. **Retention.** The module's `backup.sh` overwrites in place with no history
   (`sqlite3 .backup` + `cp -r`). Add a small timer that copies
   `/mnt/hdd/vaultwarden/backup` to `snapshots/YYYY-MM-DD/` and prunes older than
   N days. Cheap, and it turns "a bad write was backed up over the good copy" from
   fatal into annoying.

---

## 6. LAN-only reality checks

* **Binding:** nginx `listenAddresses = [ lanAddress ]`, vaultwarden on
  `127.0.0.1:8222`, firewall still off (unchanged) — so the only way in is the
  nginx port bound to the LAN address. Verify with `ss -tlnp` from the LAN **and**
  a failing `curl` from off-LAN (phone on cellular).
* **Sync-at-home semantics:** Bitwarden clients keep a local encrypted copy and
  work offline; edits made away from home are kept locally and pushed on the next
  successful sync. That is the behaviour being relied on — test it deliberately
  (add an item on cellular, come home, confirm it lands).
* **Mobile push notifications** need outbound access to Bitwarden's push relay
  (`push.bitwarden.com`); without it you lose background sync notification and
  "approve login from another device". Inbound stays closed, so this is compatible
  with the plan. If `PUSH_ENABLED` is disabled, iOS clients are noticeably more
  annoying. Keep it on, and note the dependency.
* **No SMTP** ⇒ no password-reset emails, no email verification. Bootstrap flow:
  allow signups → create the account(s) → set `SIGNUPS_ALLOWED = false` → rebuild.
  Keep the account's master password in the vault's emergency kit.
* **2FA/WebAuthn is origin-bound.** Any FIDO2 security key registered as Bitwarden
  2FA on `bitwarden.com` must be **re-registered** for `vault.edt.nz`; it cannot be
  migrated. Plan for a window where 2FA is temporarily off.
* Consider enabling `WEBSOCKET` notifications (module does it with
  `configureNginx`) so the web vault updates without polling.

---

## 7. Promotion / failover runbook (drill it, do not trust it)

**Promote the standby (Pi primary → homeserver primary):**

1. Confirm the primary is really gone (not just asleep).
2. Stop it if it is alive: `systemctl stop vaultwarden` / `systemctl poweroff` —
   **never** leave two writers up.
3. On the standby: `vaultwarden-pull` (fetch newest replica + static files),
   verify `PRAGMA integrity_check` and that the DB is newer than the last known
   good one.
4. `touch /var/lib/vaultwarden-active && systemctl start vaultwarden`.
5. Point `vault.edt.nz` at the standby's LAN IP (router/DNS), or let keepalived
   move the VIP.
6. Tell clients nothing — same URL, same `rsa_key.pem`, so sessions survive.
7. Copy the standby's DB back to the (eventually repaired) other node before it is
   ever started again, or demote it properly.

**Demote:** `rm /var/lib/vaultwarden-active && systemctl stop vaultwarden`, then
re-reverse replication.

**Drill it while nothing is broken** (phase 3 gate): promote the homeserver with
the Pi still up but stopped, log in from a laptop, sync an item, demote, confirm
the Pi has it. If the drill needs improvisation, the runbook is wrong.

---

## 8. Migrating off Bitwarden cloud

Do this **after** phase 2 (backups) and the phase 3 drill. Keep the cloud account
untouched and paid-or-free-but-alive until the new server has been through a
week of normal use.

1. **Preflight**
   * Decide the account email (reusing the current one is fine — it is just an
     identifier).
   * On the cloud account: note every **device** that must be reconfigured, every
     **2FA method** (FIDO2 keys + TOTP + recovery code), whether an **organization**
     is in use (shared with someone?), and whether there are **attachments**.
   * Export from the cloud: `bw export --format json --output /tmp/cloud.json`
     plus a per-organization export if an org exists
     (`bw export --organizationid <id>`). Store it on an encrypted volume, offline.
2. **Create the account on the new server** (with `SIGNUPS_ALLOWED = true`
   temporarily), then turn signups off and rebuild.
3. **Import**: `bw config server https://vault.edt.nz` then
   `bw import bitwardenjson /tmp/cloud.json` (CLI is the most predictable path).
4. **Known-broken-by-design bits** — budget time:
   * **Attachments** are *not* in a JSON export (metadata only). Download each with
     the CLI (`bw list items`, `bw get attachment <id> --itemid <id>`) and re-upload,
     or accept re-adding them.
   * **Sends** are not exported. Re-create if you still need them.
   * **Passkeys stored as vault items**: export support is partial — inventory them
     first, and expect to re-enrol some relying parties.
   * **FIDO2 2FA** and **login-with-device/emergency access** are origin/instance
     bound: redo them.
   * **Personal API key**: generate a new one for the new server; **rotate/revoke**
     the cloud one.
   * **Organization/collections**: re-create the org on the new server (Vaultwarden
     supports a free org for a couple of users) and re-import the org export; sharing
     keys mean the other person must accept a new invite and re-sync.
5. **Switch devices** one at a time (log out, set the self-hosted URL, log in,
   sync), starting with the machine you'd least mind debugging. Keep the cloud
   login until every device is confirmed.
6. **Verify** item count, folders, TOTP codes, a passkey login, and an attachment
   round-trip.
7. **Shred** `/tmp/cloud.json` (`shred -u`), then delete the cloud vault after a
   comfortable interval. Keep one offline encrypted export as the pre-migration
   snapshot, in a different place from the server (this is the offsite leg the
   design otherwise lacks).

---

## 9. Verification (must pass before committing / before migrating)

```bash
# On the Mac, before commit:
nix flake check --no-build
nix eval .#nixosConfigurations.homeserver-edt.config.systemd.services.vaultwarden.serviceConfig.StateDirectory
#   expect "bitwarden_rs" — the §5 tripwire
nix eval .#nixosConfigurations.rpi3b.config.services.vaultwarden.config.DOMAIN
#   expect "https://vault.edt.nz" — and identical on both hosts
nix eval '.#nixosConfigurations.rpi3b.config.services.nginx.virtualHosts."vault.edt.nz".listenAddresses'

# On the build host (no root needed, per AGENTS):
nixos-rebuild build --flake .#homeserver-edt
nixos-rebuild build --flake .#rpi3b          # aarch64 via qemu-user
# then ask the user to run `nixup` / `nixrs` (sudo needs a TTY)
```

Post-deploy:

```bash
systemctl status vaultwarden acme-vault.edt.nz.service litestream vaultwarden-pull
ss -tlnp | grep -E '8222|443'
curl -sS https://vault.edt.nz/api/config | jq .        # from the LAN
systemctl start backup-vaultwarden.service && ls -l /mnt/hdd/vaultwarden/backup
sqlite3 /mnt/hdd/vaultwarden/backup/db.sqlite3 'PRAGMA integrity_check; select count(*) from users;'
# restore drill, by hand the first time:
#   systemctl stop vaultwarden; litestream restore -o /tmp/db.sqlite3 <replica>; sqlite3 /tmp/db.sqlite3 'PRAGMA integrity_check;'
# from a phone on cellular: curl -m 5 https://vault.edt.nz/api/config  → must fail
```

Then the repo rules: new files not gitignored (`git check-ignore`), and commit to
nix-conf — live `systemctl`/DB fiddling is ephemeral and will be lost.

---

## 10. Phases

| Phase | Deliverable | Gate to move on |
| --- | --- | --- |
| 0 | Answers in §2; `.sops.yaml` + rpi3b sops wiring; DNS record `vault.edt.nz` | `nix flake check` passes with the new module stubbed in |
| 1 | Primary Vaultwarden + HTTPS + admin token, **no backups yet** | Web vault loads over TLS from a phone on the LAN; a test item syncs between two devices |
| 2 | Litestream replication + nightly snapshot + retention + **restore drill** | Drill restores a DB whose `users` count matches the live one |
| 3 | Standby on the other node + promotion runbook + drilled failover | §7 drill completed with no improvisation |
| 4 | Optional: keepalived VIP, restic repo(s), firewall, homepage tile | — |
| 5 | Migrate from Bitwarden cloud (§8), then decommission the cloud account | A week of normal use with no "wait, where did that item go" |

**Rollback:** phases 1–3 are additive; delete the import line and `nixup`. The
vault never lived only in the cloud after phase 5, so keep phase 5 last.

---

## 11. Open questions

1. ❓ Does the DNS provider for `edt.nz` have an API suitable for lego (§2.1)?
2. ❓ Public `A` record pointing at the LAN IP, or a local DNS override (§2.2)?
3. ❓ Primary on the Pi, or on the homeserver — and **which is true today: does the
   homeserver sleep, or is suspend blocked** (`AGENTS.md` says sleeps,
   `desktop.nix` says never)? This decides §2.3.
4. ❓ Is the Pi on wired ethernet where it lives? (2.4 GHz WiFi works, but it makes
   a keepalived VIP and any future promotion less reliable.)
5. ❓ Is there any offsite/offline copy wanted at all? Three copies, two devices,
   both in the same house is a real (accepted?) gap.
6. ❓ Is a second user (family/shared org) needed, or is this single-user? It
   changes the bootstrap and the org-migration effort.

## 12. References

* nixpkgs module: `nixos/modules/services/security/vaultwarden/default.nix` (options
  here are the authority for `dbBackend`, `backupDir`, `configureNginx`,
  `environmentFile`); litestream module: `…/services/network-filesystems/litestream/`.
* Vaultwarden wiki — *Backing up your vault*, *Enabling HTTPS*.
* Litestream — replica types (`file`, `sftp`) and `litestream restore`.
* Bitwarden — *Certificate Options* (self-signed is testing-only),
  *Connect Individual Clients* (`https://` required in the server URL).
* Vaultwarden discussions #2691 / #3285 — why there is no supported multi-replica
  active-active mode.
