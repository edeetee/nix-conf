# pi extensions

Extensions loaded by pi on this machine. The files here are symlinked into
`~/.pi/agent/extensions/` by `darwin/home.nix` (`mkOutOfStoreSymlink`, so edits apply live);
`cmux-session.ts` is generated there by `cmux hooks pi install` and is not managed here.

| file | what it does |
| --- | --- |
| `budget.ts` | spend cap per user request, with in-context budget feedback (this document) |
| `cmux-messaging.ts` | messaging between pi instances running in cmux surfaces |
| `cmux-sidebar.ts` | cmux workspace title/description/progress from inside pi |
| `compact-bash-call.ts` | folds long bash tool calls in the transcript |

## budget.ts

A per-request spend cap checked from inside the model loop. It exists because a long tool
loop on a growing context is where the money goes, and instructions alone did not bound it.

### What it does

Every **user prompt** opens a new budget window. Spend is summed from the session's usage
entries, so it is the provider's own cost number, not an estimate. On each turn end:

| spend | effect |
| --- | --- |
| each 10% | one `custom_message` in context: `Budget 60% used ($0.0058 of $0.0120); about 3 request(s) left at this burn rate.` |
| 100% | one message: finish the current edits, run the checks once, report, stop |
| 130% | `ctx.abort()` |

Ticks are only injected when the last turn ended in a tool call, so they steer a request that
was going to happen anyway instead of adding one. The cap is also written into the system
prompt at the start of the request (read only what you change, implement directly, one check
run, short report) — that early framing is what changes behaviour; the ticks keep the run on
the rails. Measured on a 4-file task with a hidden test suite (deepseek-flash, median of 3):

| setup | wall | cost | hidden tests |
| --- | --- | --- | --- |
| no cap | 62 s | $0.0193 | 19/19, 19/19, 19/19 |
| cap only (stop at 100%, no early feedback) | 46 s | $0.0144 | 19/19, 19/19, 19/19 |
| cap + prompt + 10% ticks, $0.005 | 18 s | $0.0056 | 19/19, 19/19, 19/19 |
| cap $0.0035 (below the floor) | 13 s | $0.0048 | 19/19, but 1/3 runs aborted before updating the visible suite |

A cap without feedback is a wall: it only stops the agent. The prompt + ticks made the agent
economise while it still had room, at the same quality.

### Configuration

| how | effect |
| --- | --- |
| default | **$0.05 per user request** |
| `PI_BUDGET_USD=0.25 pi ...` | cap for that process (inherited by any `pi` it spawns) |
| `PI_BUDGET_USD=off pi ...` | no limit: no system-prompt section, no ticks, no stop |
| `/budget` | report spend on this message vs cap, and session total |
| `/budget 0.10` | set $0.10 for this session, from the next prompt |
| `/budget default` | back to $0.05 |
| `/budget off` | no limit for this session |

A `/budget` choice is stored as a session entry, so it survives resume and fork. An explicit
`PI_BUDGET_USD` is read at process start and is not exported by `/budget` — pass it on the
spawn line when starting a child.

The window resets on **each user message**, not on the session; a message typed while the agent is
already running also resets it, because it is queued as a user message. A `pi -p` child sees one user message, so its cap is its whole run:

```bash
PI_BUDGET_USD=0.05 pi 'read /tmp/task.md and follow it'
```

Size it to the task (~$0.02 one-file fix, $0.05 normal, $0.15+ multi-phase). At 100% the child
is told to wrap up and report; at 130% it is aborted, so leave it enough to report.

### Caveats

- **The default is model-relative.** On deepseek $0.05 is roughly 6-9 turns of this kind of work;
  on a premium model a single turn can cost more than the cap, and the 130% abort will end the
  request mid-edit. For interactive work on a pricey model, set a larger cap or `PI_BUDGET_USD=off`
  and cap only spawned children.
- **Costs are provider-reported.** A provider that reports no usage (some local models) makes the
  cap inert because spend stays at zero.
- The 100% message costs one more request by design; the 130% abort is the only destructive stop.
- Sub-agents inherit `PI_BUDGET_USD`, but a parent's cap is usually the wrong size for a child —
  `AGENTS.md` rule 10 requires an explicit value on every spawn.

### Testing a change

The benchmark that produced the table above is a scratch harness in `/tmp/token-budget-bench` on
this machine (seed repo, hidden 19-check suite, runner, transcripts); it is deliberately not
committed. A quick smoke test of the extension itself:

```bash
PI_BUDGET_USD=0.005 pi -p --approve --no-extensions \
  -e darwin/pi-agent/extensions/budget.ts \
  --provider deepseek --model deepseek-flash \
  'Read SPEC.md and implement it. npm test must pass.'
```

`--no-extensions -e …` isolates `budget.ts` from the other extensions; without it they all load.
