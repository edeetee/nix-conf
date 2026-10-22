# Local Qwen3.6-35B-A3B: a LAN endpoint + autonomous loops on homeserver-edt

Status: **draft** — research done, no code written, nothing deployed.

Two deliverables, deliberately separate:

- **A. A shared endpoint.** `llama-server` on homeserver-edt serving
  `Qwen3.6-35B-A3B` at 4-bit, reachable from the Mac so a pi session here can
  point at it (`http://homeserver-edt.local:8080/v1`).
- **B. Unattended loops on the server.** A systemd-driven worker that takes
  tasks off a queue, runs one pi invocation per task against the *local* model,
  validates the result, and commits only what passes.

This is explicitly **not** a replacement for `deepseek-flash` in interactive pi
sessions — see `cheaper-models.md` §3. The local model is ~5–6 points behind
Flash on every agentic benchmark, has ~1/40th the usable context, and is 10–30×
slower per step. It is worth using only where wall-clock and per-step context
are things the workload does not need, i.e. bulk unattended iteration.

## 1. Constraints (measured on the box, 2026-10-21)

| | |
| --- | --- |
| GPU | RX 6700 XT, `gfx1031` Navi 22, **11.98 GiB VRAM**; ROCm partly wired (`rocmSupport`, `/opt/rocm/hip`). `gfx1031` is **not** a supported ROCm target: it needs the gfx1030 override plus an FA patch (§2 D2) |
| CPU / RAM | i5-10400F, 6c/12t (**AVX2 only — no AVX512/AMX**, so KTransformers-style CPU kernels are at a disadvantage) |
| RAM | **15 GiB** + 9.3 GiB swap. This, not VRAM, is the binding constraint |
| Disk | `/` 48 G free → **models go on `/mnt/hdd`** (213 G, `nofail`, `user`) |
| Firewall | off (`hosts/homeserver-edt/networking.nix`) → no port to open for LAN access |
| Suspend | blocked at logind (`desktop.nix`: `IdleAction=ignore`, `AllowSuspend=no`) → a long job cannot be interrupted by sleep |
| GPU sharing | the same card runs Steam, Jellyfin, AirPlay mirroring and Plasma |

**Memory arithmetic that sets every number below:** usable pool ≈ 12 GiB VRAM +
~12 GiB RAM ≈ **24 GB**. `Qwen3.6-35B-A3B` at 4-bit is ~21 GB, so:

- **4-bit is the ceiling.** 6-bit (29 GB) does not fit at any split.
- ~2–3 GB remains for KV + compute buffers → **16 k context is the sane default**
  (fp16 KV would be ~1.6 GB; at `q8_0` KV ~0.8 GB). 32 k only if fewer expert
  layers are left on the GPU.

## 2. Decisions still open

| # | Decision | Options | Default if nobody objects |
| --- | --- | --- | --- |
| D1 | Quant | `Q4_K_M` · `IQ4_XS` · a router-protecting DWQ/warmed GGUF if one exists | **`Q4_K_M`**, then A/B vs `IQ4_XS` on real tasks (§6). Never bare `Q4_0` — the measured spread between good and careless 4-bit is 0.027 vs 0.074 KLD |
| D2 | Backend | Vulkan · ROCm (HIP) | **Vulkan to start, ROCm if §5.5 says so.** The two split by phase on this card: ROCm is ~+85 % on prefill at 8 k but ~-23 % on decode, and RDNA2 gets *no* modern Vulkan coopmat/UFM kernels (RDNA4-only), which is where ROCm's prefill edge comes from. The loop is prefill-heavy (≈4 k in, ≈500 out) so ROCm is the likely net winner — but it needs `HSA_OVERRIDE_GFX_VERSION=10.3.0` **plus a source patch for an FA assert** (llama.cpp#26702), i.e. a fork (cf. `flatrick/llama.cpp-hip-gfx1031`) re-tested on every bump. Caveat: with `--n-cpu-moe` much of prefill is CPU-bound, so the GPU-side advantage shrinks |
| D3 | Server | bare `llama-server` unit · `llama-swap` · ollama | **bare unit.** One model, one port, no proxy layer. `llama-swap` only if a second (smaller/coder) model is later wanted on the same card |
| D4 | Residency | always resident · on demand | **always resident, VRAM-capped**, with the conflict gate in §3.3. Nothing worse than a 60 s model load before every task |
| D5 | Loop driver | `pi -p` per task · a purpose-written loop | **`pi -p` per task** — reuses the harness, tools and skills we already trust |
| D6 | RAM upgrade | 2×32 GB DDR4-2666 (~€90) | defer. It buys 6-bit/MXFP4-class quants, 32–64 k context and a real KTransformers option; do it if the loop proves useful first |

