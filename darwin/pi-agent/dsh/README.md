# DeepSeek Harness (`dsh`) web UI — LAN setup

[`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) is DeepSeek's agent harness. This dir holds the LAN overlay used to
prompt it from a phone.

## Why a patch overlay for the bind address

The CLI deliberately rejects `--host 0.0.0.0` ("would expose remote code
execution to the network"). The webserver row's schema still allows it, so
`lan.patch.yml` sets `host: 0.0.0.0` + `port: 9000` through a patch overlay
(the same mechanism as `examples/web-cordis/cordis.yml` in the harness repo).

The `/api` browser-trust fence auto-derives the machine's LAN IP literals from
the bind host (`resolveLanTrust`), so a phone hitting the LAN IP passes trust
with no extra flags. Verified: foreign Origin → 403, LAN Origin → accepted.

## Run (on the Mac, for now)

```bash
darwin/pi-agent/dsh/run-dsh-web.sh
```

Reachable from a phone on the same Wi-Fi at `http://192.168.1.24:9000`, and
over ZeroTier at `http://172.28.174.222:9000`.

Then in the browser:
1. **Settings → Models** → paste the DeepSeek API key (persists in
   `~/.dsh/storages`; the key is already in the shell env as
   `DEEPSEEK_API_KEY`).
2. **Choose workspace** → add `~/dev/nix-conf` (or another dir) and select it.

## Notes

- Requires Node ≥ 22.19; the HMR plugin needs `node --expose-internals`
  (launched directly — Node forbids that flag in `NODE_OPTIONS`).
- Not in nixpkgs; install with `npm install -g @deepseek-ai/dsh`
  (currently `0.1.1-rc.2`, dev preview, breaking changes expected).
- The server sleeps/dies with the Mac — the durable home is the always-on
  rpi3b; `hosts/rpi3b/services.nix` is reserved for that module and this
  patch file moves over unchanged.
