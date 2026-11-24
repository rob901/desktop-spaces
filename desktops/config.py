"""Desktop configs (~/.desktops/<name>.json) and runtime state (~/.desktops/.state/)."""
from __future__ import annotations

import json
import os
import re
from typing import Iterable, List

LAYOUTS = ("h_tiles", "v_tiles", "h_accordion", "v_accordion")
TYPES = ("chrome", "app")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


class ConfigError(ValueError):
    pass


def home() -> str:
    return os.path.expanduser(os.environ.get("DESKTOPS_HOME", "~/.desktops"))


def config_path(name: str) -> str:
    return os.path.join(home(), f"{name}.json")


def state_path(name: str) -> str:
    return os.path.join(home(), ".state", f"{name}.json")


def _write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


# ---- configs -------------------------------------------------------------------

def validate(cfg) -> List[str]:
    errs = []
    if not isinstance(cfg, dict):
        return ["config must be a JSON object"]
    name = cfg.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        errs.append("name: required; letters, digits, '.', '_' or '-'")
    if "workspace" in cfg and not isinstance(cfg["workspace"], str):
        errs.append("workspace: must be a string")
    if cfg.get("layout", "h_tiles") not in LAYOUTS:
        errs.append(f"layout: must be one of {', '.join(LAYOUTS)}")
    wins = cfg.get("windows")
    if not isinstance(wins, list):
        return errs + ["windows: must be a list"]
    for i, w in enumerate(wins):
        p = f"windows[{i}]"
        if not isinstance(w, dict):
            errs.append(f"{p}: must be an object")
            continue
        t = w.get("type")
        if t not in TYPES:
            errs.append(f"{p}.type: must be 'chrome' or 'app'")
        elif t == "chrome":
            if not isinstance(w.get("urls", []), list):
                errs.append(f"{p}.urls: must be a list")
        elif t == "app":
            if not (w.get("bundle_id") or w.get("app")):
                errs.append(f"{p}: needs bundle_id or app")
            if not (w.get("launch") or w.get("bundle_id")):
                errs.append(f"{p}: needs launch or bundle_id")
        if "launch" in w and not (isinstance(w["launch"], list) and w["launch"]):
            errs.append(f"{p}.launch: must be a non-empty list of strings")
        if w.get("title_match"):
            try:
                re.compile(w["title_match"])
            except re.error as e:
                errs.append(f"{p}.title_match: bad regex ({e})")
    return errs


def load_config(name: str) -> dict:
    path = config_path(name)
    try:
        with open(path) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        raise ConfigError(f"no desktop named '{name}' ({path})")
    except ValueError as e:
        raise ConfigError(f"{path}: invalid JSON: {e}")
    errs = validate(cfg)
    if errs:
        raise ConfigError(f"{path}:\n  " + "\n  ".join(errs))
    cfg.setdefault("workspace", cfg["name"])
    cfg.setdefault("layout", "h_tiles")
    return cfg


def save_config(cfg: dict, force: bool = False) -> str:
    path = config_path(cfg["name"])
    if os.path.exists(path) and not force:
        raise ConfigError(f"desktop '{cfg['name']}' already exists; use --force to overwrite")
    _write_json(path, cfg)
    return path


def list_names() -> List[str]:
    try:
        files = os.listdir(home())
    except FileNotFoundError:
        return []
    return sorted(f[:-5] for f in files if f.endswith(".json") and not f.startswith("."))


# ---- state ---------------------------------------------------------------------
# {"windows": [{"id": 123, "index": 0}, ...]}  index = position in config windows[]

def load_state(name: str) -> dict:
    try:
        with open(state_path(name)) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    state.setdefault("windows", [])
    return state


def save_state(name: str, state: dict) -> None:
    _write_json(state_path(name), state)


def clear_state(name: str) -> None:
    try:
        os.remove(state_path(name))
    except FileNotFoundError:
        pass


def prune_state(state: dict, live_ids: Iterable[int]) -> dict:
    live = set(live_ids)
    state["windows"] = [e for e in state["windows"] if e.get("id") in live]
    return state