## 3. Shape of the change

### 3.1 New module `modules/nixos/llama-cpp.nix`

Sketch, not final. Options for `enable`, `model`, `port`, `ctxSize`, `cpuMoeLayers`,
`extraFlags`; assertions that the model file exists (warn, not fail — the mount is `nofail`).

```nix
services.llama-cpp = {          # if present in the pin; otherwise a hand-written unit
  enable = true;
  model = "/mnt/hdd/models/Qwen3.6-35B-A3B-Q4_K_M.gguf";
  port = 8080;
  extraFlags = [
    "--host" "0.0.0.0" "--port" "8080"          # LAN-reachable; firewall is off
    "-c" "16384"
    "--n-cpu-moe" "24"                          # tune: fewer = more experts on GPU
    "--cache-type-k" "q8_0" "--cache-type-v" "q8_0"
    "-fa" "on" "--jinja"                        # --jinja is what makes tool calls work
    "-np" "1"                                   # one slot: 15 GiB RAM cannot hold two
    "--no-mmap"                                 # optional: avoids HDD page-cache thrash
  ];
};
```

Two repo rules apply directly:

- **`/mnt/hdd` is `nofail`.** The unit needs `RequiresMountsFor = [ "/mnt/hdd" ]`
  or it will start (and fail) against an empty directory after a boot where the
  disk came up late.
- **AGENTS.md rule 1.** Model files go in a **dedicated** `/mnt/hdd/models`, never
  `/mnt/hdd` itself — that tree holds `SteamLibrary`, `media`, `downloads`, and a
  tmpfiles `chown` on it is the `e216ab4` incident again.

Model files are **not** managed by Nix: a 21 GB GGUF in the store is wrong, and it
would have to be re-downloaded on every GC. Acquisition is
`scripts/qwen-model.sh` — resumable curl, SHA256 checked against the LFS oid
published by HF, safe to re-run (verified on the box 2026-10-21: 858 MB fetch at
~15 MB/s, sha match, re-run a no-op). The path is the only thing the flake knows
about.

### 3.2 Wiring it into the host

`hosts/homeserver-edt/default.nix` imports `../../modules/nixos/llama-cpp.nix`,
and `hosts/homeserver-edt/services.nix` (or a small dedicated `llm.nix`) sets the
options. Keep it in `modules/nixos/` because `rpi3b` may later want the same
module with a tiny model — but it must stay **NixOS-only**, never imported by
`modules/common.nix` (it would break the Darwin evaluations).

### 3.3 GPU conflict gate

The expensive mistake is not "the model is slow", it is "a batch job ate the
frame budget while someone was playing". One `ExecStartPre` check, and a manual
pause flag:

```sh
# /run/qwen-pause exists  → stay down
[ -e /run/qwen-pause ] && exit 1
# active Steam session or an AirPlay mirror → stay down
systemctl is-active --quiet steam-on-demand && exit 1
```

