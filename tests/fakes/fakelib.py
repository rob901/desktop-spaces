"""Shared state for the fake aerospace / osascript / open commands.

State lives in the JSON file named by $FAKE_STATE:
{
  "focused": "1",                      # focused workspace
  "next_id": 100,
  "windows": [{"id", "app", "bundle", "ws", "title", "chrome_title"?, "urls"?}],
  "pending": [ same + "at": epoch seconds ],   # windows that appear later
  "launch_delay": 0.0,                 # seconds before a launched window appears
  "chrome_extra_windows": 0,           # extra windows a Chrome launch restores
  "profiles": {"Profile 1": "Personal"},
  "apps": {"com.x.Y": {"app": "Y", "title": "Y window"}},
  "log": [[argv...], ...]              # every aerospace call
}
"""
import json
import os
import time

PATH = os.environ["FAKE_STATE"]


def load():
    with open(PATH) as f:
        st = json.load(f)
    now = time.time()
    ready = [p for p in st.get("pending", []) if p["at"] <= now]
    if ready:
        st["pending"] = [p for p in st["pending"] if p["at"] > now]
        for p in ready:
            p.pop("at")
            st["windows"].append(p)
        save(st)
    return st


def save(st):
    tmp = PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, PATH)


def add_window(st, **w):
    w["id"] = st["next_id"]
    st["next_id"] += 1
    w.setdefault("ws", st["focused"])
    w["at"] = time.time() + st.get("launch_delay", 0)
    st.setdefault("pending", []).append(w)
    return w
