# Desktops for macOS — v1 Build Outline

Nov 23, 2026 · @rob

## Goal and requirements

Build a small local tool, `desktop`, that saves named desktops and opens or closes them on demand. Each desktop is a set of specific windows in a tiled arrangement. v1 replaces the manual Spencer workflow; it does not replace Spencer's pixel-exact restore.

**Must have (v1)**

- Define multiple named desktops (for example `dev`, `research`, `comms`). Each holds one or more app windows.
- **Save** the desktop I'm looking at right now into a config file I can also edit by hand.
- **Open** a desktop: launch whatever is missing, put each window on that desktop, apply the tiled layout, switch to it.
- **Close** a desktop: close only the windows that desktop opened, leaving other desktops alone.
- **Per-window, not per-app.** The same app (Chrome especially) can appear on several desktops, and each desktop gets its own window.
- **Chrome profiles.** Each Chrome window opens in the right profile with the right tabs. I already keep separate Chrome profiles per desktop.
- Tiled layouts are fine. Exact pixel positions are not needed in v1.
- Everything local: no cloud, no accounts, config in plain files.

**Nice to have (v1 if cheap)**

- `list` showing each desktop and whether it is open.
- Hotkeys to open or switch desktops.
- Opening a desktop that is already open just switches to it, with no duplicate windows.

**Out of scope for v1**

- Pixel-exact window positions (possible v2 via Hammerspoon floating windows).
- Restoring app state Chrome or the app doesn't restore itself (unsaved files, terminal history).
- A GUI. v1 is a CLI plus hotkeys.

## Recommended tools

Use AeroSpace as the window manager and build a thin `desktop` CLI on top of it. AeroSpace already handles workspaces, per-window moves and tiling; the CLI adds saving, launching and closing.

