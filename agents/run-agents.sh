#!/usr/bin/env bash
# Runs autonomous Claude agents around the clock to build the Electro Motion site.
#
#   agents/run-agents.sh [start|status|stop]
#
# Agents work in a separate git worktree on $BRANCH (never on main), coordinate through the
# electmotion MCP server, and every iteration's changes under sites/electmotion are committed
# (and pushed when PUSH=1, which gives a Cloudflare Pages preview deployment per commit).
# Once you run `stop` and the agents finish their current iteration, $BRANCH is merged into
# $BASE_BRANCH (main) and pushed automatically (set MERGE_ON_STOP=0 to disable), then $BRANCH
# is reset to match main so the next run starts clean from it.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="${AGENTS:-1}"
BRANCH="${BRANCH:-agents/electmotion}"
BASE_BRANCH="${BASE_BRANCH:-main}"
WORKTREE="${WORKTREE:-$(dirname "$REPO")/EgyWeb-electmotion-agents}"
PUSH="${PUSH:-0}"
MODEL="${MODEL:-claude-sonnet-5}"
EFFORT="${EFFORT:-medium}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"  # per-iteration cap (API billing only)
SLEEP_BETWEEN="${SLEEP_BETWEEN:-300}"
IDLE_SLEEP="${IDLE_SLEEP:-7200}"
ITERATION_TIMEOUT="${ITERATION_TIMEOUT:-2700}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"  # 0 = run until stopped
PROMPT_FILE="${PROMPT_FILE:-$REPO/agents/RUN_AGENTS.md}"
DRY_RUN="${DRY_RUN:-0}"
MERGE_ON_STOP="${MERGE_ON_STOP:-1}"  # after agents finish, merge $BRANCH into $BASE_BRANCH and reset $BRANCH from it
MERGE_REPO="${MERGE_REPO:-$REPO/agents/state/merge-repo}"

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

merge_to_main() {
  [ "$MERGE_ON_STOP" = "1" ] || return 0
  local origin_url ok=1
  origin_url="$(git -C "$REPO" remote get-url origin 2>/dev/null)" || {
    say "no 'origin' remote; skipping auto-merge of $BRANCH into $BASE_BRANCH"
    return 0
  }

  until mkdir "$GIT_LOCK" 2>/dev/null; do sleep 2; done

  # Merge in a standalone clone of origin, never in $REPO or $WORKTREE, so this can never
  # collide with a branch already checked out there (e.g. you sitting on main yourself).
  if [ ! -d "$MERGE_REPO/.git" ]; then
    git clone -q "$origin_url" "$MERGE_REPO" || { say "merge: clone of $origin_url failed"; ok=0; }
  fi
  [ "$ok" = 1 ] && { git -C "$MERGE_REPO" fetch -q origin "$BASE_BRANCH" || { say "merge: fetch $BASE_BRANCH failed"; ok=0; }; }
  [ "$ok" = 1 ] && { git -C "$MERGE_REPO" checkout -q -B "$BASE_BRANCH" "origin/$BASE_BRANCH" || { say "merge: checkout $BASE_BRANCH failed"; ok=0; }; }
  [ "$ok" = 1 ] && { git -C "$MERGE_REPO" fetch -q "$WORKTREE" "$BRANCH" || { say "merge: fetch $BRANCH from worktree failed"; ok=0; }; }

  if [ "$ok" = 1 ]; then
    if git -C "$MERGE_REPO" merge -q --no-edit FETCH_HEAD -m "electmotion: merge $BRANCH into $BASE_BRANCH (autonomous agents)"; then
      if git -C "$MERGE_REPO" push -q origin "$BASE_BRANCH"; then
        say "merged $BRANCH into $BASE_BRANCH and pushed"
      else
        say "merge: push of $BASE_BRANCH failed; merge commit is sitting in $MERGE_REPO, push it manually"
        ok=0
      fi
    else
      say "merge: conflict merging $BRANCH into $BASE_BRANCH; resolve manually in $MERGE_REPO, then re-run"
      git -C "$MERGE_REPO" merge --abort 2>/dev/null
      ok=0
    fi
  fi

  if [ "$ok" = 1 ]; then
    # Fold main back into the agent branch so the next run starts from exactly what's on main.
    if git -C "$WORKTREE" fetch -q "$MERGE_REPO" "$BASE_BRANCH" && git -C "$WORKTREE" reset -q --hard FETCH_HEAD; then
      say "reset $BRANCH to match $BASE_BRANCH; next run starts from main"
    else
      say "merge: pushed $BASE_BRANCH but failed to reset $BRANCH from it; fix the worktree manually"
    fi
  fi

  rmdir "$GIT_LOCK" 2>/dev/null
}

run_agent() {
  local agent="$1" i=0 failures=0 rc out log started prompt
  prompt="$(prompt_for "$agent")" || exit 1
  local cmd=(claude -p "$prompt"
    --mcp-config "$RUNTIME_MCP" --strict-mcp-config
    --permission-mode acceptEdits
    --allowedTools Read Edit Write Glob Grep mcp__electmotion
    --disallowedTools Bash WebFetch WebSearch
    --output-format stream-json --include-partial-messages --verbose)
  [ -n "$MODEL" ] && cmd+=(--model "$MODEL")
  [ -n "$EFFORT" ] && cmd+=(--effort "$EFFORT")
  [ -n "$MAX_BUDGET_USD" ] && cmd+=(--max-budget-usd "$MAX_BUDGET_USD")

  while [ ! -f "$STOP_FILE" ]; do
    i=$((i + 1))
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$i" -gt "$MAX_ITERATIONS" ]; then break; fi
    log="$LOG_DIR/$agent-$(date '+%Y%m%d-%H%M%S').jsonl"
    started="$(date '+%Y-%m-%dT%H:%M:%S')"
    say "[$agent] iteration $i → $log"

    if [ "$DRY_RUN" = "1" ]; then
      printf '(cd %q &&' "$WORKTREE"; printf ' %q' "${cmd[@]}"; printf ')\n'
      break
    fi

    (cd "$WORKTREE" && "${cmd[@]}") </dev/null >"$log" 2>&1 &
    local pid=$!
    ( sleep "$ITERATION_TIMEOUT" && kill "$pid" 2>/dev/null && echo '{"type":"runner","event":"timeout"}' >>"$log" ) &
    local watchdog=$!
    wait "$pid"; rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null

    commit_changes "$agent" "$started"

    # The final "result" line carries the agent's last reply; that's what IDLE detection reads.
    out="$(python3 -c "
import json, sys
text = ''
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if obj.get('type') == 'result':
        text = obj.get('result', '')
print(text)
" "$log" 2>/dev/null)"
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
  stop) mkdir -p "$STATE_DIR"; touch "$STOP_FILE"; echo "Stop requested. Agents exit after their current iteration, then $BRANCH is merged into $BASE_BRANCH." ;;
  merge) merge_to_main ;;
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
    merge_to_main
    ;;
  *) echo "usage: $0 [start|status|stop|merge]"; exit 2 ;;
esac
