---
name: cmux-subagents
description: Spawn sub-agents as interactive pi sessions in new cmux tabs and orchestrate them one at a time by having each report back. Use when the user asks to "run sub agents in tabs", "get an agent to work on X in a tab", or to sequence several agents through a series of tasks.
---

# Sub-agents in cmux tabs

The user asks for sub-agents in tabs so they can **watch them work**. That means interactive `pi`
in a new tab, one tab per agent, and hand-orchestration: spawn one, wait for it to report back,
then spawn the next.

Never satisfy such a request with `pi -p` / `--mode json` chained in one tab. Print mode buffers its
output and only prints a final summary, so the tab looks dead while the agent works, the user cannot
intervene, and a series runs unattended with no chance to steer it.

## The pattern

1. **Anchor yourself.** You are the orchestrator and the reply address:

   ```bash
   cmux identify --json     # caller.surface_ref, caller.pane_ref, caller.workspace_ref
   ```

2. **Write the task to a file**, not into the spawn command. Keep the spawn line short and
   quoting-safe. See "Task file contract" below.

3. **Spawn one agent** in a new tab in your own pane, without stealing focus:

   ```bash
   PANE=$(cmux identify --json | grep -o '"pane_ref" : "[^"]*"' | head -1 | cut -d'"' -f4)
   NEW=$(cmux new-surface --workspace "${CMUX_WORKSPACE_ID}" --pane "$PANE" \
           --type terminal --focus false | awk '{print $2}')
   cmux send --surface "$NEW" "cd $(pwd) && pi 'read /tmp/pi-agents/01-movement.md and follow it'\n"
   cmux rename-tab --surface "$NEW" "agent 01"
   ```

   Passing the prompt as a *positional argument* to an interactive `pi` opens the TUI with the
   prompt already submitted. Do not spawn a bare `pi`, sleep, and then type the prompt: that race is
   the usual cause of a half-typed first message. Reserve `cmux send` for messages to an agent that
   is already running.

   Print the surface ref so both the user and you can find the tab later.

4. **Wait for the report-back.** Do not poll the working tree, do not tail logs, do not guess from
   `git log`. The sub-agent messages you when it is done (next section). Waiting for that message is
   what makes the series a series.

5. **Spawn the next one** only after the previous agent has reported *and* the working tree is in the
   state you expect (`git status`, `git log --oneline -3`). Between steps is the natural moment to
   sanity-check the handoff yourself.

## Task file contract

The task file must contain, explicitly:

- The task itself (a plan path is usually enough: "complete `plans/06-iteration-speed.md`").
- The repo/working-tree rules: which files it may touch, that another agent owns other paths,
  commit/verify expectations.
- **The report-back instruction**, with your surface ref filled in:

  > When you are done, or genuinely blocked, report to the orchestrator with the `cmux_msg` tool:
  > target `surface:75`, `deliver: true`, text = one line of status plus the path to your fuller
  > status file. Then stop.
  >
  > Write the detail to `/tmp/pi-agents/status-01.md`: status, commits, what landed, what remains,
  > and anything the next agent in the series needs.

- Anything it must not do (launch the pointer-grabbing game, touch tracked data files, push).

One line of message plus a status file is the right shape: messages wake the recipient, so the detail
belongs in the file, and a receiving agent should read the file rather than trust a summary.

## Report-back mechanics

A sub-agent sends with the `cmux_msg` tool (extension `cmux-messaging.ts`): `target` is your surface
ref, `deliver: true` routes it to you as a real message instead of a notification. Multi-line text is
fine; the encoder percent-encodes it.

If you need something *outside* pi to wake you (a long `cargo build`, a test run, a job finishing),
run the watcher in its own tab and send the envelope yourself. Single-line text needs no `enc` field:

```bash
until [ -f /tmp/pi-agents/status-04.md ]; do sleep 15; done
cmux send --surface surface:75 \
  '{"pi-msg":{"v":1,"from":{"surface":"watcher"},"text":"agent 04 finished - read /tmp/pi-agents/status-04.md","deliver":true}}'"$(printf '\n')"
```

The `from` field is self-reported, so name the watcher honestly.

## Rules

- **One writer per working tree.** Series, not parallel, unless each agent gets its own git worktree
  or clone. Two agents editing one tree produce a merge you have to untangle by hand.
- **Never steal focus.** Always `--focus false` on creation and moves; the user may be looking at
  another workspace. Renaming a tab is fine and helps them find it.
- **One tab per agent**, named after its task, so the user can scroll back through each agent's TUI
  independently. Reuse a tab only if the user asks for it.
- **Do not commit for the sub-agent** and do not tidy its work while it runs. Wait for its report.
- **Report to the user what you spawned** (tab name, surface ref, task) so they can watch, and say
  what you will do when each agent reports back.
- If an agent dies without reporting, check its tab (`cmux read-screen --surface <ref> --lines 40`)
  and its session file under `~/.pi/agent/sessions/<project>/`, then decide: restart it, or do the
  work yourself. Do not silently continue the series.
