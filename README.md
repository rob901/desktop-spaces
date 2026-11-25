# Desktops

A small macOS menu bar tool that saves the windows on a desktop (a Mission Control space) and reopens them later on another desktop, at the same sizes and positions. Closing a desktop closes its windows and quits any app that has nothing left open, to free up memory.

Built on [Hammerspoon](https://www.hammerspoon.org).

## How to use it

Everything is in the monitor icon in the menu bar:

- **Save current desktop…**: saves every window on the desktop you're looking at, with its app, size and position. Chrome windows record which profile they use, and each reopens as a new window in that profile. Tabs aren't saved.
- **A saved desktop's name**: opens it on the desktop you're on. The usual flow is: swipe up, add a desktop, then pick a saved desktop from the menu. If it's already open somewhere else, the menu switches to it. A check mark means it's open.
- **The saved desktop you're on** (✓ with an arrow): hover for
  - **Update Desktop Items**: re-saves the windows now on this desktop under the same name. It only works on the desktop where that saved desktop was opened. The previous version goes to `.backup/`. Hand-edited fields are kept for windows that are still there.
  - **Close**: see below.
- **Close ▸ name**: closes that desktop. Apps used only on this desktop are quit with their windows still open, so they keep their state (see "App state" below). Apps also open on another desktop just get this desktop's windows closed and keep running. Apps ask about unsaved work as usual. Then remove the empty desktop in Mission Control.
- **Preferences…**: a window with four pages:
  - **Saved Desktops**: drag to reorder the menu, Edit to rename, Delete.
  - **Keyboard Shortcuts**: click a desktop's box and press a shortcut (⌃ Control plus ⇧/⌥/⌘ and a letter, number or F-key). Pressing it jumps to that desktop if it's open, otherwise opens it on the current desktop. Combinations macOS or other apps use, and duplicates, are refused.
  - **Desktops Folder**: where everything is stored (default `~/.desktops`). Changing it moves everything to the new folder.
  - **About**: version and links.

## App state

When Close quits an app, the app saves what it had open, and opening the desktop again brings it back:

- Apps with their own session restore, like Sublime Text, VS Code, Zed, Slack and Chrome (if "On startup" is set to "Continue where you left off"), do this themselves.
- Other apps (Terminal tabs and folders, TextEdit, Preview, Office documents) use macOS Resume. Resume is off unless "Close windows when quitting an application" is turned off in System Settings, so the tool turns it on for each app in a saved desktop (`defaults write <bundle id> NSQuitAlwaysKeepsWindows -bool true`). Your system-wide setting isn't changed, but those apps also restore their windows when you quit them yourself. To undo it for one app: `defaults delete <bundle id> NSQuitAlwaysKeepsWindows`. Resume isn't turned on for apps that restore themselves (Sublime Text, VS Code, Zed, Chrome, and any Electron app such as Slack or Claude): it would put their windows back on the desktop they were on, and macOS doesn't allow moving them from there.

When the desktop is opened, windows an app restored are reused, matched by title (and by profile for Chrome), and moved to their saved positions. Restored windows that don't match a saved entry stay open and belong to the desktop.

A Resume app's window goes back to its old desktop if that desktop still exists, so remove a desktop in Mission Control after closing it. Open warns when a restored window lands on another desktop.

Limits: state is saved per app, not per window. An app that's also open on another desktop isn't quit, so this desktop's windows close without their state and come back as new windows. Running commands in Terminal don't come back, only the tabs and their folders.

## Setup

1. `brew install --cask hammerspoon`
2. `./install.sh`: links `hammerspoon/desktops` into `~/.hammerspoon` and adds the loader to `~/.hammerspoon/init.lua`.
3. Open Hammerspoon. Grant it Accessibility (System Settings → Privacy & Security → Accessibility) and turn on "Launch Hammerspoon at login".

Code changes take effect after Hammerspoon → Reload Config, or the menu's **Reload**.

## Files

Paths below assume the default folder; it can be moved in Preferences → Desktops Folder. The chosen location is kept in Hammerspoon's settings (`desktops.folder`).

| Path | What |
| --- | --- |
| `~/.desktops/<name>.json` | A saved desktop. Hand-editable (see below) |
| `~/.desktops/.state/<name>.json` | Window IDs the desktop currently has open. Don't edit |
| `~/.desktops/.settings.json` | Menu order and keyboard shortcuts |
| `~/.desktops/.backup/<name>.json` | The previous version, kept when a desktop is updated or replaced |
| `hammerspoon/desktops/init.lua` | Menu, save, open, close |
| `hammerspoon/desktops/store.lua` | Config, state and settings files |
| `hammerspoon/desktops/chrome.lua` | Chrome profiles (`Local State`), profile detection, launch arguments |
| `hammerspoon/desktops/prefs.lua` | Preferences window (sidebar pages, shortcut recorder) |

### Config format

```json
{
  "name": "dev",
  "saved": "2026-11-24 14:30",
  "windows": [
    { "type": "chrome", "profile": "Profile 1", "profile_name": "designalytics user", "title": "Inbox",
      "frame": { "x": 0, "y": 38, "w": 960, "h": 1166 } },
    { "type": "app", "app": "Code", "bundle_id": "com.microsoft.VSCode", "title": "myproject",
      "frame": { "x": 960, "y": 38, "w": 960, "h": 1166 } }
  ]
}
```

Optional per-window fields you can add by hand:

- `"launch": ["code", "-n", "~/code/myproject"]`: the command that opens the window, instead of launching the app or choosing File → New Window.
- `"urls": ["https://…"]`: pages a Chrome window opens with (otherwise Chrome's new-tab page).
- `"keep_running": true`: never quit this app when the desktop closes (Slack or Mail, say).

## How it works

- **Open:** new windows always appear on the desktop you're looking at, so the tool never has to move windows between desktops. That's the part macOS makes hard. For each saved window it launches the app (or asks a running app for a new window), waits for the new window to appear, and sets its frame. It places everything a second time after a second, because some apps resize themselves once loaded.
- **Close:** switches to the desktop if needed. For each app it checks whether the app has windows on any other desktop. To see windows on *other* desktops it asks the window server directly (CoreGraphics through JavaScript for Automation), because Hammerspoon's accessibility view only covers the current desktop. On a desktop that's showing, only visible windows count: some apps, such as Windows App, hide a closed window instead of destroying it. If it can't tell, it treats the app as in use. Apps only on this desktop are quit. For the others, each window is closed with the app's own Close Window menu item, which closes all of a window's tabs (Terminal, Finder), and apps left with no windows anywhere are then quit.
- **Open (restored windows):** after launching an app, the tool waits a few seconds for the windows it restores and uses those before asking for new ones.
- **Chrome:** the profile is read from the window title or the toolbar's profile button, and matched against the names in Chrome's `Local State`. Give every profile a different name. A window reopens with `open -na "Google Chrome" --args --profile-directory=<profile>`, the same as Chrome's Profiles menu, so the profile's "On startup" pages load. If the profile already has a window open, it asks again with `--new-window`. No Automation permission is needed.

## Development notes

- The menu bar icon uses the autosave name `desktops-menu`, so macOS keeps its position across reloads. Without it, the re-created icon can land off-screen.
- Hammerspoon extensions are loaded at startup (top of `init.lua`). Loading one later prints a message, and that can crash when an `hs` CLI session is attached.

- The `hs` command-line tool can jam if a command runs AppleScript while the CLI waits on it. To test from a shell, queue the work instead: `hs -c 'hs.timer.doAfter(0.1, function() dofile("/tmp/probe.lua") end)'`, and have the probe write its results to a file.
- `Desktops for macOS — v1 Build Outline.md` is the original plan, which used AeroSpace. That approach was dropped: forced tiling and replacing Spaces didn't fit this workflow.
