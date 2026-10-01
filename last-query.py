#!/usr/bin/env python3
"""Map each Cursor CLI Foot window to its last <user_query> (JSONL)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

QUERY_RE = re.compile(
    r"<user_query>\s*(.*?)\s*</user_query>",
    re.DOTALL,
)
HZ = os.sysconf("SC_CLK_TCK")


def cmdline(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(
            "utf-8", "replace"
        )
    except OSError:
        return ""


def children(pid: int) -> list[int]:
    out: list[int] = []
    try:
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                ppid = int(entry.joinpath("stat").read_text().split(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            if ppid == pid:
                out.append(int(entry.name))
    except OSError:
        pass
    return out


def descendants(pid: int) -> list[int]:
    found: list[int] = []
    stack = [pid]
    seen = {pid}
    while stack:
        cur = stack.pop()
        for child in children(cur):
            if child not in seen:
                seen.add(child)
                found.append(child)
                stack.append(child)
    return found


def proc_start(pid: int) -> float | None:
    try:
        uptime = float(Path("/proc/uptime").read_text().split()[0])
        ticks = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19])
        return time.time() - uptime + ticks / HZ
    except (OSError, IndexError, ValueError):
        return None


def agent_pid_and_cwd(foot_pid: int) -> tuple[int | None, Path | None]:
    for pid in descendants(foot_pid):
        cmd = cmdline(pid)
        if "cursor-agent" not in cmd:
            continue
        if "screenlook" in cmd or "hypruse" in cmd:
            continue
        try:
            return pid, Path(f"/proc/{pid}/cwd").resolve()
        except OSError:
            continue
    return None, None


def transcripts_dir_for(cwd: Path) -> Path:
    slug = str(cwd.resolve()).lstrip("/").replace("/", "-")
    return Path.home() / ".cursor" / "projects" / slug / "agent-transcripts"


# Folder ctime vs process start. Sessions older than this still match:
# ctime is creation time, not "how long the chat has been open".
MATCH_SLACK_S = 180.0


def assign_jsonls(windows: list[dict]) -> dict[str, Path]:
    """One JSONL per window. Closest transcript-dir ctime to agent start wins."""
    by_dir: dict[Path, list[dict]] = {}
    for win in windows:
        by_dir.setdefault(win["tdir"], []).append(win)

    assigned: dict[str, Path] = {}
    for tdir, group in by_dir.items():
        jsonls = list(tdir.glob("*/*.jsonl"))
        pairs: list[tuple[float, str, Path]] = []
        for win in group:
            start = win["start"]
            if start is None:
                continue
            for path in jsonls:
                dt = path.parent.stat().st_ctime - start
                if dt < -5 or dt > MATCH_SLACK_S:
                    continue
                pairs.append((abs(dt), win["address"], path))
        pairs.sort()
        used_addr: set[str] = set()
        used_path: set[Path] = set()
        for _score, address, path in pairs:
            if address in used_addr or path in used_path:
                continue
            used_addr.add(address)
            used_path.add(path)
            assigned[address] = path

        # --resume: folder ctime is the original session, not this Foot.
        unmatched = [w for w in group if w["address"] not in used_addr]
        unused = [p for p in jsonls if p not in used_path]
        unmatched.sort(key=lambda w: w["start"] or 0, reverse=True)
        for win in unmatched:
            start = win["start"]
            candidates: list[tuple[float, Path]] = []
            for path in unused:
                mt = path.stat().st_mtime
                if start is not None and mt < start - 5:
                    continue
                candidates.append((-mt, path))
            if not candidates:
                continue
            candidates.sort()
            path = candidates[0][1]
            unused.remove(path)
            assigned[win["address"]] = path
    return assigned


def one_line(text: str) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    if len(text) > 300:
        text = text[:299].rstrip() + "…"
    return text


def message_text(obj: dict) -> str:
    texts: list[str] = []
    for part in (obj.get("message") or {}).get("content") or []:
        if isinstance(part, dict) and part.get("type") == "text":
            chunk = (part.get("text") or "").strip()
            if chunk:
                texts.append(chunk)
    return "\n".join(texts).strip()


def scan_jsonl(jsonl: Path) -> tuple[str, str, bool]:
    """Last user query, last assistant fingerprint, whether the file ends on assistant."""
    query = ""
    assistant_key = ""
    last_role = ""
    try:
        lines = jsonl.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return "", "", False
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = obj.get("role")
        if role not in ("user", "assistant"):
            continue
        if not last_role:
            last_role = role
        body = message_text(obj)
        if role == "user" and not query:
            match = QUERY_RE.search(body)
            if match:
                body = match.group(1).strip()
            query = one_line(body)
        elif role == "assistant" and not assistant_key:
            body = one_line(body)
            if body:
                assistant_key = body[:240]
        if query and assistant_key:
            break
    return query, assistant_key, last_role == "assistant"


def hypr_clients() -> list[dict]:
    try:
        return json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def load_prev(dest: Path | None) -> dict[str, dict]:
    if dest is None or not dest.is_file():
        return {}
    try:
        raw = json.loads(dest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    out: dict[str, dict] = {}
    if not isinstance(raw, dict):
        return out
    for key, value in raw.items():
        if isinstance(value, str):
            out[str(key).lower()] = {"query": value, "assistantKey": "", "lastResponseAt": 0}
        elif isinstance(value, dict):
            out[str(key).lower()] = value
    return out


def record_for(
    address: str,
    query: str,
    assistant_key: str,
    last_is_assistant: bool,
    mtime_ms: int,
    prev: dict[str, dict],
) -> dict:
    old = prev.get(address.lower()) or {}
    old_key = str(old.get("assistantKey") or "")
    old_query = str(old.get("query") or "")
    # Streaming still appends assistant lines (fingerprint changes). Idle
    # composer = last role assistant and the text has settled.
    in_flight = (not last_is_assistant) or bool(assistant_key and assistant_key != old_key)
    waiting_for_prompt = not in_flight
    last_at = int(old.get("lastResponseAt") or 0)
    if waiting_for_prompt:
        last_at = 0
    elif (not last_is_assistant) and (
        query != old_query or last_at <= 0 or bool(old.get("waitingForPrompt"))
    ):
        last_at = mtime_ms
    elif last_at <= 0:
        last_at = mtime_ms
    return {
        "query": query,
        "assistantKey": assistant_key,
        "lastResponseAt": last_at,
        "waitingForPrompt": waiting_for_prompt,
    }


def store(out: dict[str, dict], address: str, record: dict) -> None:
    if not address or not record.get("query"):
        return
    out[address] = record
    low = address.lower()
    if low != address:
        out[low] = record


def emit(out: dict[str, dict], dest: Path | None) -> None:
    payload = json.dumps(out, ensure_ascii=False, sort_keys=True) + "\n"
    if dest is not None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            if dest.is_file() and dest.read_text(encoding="utf-8") == payload:
                sys.stdout.write(payload)
                return
        except OSError:
            pass
        dest.write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)


def main() -> int:
    dest: Path | None = None
    args = sys.argv[1:]
    if args[:1] == ["--write"] and len(args) >= 2:
        dest = Path(args[1])

    prev = load_prev(dest)
    out: dict[str, dict] = {}
    for address, jsonl in assign_jsonls(windows_from_hypr()).items():
        query, assistant_key, last_is_assistant = scan_jsonl(jsonl)
        try:
            mtime_ms = int(jsonl.stat().st_mtime * 1000)
        except OSError:
            mtime_ms = int(time.time() * 1000)
        store(
            out,
            address,
            record_for(address, query, assistant_key, last_is_assistant, mtime_ms, prev),
        )
    emit(out, dest)
    return 0


def windows_from_hypr() -> list[dict]:
    windows: list[dict] = []
    for client in hypr_clients():
        if client.get("class") != "org.omarchy.agent":
            continue
        address = str(client.get("address") or "")
        try:
            foot_pid = int(client["pid"])
        except (KeyError, TypeError, ValueError):
            continue
        agent_pid, cwd = agent_pid_and_cwd(foot_pid)
        if cwd is None:
            continue
        tdir = transcripts_dir_for(cwd)
        if not tdir.is_dir():
            continue
        start = proc_start(agent_pid) if agent_pid else proc_start(foot_pid)
        windows.append({"address": address, "tdir": tdir, "start": start})
    return windows


if __name__ == "__main__":
    raise SystemExit(main())
