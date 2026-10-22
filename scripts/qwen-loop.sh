#!/usr/bin/env bash
# Autonomous task-queue worker for the local llama.cpp endpoint.
#
# Design: plans/local-qwen.md §3.5. One task = one prompt = one validated
# artifact. NOT a general agent loop: the local model gets 16k of context, so
# anything that needs pi's usual 134k median turn will truncate mid-tool-call.
#
# A task is a markdown file in $QUEUE/queue with front matter:
#
#   ---
#   target: /home/edeetee/scratch/repo
#   verify: cargo test -q
#   max_attempts: 2
#   ---
#   Replace the deprecated calls in src/ ... (the body pi reads)
#
# The worker never pushes. It commits to a `qwen/<task-id>` branch in the target
# repo and moves the task to done/ or failed/ with the transcript.
#
#   ./scripts/qwen-loop.sh --dry-run    # list what a run would do, change nothing
#   ./scripts/qwen-loop.sh              # work the queue, then poll forever
#   ./scripts/qwen-loop.sh --once       # work what is queued, then exit
#
# Env: QWEN_LOOP_DIR (default /var/lib/qwen-loop), QWEN_LOOP_MODEL,
#      QWEN_LOOP_PROVIDER, QWEN_LOOP_THINKING, QWEN_LOOP_TIMEOUT (seconds/task).
set -uo pipefail

QUEUE=${QWEN_LOOP_DIR:-/var/lib/qwen-loop}
MODEL=${QWEN_LOOP_MODEL:-qwen3.6-35b-a3b}
PROVIDER=${QWEN_LOOP_PROVIDER:-local}
THINKING=${QWEN_LOOP_THINKING:-low}
TIMEOUT=${QWEN_LOOP_TIMEOUT:-3600}
POLL=${QWEN_LOOP_POLL:-60}
LOG=$QUEUE/qwen-loop.log

# pi is an npm install in the user prefix, which is not on a systemd unit's
# PATH -- resolve it here rather than relying on the unit's environment.
PI=${QWEN_LOOP_PI:-}
[[ -n $PI ]] || PI=$(command -v pi || true)
[[ -n $PI ]] || PI=/home/edeetee/.npm-global/bin/pi

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

meta() { # meta <key> <file>
  awk -v k="$1" '
    /^---[[:space:]]*$/ { f++; next }
    f == 1 && index($0, k ":") == 1 { sub("^" k ":[[:space:]]*", ""); print; exit }
  ' "$2"
}

body() { # everything after the closing front-matter fence
  awk '/^---[[:space:]]*$/ { f++; next } f >= 2' "$1"
}