`qwen-pause` / `qwen-resume` become two tiny shell aliases in `packages.nix`, next
to `nixup`/`nixrs`. This is cheaper and more honest than trying to make the model
yield mid-run: the GPU has no preemption worth relying on.

### 3.4 Client side: use it from the Mac

The Mac's pi config is declarative in this repo — `darwin/pi-agent/models.json`.
Add one provider next to `deepseek`:

```jsonc
"local": {
  "baseUrl": "http://homeserver-edt.local:8080/v1",
  "api": "openai-completions",
  "models": [ { "id": "qwen3.6-35b-a3b", "name": "Qwen3.6-35B-A3B (local)",
                "contextWindow": 16384, "maxTokens": 4096,
                "input": ["text"], "reasoning": true,
                "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 } } ]
}
```

`contextWindow: 16384` is not cosmetic — pi must compact to what the server can
actually hold, or every long session truncates mid-tool-call. Zero cost keeps
`/budget` honest; the extension measures nothing, which is correct here.

Smoke test from the Mac before touching pi:

```bash
curl -s http://homeserver-edt.local:8080/v1/models | jq .
curl -s http://homeserver-edt.local:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"say hi"}],"max_tokens":16}'
```

### 3.5 The autonomous loop (`qwen-loop`)

**Do not point this at pi's normal profile.** pi's median turn is 134 k tokens of
context; the local model gets 16 k. A loop that assumes otherwise fails in the
confusing way — mid-tool-call truncation, not a clean error. So the loop is built
around one rule: **one task, one small prompt, one validated artifact.**

```
/var/lib/qwen-loop/
  queue/       0012-fix-import.md   task description (~500 words max)
  running/                          claimed task
  done/        + result patch + log
  failed/      + log                (retried at most once, then out)
  qwen-loop.log
```

Task file carries its own verification (the thing that makes this autonomous and
not just a token generator):

```markdown
---
target: /home/edeetee/dev/scratch/repo
verify: nix flake check --no-build || cargo test -q
max_attempts: 2
---
Replace the deprecated `lib.mdDoc` calls in modules/ with plain strings …
```

Loop body, sketched as a single `while` in a `systemd` service (timer-triggered,
or `Restart=always` with an active-hours check):

1. claim the oldest `queue/*.md` (atomic `mv` — no database needed)
2. `pi -p "read <task file> and follow it"` with `PI_PROVIDER=local` in the env,
   one task per invocation so a crash loses one task, not the run
3. run the task's `verify:` command in the target repo
4. pass → commit to a branch named `qwen/<task-id>`, move to `done/`; fail →
   `failed/`, log the pi transcript
5. **never merge, never push, never `git checkout` the user's branch.** The loop
   produces reviewable commits; a human or a hosted-model session reviews them

Cap it: `--max-attempts 2`, and an active-hours check (e.g. 22:00–08:00) so the
TV is free in the evening. Because the tokens are free, there is no budget to
enforce — the guard is wall-clock and GPU occupancy, not money.

## 4. What to expect (estimates, to be replaced by §5 measurements)

| | Local Qwen3.6-35B-A3B Q4 | deepseek-flash (today) |
| --- | --- | --- |
| SWE-bench Verified / TB2 / MCP-Atlas | 73.4 / 51.5 / 62.8 | 79.0 / 56.9 / 69.0 |
| quant damage | mean KLD 0.027 (good 4-bit) vs 0.011 (6-bit) | n/a |
| context | 16 k (`q8_0` KV) | 1 M |
| decode | **10–20 t/s** (3 B active, experts in RAM) | fast |
| prefill | 30–60 t/s → **4 k prompt ≈ 1–2 min** | seconds |
| per-step wall clock | ~3–6 min at 4 k in / 500 out | ~20–60 s |
| concurrency | 1 (`-np 1`) | many |
| marginal cost | **€0** (~180 W × 8 h ≈ €0.43/session) | $0.022–0.044/prompt |

