# Cheaper models for the pi agent loop (hosted + local)

Status: **draft** — research only. Nothing here is configured, deployed or committed.

Question: the pi sessions on this Mac cost ~$0.05/prompt (median $0.015 over the last
26 sessions, one prompt = 18% of spend). Is there a cheaper hosted model that still
drives a 20-turn tool loop, and can `homeserver-edt` (RX 6700 XT, 12 GB) serve it?

**Answer: no to both, with one real exception — the current model is already billed
off-peak at half price half the week, and the fix is turn/context discipline, not a
model swap.** Numbers below.

## 1. The measured profile (recomputed, not assumed)

From `~/.pi/agent/sessions/**/*.jsonl` (usage blocks, last 26 sessions, 103 prompts,
1976 assistant turns, pi-reported `cost.total` $4.5493):

| Metric | Value |
| --- | --- |
| turns / prompt | 19.2 |
| cached input / prompt | **3.48 M tokens** |
| uncached input / prompt | 16.7 k tokens |
| output / prompt | 15.3 k tokens (60% reasoning) |
| context/turn | median 134 k, mean 182 k, p90 436 k |
| spend split | cache read 47%, output 41%, input 11% |
| $/prompt | mean $0.044, median $0.015 (heavy tail) |

So the cost function for any candidate is
`$/prompt ≈ 3.48·cacheRead + 0.0167·input + 0.0153·output` ($/M each).
**Cache read is half the bill**, so `cacheRead/input` ratio decides everything else.
The median prompt is ~⅓ of these tokens; the mean is what pays the bill.

## 2. Hosted candidates at that profile

Cost column = the formula above at catalog prices (`pi-ai` `providers/data/*.json`,
cross-checked against provider docs where noted). Sorted cheapest first.

| Model (pi provider) | in $/M | out $/M | cacheRead $/M | cacheWrite $/M | ctx | tool calls | **$/prompt** | quality evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **deepseek-flash, off-peak** (deepseek) | 0.15 | 0.60 | **0.003** | 0 | 1 M | reliable (in daily use) | **0.022** | V4-Pro = #1 SWE-bench Verified 96.4% (vals.ai 2026‑09); Flash's own score unverified here |
| **deepseek-flash, peak** (deepseek) — *baseline* | 0.30 | 1.20 | **0.006** | 0 | 1 M | same | **0.044** | as above |
| qwen3.5-plus (opencode) | 0.20 | 1.20 | 0.02 | 0.25 | 262 k | unverified | 0.095 | no public agentic number found |
| gemini-3.1-flash-lite (google) | 0.25 | 1.50 | 0.025 | 0 | 1 M | yes (native) | 0.114 | **Terminal-Bench Hard 24.2%**, ranked 91/326 (BenchmarkList); 28th SWE-bench, 29th LCB/TB2 (Vals) |
| gpt-5-mini (openai) | 0.25 | 2.00 | 0.025 | 0 | 400 k | yes | 0.122 | not verified this pass |
| deepseek-v4-flash (openrouter) | 0.03 | 1.28 | 0.03 | 0 | 1 M | yes | 0.124 | *same weights*, 2.8× cost: OpenRouter has no DeepSeek cache discount |
| gemini-3.5-flash-lite (google) | 0.30 | 2.50 | 0.03 | 0 | 1 M | yes | 0.148 | weaker tier than 3.1-lite's sibling; unverified |
| devstral-2512 (mistral) | 0.40 | 2.00 | 0.04 | 0 | 262 k | yes | 0.176 | SWE-bench figure unverified |
| MiniMax-M3 (minimax) | 0.30 | 1.20 | 0.06 | 0 | 1 M | yes | 0.232 | Terminal-Bench 2.1 **66%**, LCB 82.2% (AnotherWrapper) |
| deepseek-v4-pro (deepseek, peak) | 1.32 | 3.96 | 0.044 | 0 | 1 M | reliable | 0.236 | **#1 SWE-bench Verified 96.4%** (vals.ai) |
| qwen3.8-27b (openrouter) | 0.425 | 2.55 | 0.085 | 0.53 | 1 M | yes | 0.351 | Terminal-Bench 2.1 **73%**, LCB 84% |
| gemini-3.6-flash (google) / gpt-5.4-mini (openai) | 0.75 | 3.75/4.50 | 0.075 | 0 | 1 M/400 k | yes | 0.331/0.342 | unverified |
| kimi-k2.7-code (moonshotai) / glm-5.3 (zai) | 0.95/1.40 | 4.00/4.40 | 0.19/0.26 | 0 | 262 k/1 M | yes | 0.738/0.996 | provider marketing only |
| groq qwen3.6-27b / cerebras qwen-3.8-27b | 0.6/0.99 | 3.0/1.49 | 0.6/0.99 | 0 | 131 k | yes | 2.14 / 3.49 | fast tiers, **no prompt caching → unusable here** |