# The live nix-conf is never a loop target: a worker that commits branches into
# it would fight every other agent and the deploy path.
refuse_live_repo() {
  case "$1" in
    /home/*/dev/nix-conf | /home/*/dev/nix-conf/*)
      log "REFUSED target $1: the nix-conf repo is not a loop target"
      return 1
      ;;
  esac
  return 0
}

run_pi() { # run_pi <task-file> <target>
  local task=$1 target=$2 prompt
  # The task body goes into the prompt: a 10-20 t/s model should not spend a
  # tool call (and a round trip) reading a file it has already been given.
  prompt=$(body "$task")
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    echo "would run: $PI --provider $PROVIDER --model $MODEL --thinking $THINKING --print (in $target)"
    return 0
  fi
  (
    cd "$target" || exit 1
    # --no-session: a queue of hundreds of tasks must not accumulate session files.
    # timeout: one stuck task must not wedge the queue for the night.
    timeout "$TIMEOUT" "$PI" \
      --provider "$PROVIDER" \
      --model "$MODEL" \
      --thinking "$THINKING" \
      --no-session \
      --mode text \
      --print "$prompt

Working tree: $target"
  ) 2>&1
}

verify_task() { # verify_task <verify-cmd> <target>
  local cmd=$1 target=$2
  [[ -z $cmd ]] && {
    echo "no verify: command — treating as unverified failure"
    return 1
  }
  ( cd "$target" && bash -c "$cmd" ) 2>&1
}

commit_task() { # commit_task <target> <task-id> <title>
  local target=$1 id=$2 title=$3
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "(not a git repo, nothing committed)"
    return 0
  }
  git -C "$target" checkout -q -B "qwen/$id" || return 1
  git -C "$target" add -A || return 1
  git -C "$target" -c user.name=pi -c user.email=pi@localhost \
    commit -q -m "qwen: $id — $title" || {
    echo "(nothing to commit)"
    return 0
  }
  echo "committed on branch qwen/$id (not pushed)"
}

handle() { # handle <claimed task file>
  local task=$1
  local id title target verify attempts n=1 rc out
  id=$(basename "$task" .md)
  title=$(head -1 "$task" | sed 's/^# *//')
  target=$(meta target "$task")
  verify=$(meta verify "$task")
  attempts=$(meta max_attempts "$task")
  attempts=${attempts:-2}

  if [[ -z $target ]]; then
    log "FAIL $id: no target: in front matter"
    mv "$task" "$QUEUE/failed/" 2>/dev/null
    return 1
  fi
  refuse_live_repo "$target" || {
    mv "$task" "$QUEUE/failed/" 2>/dev/null
    return 1
  }
  [[ -d $target ]] || {
    log "FAIL $id: target does not exist: $target"
    mv "$task" "$QUEUE/failed/" 2>/dev/null
    return 1
  }

  while (( n <= attempts )); do
    log "RUN  $id (attempt $n/$attempts) target=$target"
    out=$(run_pi "$QUEUE/running/$id.md" "$target")
    printf '%s\n' "$out" >"$QUEUE/running/$id.log"

    if verify_task "$verify" "$target" >>"$QUEUE/running/$id.log" 2>&1; then
      commit_task "$target" "$id" "${title:-task}" >>"$QUEUE/running/$id.log" 2>&1
      log "PASS $id"
      mv "$task" "$QUEUE/done/" 2>/dev/null
      mv "$QUEUE/running/$id.log" "$QUEUE/done/$id.log" 2>/dev/null
      return 0
    fi
    log "MISS $id attempt $n failed its verify"
    (( n++ ))
  done

  log "FAIL $id after $attempts attempts"
  mv "$task" "$QUEUE/failed/" 2>/dev/null
  mv "$QUEUE/running/$id.log" "$QUEUE/failed/$id.log" 2>/dev/null
  return 1
}

prepare() {
  mkdir -p "$QUEUE"/{queue,running,done,failed} || exit 1
  touch "$LOG"
}

dry_run() {
  local f found=0
  for f in "$QUEUE"/queue/*.md; do
    [[ -e $f ]] || break
    found=1
    printf '%s\n  target: %s\n  verify: %s\n  attempts: %s\n' \
      "$(basename "$f" .md)" "$(meta target "$f")" "$(meta verify "$f")" \
      "$(meta max_attempts "$f")"
    refuse_live_repo "$(meta target "$f")" || echo "  (would be refused)"
  done
  (( found )) || echo "queue is empty"
}

work_queue() {
  local f base claimed=0
  for f in "$QUEUE"/queue/*.md; do
    [[ -e $f ]] || break
    base=$(basename "$f")
    # Portable claim (`mv -n`, not GNU's --no-clobber): two workers, or a crash
    # mid-claim, can never both take a task. Verify by the result, because -n
    # reports success even when it declines to move.
    mv -n "$f" "$QUEUE/running/" 2>/dev/null
    if [[ -e $f || ! -f $QUEUE/running/$base ]]; then
      log "SKIP $base: could not claim (another worker?)"
      continue
    fi
    claimed=1
    handle "$QUEUE/running/$base"
  done
  (( claimed ))
}

main() {
  local mode=forever
  case "${1:-}" in
    --dry-run) DRY_RUN=1; mode=dry ;;
    --once) mode=once ;;
    "") ;;
    *)
      echo "usage: $0 [--dry-run|--once]" >&2
      exit 2
      ;;
  esac
  prepare
  [[ $mode == dry ]] && {
    dry_run
    exit 0
  }
  log "worker up (model=$MODEL provider=$PROVIDER timeout=${TIMEOUT}s)"
  while true; do
    work_queue
    [[ $mode == once ]] && break
    sleep "$POLL"
  done
  log "worker done"
}

main "$@"
