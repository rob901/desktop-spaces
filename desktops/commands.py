"""The desktop commands: save, open, close, list, edit, windows."""
from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import time
from typing import Dict, List, Optional, Set

from . import aero, chrome, config

JOIN_DIR = {"h_tiles": "left", "h_accordion": "left", "v_tiles": "up", "v_accordion": "up"}


def warn(msg: str) -> None:
    print(f"warning: {msg}", file=sys.stderr)


def _launch_timeout() -> float:
    return float(os.environ.get("DESKTOP_LAUNCH_TIMEOUT", "20"))


def _poll_interval() -> float:
    return float(os.environ.get("DESKTOP_POLL_INTERVAL", "0.25"))


def _live_ids(wins: List[aero.Window]) -> Set[int]:
    return {w.id for w in wins}


def _claimed_by_others(name: str, live: Set[int]) -> Set[int]:
    claimed = set()
    for other in config.list_names():
        if other == name:
            continue
        st = config.prune_state(config.load_state(other), live)
        claimed.update(e["id"] for e in st["windows"])
    return claimed


# ---- windows -------------------------------------------------------------------

def cmd_windows(args) -> int:
    for w in aero.list_windows(args.workspace):
        print(f"{w.id:<8} {w.workspace:<12} {w.app:<22} {w.title}")
    return 0


# ---- save ----------------------------------------------------------------------

def build_config(name: str, workspace: str, wins: List[aero.Window],
                 chrome_wins: List[chrome.ChromeWindow], profiles: Dict[str, str]) -> dict:
    chrome_titles = [w.title for w in wins if w.bundle_id == chrome.BUNDLE_ID]
    matches = chrome.match_windows(chrome_titles, chrome_wins)
    entries = []
    ci = 0
    for w in wins:
        if w.bundle_id == chrome.BUNDLE_ID:
            m = matches[ci]
            ci += 1
            if m is None:
                warn(f"Chrome window '{w.title}': couldn't find its tabs; urls left empty")
                urls = []
            else:
                urls = chrome_wins[m][1]
            profile = chrome.detect_profile(w.title, profiles)
            if profile is None:
                warn(f"Chrome window '{w.title}': profile unknown; set \"profile\" by hand "
                     f"(known: {', '.join(f'{k} = {v}' for k, v in profiles.items()) or 'none'})")
            entries.append({
                "type": "chrome",
                "profile": profile,
                "profile_name": profiles.get(profile) if profile else None,
                "urls": urls,
            })
        else:
            entry = {
                "type": "app",
                "app": w.app,
                "bundle_id": w.bundle_id,
                "launch": ["open", "-b", w.bundle_id] if w.bundle_id else ["open", "-a", w.app],
                "reuse_existing": True,
            }
            if w.title:
                entry["title_match"] = "^" + re.escape(w.title) + "$"
            entries.append(entry)
    return {"name": name, "workspace": workspace, "layout": "h_tiles", "windows": entries}


def cmd_save(args) -> int:
    workspace = args.workspace or aero.focused_workspace()
    wins = aero.list_windows(workspace)
    if not wins:
        print(f"workspace '{workspace}' has no windows; nothing to save", file=sys.stderr)
        return 1
    chrome_wins: List[chrome.ChromeWindow] = []
    profiles: Dict[str, str] = {}
    if any(w.bundle_id == chrome.BUNDLE_ID for w in wins):
        chrome_wins = chrome.capture_windows()
        profiles = chrome.load_profiles()
    cfg = build_config(args.name, workspace, wins, chrome_wins, profiles)
    path = config.save_config(cfg, force=args.force)
    config.save_state(args.name, {"windows": [{"id": w.id, "index": i} for i, w in enumerate(wins)]})
    print(f"saved {len(wins)} window(s) from workspace '{workspace}' to {path}")
    return 0


# ---- open ----------------------------------------------------------------------

def _launch_cmd(entry: dict) -> List[str]:
    if entry["type"] == "chrome":
        return chrome.launch_command(entry.get("profile"), entry.get("urls", []))
    cmd = entry.get("launch") or ["open", "-b", entry["bundle_id"]]
    return [os.path.expanduser(a) for a in cmd]


def _belongs(w: aero.Window, entry: dict) -> bool:
    if entry["type"] == "chrome":
        return w.bundle_id == chrome.BUNDLE_ID
    if entry.get("bundle_id"):
        return w.bundle_id == entry["bundle_id"]
    return w.app == entry.get("app")


def _find_existing(entry: dict, wins: List[aero.Window], taken: Set[int]) -> Optional[aero.Window]:
    pattern = entry.get("title_match")
    for w in wins:
        if w.id in taken or not _belongs(w, entry):
            continue
        if pattern and not re.search(pattern, w.title):
            continue
        return w
    return None


def _launch_and_wait(entry: dict) -> Optional[int]:
    before = _live_ids(aero.list_windows())
    cmd = _launch_cmd(entry)
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as e:
        warn(f"launch failed ({shlex.join(cmd)}): {getattr(e, 'stderr', '') or e}")
        return None
    deadline = time.monotonic() + _launch_timeout()
    while True:
        new = [w for w in aero.list_windows() if w.id not in before and _belongs(w, entry)]
        if new:
            if len(new) > 1:
                time.sleep(_poll_interval())  # let siblings (session restore) settle for the warning
                extra = [w for w in aero.list_windows() if w.id not in before and _belongs(w, entry)]
                warn(f"{len(extra)} new {new[0].app} windows appeared; using the first "
                     f"({', '.join(str(w.id) for w in extra[1:])} left alone)")
            return new[0].id
        if time.monotonic() >= deadline:
            warn(f"no new window appeared within {_launch_timeout():g}s for: {shlex.join(cmd)}")
            return None
        time.sleep(_poll_interval())


