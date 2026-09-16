#!/usr/bin/env python3
"""Electro Motion site-builder MCP server.

A dependency-free MCP server (JSON-RPC 2.0 over stdio, Python 3.9+) that coordinates
autonomous Claude agents building the Electro Motion website:

  * a shared, file-locked task backlog agents claim work from
  * a static-site validator (links, anchors, assets, SEO/a11y basics)
  * the brand & content guide every agent must follow
  * a progress log so humans can see what the agents did

Environment:
  EM_SITE_ROOT   site directory to validate      (default: <repo>/sites/electmotion)
  EM_STATE_DIR   backlog + log storage (ignored) (default: <repo>/agents/state)
"""

import fcntl
import json
import os
import sys
import time
from contextlib import contextmanager
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SITE_ROOT = Path(os.environ.get("EM_SITE_ROOT", REPO / "sites" / "electmotion")).resolve()
STATE_DIR = Path(os.environ.get("EM_STATE_DIR", REPO / "agents" / "state")).resolve()
BACKLOG = STATE_DIR / "backlog.json"
LOCK = STATE_DIR / "backlog.lock"
PROGRESS = STATE_DIR / "progress.log"
SEED = HERE / "seed_backlog.json"
BRAND = HERE / "brand.json"

CLAIM_TTL_SECONDS = int(os.environ.get("EM_CLAIM_TTL", 3 * 3600))
SERVER_INFO = {"name": "electmotion-builder", "version": "1.0.0"}


# ---------------------------------------------------------------- backlog store