Notes that decide the sweep:

- **Nothing beats DeepSeek's cache-read price.** $0.006/M (peak) and $0.003/M (off-peak)
  is 2–160× below every other provider; the next best (Gemini lite, gpt-5-mini) is
  4× more expensive per prompt *purely* on cache reads.
- **The `~deepseek` / OpenRouter cheap-input rows are a trap.** $0.03/M input looks
  great, but with no cache discount the 3.48 M cached tokens are billed at full input
  rate: 2.8× the direct API. Same for Cerebras/Groq free tiers (cache not offered).
- **Cheap output is worth less than cheap cache.** Output is 41% of spend: halving its
  price saves ≤20%, while going off-peak halves 47% of the bill outright.
- Peak rate verified at <https://api-docs.deepseek.com/quick_start/pricing>: peak is
  01:00–04:00 and 06:00–10:00 UTC Mon–Fri only; everything else (incl. weekends) is
  half price. Gemini 3.1 Flash-Lite's $0.25/$1.50/$0.025 also matches
  <https://ai.google.dev/gemini-api/docs/pricing> (plus $1.00/M-token/hour cache
  *storage*, which pi does not model).
- pi's own `cost.total` is computed at **peak** catalog rates. If the sessions really
  ran off-peak, true spend is closer to $2.3 than $4.55 — check the DeepSeek balance,
  not the pi estimate.

## 3. The local option on homeserver-edt

Confirmed on the box (read-only `ssh`, 2026‑10‑20): `1002:73df` = Navi 22, VRAM
12,868,124,672 B (11.98 GiB), 12 threads, 15 GiB RAM, `rocm-smi` present, no
`vulkaninfo`/`llama-cli`/`ollama`. The host was awake.

**Context, not weights, is the wall.** A 9B-class GQA model (36 layers, 8 KV heads,
head_dim 128) costs **144 KiB/token** of fp16 KV: 140 k context = **20.6 GB**, 32 k =
4.4 GiB (2.2 GiB with Q8 KV). Add 5–9 GB of Q4 weights and the 12 GB card tops out at
**~16–32 k context** with a 9–14B model. Our median turn is 134 k. The profile does
not fit; pi would have to compact to ~1/5 of its real context, which changes the
workload rather than serving it.

