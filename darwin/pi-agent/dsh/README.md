# DeepSeek Harness (`dsh`) web UI — LAN setup

[`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) is DeepSeek's agent harness. This dir holds the LAN overlay used to
prompt it from a phone, plus the launcher.

## Why a patch overlay for the bind address

The CLI deliberately rejects `--host 0.0.0.0` ("would expose remote code
execution to the network"). The webserver row's schema still allows it, so
`lan.patch.yml` sets `host: 0.0.0.0` + `port: 9000` through a patch overlay
(the same mechanism as `examples/web-cordis/cordis.yml` in the harness repo).

The `/api` browser-trust fence auto-derives the machine's LAN IP literals from
the bind host (`resolveLanTrust`), so a phone hitting the LAN IP passes trust
with no extra flags. Verified: foreign Origin → 403, LAN Origin → accepted.

## Why run from source (npm package is broken)

`npm install -g @deepseek-ai/dsh` (0.1.1-rc.2) produces a web UI that fails to
load: `dsh-client-ui-primitives` and `dsh-client-ui-slots` are only
devDependencies upstream so npm never installs them, and the published
tarballs of those two are misbuilt anyway (no `lib/client.js`, raw `.css`
imports in `lib/index.js`). Every client UI bundle (workflow-run, subagent,
jobs, …) requires them at runtime → browser throws `failed to import loader
entry`. A checkout at the same tag builds and runs correctly (consumer bundles
inline the primitives code).

## Setup (done once)

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git ~/dev/deepseek-harness
cd ~/dev/deepseek-harness && git checkout <tag matching the release, e.g. 0.1.1-rc.2>
pnpm install
pnpm run build        # builds host+client libs and the web frontend
```

Requires Node ≥ 22.19 (we use v24), pnpm.

## Run

```bash
darwin/pi-agent/dsh/run-dsh-web.sh
```

Reachable from a phone on the same Wi-Fi at `http://192.168.1.24:9000`, and
over ZeroTier at `http://172.28.174.222:9000`.

Then in the browser:
1. **Settings → Models** → paste the DeepSeek API key (persists in
   `~/.dsh/storages`; the key is also in the shell env as
   `DEEPSEEK_API_KEY`).
2. **Choose workspace** → add `~/dev/nix-conf` (or another dir) and select it.

## Notes

- The HMR plugin needs `node --expose-internals` (launched directly — Node
  forbids that flag in `NODE_OPTIONS`).
- Dev-preview harness, breaking changes expected; update = pull + `pnpm
  install && pnpm run build` in `~/dev/deepseek-harness`.
- The server sleeps/dies with the Mac — the durable home is the always-on
  rpi3b; `hosts/rpi3b/services.nix` is reserved for that module and this
  patch file moves over unchanged.