Break-even against hosted is ~20 Flash prompts per 8-hour session; an unattended
queue of small tasks clears that by an order of magnitude. A single interactive
question does not.

## 5. Verification (before commit, per repo rule 2)

1. `nix flake check --no-build` — must pass; this module must not be reachable
   from `modules/common.nix` (Darwin would break).
2. `nixos-rebuild build --flake .#homeserver-edt` on the server (no root needed),
   then a real deploy.
3. `systemctl status llama-cpp` + `ss -tlnp | grep 8080` on the box; journal shows
   no OOM and reports the actual GPU layers chosen.
4. `curl` the two commands in §3.4 **from the Mac** — this is the deliverable A test.
5. `llama-bench -m <model> -p 512 -n 128` and record real pp/tg in this file,
   replacing §4's estimates. **Run it on both backends, and at `-p 4096` as well as
   `-p 512`** — D2 turns on prefill at our real prompt size, not on pp512. ROCm
   needs `HSA_OVERRIDE_GFX_VERSION=10.3.0` even to start; record whether the
   FA-assert patch is still required on the pinned version.
6. One real pi task from the Mac with `--provider local`, compared against the
   same task on `deepseek-flash`: wall clock, and whether it actually finished.
7. Loop dry run: three synthetic tasks, one of which is designed to fail its
   `verify:` command. Confirm it lands in `failed/` and does not commit.
8. Contention check: start Steam, confirm the gate keeps the server down, then
   confirm `qwen-resume` works when the seat is idle.
9. Reboot test: with `/mnt/hdd` coming up late, the unit must not start against an
   empty directory (`RequiresMountsFor` proof).
10. A/B `Q4_K_M` vs `IQ4_XS` on ~20 of our own tasks, compare **success rate**.
    KLD cannot be measured locally — the bf16 reference is ~70 GB.

## 6. What would make this fail

- **15 GiB RAM is not enough for 32 k context.** If real tasks need >16 k, the
  answer is D6 (the RAM upgrade), not a cleverer flag.
- **Router damage at 4-bit.** It shows up first as malformed tool-call JSON on
  long runs, not as a worse answer. Watch the loop's failure log for it; that is
  the signal to move to 6-bit once RAM allows.
- **GPU contention is unsolvable mid-run.** The gate prevents starting during a
  game; it cannot pause a running batch. Schedule, do not preempt.
- **The HDD is a spinning disk holding 21 GB of weights.** With `--no-mmap` the
  load is a one-off ~1–2 min; without it, a cold page cache makes the first
  tokens pathologically slow. Measure both before choosing.
- **Nobody reads the loop's output.** An autonomous queue that produces
  unreviewed commits is a slow-motion mess. The branch-and-review rule in §3.5 is
  load-bearing, not a nicety.

## 7. Open questions

- **Does the FA-assert patch still apply to the pinned llama.cpp?** If it has been
  upstreamed, ROCm on gfx1031 is a flag plus an env var and D2 flips to ROCm
  outright; if not, it is a fork we own and must re-test on every bump. Check this
  *first* — it decides how much of D2 is real work.
- Is `services.llama-cpp` in the pinned nixpkgs, or is a hand-written unit needed?
  (Check `nix eval .#nixosConfigurations.homeserver-edt.options.services.llama-cpp`
  on the pin before writing the module.)
- Does a router-protecting 4-bit GGUF exist for `Qwen3.6-35B-A3B`? The DWQ recipe
  is MLX-only in the KLD study; the GGUF equivalent (warmed/`Q4_K_M` mixed) has
  not been measured for this model.
- Is `Hy-Memory-30B-A3B` (Apache 2.0, memory-focused, smaller at ~18 GB) the
  better loop model? It leaves ~4 GB more for context, which is the scarce
  resource here. Worth a side-by-side once the harness exists.
- Does pi's local provider report usage in a way `/budget` tolerates at zero cost?
  Verify before trusting the sidebar's numbers.