@contextmanager
def locked_backlog():
    """Yield the backlog dict under an exclusive lock and persist it afterwards."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if BACKLOG.exists():
                data = json.loads(BACKLOG.read_text())
            else:
                seed = json.loads(SEED.read_text())
                data = {"next_id": 1, "tasks": []}
                for t in seed:
                    data["tasks"].append(_new_task(data, t["title"], t["description"], t.get("priority", 3), "seed"))
            _expire_stale_claims(data)
            yield data
            tmp = BACKLOG.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=2))
            tmp.replace(BACKLOG)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def _new_task(data, title, description, priority, created_by):
    task = {
        "id": data["next_id"],
        "title": title,
        "description": description,
        "priority": int(priority),
        "status": "open",
        "created_by": created_by,
        "created_at": _now(),
        "claimed_by": None,
        "claimed_at": None,
        "claimed_ts": None,
        "attempts": 0,
        "notes": [],
    }
    data["next_id"] += 1
    return task


def _expire_stale_claims(data):
    cutoff = time.time() - CLAIM_TTL_SECONDS
    for t in data["tasks"]:
        if t["status"] == "in_progress" and (t.get("claimed_ts") or 0) < cutoff:
            t["status"] = "open"
            t["notes"].append(f"{_now()} claim by {t['claimed_by']} expired")
            t["claimed_by"] = None


def _find(data, task_id):
    for t in data["tasks"]:
        if t["id"] == int(task_id):
            return t
    raise ToolError(f"task {task_id} not found")


def _brief(t):
    return {k: t[k] for k in ("id", "title", "priority", "status", "claimed_by", "attempts")}


def log(agent_id, message):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(PROGRESS, "a") as f:
        f.write(f"{_now()} [{agent_id}] {message}\n")


# ---------------------------------------------------------------- tools

class ToolError(Exception):
    pass


def tool_backlog_list(args):
    status = args.get("status")
    with locked_backlog() as data:
        tasks = [t for t in data["tasks"] if not status or t["status"] == status]
    tasks.sort(key=lambda t: (t["status"] != "in_progress", t["status"] != "open", t["priority"], t["id"]))
    counts = {}
    for t in data["tasks"]:
        counts[t["status"]] = counts.get(t["status"], 0) + 1
    return {"counts": counts, "tasks": [_brief(t) for t in tasks]}


def tool_backlog_claim(args):
    agent = args["agent_id"]
    max_attempts = int(os.environ.get("EM_MAX_ATTEMPTS", 3))
    with locked_backlog() as data:
        mine = [t for t in data["tasks"] if t["status"] == "in_progress" and t["claimed_by"] == agent]
        if mine:
            task = mine[0]
        else:
            open_tasks = [t for t in data["tasks"] if t["status"] == "open" and t["attempts"] < max_attempts]
            if not open_tasks:
                return {"task": None, "hint": "Backlog is empty. Run a site audit (site_validate + review pages "
                        "against brand_guide) and add the most valuable improvements with backlog_add."}
            task = min(open_tasks, key=lambda t: (t["priority"], t["id"]))
            task.update(status="in_progress", claimed_by=agent, claimed_at=_now(), claimed_ts=time.time())
            task["attempts"] += 1
    log(agent, f"claimed #{task['id']} {task['title']}")
    return {"task": task}


def tool_backlog_complete(args):
    agent, summary = args["agent_id"], args["summary"]
    with locked_backlog() as data:
        task = _find(data, args["task_id"])
        if task["status"] != "in_progress" or task["claimed_by"] != agent:
            raise ToolError(f"task {task['id']} is not claimed by {agent}")
        task.update(status="done", completed_at=_now(), summary=summary)
    log(agent, f"completed #{task['id']}: {summary}")
    return {"ok": True, "task": _brief(task)}


def tool_backlog_release(args):
    agent, reason = args["agent_id"], args["reason"]
    blocked = bool(args.get("blocked"))
    with locked_backlog() as data:
        task = _find(data, args["task_id"])
        if task["claimed_by"] != agent:
            raise ToolError(f"task {task['id']} is not claimed by {agent}")
        task.update(status="blocked" if blocked else "open", claimed_by=None)
        task["notes"].append(f"{_now()} {agent}: {reason}")
    log(agent, f"{'blocked' if blocked else 'released'} #{task['id']}: {reason}")
    return {"ok": True, "task": _brief(task)}


def tool_backlog_add(args):
    agent = args.get("agent_id", "agent")
    with locked_backlog() as data:
        title = args["title"].strip()
        dupe = next((t for t in data["tasks"] if t["title"].lower() == title.lower() and t["status"] != "done"), None)
        if dupe:
            return {"ok": False, "reason": "duplicate", "existing": _brief(dupe)}
        task = _new_task(data, title, args["description"], args.get("priority", 3), agent)
        data["tasks"].append(task)
    log(agent, f"added #{task['id']} {title}")
    return {"ok": True, "task": _brief(task)}


def tool_brand_guide(args):
    return json.loads(BRAND.read_text())


def tool_progress_log(args):
    limit = int(args.get("limit", 40))
    if not PROGRESS.exists():
        return {"entries": []}
    return {"entries": PROGRESS.read_text().splitlines()[-limit:]}


def tool_site_list_files(args):
    files = []
    for p in sorted(SITE_ROOT.rglob("*")):
        if p.is_file():
            files.append({"path": str(p.relative_to(SITE_ROOT)), "bytes": p.stat().st_size})
    return {"site_root": str(SITE_ROOT), "files": files}


VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
# SVG and optional-close elements are excluded from nesting checks
LOOSE = {"p", "li", "option", "tr", "td", "th", "thead", "tbody"}


class PageScan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids, self.dupe_ids, self.refs, self.issues = set(), set(), [], []
        self.lang = self.title = self.description = self.viewport = self.h1 = None
        self.h1_count = 0
        self.stack = []
        self._in_title = False
        self._svg_depth = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        line = self.getpos()[0]
        if "id" in a:
            (self.dupe_ids if a["id"] in self.ids else self.ids).add(a["id"])
        if tag == "svg":
            self._svg_depth += 1
        if tag == "html":
            self.lang = a.get("lang")
        elif tag == "title":
            self._in_title = True
        elif tag == "meta" and a.get("name") == "description":
            self.description = a.get("content")
        elif tag == "meta" and a.get("name") == "viewport":
            self.viewport = a.get("content")
        elif tag == "h1":
            self.h1_count += 1
        elif tag == "img":
            if "alt" not in a:
                self.issues.append(f"line {line}: <img> without alt")
        for attr in ("href", "src"):
            if attr in a and a[attr] is not None:
                self.refs.append((line, tag, a[attr]))
        if self._svg_depth == 0 and tag not in VOID:
            self.stack.append((tag, line))

    def handle_startendtag(self, tag, attrs):
        # self-closing: record refs/ids but don't push onto the stack
        depth = self._svg_depth
        self.handle_starttag(tag, attrs)
        if depth == 0 and tag not in VOID and tag != "svg":
            self.stack.pop()
        if tag == "svg":
            self._svg_depth -= 1

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if self._svg_depth:
            if tag == "svg":
                self._svg_depth -= 1
                if self._svg_depth == 0 and self.stack and self.stack[-1][0] == "svg":
                    self.stack.pop()
            return
        if tag in VOID:
            return
        while self.stack and self.stack[-1][0] != tag and self.stack[-1][0] in LOOSE:
            self.stack.pop()
        if self.stack and self.stack[-1][0] == tag:
            self.stack.pop()
        else:
            self.issues.append(f"line {self.getpos()[0]}: unexpected </{tag}>")

    def handle_data(self, data):
        if self._in_title:
            self.title = (self.title or "") + data


def tool_site_validate(args):
    pages = sorted(SITE_ROOT.rglob("*.html"))
    scans = {}
    for p in pages:
        s = PageScan()
        s.feed(p.read_text(encoding="utf-8"))
        s.close()
        scans[p] = s

    report = {}
    total = 0
    for p, s in scans.items():
        issues = list(s.issues)
        rel = str(p.relative_to(SITE_ROOT))
        if not s.lang:
            issues.append("missing <html lang>")
        if not (s.title or "").strip():
            issues.append("missing <title>")
        if not s.description:
            issues.append("missing meta description")
        elif not 50 <= len(s.description) <= 170:
            issues.append(f"meta description length {len(s.description)} (aim for 50-170)")
        if not s.viewport:
            issues.append("missing viewport meta")
        if s.h1_count != 1:
            issues.append(f"expected exactly one <h1>, found {s.h1_count}")
        for dup in sorted(s.dupe_ids):
            issues.append(f"duplicate id '{dup}'")
        for tag, line in s.stack:
            if tag not in LOOSE and tag not in ("html", "body", "head"):
                issues.append(f"line {line}: <{tag}> never closed")
        for line, tag, ref in s.refs:
            issues.extend(_check_ref(p, s, line, ref, scans))
        if issues:
            report[rel] = issues
            total += len(issues)
    return {"pages_checked": len(pages), "issue_count": total, "issues": report,
            "status": "clean" if total == 0 else "needs_fixes"}


def _check_ref(page, scan, line, ref, scans):
    parts = urlsplit(ref)
    if parts.scheme or ref.startswith("//") or ref.startswith(("mailto:", "tel:", "data:", "javascript:")):
        return []
    path, frag = unquote(parts.path), parts.fragment
    if not path:
        if frag and frag not in scan.ids:
            return [f"line {line}: anchor '#{frag}' not found on page"]
        return []
    target = (SITE_ROOT / path.lstrip("/")) if path.startswith("/") else (page.parent / path)
    target = target.resolve()
    if target.is_dir():
        target = target / "index.html"
    if SITE_ROOT not in target.parents and target != SITE_ROOT:
        return [f"line {line}: '{ref}' points outside the site"]
    if not target.exists():
        # Cloudflare Pages serves /about for about.html
        if target.with_suffix(".html").exists():
            target = target.with_suffix(".html")
        else:
            return [f"line {line}: broken link '{ref}'"]
    if frag and target.suffix == ".html":
        other = scans.get(target)
        if other is not None and frag not in other.ids:
            return [f"line {line}: anchor '#{frag}' not found in {target.relative_to(SITE_ROOT)}"]
    return []


TOOLS = {
    "backlog_list": (tool_backlog_list, "List backlog tasks with status counts. Optional filter by status.", {
        "status": {"type": "string", "enum": ["open", "in_progress", "done", "blocked"]}}, []),
    "backlog_claim": (tool_backlog_claim, "Claim the highest-priority open task for this agent (returns your current task if you already hold one). Returns task=null when the backlog is empty.", {
        "agent_id": {"type": "string"}}, ["agent_id"]),
    "backlog_complete": (tool_backlog_complete, "Mark your claimed task done with a short summary of what changed.", {
        "agent_id": {"type": "string"}, "task_id": {"type": "integer"}, "summary": {"type": "string"}}, ["agent_id", "task_id", "summary"]),
    "backlog_release": (tool_backlog_release, "Give a claimed task back (blocked=true if it needs a human, e.g. missing real company data).", {
        "agent_id": {"type": "string"}, "task_id": {"type": "integer"}, "reason": {"type": "string"},
        "blocked": {"type": "boolean"}}, ["agent_id", "task_id", "reason"]),
    "backlog_add": (tool_backlog_add, "Add a follow-up task. Priority 1 (urgent) to 5 (nice to have). Duplicate titles are rejected.", {
        "agent_id": {"type": "string"}, "title": {"type": "string"}, "description": {"type": "string"},
        "priority": {"type": "integer", "minimum": 1, "maximum": 5}}, ["title", "description"]),
    "brand_guide": (tool_brand_guide, "Company profile, design tokens, voice and the content rules every page must follow.", {}, []),
    "site_list_files": (tool_site_list_files, "List files in the Electro Motion site directory.", {}, []),
    "site_validate": (tool_site_validate, "Validate every HTML page: broken links/anchors/assets, unclosed tags, duplicate ids, lang/title/description/viewport, single h1, img alt.", {}, []),
    "progress_log": (tool_progress_log, "Read the most recent agent progress entries.", {
        "limit": {"type": "integer"}}, []),
}


# ---------------------------------------------------------------- JSON-RPC loop

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(req):
    method, rid, params = req.get("method"), req.get("id"), req.get("params") or {}
    if rid is None:  # notification
        return None
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
                "instructions": "Coordinate Electro Motion website work: claim a task, follow brand_guide, "
                                "run site_validate before completing."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [
            {"name": name, "description": desc,
             "inputSchema": {"type": "object", "properties": props, "required": req_}}
            for name, (_, desc, props, req_) in TOOLS.items()]}
    if method == "tools/call":
        name = params.get("name")
        if name not in TOOLS:
            raise RpcError(-32602, f"unknown tool {name}")
        try:
            result = TOOLS[name][0](params.get("arguments") or {})
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}], "isError": False}
        except (ToolError, KeyError, ValueError) as e:
            msg = f"missing argument {e}" if isinstance(e, KeyError) else str(e)
            return {"content": [{"type": "text", "text": msg}], "isError": True}
    raise RpcError(-32601, f"method not found: {method}")


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        try:
            result = handle(req)
            if result is not None:
                send({"jsonrpc": "2.0", "id": req["id"], "result": result})
        except RpcError as e:
            send({"jsonrpc": "2.0", "id": req.get("id"), "error": {"code": e.code, "message": str(e)}})
        except Exception as e:  # never crash the agent session
            send({"jsonrpc": "2.0", "id": req.get("id"), "error": {"code": -32603, "message": repr(e)}})


if __name__ == "__main__":
    main()
