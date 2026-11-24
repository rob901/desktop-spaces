"""Chrome helpers: tab capture via AppleScript, profile names, launch command."""
from __future__ import annotations

import json
import os
import subprocess
from typing import Dict, List, Optional, Sequence, Tuple

BUNDLE_ID = "com.google.Chrome"
LOCAL_STATE = "~/Library/Application Support/Google/Chrome/Local State"

RS = "\x1e"  # between windows
US = "\x1f"  # between title and each URL

CAPTURE_SCRIPT = """
if application "Google Chrome" is running then
  tell application "Google Chrome"
    set RS to (ASCII character 30)
    set US to (ASCII character 31)
    set out to ""
    repeat with w in windows
      set out to out & (name of w)
      repeat with t in tabs of w
        set out to out & US & (URL of t)
      end repeat
      set out to out & RS
    end repeat
    return out
  end tell
end if
return ""
"""

ChromeWindow = Tuple[str, List[str]]  # (title, urls)


def parse_capture(text: str) -> List[ChromeWindow]:
    out = []
    for chunk in text.rstrip("\n").split(RS):
        if not chunk:
            continue
        parts = chunk.split(US)
        out.append((parts[0], [u for u in parts[1:] if u]))
    return out


def capture_windows() -> List[ChromeWindow]:
    proc = subprocess.run(["osascript", "-e", CAPTURE_SCRIPT], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Chrome tab capture failed: {proc.stderr.strip()}")
    return parse_capture(proc.stdout)


def load_profiles(path: Optional[str] = None) -> Dict[str, str]:
    """Map profile folder ("Profile 2") -> display name ("Work")."""
    path = os.path.expanduser(path or os.environ.get("DESKTOP_CHROME_LOCAL_STATE", LOCAL_STATE))
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    cache = data.get("profile", {}).get("info_cache", {})
    return {folder: info.get("name", folder) for folder, info in cache.items()}


def titles_match(a: str, b: str) -> bool:
    return a == b or a.startswith(b) or b.startswith(a)


def match_windows(aero_titles: Sequence[str], chrome: Sequence[ChromeWindow]) -> List[Optional[int]]:
    """For each AeroSpace title, the index of its Chrome window (each used once).

    Exact matches are assigned first, then prefix matches.
    """
    result: List[Optional[int]] = [None] * len(aero_titles)
    used = set()
    for exact in (True, False):
        for i, at in enumerate(aero_titles):
            if result[i] is not None:
                continue
            for j, (ct, _) in enumerate(chrome):
                if j in used:
                    continue
                if (at == ct) if exact else titles_match(at, ct):
                    result[i] = j
                    used.add(j)
                    break
    return result


def detect_profile(title: str, profiles: Dict[str, str]) -> Optional[str]:
    """Best effort: the profile whose display name ends the window title."""
    hits = [folder for folder, name in profiles.items()
            if name and (title.endswith(" - " + name) or title.endswith(" — " + name))]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:  # prefer the longest display name ("Work 2" over "2")
        return max(hits, key=lambda f: len(profiles[f]))
    if len(profiles) == 1:
        return next(iter(profiles))
    return None


def launch_command(profile: Optional[str], urls: Sequence[str]) -> List[str]:
    cmd = ["open", "-na", "Google Chrome", "--args"]
    if profile:
        cmd.append(f"--profile-directory={profile}")
    cmd += ["--new-window", "--no-restore-last-session", *urls]
    return cmd
