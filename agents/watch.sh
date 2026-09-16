#!/usr/bin/env bash
# Live view of an agent's thinking, tool calls and tool results.
#
#   agents/watch.sh              # follow the newest log
#   agents/watch.sh <path.jsonl> # follow a specific one (e.g. from `status`)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$REPO/agents/state/logs"

LOG="${1:-}"
if [ -z "$LOG" ]; then
  LOG="$(ls -t "$LOG_DIR"/*.jsonl 2>/dev/null | head -1)"
  [ -n "$LOG" ] || { echo "No agent logs yet in $LOG_DIR"; exit 1; }
fi

echo "Watching $LOG (Ctrl-C to stop)"
tail -n +1 -F "$LOG" | python3 -u -c "
import json, sys, textwrap

def clip(s, n=280):
    s = (s or '').strip()
    return s if len(s) <= n else s[:n] + '…'

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    t = obj.get('type')
    if obj.get('event') == 'session_started' or (t == 'system' and obj.get('subtype') == 'init' and obj.get('model')):
        print(f\"— session started (model {obj.get('model', '?')}) —\")
    elif t == 'system':
        pass  # partial-message chunk noise from --include-partial-messages
    elif t == 'assistant':
        for block in obj.get('message', {}).get('content', []) or []:
            kind = block.get('type')
            if kind == 'thinking':
                print('[thinking] ' + clip(block.get('thinking'), 500))
            elif kind == 'text':
                text = clip(block.get('text'), 1000)
                if text:
                    print('[says] ' + text)
            elif kind == 'tool_use':
                name = block.get('name', '?')
                args = json.dumps(block.get('input', {}), ensure_ascii=False)
                print(f'[calls] {name} {clip(args, 200)}')
    elif t == 'user':
        for block in obj.get('message', {}).get('content', []) or []:
            if block.get('type') == 'tool_result':
                content = block.get('content')
                if isinstance(content, list):
                    content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
                print('[result] ' + clip(content, 300))
    elif t == 'result':
        print('=== FINAL: ' + clip(obj.get('result'), 1000) + ' ===')
    elif t == 'runner':
        print(f\"[runner] {obj.get('event')}\")
"