| Tool | Role | Why |
| --- | --- | --- |
| [AeroSpace](https://github.com/nikitabobko/AeroSpace) | Window manager: named workspaces, tiling, per-window moves | Works by window ID, has a full CLI with JSON output, no SIP changes needed, plain-text config |
| `desktop` CLI (to build) | Save, open, close, list desktops | The piece AeroSpace lacks: launching apps and remembering what belongs where |
| Python 3, standard library only | Language for the CLI | Ships with Xcode Command Line Tools; JSON and subprocess built in; no installs. Target Python 3.9 (the Command Line Tools version) |
| Chrome command-line flags | Open a window in a given profile with given URLs | `open -na "Google Chrome" --args --profile-directory="Profile 2" --new-window <urls>` |
| AppleScript via `osascript` | Read each Chrome window's tab URLs when saving | Chrome's scripting dictionary exposes windows and tab URLs |
| Chrome `Local State` file | Map profile folder names (`Profile 2`) to display names (`Work`) | JSON at `~/Library/Application Support/Google/Chrome/Local State`, key `profile.info_cache` |

**Considered and ruled out**

- **Modifying Spencer:** closed source, paid, and no scripting interface.
- **FlashSpace:** assigns whole apps to workspaces, not individual windows, and doesn't save layouts. It can't keep three Chrome windows on three desktops.
- **yabai:** uses real macOS Spaces but needs SIP partly disabled for the Spaces features. More fragile than AeroSpace across macOS updates.
- **Hammerspoon:** keep as the v2 option if pixel-exact positions become necessary.

**One trade-off to accept:** AeroSpace uses its own virtual workspaces instead of macOS Spaces. Windows on inactive workspaces are parked off-screen, and Mission Control stops being the way you switch. Use one macOS Space per display once AeroSpace is running.

## Architecture

The CLI is the only new piece. It keeps desktop definitions and runtime state in plain files, launches windows, and tells AeroSpace where each one goes by window ID.

&#91;embedded content: architecture · CLI on top of AeroSpace\]

AeroSpace sees every new window; the CLI finds the new one by diffing window IDs before and after a launch, then moves and arranges it.

## Desktop config format

One JSON file per desktop in `~/.desktops/<name>.json`. `desktop save` writes it; you can edit it by hand. JSON (not TOML) because Python 3.9 has no built-in TOML reader.

```json
{
  "name": "dev",
  "workspace": "dev",
  "layout": "h_tiles",
  "hotkey": "alt-d",
  "windows": [
    {
      "type": "chrome",
      "profile": "Profile 2",
      "profile_name": "Work",
      "urls": ["https://github.com", "http://localhost:3000"]
    },
    {
      "type": "app",
      "app": "Visual Studio Code",
      "bundle_id": "com.microsoft.VSCode",
      "launch": ["open", "-a", "Visual Studio Code", "~/code/myproject"],
      "title_match": "myproject",
      "reuse_existing": true
    },
    {
      "type": "app",
      "app": "iTerm2",
      "bundle_id": "com.googlecode.iterm2",
      "stack": true,
      "keep_on_close": false
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `workspace` | AeroSpace workspace name the desktop lives on. Usually the same as `name` |
| `layout` | Root layout: `h_tiles`, `v_tiles`, `h_accordion` or `v_accordion` |
| `hotkey` | Optional; used when generating AeroSpace bindings |
| `windows[]` | Windows in order, left to right (or top to bottom) |
| `type` | `chrome` (opened by profile + URLs) or `app` (any other app) |
| `profile` | Chrome profile folder name; `profile_name` is the display name, for readability |
| `urls` | Tabs to open in that Chrome window |
| `launch` | Command that opens the window. Default: `open -b <bundle_id>` |
| `title_match` | Regex on the window title, used to find an existing window to reuse |
| `reuse_existing` | Use an open matching window instead of launching a new one. Default `true` for apps, `false` for Chrome |
| `stack` | Stack this window with the previous one (a column inside the row) |
| `keep_on_close` | Leave this window open when the desktop closes (for example a shared Slack) |

Runtime state lives separately in `~/.desktops/.state/<name>.json`: the AeroSpace window IDs this desktop opened or claimed. It is never hand-edited.

## Commands to build

Six commands. `save`, `open` and `close` are the core; the rest are small.

### `desktop save <name> [--workspace W] [--force]`

Captures the windows on the focused (or given) AeroSpace workspace into `~/.desktops/<name>.json`.

1. Read all windows with `aerospace list-windows --all --json` and keep those on the workspace, in the order AeroSpace returns them.
2. For Chrome windows: run an AppleScript that returns each Chrome window's title and tab URLs. Match each AeroSpace window to a Chrome window by title.
3. Work out each Chrome window's profile: read display names from Chrome's `Local State` file and match the one the window title ends with. If none matches, write `"profile": null` and print a warning to fill it in by hand.
4. For other apps: record app name, bundle ID and window title. Write `title_match` as the escaped title and a default `launch` command.
5. Write the JSON. Refuse to overwrite an existing desktop without `--force`.
6. Record the current window IDs as this desktop's state, so an immediate `close` works.

### `desktop open <name> [--fresh]`

1. Load the config and the state. If the desktop's recorded windows still exist, just switch to its workspace and stop (unless `--fresh`).
2. Switch to the workspace (`aerospace workspace <W>`), so new windows land there.
3. For each window in order:
   1. If `reuse_existing`, look for an open window with the same bundle ID and a title matching `title_match` that no other open desktop has claimed.
   2. Otherwise, snapshot all window IDs, run the launch command, then poll `list-windows` (every 250 ms, up to 20 s) for a new window from that app.
   3. Move it: `aerospace move-node-to-workspace --window-id <id> <W>`.
   4. Add the ID to this desktop's state.
4. Arrange: `flatten-workspace-tree`, focus the first window, apply `layout <layout>`, then for each `stack: true` window focus it and `join-with left`. Finish with `balance-sizes`.
5. Save state and focus the workspace.

### `desktop close <name>`

1. Load state. For each recorded window ID still open and not marked `keep_on_close`, close it (`aerospace close --window-id <id>`; fall back to focus then `close` on older AeroSpace versions).
2. Clear the state file.

### `desktop list`

One line per config: name, workspace, window count, and `open` / `closed` (open = at least one recorded window still exists).

### `desktop edit <name>`

Opens the config in `$EDITOR`, then validates the JSON on save.

### `desktop windows [--workspace W]`

Debug view: prints AeroSpace window ID, app, workspace and title. Used to write `title_match` rules and to troubleshoot.

## Implementation details and gotchas

Most of the risk is in finding the right window after a launch and in AeroSpace CLI details that vary by version. Verify each item below against the installed AeroSpace before relying on it.

- **Check AeroSpace flags first.** Confirm on the installed version: `list-windows --json` with `--format`, and `--window-id` on `move-node-to-workspace`, `focus`, `close` and `layout`. Write a thin wrapper that falls back to "focus the window, then run the command" when `--window-id` isn't supported.
- **Parsing `list-windows`.** Prefer `--json`. Keep a fallback that uses a pipe-delimited `--format` with the window title as the last field, since titles can contain pipes.
- **Finding the new window.** Diff window IDs before and after launch, filtered by bundle ID. Cold-starting Chrome may restore its previous session and open several windows at once: take the first new one, and warn about the extras. Consider launching Chrome with `--no-restore-last-session`, or turning off "Continue where you left off".
- **Chrome title matching.** Chrome's AppleScript window name and AeroSpace's window title may differ (one may carry a "- Google Chrome - \<profile>" suffix). Match on exact title, then on either one being a prefix of the other. Test on the real machine and log both strings.
- **Profile detection is best effort.** If the title carries no profile name, fall back to: only one profile, use it; otherwise `null` plus a warning. The config is meant to be hand-fixed once.
- **AeroSpace rules apply only to new windows.** `on-window-detected` rules don't touch windows that already exist. The CLI moves windows by ID instead of depending on those rules.
- **Window order.** New windows are inserted next to the focused window. Focus the last placed window before each launch so windows land in config order. Treat order as best effort in v1.
- **Shared windows.** A window recorded in one open desktop's state is "claimed". `reuse_existing` must skip claimed windows, so two desktops never fight over one window.
- **Stale state.** Window IDs die when windows close. Every command drops state IDs that no longer appear in `list-windows`.
- **macOS permissions.** The terminal (or AeroSpace, when run from a hotkey) needs Automation permission to control Chrome; the first `save` triggers the prompt. AeroSpace itself needs Accessibility.
- **Hotkey PATH.** AeroSpace's `exec-and-forget` runs with a minimal PATH. Bind hotkeys to the absolute path of the script, and have the script find `aerospace` at `/opt/homebrew/bin` or `/usr/local/bin`.
- **No `rm` of configs from `close`.** `close` touches state only, never the desktop's config.

## Machine setup

The Mac needs AeroSpace installed and running before any of the CLI is useful. Quit Spencer while testing so the two don't move windows against each other.

1. Install AeroSpace: `brew install --cask nikitabobko/tap/aerospace`. Grant Accessibility when asked.
2. Reduce to one macOS Space per display (Mission Control). AeroSpace workspaces replace Spaces.
3. Confirm `python3 --version` reports 3.9 or later (install Xcode Command Line Tools if missing).
4. Put the script at `~/.local/bin/desktop`, `chmod +x`, and add `~/.local/bin` to PATH.
5. Add AeroSpace bindings in `~/.aerospace.toml`, then `aerospace reload-config`:

```toml
[mode.main.binding]
# switch between desktops
alt-d = 'workspace dev'
alt-r = 'workspace research'
alt-c = 'workspace comms'

# open (launch + arrange) a saved desktop
alt-shift-d = 'exec-and-forget /Users/<you>/.local/bin/desktop open dev'
alt-shift-r = 'exec-and-forget /Users/<you>/.local/bin/desktop open research'

# usual window moves, for tweaking a layout before re-saving
alt-h = 'focus left'
alt-l = 'focus right'
alt-shift-h = 'move left'
alt-shift-l = 'move right'
alt-slash = 'layout tiles horizontal vertical'
```

6. Migrate from Spencer: for each Spencer desktop, move its windows onto one AeroSpace workspace, run `desktop save <name>`, then check the generated JSON (especially Chrome `profile`).

## Build plan

Build in five steps, each usable on its own, and test on the real Mac after each one. A fake `aerospace` / `osascript` / `open` set on PATH lets the logic be unit-tested without touching real windows.

1. **Spike (1–2 hours):** install AeroSpace, and by hand confirm the CLI flags listed under gotchas, the `list-windows --json` shape, and what Chrome window titles look like in AeroSpace versus AppleScript. Write the findings into the repo README. Everything after depends on this.
2. **Wrapper + `windows`:** an `aerospace` wrapper module (run, parse windows, move/focus/close by ID with fallbacks) and the `desktop windows` debug command.
3. **`save`:** Chrome tab capture, profile detection, config writing. Done when saving a real workspace produces a config that needs no hand edits, or a clear warning where it does.
4. **`open` and `close`:** launch, detect, move, arrange, state tracking, the already-open check. Done when `close dev && open dev` gives back the same windows in the same arrangement.
5. **Polish:** `list`, `edit`, hotkey bindings, a README with setup steps.

**Suggested repo layout**

```
desktops/
  desktop               # entry point (python3 script)
  desktops/
    aero.py             # AeroSpace wrapper
    chrome.py           # AppleScript tab capture, Local State profiles, launch
    config.py           # load/validate/save configs and state
    commands.py         # save, open, close, list, edit, windows
  tests/
    fakes/              # fake aerospace, osascript, open on PATH
    test_*.py
  examples/aerospace.toml
  README.md
```

**Tests worth having:** parse `list-windows` output (JSON and fallback); diff-based new-window detection with a slow-launching fake; the claimed-window rule across two desktops; stale state IDs dropped; Chrome title matching with and without suffixes; a full save → close → open round trip against the fakes.

## Open questions and v2 ideas

**Open questions (answer during the spike)**

- [ ] Does the installed AeroSpace support `--window-id` on `close`, `focus` and `layout`?
- [ ] What do Chrome window titles look like in AeroSpace on this Mac: is the profile name in them?
- [ ] Which non-Chrome apps go on each desktop, and do they open one window per launch (VS Code, iTerm) or reuse a single window (Slack, Mail)?
- [ ] Multiple displays: should a desktop pin to a specific monitor? (AeroSpace can assign workspaces to monitors in its config.)

**v2 ideas**

- Save and restore the full tiling tree (nested splits), not just order plus stacks.
- Pixel-exact positions for chosen windows, via floating windows placed by Hammerspoon.
- Save new tabs back automatically on `close`, so a Chrome window reopens with what you last had.
- A menu bar list of desktops with open/closed status (SketchyBar or a small SwiftUI app).
- Per-desktop hooks: run a command on open or close (start a dev server, `docker compose up`).

## Session handoff — status as of Nov 23, 2026

The outline has been reviewed and is ready to build from. No code has been written yet.

**Machine check**

- Python: 3.9.6 at `/usr/bin/python3`, which matches the target.
- Google Chrome: installed.
- Spencer: installed. Quit it before testing so it doesn't move windows against AeroSpace.
- **AeroSpace: not installed.** `aerospace` isn't on PATH. This blocks the spike (build step 1).
- Project folder: contains only this outline. It isn't a git repo yet.

**Next steps**

1. **Rob:** install AeroSpace (`brew install --cask nikitabobko/tap/aerospace`), launch it, grant Accessibility, and reduce to one macOS Space per display. The permission grants have to be done by hand.
2. **Spike (build step 1):** check the installed AeroSpace's flags: `--window-id` on `close`, `focus`, `layout` and `move-node-to-workspace`, and `list-windows --json` versus `--format`. Record the `list-windows` JSON shape and compare Chrome window titles in AeroSpace with the AppleScript window names (is the profile name in them?). Write the findings into `README.md`.
3. **Can start before the spike:** `git init`, create the repo layout from "Suggested repo layout", and write the fake `aerospace`, `osascript` and `open` scripts in `tests/fakes/`. The fakes' output format must be confirmed against the spike findings.

**Open decision:** should Claude run the brew install of AeroSpace, or will Rob do it?