def _describe(entry: dict) -> str:
    if entry["type"] == "chrome":
        return f"Chrome ({entry.get('profile_name') or entry.get('profile') or 'default profile'})"
    return entry.get("app") or entry.get("bundle_id")


def _arrange(cfg: dict, placed: Dict[int, int]) -> None:
    ws = cfg["workspace"]
    order = [placed[i] for i in sorted(placed)]
    if not order:
        return
    aero.flatten(ws)
    aero.layout(order[0], cfg["layout"])
    direction = JOIN_DIR[cfg["layout"]]
    for i in sorted(placed):
        if i > 0 and cfg["windows"][i].get("stack"):
            aero.join_with(placed[i], direction)
    aero.balance(ws)
    aero.focus(order[0])


def cmd_open(args) -> int:
    cfg = config.load_config(args.name)
    ws = cfg["workspace"]
    wins = aero.list_windows()
    live = _live_ids(wins)
    state = config.prune_state(config.load_state(args.name), live)

    if state["windows"] and not args.fresh:
        config.save_state(args.name, state)
        aero.switch_workspace(ws)
        print(f"'{args.name}' is already open; switched to workspace '{ws}'")
        return 0

    placed: Dict[int, int] = {e["index"]: e["id"] for e in state["windows"]}
    taken = _claimed_by_others(args.name, live) | set(placed.values())
    aero.switch_workspace(ws)
    failures = 0

    for i, entry in enumerate(cfg["windows"]):
        if i in placed:
            continue
        reuse = entry.get("reuse_existing", entry["type"] == "app")
        wid = None
        if reuse:
            found = _find_existing(entry, aero.list_windows(), taken)
            if found:
                wid = found.id
                print(f"  reusing {_describe(entry)}: {found.title}")
        if wid is None:
            prior = [placed[j] for j in sorted(placed) if j < i]
            if prior:
                aero.focus(prior[-1])  # new windows land next to the focused one
            print(f"  launching {_describe(entry)}")
            wid = _launch_and_wait(entry)
        if wid is None:
            failures += 1
            continue
        aero.move_to_workspace(wid, ws)
        placed[i] = wid
        taken.add(wid)
        config.save_state(args.name, {"windows": [{"id": v, "index": k} for k, v in sorted(placed.items())]})

    _arrange(cfg, placed)
    aero.switch_workspace(ws)
    print(f"opened '{args.name}' on workspace '{ws}': {len(placed)}/{len(cfg['windows'])} window(s)")
    return 1 if failures else 0


# ---- close ---------------------------------------------------------------------

def cmd_close(args) -> int:
    cfg = config.load_config(args.name)
    state = config.prune_state(config.load_state(args.name), _live_ids(aero.list_windows()))
    closed = kept = 0
    for e in state["windows"]:
        idx = e.get("index")
        entry = cfg["windows"][idx] if isinstance(idx, int) and idx < len(cfg["windows"]) else {}
        if entry.get("keep_on_close"):
            kept += 1
            continue
        try:
            aero.close(e["id"])
            closed += 1
        except aero.AeroError as err:
            warn(str(err))
    config.clear_state(args.name)
    print(f"closed {closed} window(s) of '{args.name}'" + (f", kept {kept}" if kept else ""))
    return 0


# ---- list / edit -----------------------------------------------------------------

def cmd_list(args) -> int:
    names = config.list_names()
    if not names:
        print(f"no desktops saved in {config.home()}")
        return 0
    live = _live_ids(aero.list_windows())
    for name in names:
        try:
            cfg = config.load_config(name)
        except config.ConfigError as e:
            print(f"{name:<14} INVALID  {str(e).splitlines()[-1].strip()}")
            continue
        state = config.prune_state(config.load_state(name), live)
        status = "open" if state["windows"] else "closed"
        print(f"{name:<14} {status:<7} workspace={cfg['workspace']:<12} windows={len(cfg['windows'])}")
    return 0


def cmd_edit(args) -> int:
    path = config.config_path(args.name)
    if not os.path.exists(path):
        print(f"no desktop named '{args.name}' ({path})", file=sys.stderr)
        return 1
    editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
    subprocess.call(shlex.split(editor) + [path])
    try:
        config.load_config(args.name)
    except config.ConfigError as e:
        print(f"config is invalid:\n{e}", file=sys.stderr)
        return 1
    print("config OK")
    return 0


# ---- entry point -----------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="desktop", description="Save, open and close named desktops on AeroSpace.")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("save", help="save the windows on a workspace as a desktop")
    s.add_argument("name")
    s.add_argument("--workspace", help="workspace to save (default: focused)")
    s.add_argument("--force", action="store_true", help="overwrite an existing desktop")
    s.set_defaults(func=cmd_save)

    s = sub.add_parser("open", help="open (or switch to) a desktop")
    s.add_argument("name")
    s.add_argument("--fresh", action="store_true",
                   help="even if partly open, launch any of its windows that are missing")
    s.set_defaults(func=cmd_open)

    s = sub.add_parser("close", help="close the windows a desktop opened")
    s.add_argument("name")
    s.set_defaults(func=cmd_close)

    s = sub.add_parser("list", help="list desktops and whether they are open")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("edit", help="edit a desktop config in $EDITOR")
    s.add_argument("name")
    s.set_defaults(func=cmd_edit)

    s = sub.add_parser("windows", help="debug: list AeroSpace windows")
    s.add_argument("--workspace")
    s.set_defaults(func=cmd_windows)
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (config.ConfigError, aero.AeroError, RuntimeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
