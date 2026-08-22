#!/usr/bin/env bash
# Launch dsh (DeepSeek Harness) web UI on 0.0.0.0:9000 for phone access.
#
# Why node --expose-internals: the harness's HMR plugin requires it
# (ctx.loader.internal), and Node forbids that flag inside NODE_OPTIONS, so the
# bin must be launched through node directly.
#
# Stop: pkill -f "bin.js web"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/lan.patch.yml"
LOG="${DSH_WEB_LOG:-/tmp/dsh-web.log}"
DIR="${DSH_WEB_DIR:-$HOME/dev/nix-conf}"

cd "$DIR"
exec node --expose-internals \
  "$(npm root -g)/@deepseek-ai/dsh/lib/bin.js" \
  web --patch "$PATCH" --no-open \
  >"$LOG" 2>&1
