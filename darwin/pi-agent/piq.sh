#!/usr/bin/env bash
# `pi` against the local Qwen3.6-35B-A3B on homeserver-edt, with a minimal prompt.
#
# Why this exists: pi's stock system prompt plus its full tool/skill catalogue is
# ~9.3k tokens, measured, against a 32k window on the endpoint. This wrapper is
# ~3.3k — it returns ~6k of window and saves ~23s of prefill per turn (prompt
# processing runs at ~200-270 t/s). Numbers and the endpoint's own limits:
# plans/local-qwen.md §4.1.
#
# Deliberately dropped: extensions (the skill list is large), MCP, and every tool
# except read/bash/edit/write. Add flags on the command line if you need them
# back; the last flag wins.
set -euo pipefail

exec pi \
  --provider local \
  --model qwen3.6-35b-a3b \
  --system-prompt "You are a coding assistant running on a small local model with a 32k window. Be terse: one-line answers, small edits, few tool calls. Prefer reading a file once over re-reading it. If a task needs many steps, say so before starting rather than half-finishing it." \
  --tools read,bash,edit,write \
  --no-extensions \
  --no-mcp \
  "$@"
