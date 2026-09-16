#!/usr/bin/env bash
# Runs autonomous Claude agents around the clock to build the Electro Motion site.
#
#   agents/run-agents.sh [start|status|stop]
#
# Agents work in a separate git worktree on $BRANCH (never on main), coordinate through the
# electmotion MCP server, and every iteration's changes under sites/electmotion are committed
# (and pushed when PUSH=1, which gives a Cloudflare Pages preview deployment per commit).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="${AGENTS:-1}"
BRANCH="${BRANCH:-agents/electmotion}"
BASE_BRANCH="${BASE_BRANCH:-main}"
WORKTREE="${WORKTREE:-$(dirname "$REPO")/EgyWeb-electmotion-agents}"
PUSH="${PUSH:-0}"
MODEL="${MODEL:-}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-60}"
IDLE_SLEEP="${IDLE_SLEEP:-1800}"
ITERATION_TIMEOUT="${ITERATION_TIMEOUT:-2700}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"  # 0 = run until stopped
PROMPT_FILE="${PROMPT_FILE:-$REPO/agents/RUN_AGENTS.md}"
DRY_RUN="${DRY_RUN:-0}"

STATE_DIR="$REPO/agents/state"
LOG_DIR="$STATE_DIR/logs"
STOP_FILE="$STATE_DIR/STOP"
GIT_LOCK="$STATE_DIR/git.lock"
RUNTIME_MCP="$STATE_DIR/mcp.runtime.json"
SITE_DIR="sites/electmotion"

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

status() {
  python3 - "$STATE_DIR" <<'EOF'
import json, sys, pathlib
state = pathlib.Path(sys.argv[1])
backlog = state / "backlog.json"
if not backlog.exists():
    print("No backlog yet (it is created on the first agent run).")
else:
    tasks = json.loads(backlog.read_text())["tasks"]
    counts = {}
    for t in tasks:
        counts[t["status"]] = counts.get(t["status"], 0) + 1
    print("Backlog:", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    for t in tasks:
        if t["status"] in ("in_progress", "blocked"):
            print(f"  #{t['id']} [{t['status']}] {t['title']}" + (f" ({t['claimed_by']})" if t["claimed_by"] else ""))
log = state / "progress.log"
if log.exists():
    print("\nRecent progress:")
    print("\n".join(log.read_text().splitlines()[-15:]))
EOF
  [ -f "$STOP_FILE" ] && echo "STOP requested; agents exit after their current iteration."
  return 0
}

prompt_for() {
  python3 - "$PROMPT_FILE" "$1" <<'EOF'
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r"<!-- AGENT-PROMPT:START -->(.*?)<!-- AGENT-PROMPT:END -->", text, re.S)
if not m:
    sys.exit("AGENT-PROMPT markers not found in " + sys.argv[1])
print(m.group(1).strip().replace("{{AGENT_ID}}", sys.argv[2]))
EOF
}

setup() {
  command -v claude >/dev/null || { echo "claude CLI not found on PATH"; exit 1; }
  [ -f "$PROMPT_FILE" ] || { echo "Prompt file missing: $PROMPT_FILE"; exit 1; }
  mkdir -p "$LOG_DIR"
  rm -f "$STOP_FILE"

  if [ ! -e "$WORKTREE/.git" ]; then
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$REPO" worktree add "$WORKTREE" "$BRANCH"
    else
      git -C "$REPO" worktree add -b "$BRANCH" "$WORKTREE" "$BASE_BRANCH"
    fi
  fi

  # The server code runs from the main checkout; it validates the worktree's copy of the site.
  cat > "$RUNTIME_MCP" <<EOF
{
  "mcpServers": {
    "electmotion": {
      "command": "python3",
      "args": ["$REPO/agents/mcp-server/server.py"],
      "env": {
        "EM_SITE_ROOT": "$WORKTREE/$SITE_DIR",
        "EM_STATE_DIR": "$STATE_DIR"
      }
    }
  }
}
EOF
}