Speed on this card (Vulkan, llama.cpp): **pp512 ≈ 1237 t/s, tg128 ≈ 76–90 t/s** for
Llama-2-7B Q4_0 (upstream row 83.88 t/s; 81.6–85.7 t/s reproduced,
<https://github.com/austxu/RX-6700XT-Optimization>). Scaled down: 9B ≈ 900 t/s, 14B ≈ 700 t/s.

Prefill arithmetic for our profile (cache-reusing loop: one 140 k first turn, ~350 k
unique tokens over the prompt, 15.3 k output):

| | 7B Q4 | 9B Q4 | 14B Q4 |
| --- | --- | --- | --- |
| first-turn 140 k prefill | 113 s | 156 s | 200 s |
| total prefill / prompt | 4.7 min | 6.5 min | 8.3 min |
| decode 15.3 k @ tg | 3.0 min (85 t/s) | 6.4 min (40) | 10.2 min (25) |
| **dead time / prompt** | **≈8 min** | **≈13 min** | **≈19 min** |
| electricity @180 W, €0.30/kWh | €0.007 | €0.012 | €0.017 |

**Verdict: local loses on latency and quality, not on electricity.** 8–19 min of wall
clock per prompt versus 1–3 min hosted, from a model a tier below DeepSeek Flash on
tool use, with a context 5× too small. Electricity (~€0.01/prompt) is cheap — but
keeping a 50 W-idle box awake to serve it burns 1.2 kWh/day ≈ €0.36/day, **more than
the hosted tokens of a normal working day**, and cancels the machine's sleep design.
Local is only defensible as an offline fallback for small-context edits.

pi wiring, for the record (`docs/llama-cpp.md`): `llama-server --models-dir ~/models
--no-models-autoload --jinja -c 32768 -ngl 999`, then `/login llama.cpp` or
`LLAMA_BASE_URL=http://homeserver-edt.local:8080`. Not proposed.

## 4. Ranked recommendation

| # | Option | $/prompt | Quality change | When |
| --- | --- | --- | --- | --- |
| 1 | **Keep `deepseek/deepseek-flash`, direct API — and stop paying peak** | 0.022–0.044 | none | always |
| 2 | Keep the same model, **cut turns × context**: compaction earlier, no 140 k+ reads, `thinkingLevel` low for mechanical edits (output is 41% of spend, 60% of it reasoning) | 0.015–0.030 | slightly worse on hard reasoning | always |
| 3 | Escalate to `deepseek/deepseek-v4-pro` for the ~10 % of prompts that fail twice | 0.236 (that prompt only) | better (#1 SWE-bench) | on demand |
| — | Rejected: gemini-3.1-flash-lite (2.6× cost, Terminal-Bench Hard 24%), MiniMax-M3 (5×), qwen3.8-27b (8×), anything on OpenRouter/Cerebras/Groq (no cache discount), local (see §3) | | | |

Escalating the 10% hard prompts costs ~1.2× total spend; swapping *everything* to a
2.6× model costs 2.6×. That is the whole argument for a null result.

Sketch for the escalation path (not applied; `darwin/pi-agent/models.json` is
git-tracked and mirrored from nix-conf — change it there, not in `~/.pi`):

```jsonc
{
  "providers": {
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "api": "openai-completions",
      "apiKey": "$DEEPSEEK_API_KEY",
      "modelOverrides": {
        "deepseek-flash": { "inputLimits": { "images": { "resize": { "maxWidth": 1280, "maxHeight": 1280 } } } },
        "deepseek-v4-pro": { "promptCache": { "short": 3600 } }   // sketch
      }
    }
  }
}
```

## 5. Verification

1. **Billing truth first.** Compare the DeepSeek dashboard/balance delta for a known
   window against the sum of `cost.total` in those sessions. If the ratio is ~0.5,
   pi is over-reporting off-peak usage and every number in §2 halves — that is the
   single largest open question in this document.
2. **Off-peak windows** are 01:00–04:00 and 06:00–10:00 UTC Mon–Fri; a batch run
   started at 20:00 UTC pays half. Re-verify on the pricing page before relying on it.
3. **Re-measure the profile** before/after any change, from the session files:
   `python3 -c` over `~/.pi/agent/sessions/**/*.jsonl`, summing `message.usage`
   (`input`, `output`, `cacheRead`, `cost.total`) and counting assistant turns and
   user prompts. The three numbers to watch are turns/prompt, cached tokens/prompt
   and output/prompt.
4. **A/B a candidate properly**: fixed 10-task list, one prompt each, run with
   `PI_BUDGET_USD=0.15 pi 'read /tmp/ab/task-N.md and do it'`, then compare
   $/prompt (from the session rollup) *and* success rate — a model that is 2.6×
   cheaper per token but needs 1.5× the turns is a loss.
5. If a local trial is ever wanted: `nixos-rebuild build` first, start
   `llama-server` by hand (not as a unit), measure with `llama-bench -p 512 -n 128`
   on the actual box rather than trusting §3's borrowed numbers, and remove it the
   same day (AGENTS.md §9 — no temporary units on the live box).
