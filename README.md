# desktop

Save named desktops (sets of specific windows in a tiled layout) and open or close them on demand. A thin Python CLI on top of the [AeroSpace](https://github.com/nikitabobko/AeroSpace) window manager.

See `Desktops for macOS — v1 Build Outline.md` for the full design.

```
desktop save <name> [--workspace W] [--force]   # capture the focused workspace
desktop open <name> [--fresh]                   # launch, place, tile, switch
desktop close <name>                            # close only this desktop's windows
desktop list                                    # desktops and open/closed status
desktop edit <name>                             # edit the config in $EDITOR, then validate
desktop windows [--workspace W]                 # debug: AeroSpace window IDs and titles
```

`open` on a desktop that is already open just switches to it. `--fresh` launches any of its windows that are missing.

## Setup

1. Install AeroSpace: `brew install --cask nikitabobko/tap/aerospace`. Launch it and grant Accessibility.
2. In Mission Control, reduce to one macOS Space per display. Quit Spencer.
3. Python 3.9+ (`/usr/bin/python3` from the Xcode Command Line Tools is fine). No packages needed.
4. Link the script onto your PATH:
   ```
   mkdir -p ~/.local/bin
   ln -s "$PWD/desktop" ~/.local/bin/desktop
   ```
5. Add hotkeys from `examples/aerospace.toml` to `~/.aerospace.toml` and run `aerospace reload-config`.
6. For each desktop: put its windows on one AeroSpace workspace, run `desktop save <name>`, and check `~/.desktops/<name>.json` (especially Chrome `profile`). The first save asks for Automation permission to control Chrome.

## Files

- `~/.desktops/<name>.json`: desktop config. Editable by hand; the format is in the build outline.
- `~/.desktops/.state/<name>.json`: the AeroSpace window IDs this desktop opened or claimed. Don't edit.

## Development

```
/usr/bin/python3 -m unittest discover -s tests
```

The tests run every command against fake `aerospace`, `osascript` and `open` scripts in `tests/fakes/`, so no real windows are touched.

Environment overrides (mainly for tests): `DESKTOPS_HOME`, `DESKTOP_AEROSPACE`, `DESKTOP_CHROME_LOCAL_STATE`, `DESKTOP_LAUNCH_TIMEOUT` (seconds, default 20), `DESKTOP_POLL_INTERVAL` (default 0.25).

## Spike findings (AeroSpace 0.21.3-Beta)

Confirmed from the installed CLI's `--help`:

- `--window-id` is supported on `move-node-to-workspace`, `focus`, `close`, `layout` and `join-with`. The wrapper still falls back to "focus, then run the command" if an older version rejects it.
- `list-windows` accepts `--all`, `--workspace`, `--json` and `--format`.
- `flatten-workspace-tree` and `balance-sizes` take `--workspace`.

Still to confirm with the AeroSpace server running:

- [ ] The exact JSON keys `list-windows --all --json --format '%{window-id} %{app-name} %{app-bundle-id} %{workspace} %{window-title}'` returns. The parser expects `window-id`, `app-name`, `app-bundle-id`, `workspace`, `window-title`, and falls back to a pipe-delimited `--format` if JSON fails.
- [ ] Chrome window titles in AeroSpace (`desktop windows`) versus AppleScript: does the AeroSpace title end in ` - Google Chrome - <profile name>`? Profile detection depends on it.
- [ ] Whether `--no-restore-last-session` stops a cold-started Chrome from restoring extra windows.
