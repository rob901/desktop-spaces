"""Thin wrapper around the AeroSpace CLI."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional

FIELDS = ["window-id", "app-name", "app-bundle-id", "workspace", "window-title"]
JSON_FORMAT = " ".join("%{" + f + "}" for f in FIELDS)
# Title is last because titles can contain the separator.
PIPE_FORMAT = "|".join("%{" + f + "}" for f in FIELDS)

SEARCH_PATHS = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]


class AeroError(RuntimeError):
    pass


@dataclass
class Window:
    id: int
    app: str
    bundle_id: str
    workspace: str
    title: str


def find_aerospace() -> str:
    override = os.environ.get("DESKTOP_AEROSPACE")
    if override:
        return override
    found = shutil.which("aerospace")
    if found:
        return found
    for path in SEARCH_PATHS:
        if os.access(path, os.X_OK):
            return path
    raise AeroError("aerospace not found on PATH, /opt/homebrew/bin or /usr/local/bin")


def run(*args: str) -> str:
    proc = subprocess.run([find_aerospace(), *args], capture_output=True, text=True)
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout).strip()
        raise AeroError(f"aerospace {' '.join(args)} failed: {msg}")
    return proc.stdout


# ---- parsing (pure, unit-tested) -------------------------------------------

def _get(d: dict, key: str, default=""):
    for k in (key, key.replace("-", "_")):
        if k in d:
            return d[k]
    return default


def parse_windows_json(text: str) -> List[Window]:
    data = json.loads(text or "[]")
    out = []
    for d in data:
        out.append(Window(
            id=int(_get(d, "window-id")),
            app=str(_get(d, "app-name")),
            bundle_id=str(_get(d, "app-bundle-id")),
            workspace=str(_get(d, "workspace")),
            title=str(_get(d, "window-title")),
        ))
    return out


def parse_windows_format(text: str) -> List[Window]:
    out = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("|", len(FIELDS) - 1)
        if len(parts) != len(FIELDS):
            continue
        wid, app, bundle, ws, title = parts
        out.append(Window(int(wid), app, bundle, ws, title))
    return out


# ---- queries -----------------------------------------------------------------

def list_windows(workspace: Optional[str] = None) -> List[Window]:
    try:
        wins = parse_windows_json(run("list-windows", "--all", "--json", "--format", JSON_FORMAT))
    except (AeroError, ValueError, TypeError):
        wins = parse_windows_format(run("list-windows", "--all", "--format", PIPE_FORMAT))
    if workspace is not None:
        wins = [w for w in wins if w.workspace == workspace]
    return wins


def focused_workspace() -> str:
    return run("list-workspaces", "--focused").strip()


# ---- actions -------------------------------------------------------------------

def _by_id(cmd: str, window_id: int, *rest: str) -> None:
    """Run `cmd --window-id ID rest`, falling back to focus-then-cmd."""
    try:
        run(cmd, "--window-id", str(window_id), *rest)
    except AeroError as e:
        if "window-id" not in str(e):
            raise
        run("focus", "--window-id", str(window_id))
        run(cmd, *rest)


def switch_workspace(name: str) -> None:
    run("workspace", name)


def move_to_workspace(window_id: int, workspace: str) -> None:
    _by_id("move-node-to-workspace", window_id, workspace)


def focus(window_id: int) -> None:
    run("focus", "--window-id", str(window_id))


def close(window_id: int) -> None:
    _by_id("close", window_id)


def layout(window_id: int, name: str) -> None:
    _by_id("layout", window_id, name)


def join_with(window_id: int, direction: str) -> None:
    _by_id("join-with", window_id, direction)


def flatten(workspace: str) -> None:
    run("flatten-workspace-tree", "--workspace", workspace)


def balance(workspace: str) -> None:
    run("balance-sizes", "--workspace", workspace)