commit_changes() {
  local agent="$1" started="$2" summary
  until mkdir "$GIT_LOCK" 2>/dev/null; do sleep 2; done
  # Agents may only change the site; drop anything they touched elsewhere.
  git -C "$WORKTREE" checkout -q -- ":(exclude)$SITE_DIR" 2>/dev/null
  git -C "$WORKTREE" clean -fdq -- ":(exclude)$SITE_DIR" 2>/dev/null
  git -C "$WORKTREE" add -A -- "$SITE_DIR"
  if ! git -C "$WORKTREE" diff --cached --quiet; then
    summary="$(awk -v a="[$agent]" -v s="$started" '$1 >= s && $2 == a && $3 == "completed" {sub(/^[^ ]+ [^ ]+ completed /, ""); line=$0} END {print line}' "$STATE_DIR/progress.log" 2>/dev/null)"
    git -C "$WORKTREE" commit -q -m "electmotion($agent): ${summary:-work in progress}" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
    say "[$agent] committed: ${summary:-work in progress}"
    if [ "$PUSH" = "1" ]; then
      git -C "$WORKTREE" push -q -u origin "$BRANCH" || say "[$agent] push failed"
    fi
  fi
  rmdir "$GIT_LOCK"
}

run_agent() {
  local agent="$1" i=0 failures=0 rc out log started prompt
  prompt="$(prompt_for "$agent")" || exit 1
  local cmd=(claude -p "$prompt"
    --mcp-config "$RUNTIME_MCP" --strict-mcp-config
    --permission-mode acceptEdits
    --allowedTools Read Edit Write Glob Grep mcp__electmotion
    --disallowedTools Bash WebFetch WebSearch
    --output-format text)
  [ -n "$MODEL" ] && cmd+=(--model "$MODEL")

  while [ ! -f "$STOP_FILE" ]; do
    i=$((i + 1))
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$i" -gt "$MAX_ITERATIONS" ]; then break; fi
    log="$LOG_DIR/$agent-$(date '+%Y%m%d-%H%M%S').log"
    started="$(date '+%Y-%m-%dT%H:%M:%S')"
    say "[$agent] iteration $i → $log"

    if [ "$DRY_RUN" = "1" ]; then
      printf '(cd %q &&' "$WORKTREE"; printf ' %q' "${cmd[@]}"; printf ')\n'
      break
    fi

    (cd "$WORKTREE" && "${cmd[@]}") </dev/null >"$log" 2>&1 &
    local pid=$!
    ( sleep "$ITERATION_TIMEOUT" && kill "$pid" 2>/dev/null && echo "[runner] iteration timed out" >>"$log" ) &
    local watchdog=$!
    wait "$pid"; rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null

    commit_changes "$agent" "$started"

    out="$(tail -n 5 "$log")"
    if [ "$rc" -ne 0 ]; then
      failures=$((failures + 1))
      local backoff=$((SLEEP_BETWEEN * 2 ** (failures < 5 ? failures : 5)))
      say "[$agent] claude exited $rc (failure $failures); sleeping ${backoff}s"
      sleep "$backoff"
    elif printf '%s' "$out" | grep -q '^IDLE'; then
      failures=0
      say "[$agent] nothing valuable left; idle for ${IDLE_SLEEP}s"
      sleep "$IDLE_SLEEP"
    else
      failures=0
      sleep "$SLEEP_BETWEEN"
    fi
  done
  say "[$agent] stopped"
}

case "${1:-start}" in
  status) status ;;
  stop) mkdir -p "$STATE_DIR"; touch "$STOP_FILE"; echo "Stop requested. Agents exit after their current iteration." ;;
  start)
    # Keep the Mac awake while agents run.
    if [ "$DRY_RUN" != "1" ] && command -v caffeinate >/dev/null && [ -z "${EM_CAFFEINATED:-}" ]; then
      EM_CAFFEINATED=1 exec caffeinate -is "$0" ${1+"$@"}
    fi
    setup
    say "Starting $AGENTS agent(s) on branch $BRANCH in $WORKTREE (push=$PUSH)"
    trap 'say "Interrupted; stopping agents"; kill 0' INT TERM
    for n in $(seq 1 "$AGENTS"); do
      run_agent "agent-$n" &
      sleep 5
    done
    wait
    ;;
  *) echo "usage: $0 [start|status|stop]"; exit 2 ;;
esac
