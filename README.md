# Desktops

A small macOS menu bar tool that saves the windows on a desktop (a Mission Control space) and reopens them later on another desktop, at the same sizes and positions. Closing a desktop closes its windows and quits any app that has nothing left open, to free up memory.

Built on [Hammerspoon](https://www.hammerspoon.org).

## How to use it

Everything is in the monitor icon in the menu bar:

- **Save current desktop…**: saves every window on the desktop you're looking at, with its app, size and position. Chrome windows also keep their profile and tabs.
- **A saved desktop's name**: opens it on the desktop you're on. The usual flow is: swipe up, add a desktop, then pick a saved desktop from the menu. If it's already open, the menu switches to it. A check mark means it's open.
- **Close ▸ name**: closes that desktop's windows, then quits apps that have no windows left on any desktop. Apps still open elsewhere keep running, and apps ask about unsaved work as usual. Then remove the empty desktop in Mission Control.
- **Preferences…**: rename (Edit), reorder (drag) and delete saved desktops. The menu follows this order.
- **Open desktops folder**: the saved configs, in `~/.desktops/`.

## Setup

1. `brew install --cask hammerspoon`
2. `./install.sh`: links `hammerspoon/desktops` into `~/.hammerspoon` and adds the loader to `~/.hammerspoon/init.lua`.
3. Open Hammerspoon. Grant it Accessibility (System Settings → Privacy & Security → Accessibility) and turn on "Launch Hammerspoon at login".
4. The first save with a Chrome window asks permission for Hammerspoon to control Chrome. Allow it.

Code changes take effect after Hammerspoon → Reload Config, or the menu's **Reload**.

## Files

| Path | What |
| --- | --- |
| `~/.desktops/<name>.json` | A saved desktop. Hand-editable (see below) |
| `~/.desktops/.state/<name>.json` | Window IDs the desktop currently has open. Don't edit |
| `~/.desktops/.settings.json` | Menu order |
| `hammerspoon/desktops/init.lua` | Menu, save, open, close |
| `hammerspoon/desktops/store.lua` | Config, state and settings files |
| `hammerspoon/desktops/chrome.lua` | Chrome tabs (AppleScript), profiles (`Local State`), launch arguments |
| `hammerspoon/desktops/prefs.lua` | Preferences window |

### Config format

```json
{
  "name": "dev",
  "saved": "2026-11-24 14:30",
  "windows": [
    { "type": "chrome", "profile": "Profile 1", "profile_name": "designalytics user",
      "urls": ["https://github.com"], "title": "GitHub",
      "frame": { "x": 0, "y": 38, "w": 960, "h": 1166 } },
    { "type": "app", "app": "Code", "bundle_id": "com.microsoft.VSCode", "title": "myproject",
      "frame": { "x": 960, "y": 38, "w": 960, "h": 1166 } }
  ]
}
```

Optional per-window fields you can add by hand:

- `"launch": ["code", "-n", "~/code/myproject"]`: the command that opens the window, instead of launching the app or choosing File → New Window.
- `"keep_running": true`: never quit this app when the desktop closes (Slack or Mail, say).

## How it works

- **Open:** new windows always appear on the desktop you're looking at, so the tool never has to move windows between desktops. That's the part macOS makes hard. For each saved window it launches the app (or asks a running app for a new window), waits for the new window to appear, and sets its frame. It places everything a second time after a second, because some apps resize themselves once loaded.
- **Close:** switches to the desktop if needed, closes the recorded windows, then quits apps with no windows left. To see windows on *other* desktops it asks the window server directly (CoreGraphics through JavaScript for Automation), because Hammerspoon's accessibility view only covers the current desktop. On a desktop that's showing, only visible windows count: some apps, such as Windows App, hide a closed window instead of destroying it. If it can't tell, it leaves the app running.
- **Chrome:** tabs come from AppleScript. The profile is read from the window title or the toolbar's profile button, matched against the names in Chrome's `Local State`. Give every profile a different name.

## Development notes

- The `hs` command-line tool can jam if a command runs AppleScript while the CLI waits on it. To test from a shell, queue the work instead: `hs -c 'hs.timer.doAfter(0.1, function() dofile("/tmp/probe.lua") end)'`, and have the probe write its results to a file.
- `Desktops for macOS — v1 Build Outline.md` is the original plan, which used AeroSpace. That approach was dropped: forced tiling and replacing Spaces didn't fit this workflow.
