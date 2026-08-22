#!/usr/bin/env bash
# Launch the DeepSeek Harness web UI from source, bound to 0.0.0.0:9000 for
# phone access.
#
# Why from source: the npm distribution of @deepseek-ai/dsh 0.1.1-rc.2 is
# broken — dsh-client-ui-primitives/dsh-client-ui-slots are published without
# client bundles and with raw .css imports in lib/index.js (and are only
# devDeps upstream, so npm never installs them). Every client UI bundle fails
# to import in the browser. The repo checkout builds and runs correctly.
#
# Why node --expose-internals: the harness's HMR plugin requires it
# (ctx.loader.internal), and Node forbids that flag inside NODE_OPTIONS, so
# the bin must be launched through node directly.
#
# Stop: pkill -f "bin.js web"
set -euo pipefail

HARNESS="${DSH_SOURCE:-$HOME/dev/deepseek-harness}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/lan.patch.yml"
LOG="${DSH_WEB_LOG:-/tmp/dsh-web.log}"
DIR="${DSH_WEB_DIR:-$HOME/dev/nix-conf}"

cd "$HARNESS"
cd "$DIR"
exec node --expose-internals "$HARNESS/apps/cli/lib/bin.js" \
  web --patch "$PATCH" --no-open \
  >"$LOG" 2>&1
