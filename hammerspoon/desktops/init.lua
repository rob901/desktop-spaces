-- Desktops: save the windows on the current macOS desktop (Space) and
-- reopen them later on another desktop, at the same sizes; close them
-- again and quit apps nothing else is using.
-- Load the Hammerspoon extensions up front rather than on first use.
for _, ext in ipairs({ "hs.webview", "hs.webview.usercontent", "hs.osascript", "hs.dialog", "hs.canvas",
                       "hs.axuielement", "hs.task", "hs.spaces", "hs.menubar", "hs.json", "hs.eventtap", "hs.settings", "hs.urlevent", "hs.hotkey",
                       "hs.drawing", "hs.styledtext", "hs.image", "hs.screen", "hs.alert", "hs.timer", "hs.geometry", "hs.application", "hs.window" }) do
  require(ext)
end

local store = require("desktops.store")
local chrome = require("desktops.chrome")
local prefs = require("desktops.prefs")

local M = {}

M.launchTimeout = 20      -- seconds to wait for a launched window
M.newWindowAfter = 4      -- running app shows no new window: try "New Window" after this
M.restoreWait = 5         -- after launching an app, how long its restored windows may take to appear
local NEVER_QUIT = {
  ["com.apple.finder"] = true,
  ["org.hammerspoon.Hammerspoon"] = true,
}
local IGNORE = { ["org.hammerspoon.Hammerspoon"] = true }
local log = hs.logger.new("desktops", "info")

local function alert(msg, secs) hs.alert.show(msg, secs or 2.5) end

-- ---- async helpers ------------------------------------------------------------
-- Commands run as coroutines so waiting for windows doesn't freeze Hammerspoon.

local busy, busySince, busyWhat = false, 0, nil
M.busyTimeout = 90        -- seconds; a request running longer is assumed stuck

-- Dialogs from inside a request are shown after it has finished, so a dialog
-- you haven't seen (behind windows, or on another desktop) can't keep
-- Desktops "busy".
local function notify(title, text)
  hs.timer.doAfter(0.1, function() hs.dialog.blockAlert(title, text) end)
end

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    busy = false
    log.e(debug.traceback(co, err))
    notify("Desktops error", tostring(err))
  end
end

-- Timers are kept referenced until they fire, so the garbage collector can't
-- drop one and leave a request waiting forever.
local pendingTimers = {}
local function sleep(secs)
  local co = coroutine.running()
  local t
  t = hs.timer.doAfter(secs, function() pendingTimers[t] = nil; resume(co) end)
  pendingTimers[t] = true
  coroutine.yield()
end

local function run(fn, what)
  if busy then
    local age = hs.timer.secondsSinceEpoch() - busySince
    if age < M.busyTimeout then
      alert("Desktops is still working on the last request (" .. (busyWhat or "?") .. ")")
      return
    end
    log.w(string.format("request %q still running after %ds; assuming it's stuck", busyWhat or "?", math.floor(age)))
  end
  busy, busySince, busyWhat = true, hs.timer.secondsSinceEpoch(), what
  log.i("start: " .. (what or "?"))
  resume(coroutine.create(function()
    fn()
    busy = false
    log.i(string.format("done: %s (%.1fs)", what or "?", hs.timer.secondsSinceEpoch() - busySince))
  end))
end

-- ---- windows -------------------------------------------------------------------

local function bundleOf(win)
  local app = win:application()
  return app and app:bundleID()
end

-- Does a window with this ID still exist, on any desktop?
local function alive(id)
  if hs.window.get(id) then return true end
  local spaces = hs.spaces.windowSpaces(id)
  return spaces ~= nil and #spaces > 0
end

-- Standard windows on the desktop you're looking at, back to front.
local function currentDesktopWindows()
  local onSpace = {}
  for _, id in ipairs(hs.spaces.windowsForSpace(hs.spaces.focusedSpace()) or {}) do onSpace[id] = true end
  -- Tabs (Terminal, Finder...) show up as separate windows sharing one frame;
  -- keep only the frontmost of each group so a tabbed window counts once.
  local ordered, out, seen = hs.window.orderedWindows(), {}, {}
  for _, w in ipairs(ordered) do -- front to back
    local b = bundleOf(w)
    if onSpace[w:id()] and w:isStandard() and b and not IGNORE[b] then
      local f = w:frame()
      local key = string.format("%s|%d|%d|%d|%d", b, f.x, f.y, f.w, f.h)
      if not seen[key] then
        seen[key] = true
        table.insert(out, 1, w) -- result is back to front
      end
    end
  end
  return out
end

-- Every app window the window server knows about, on all desktops.
-- (hs.window.list misses other desktops or hangs, so ask CoreGraphics directly.)
local WINDOW_SERVER_JS = [[
ObjC.import('CoreGraphics');
const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)));
JSON.stringify(list.filter(w => w.kCGWindowLayer === 0).map(w =>
  ({id: w.kCGWindowNumber, pid: w.kCGWindowOwnerPID, w: w.kCGWindowBounds.Width, h: w.kCGWindowBounds.Height,
    onscreen: !!w.kCGWindowIsOnscreen})));
]]

local function windowServerWindows()
  local ok, result = hs.osascript.javascript(WINDOW_SERVER_JS)
  if not ok or type(result) ~= "string" then return nil end
  return hs.json.decode(result)
end

-- Window ID -> desktop (space) ID, for every user desktop on all displays.
local function idsOnDesktops()
  local ids = {}
  for _, spaces in pairs(hs.spaces.allSpaces() or {}) do
    for _, sp in ipairs(spaces) do
      for _, id in ipairs(hs.spaces.windowsForSpace(sp) or {}) do ids[id] = sp end
    end
  end
  return ids
end

-- Does the app have any window left, on any desktop (minimized included)?
-- When unsure, answers true, so Close never quits an app that's still in use.
local function appHasWindows(app)
  for _, w in ipairs(app:allWindows()) do
    if w:isStandard() or w:isMinimized() then return true end
  end
  -- Windows on other desktops are invisible to the accessibility API.
  local wins = windowServerWindows()
  if not wins then return true end
  local desktopOf, pid = idsOnDesktops(), app:pid()
  local showing = {}
  for _, sp in pairs(hs.spaces.activeSpaces() or {}) do showing[sp] = true end
  for _, w in ipairs(wins) do
    local sp = desktopOf[w.id]
    -- Small strips and popups (< 100px) are helper windows, not real ones.
    if w.pid == pid and sp and w.w >= 100 and w.h >= 100 then
      -- On a desktop that's showing, a real window is on screen (minimized ones
      -- were caught above). Some apps hide closed windows instead of destroying them.
      -- On other desktops we can't tell, so count it.
      if w.onscreen or not showing[sp] then return true end
    end
  end
  return false
end

-- Does the app have windows anywhere other than desktop `here`? Used before
-- closing, to decide whether the whole app can be quit (keeping its state).
-- Windows in `ours` (this desktop's recorded windows) never count.
-- When unsure, answers true.
local function appUsedElsewhere(app, here, ours)
  for _, w in ipairs(app:allWindows()) do
    if w:isMinimized() and not ours[w:id()] then return true, "minimized window " .. w:id() end
  end
  local wins = windowServerWindows()
  if not wins then return true, "couldn't list windows" end
  local desktopOf, pid = idsOnDesktops(), app:pid()
  local showing = {}
  for _, sp in pairs(hs.spaces.activeSpaces() or {}) do showing[sp] = true end
  for _, w in ipairs(wins) do
    local sp = desktopOf[w.id]
    if w.pid == pid and sp and sp ~= here and not ours[w.id] and w.w >= 100 and w.h >= 100 then
      if w.onscreen or not showing[sp] then
        return true, string.format("window %d (%dx%d) on desktop %s", w.id, w.w, w.h, tostring(sp))
      end
    end
  end
  return false
end

-- macOS Resume: an app restores its windows (documents, Terminal tabs...) on
-- the next launch. Off by default system-wide ("Close windows when quitting an
-- application"); turned on here only for apps in saved desktops.
--
-- Resume also puts each window back on the desktop it was on, if that desktop
-- still exists, and macOS no longer lets us move it from there. So apps that
-- restore their own session (and then open on the current desktop) are left
-- alone: these, and any Electron app (Slack, VS Code, Claude...).
local OWN_RESTORE = {
  ["com.sublimetext.4"] = true, ["com.sublimetext.3"] = true,
  ["com.microsoft.VSCode"] = true, ["dev.zed.Zed"] = true,
  ["com.google.Chrome"] = true, ["com.tinyspeck.slackmacgap"] = true,
  ["com.anthropic.claudefordesktop"] = true,
}
local function restoresItself(bundle)
  if OWN_RESTORE[bundle] then return true end
  local app = hs.application.get(bundle)
  local path = app and app:path()
  return path ~= nil and hs.fs.attributes(path .. "/Contents/Frameworks/Electron Framework.framework") ~= nil
end

local resumeEnabled = {}
local function enableResume(bundle)
  if not bundle or resumeEnabled[bundle] or not bundle:match("^[%w%.%-_]+$") then return end
  resumeEnabled[bundle] = true
  if restoresItself(bundle) then return end
  hs.execute("/usr/bin/defaults write " .. bundle .. " NSQuitAlwaysKeepsWindows -bool true")
end

local function frameOf(win)
  local f = win:frame()
  return { x = math.floor(f.x + 0.5), y = math.floor(f.y + 0.5), w = math.floor(f.w + 0.5), h = math.floor(f.h + 0.5) }
end

local function place(win, frame)
  if not frame then return end
  local rect = hs.geometry.rect(frame.x, frame.y, frame.w, frame.h)
  local onScreen = false
  for _, s in ipairs(hs.screen.allScreens()) do
    if rect.center:inside(s:fullFrame()) then onScreen = true break end
  end
  win:setFrame(rect, 0)
  if not onScreen then win:moveToScreen(hs.screen.mainScreen(), true, true, 0) end
end

-- ---- launching -------------------------------------------------------------------

local function runTask(argv)
  local args = {}
  for i = 2, #argv do args[#args + 1] = (argv[i]:gsub("^~", os.getenv("HOME"))) end
  local path = argv[1]
  if not path:find("/") then
    table.insert(args, 1, path)
    path = "/usr/bin/env"
  end
  local task = hs.task.new(path, function(code, _, err)
    if code ~= 0 then log.w("launch failed: " .. table.concat(argv, " ") .. ": " .. (err or "")) end
  end, args)
  task:setEnvironment({
    HOME = os.getenv("HOME"),
    PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
  })
  task:start()
end

local function newWindow(app)
  for _, item in ipairs({ "New Window", "New Finder Window", "New Viewer Window" }) do
    if app:findMenuItem(item) and app:selectMenuItem(item) then return end
  end
  hs.eventtap.keyStroke({ "cmd" }, "n", 0, app)
end

local function label(entry)
  if entry.type == "chrome" then
    return "Chrome (" .. (entry.profile_name or entry.profile or "default profile") .. ")"
  end
  return entry.app or entry.bundle_id or "?"
end

local function belongs(win, entry)
  local b = bundleOf(win)
  if entry.type == "chrome" then return b == chrome.bundleID end
  if entry.bundle_id then return b == entry.bundle_id end
  local app = win:application()
  return app and app:name() == entry.app
end

-- Pick the window for an entry: same title first, otherwise the first one.
local function pickByTitle(found, entry)
  for _, w in ipairs(found) do
    if entry.title and w:title() == entry.title then return w end
  end
  return found[1]
end

-- Windows that appeared since the desktop started opening (restored by an app
-- this open launched) and fit the entry. For Chrome, the profile must match.
local function restoredFor(entry, taken, ctx)
  local found = {}
  for _, w in ipairs(hs.window.allWindows()) do
    if not ctx.before[w:id()] and not taken[w:id()] and w:isStandard() and belongs(w, entry) then
      local ok = true
      if entry.type == "chrome" and entry.profile then
        ctx.profiles = ctx.profiles or chrome.profiles()
        local p = chrome.detectProfile(w, ctx.profiles)
        ok = (p == nil or p == entry.profile)
      end
      if ok then table.insert(found, w) end
    end
  end
  return found
end

-- Start the entry's window and wait for it to appear. Returns the window or nil.
-- ctx (shared across one open): before = window IDs present when the open
-- started; launched = bundle -> time this open launched that app.
local function launchAndWait(entry, taken, ctx)
  local bundle = entry.type == "chrome" and chrome.bundleID or entry.bundle_id

  -- An app this open launched may have restored this window already (Resume
  -- or its own session restore). Use it rather than opening another; give
  -- the app a few seconds after launch to bring all its windows back.
  local launchedAt = bundle and ctx.launched[bundle]
  repeat
    local found = restoredFor(entry, taken, ctx)
    if #found > 0 then return pickByTitle(found, entry), true end
    if not launchedAt or hs.timer.secondsSinceEpoch() - launchedAt > M.restoreWait then break end
    sleep(0.25)
  until false

  local before = {}
  for _, w in ipairs(hs.window.allWindows()) do before[w:id()] = true end

  local app = bundle and hs.application.get(bundle)
  if bundle and not app then ctx.launched[bundle] = hs.timer.secondsSinceEpoch() end
  local function openChrome(forceNewWindow)
    local argv = { "/usr/bin/open" }
    for _, a in ipairs(chrome.launchArgs(entry.profile, entry.urls, forceNewWindow)) do argv[#argv + 1] = a end
    runTask(argv)
  end
  if entry.type == "chrome" then
    openChrome(false)
  elseif entry.launch then
    runTask(entry.launch)
  elseif app then
    newWindow(app)
  elseif bundle then
    hs.application.launchOrFocusByBundleID(bundle)
  else
    hs.application.launchOrFocus(entry.app)
  end

  -- Chrome opened as "start this profile" (for its startup pages) may just bring
  -- an existing window of that profile forward; then ask for a new window.
  local chromeFallback = entry.type == "chrome" and app ~= nil and not (entry.urls and #entry.urls > 0)
  local triedNew = chromeFallback == false and (entry.type == "chrome" or entry.launch ~= nil or app ~= nil)
  local start = hs.timer.secondsSinceEpoch()
  while hs.timer.secondsSinceEpoch() - start < M.launchTimeout do
    sleep(0.25)
    local found = {}
    for _, w in ipairs(hs.window.allWindows()) do
      if not before[w:id()] and not taken[w:id()] and w:isStandard() and belongs(w, entry) then
        local ok = true
        if entry.type == "chrome" and entry.profile then
          -- A freshly launched Chrome can restore other profiles' windows too.
          ctx.profiles = ctx.profiles or chrome.profiles()
          local p = chrome.detectProfile(w, ctx.profiles)
          ok = (p == nil or p == entry.profile)
        end
        if ok then table.insert(found, w) end
      end
    end
    if #found > 0 then return pickByTitle(found, entry) end
    -- App launched but restored no window: ask it for one.
    if not triedNew and hs.timer.secondsSinceEpoch() - start > M.newWindowAfter then
      triedNew = true
      if entry.type == "chrome" then
        openChrome(true)
      else
        local a = bundle and hs.application.get(bundle) or hs.application.get(entry.app)
        if a then newWindow(a) end
      end
    end
  end
  return nil
end

-- ---- state ---------------------------------------------------------------------

local function liveState(name)
  local st = store.loadState(name)
  -- Saved before the last restart: those windows are gone (and their IDs may
  -- now belong to other windows).
  -- (The recorded startup time can shift by a second or so; allow for that.)
  local stale = st.boot and math.abs(st.boot - store.bootTime()) > 120
  if not st.boot and #st.windows > 0 then  -- older state files: go by when it was written
    local attrs = hs.fs.attributes(store.statePath(name))
    stale = attrs ~= nil and attrs.modification < store.bootTime() - 5
  end
  if stale then
    store.clearState(name)
    return { windows = {} }
  end
  local live = {}
  for _, e in ipairs(st.windows) do
    if alive(e.id) then table.insert(live, e) end
  end
  st.windows = live
  return st
end

function M.isOpen(name) return #liveState(name).windows > 0 end

-- Is this saved desktop open on the desktop you're looking at? (The desktop it
-- was opened or saved on is recorded in its state as `space`.)
function M.isCurrent(name)
  local st = liveState(name)
  if #st.windows == 0 then return false end
  local here = hs.spaces.focusedSpace()
  if st.space then return st.space == here end
  -- Older state without a recorded desktop: go by where its windows are.
  for _, e in ipairs(st.windows) do
    for _, sp in ipairs(hs.spaces.windowSpaces(e.id) or {}) do
      if sp == here then return true end
    end
  end
  return false
end

-- Switch to the desktop holding a window. Returns true if we're there.
local function gotoWindowDesktop(id)
  local spaces = hs.spaces.windowSpaces(id) or {}
  local target = spaces[1]
  if not target or target == hs.spaces.focusedSpace() then return true end
  hs.spaces.gotoSpace(target)
  -- The switch animates; wait until the window is reachable (up to 3s).
  for _ = 1, 12 do
    sleep(0.25)
    if hs.spaces.focusedSpace() == target and hs.window.get(id) then return true end
  end
  return false
end

-- ---- commands --------------------------------------------------------------------

-- Fields Save/Update work out from the live window. Anything else in a saved
-- entry (launch, keep_running, urls, ...) was added by hand and is kept on Update.
local CAPTURED = { type = true, app = true, bundle_id = true, title = true, frame = true,
                   profile = true, profile_name = true }

-- Build a config from windows on this desktop. `old`/`oldState` (for Update)
-- let hand-edited fields carry over for windows that are still there.
local function buildConfig(name, wins, old, oldState)
  local warnings = {}
  -- Chrome windows are saved by profile (not tabs): each reopens as a new
  -- window in that profile.
  local profiles = {}
  for _, w in ipairs(wins) do
    if bundleOf(w) == chrome.bundleID then profiles = chrome.profiles() break end
  end

  local previous = {}  -- window id -> its entry in the old config
  if old and oldState then
    for _, e in ipairs(oldState.windows or {}) do previous[e.id] = old.windows[e.index] end
  end

  local cfg = {}
  for k, v in pairs(old or {}) do cfg[k] = v end  -- keep hand-added top-level fields
  cfg.name, cfg.saved, cfg.windows = name, os.date("%Y-%m-%d %H:%M"), {}
  local state = { space = hs.spaces.focusedSpace(), windows = {} }

  for i, w in ipairs(wins) do
    local app = w:application()
    local prev = previous[w:id()]
    local entry
    if app:bundleID() == chrome.bundleID then
      local folder, display = chrome.detectProfile(w, profiles)
      if not folder and prev and prev.profile then folder, display = prev.profile, prev.profile_name end
      if not folder then
        local known = {}
        for f, n in pairs(profiles) do table.insert(known, n .. " = " .. f) end
        table.insert(warnings, "Chrome window “" .. w:title() .. "”: couldn't tell which profile it uses. "
          .. "Set \"profile\" in the file (" .. table.concat(known, ", ") .. ").")
      end
      entry = { type = "chrome", profile = folder, profile_name = display, title = w:title() }
    else
      entry = { type = "app", app = app:name(), bundle_id = app:bundleID(), title = w:title() }
    end
    entry.frame = frameOf(w)
    enableResume(app:bundleID())
    if prev then
      for k, v in pairs(prev) do
        if not CAPTURED[k] then entry[k] = v end
      end
    end
    table.insert(cfg.windows, entry)
    table.insert(state.windows, { id = w:id(), index = i })
  end
  return cfg, state, warnings
end

local function reportSaved(verb, name, count, warnings)
  if #warnings > 0 then
    hs.dialog.blockAlert(verb .. " “" .. name .. "” with warnings", table.concat(warnings, "\n\n"))
  else
    alert(verb .. " “" .. name .. "” (" .. count .. " windows)")
  end
end

function M.saveCurrent()
  local wins = currentDesktopWindows()
  if #wins == 0 then alert("No windows on this desktop to save") return end

  local button, text = hs.dialog.textPrompt("Save desktop",
    "Save the " .. #wins .. " window(s) on this desktop as:", "", "Save", "Cancel")
  if button ~= "Save" then return end
  local name, why = store.cleanName(text)
  if not name then hs.dialog.blockAlert("Can't save", why) return end
  if store.exists(name) then
    local b = hs.dialog.blockAlert("Replace “" .. name .. "”?",
      "A desktop with this name is already saved.", "Replace", "Cancel")
    if b ~= "Replace" then return end
    store.backup(name)
  end

  local cfg, state, warnings = buildConfig(name, wins)
  if not store.save(cfg) then hs.dialog.blockAlert("Can't save", "Couldn't write " .. store.configPath(name)) return end
  store.saveState(name, state)
  reportSaved("Saved", name, #wins, warnings)
end

-- Re-save an open desktop from the windows on it now. Only offered (and only
-- allowed) on the desktop where that saved desktop was opened.
function M.update(name)
  if not M.isCurrent(name) then
    hs.dialog.blockAlert("Can't update “" .. name .. "”",
      "Switch to the desktop where “" .. name .. "” is open, then choose Update Desktop Items there.")
    return
  end
  local wins = currentDesktopWindows()
  if #wins == 0 then alert("No windows on this desktop to save") return end
  local old, err = store.load(name)
  if not old then hs.dialog.blockAlert("Can't update “" .. name .. "”", err) return end

  local cfg, state, warnings = buildConfig(name, wins, old, liveState(name))
  store.backup(name)
  if not store.save(cfg) then hs.dialog.blockAlert("Can't update", "Couldn't write " .. store.configPath(name)) return end
  store.saveState(name, state)
  reportSaved("Updated", name, #wins, warnings)
end

function M.open(name)
  run(function()
    local cfg, err = store.load(name)
    if not cfg then notify("Can't open “" .. name .. "”", err) return end
    local st = liveState(name)
    if #st.windows > 0 then
      store.saveState(name, st)
      if gotoWindowDesktop(st.windows[1].id) then
        local w = hs.window.get(st.windows[1].id)
        if w then w:focus() end
        alert("“" .. name .. "” is already open")
      else
        alert("“" .. name .. "” is already open on another desktop")
      end
      return
    end

    alert("Opening “" .. name .. "”…")
    local openedOn = hs.spaces.focusedSpace()
    local placed, taken, failed = {}, {}, {}
    local ctx = { before = {}, launched = {} }
    for _, w in ipairs(hs.window.allWindows()) do ctx.before[w:id()] = true end
    local wsBefore = {}
    for _, w in ipairs(windowServerWindows() or {}) do wsBefore[w.id] = true end
    for i, entry in ipairs(cfg.windows) do
      local win = launchAndWait(entry, taken, ctx)
      if win then
        place(win, entry.frame)
        taken[win:id()] = true
        table.insert(placed, { id = win:id(), index = i, win = win })
        store.saveState(name, { space = openedOn, windows = (function()
          local t = {}
          for _, p in ipairs(placed) do t[#t + 1] = { id = p.id, index = p.index } end
          return t
        end)() })
      else
        table.insert(failed, label(entry))
      end
    end

    -- Some apps resize themselves once loaded; place everything again.
    sleep(1.0)

    -- Restored windows no saved entry claimed (the app had more open when it
    -- quit) stay where the app put them, but belong to this desktop now, so
    -- Close handles them too.
    local extra = 0
    if next(ctx.launched) then
      local onSpace = {}
      for _, id in ipairs(hs.spaces.windowsForSpace(openedOn) or {}) do onSpace[id] = true end
      local t = {}
      for _, p in ipairs(placed) do t[#t + 1] = { id = p.id, index = p.index } end
      for _, w in ipairs(hs.window.allWindows()) do
        local b = bundleOf(w)
        if b and ctx.launched[b] and not ctx.before[w:id()] and not taken[w:id()] and onSpace[w:id()] and w:isStandard() then
          taken[w:id()] = true
          t[#t + 1] = { id = w:id() }
          extra = extra + 1
        end
      end
      if extra > 0 then store.saveState(name, { space = openedOn, windows = t }) end
    end

    -- macOS Resume puts restored windows back on the desktop they were on
    -- (if it still exists), and they can't be moved from here. Say so.
    local strays = {}
    if next(ctx.launched) then
      local desktopOf = idsOnDesktops()
      local pids = {}
      for b in pairs(ctx.launched) do
        local a = hs.application.get(b)
        if a then pids[a:pid()] = a:name() end
      end
      local seen = {}
      for _, w in ipairs(windowServerWindows() or {}) do
        local sp = desktopOf[w.id]
        if pids[w.pid] and not wsBefore[w.id] and sp and sp ~= openedOn and w.w >= 100 and w.h >= 100
          and not seen[w.pid] then
          seen[w.pid] = true
          table.insert(strays, pids[w.pid])
        end
      end
      if #strays > 0 then
        table.sort(strays)
        log.i("restored onto another desktop: " .. table.concat(strays, ", "))
      end
    end
    for _, p in ipairs(placed) do place(p.win, cfg.windows[p.index].frame) end
    if placed[#placed] then placed[#placed].win:focus() end

    if #failed > 0 then
      notify("Opened “" .. name .. "” with problems",
        "These windows didn't appear within " .. M.launchTimeout .. " seconds:\n" .. table.concat(failed, "\n"))
    else
      alert("Opened “" .. name .. "”"
        .. (#strays > 0 and ("\n" .. table.concat(strays, ", ") .. " restored a window onto another desktop") or ""), #strays > 0 and 5 or nil)
    end
  end, "open " .. name)
end

-- Closing a tabbed window (Terminal, Finder...) with its close button only
-- closes the selected tab; the next tab then appears as a new window (its
-- frame can differ, since the tab bar goes away). Must run inside run().
local CLOSE_WINDOW_MENUS = { { "Shell", "Close Window" }, { "File", "Close Window" } }

local function appWindowsHere(app)
  local onSpace, out = {}, {}
  for _, id in ipairs(hs.spaces.windowsForSpace(hs.spaces.focusedSpace()) or {}) do onSpace[id] = true end
  for _, o in ipairs(app:allWindows()) do
    if onSpace[o:id()] and o:isStandard() then out[#out + 1] = o end
  end
  return out
end

local function closeWithTabs(w)
  local app = w:application()
  if not app then return w:close() end
  local before = {}
  for _, o in ipairs(appWindowsHere(app)) do before[o:id()] = true end

  -- Preferred: the app's own "Close Window" (Terminal: Shell → Close Window),
  -- which closes every tab. The app must really be frontmost with this window
  -- focused, otherwise the menu item is disabled and pressing it does nothing
  -- (right after a menu bar click, Hammerspoon is frontmost).
  local path
  for _, p in ipairs(CLOSE_WINDOW_MENUS) do
    if app:findMenuItem(p) then path = p break end
  end
  if path then
    local ready = false
    for i = 1, 20 do
      if i == 1 or i == 8 then app:activate(true); w:focus() end
      sleep(0.1)
      local front, fw = hs.application.frontmostApplication(), hs.window.focusedWindow()
      local item = app:findMenuItem(path)
      if front and front:pid() == app:pid() and fw and fw:id() == w:id() and item and item.enabled then
        ready = true break
      end
    end
    if ready and app:selectMenuItem(path) then
      for _ = 1, 20 do
        sleep(0.1)
        if not hs.window.get(w:id()) then return true end
      end
    end
    if not hs.window.get(w:id()) then return true end
    log.i("Close Window didn't close " .. app:name() .. " window " .. w:id()
      .. " (ready=" .. tostring(ready) .. "); closing tab by tab")
  end

  -- Fallback: close button, then keep closing windows of this app that newly
  -- appear on this desktop (the revealed tabs).
  local ok = w:close()
  for _ = 1, 30 do
    if not ok then break end
    local revealed
    for _ = 1, 5 do
      sleep(0.15)
      if hs.window.get(w:id()) then return ok end -- still open (e.g. "terminate running processes?")
      for _, o in ipairs(appWindowsHere(app)) do
        if not before[o:id()] then revealed = o break end
      end
      if revealed then break end
    end
    if not revealed then break end
    w = revealed
    before[w:id()] = true
    ok = w:close()
  end
  return ok
end

function M.close(name)
  run(function()
    local cfg = store.load(name) or { windows = {} }
    local st = liveState(name)
    if #st.windows == 0 then
      store.clearState(name)
      alert("“" .. name .. "” isn't open")
      return
    end
    if not gotoWindowDesktop(st.windows[1].id) then
      alert("Switch to the “" .. name .. "” desktop, then choose Close again", 4)
      return
    end

    -- Group this desktop's windows by app.
    local here = hs.spaces.focusedSpace()
    local groups, order, ours = {}, {}, {}
    for _, e in ipairs(st.windows) do
      local w = hs.window.get(e.id)
      local app = w and w:application()
      local b = app and app:bundleID()
      if w then ours[w:id()] = true end
      if b then
        if not groups[b] then groups[b] = { app = app, wins = {} } table.insert(order, b) end
        table.insert(groups[b].wins, w)
        if (cfg.windows[e.index] or {}).keep_running then groups[b].keep = true end
      elseif w then
        groups["?" .. w:id()] = { wins = { w }, keep = true }
        table.insert(order, "?" .. w:id())
      end
    end

    -- Apps used only on this desktop are quit with their windows still open,
    -- so they save their state (Resume, or the app's own session restore) and
    -- bring it back when the desktop is opened again. Apps also open on other
    -- desktops (or marked keep_running) only get this desktop's windows closed.
    local quit, quitting, apps, closed = {}, {}, {}, 0
    for _, b in ipairs(order) do
      local g = groups[b]
      local elsewhere, why = false, nil
      if not g.keep and g.app and not NEVER_QUIT[b] then elsewhere, why = appUsedElsewhere(g.app, here, ours) end
      local appName = g.app and g.app:name() or b
      if g.keep or not g.app or NEVER_QUIT[b] then
        log.i(appName .. ": closing " .. #g.wins .. " window(s), app kept running (keep_running / never quit)")
      elseif elsewhere then
        log.i(appName .. ": closing " .. #g.wins .. " window(s) only; app also in use elsewhere: " .. why)
      else
        log.i(appName .. ": quitting (only on this desktop)")
      end
      if not g.keep and g.app and not NEVER_QUIT[b] and not elsewhere then
        enableResume(b)
        quitting[b] = g.app
        closed = closed + #g.wins
        g.app:kill()
      else
        if g.app and not g.keep and not NEVER_QUIT[b] then apps[b] = g.app end
        for _, w in ipairs(g.wins) do
          if closeWithTabs(w) then closed = closed + 1 end
        end
      end
    end

    store.clearState(name)

    -- Wait (up to 6s) for quitting apps to exit. One that's still running is
    -- most likely asking about unsaved changes.
    for _ = 1, 12 do
      if next(quitting) == nil then break end
      sleep(0.5)
      for b, app in pairs(quitting) do
        if not app:isRunning() then
          table.insert(quit, app:name())
          quitting[b] = nil
        end
      end
    end
    local waiting = {}
    for _, app in pairs(quitting) do table.insert(waiting, app:name()) end

    -- Give windows a moment to finish closing (up to 3s), then quit apps
    -- that have nothing left open anywhere.
    local pending = {}
    for b, app in pairs(apps) do pending[b] = app end
    for _ = 1, 6 do
      sleep(0.5)
      for b, app in pairs(pending) do
        if not app:isRunning() then
          pending[b] = nil
        elseif not appHasWindows(app) then
          table.insert(quit, app:name())
          app:kill()
          pending[b] = nil
        end
      end
      if next(pending) == nil then break end
    end
    local kept = {}
    for _, app in pairs(pending) do table.insert(kept, app:name()) end
    if #kept > 0 then log.i("left running (windows elsewhere): " .. table.concat(kept, ", ")) end
    table.sort(quit)
    table.sort(waiting)
    alert("Closed “" .. name .. "”: " .. closed .. " window(s)"
      .. (#quit > 0 and ("; quit " .. table.concat(quit, ", ")) or "")
      .. (#waiting > 0 and ("\n" .. table.concat(waiting, ", ") .. " is waiting for you (unsaved changes?)") or ""), 4)
  end, "close " .. name)
end

-- ---- menu bar --------------------------------------------------------------------

local function monitorIcon()
  local black = { red = 0, green = 0, blue = 0, alpha = 1 }
  local c = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
  c[1] = { type = "rectangle", action = "stroke", strokeColor = black, strokeWidth = 1.5,
           frame = { x = 1.5, y = 2.5, w = 15, h = 10 }, roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 } }
  c[2] = { type = "rectangle", action = "fill", fillColor = black, frame = { x = 8, y = 12.5, w = 2, h = 2.5 } }
  c[3] = { type = "rectangle", action = "fill", fillColor = black,
           frame = { x = 5, y = 14.75, w = 8, h = 1.5 }, roundedRectRadii = { xRadius = 0.75, yRadius = 0.75 } }
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

-- Menu titles with the desktop's keyboard shortcut right-aligned, like
-- native menu shortcuts. Returns name -> title (plain name when none set).
local function menuTitles(names, current)
  local font = hs.styledtext.defaultFonts.menu or { name = ".AppleSystemUIFont", size = 14 }
  local labels, nameW, labelW = {}, 0, 0
  local shortcuts = store.shortcuts()
  for _, n in ipairs(names) do
    local sc = shortcuts[n]
    if type(sc) == "table" and sc.key then labels[n] = prefs.formatShortcut(sc) end
    nameW = math.max(nameW, hs.drawing.getTextDrawingSize(n, { font = font.name, size = font.size }).w)
    if labels[n] then
      labelW = math.max(labelW, hs.drawing.getTextDrawingSize(labels[n], { font = font.name, size = font.size }).w)
    end
  end
  local stop = math.ceil(nameW + 40 + labelW)
  local titles = {}
  for _, n in ipairs(names) do
    local para = { tabStops = { { location = stop, tabStopType = "right" } } }
    if n == current then
      -- The desktop you're on: bold.
      -- (convertFont gives ".SFNS-Bold", which can't be loaded by name and
      -- silently falls back to regular; the system bold font name works.)
      local bold = { name = ".AppleSystemUIFontBold", size = font.size }
      titles[n] = labels[n]
        and hs.styledtext.new(n .. "\t" .. labels[n], { font = bold, paragraphStyle = para })
        or hs.styledtext.new(n, { font = bold })
    elseif labels[n] then
      titles[n] = hs.styledtext.new(n .. "\t" .. labels[n], { font = font, paragraphStyle = para })
    else
      titles[n] = n
    end
  end
  return titles
end

local function buildMenu()
  local items = {
    { title = "Save current desktop…", fn = function() M.saveCurrent() end },
    { title = "-" },
  }
  local names = store.list()
  local current
  for _, name in ipairs(names) do
    if M.isOpen(name) and M.isCurrent(name) then current = name break end
  end
  local titles = menuTitles(names, current)
  local closeItems = {}
  if #names == 0 then
    table.insert(items, { title = "No saved desktops yet", disabled = true })
  end
  for _, name in ipairs(names) do
    local open = M.isOpen(name)
    if name == current then
      -- The saved desktop you're on: hover for actions instead of reopening it.
      table.insert(items, { title = titles[name], checked = true, menu = {
        { title = "Update Desktop Items", fn = function() M.update(name) end },
        { title = "Close", fn = function() M.close(name) end },
      } })
    else
      table.insert(items, { title = titles[name], checked = open, fn = function() M.open(name) end })
    end
    table.insert(closeItems, { title = name, disabled = not open, fn = function() M.close(name) end })
  end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Close", menu = closeItems, disabled = #names == 0 })
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Preferences…", fn = function() M.showPrefs() end })
  table.insert(items, { title = "Open desktops folder", fn = function()
    hs.fs.mkdir(store.home)
    hs.task.new("/usr/bin/open", nil, { store.home }):start()
  end })
  table.insert(items, { title = "Reload", fn = hs.reload })
  return items
end

-- A small monitor outline, drawn as a template image so it follows the
-- menu bar's light/dark appearance.

-- ---- keyboard shortcuts ----------------------------------------------------------

M.hotkeys = {}

-- A desktop's shortcut: jump to it if it's open, otherwise open it here.
function M.jump(name)
  if M.isCurrent(name) then
    alert("You're on “" .. name .. "”", 1.2)
    return
  end
  M.open(name)
end

-- (Re)register a hotkey for every saved desktop that has a shortcut.
function M.bindShortcuts()
  for _, hk in ipairs(M.hotkeys) do hk:delete() end
  M.hotkeys = {}
  local saved = {}
  for _, n in ipairs(store.list()) do saved[n] = true end
  for name, sc in pairs(store.shortcuts()) do
    if saved[name] and type(sc) == "table" and sc.key then
      local hk = hs.hotkey.new(sc.mods or {}, sc.key, function() M.jump(name) end)
      if hk then
        hk:enable()
        table.insert(M.hotkeys, hk)
      else
        log.w("couldn't register shortcut for " .. name)
      end
    end
  end
end

-- Pause shortcuts while one is being recorded in Preferences.
function M.pauseShortcuts(paused)
  for _, hk in ipairs(M.hotkeys) do
    if paused then hk:disable() else hk:enable() end
  end
end

function M.showPrefs()
  prefs.show(M.isOpen, M.bindShortcuts, M.pauseShortcuts)
end

function M.start()
  -- Cap how long one accessibility call waits on an app (default is several
  -- seconds per call). Right after login, apps that are still starting can
  -- otherwise stall window lookups for minutes.
  if hs.window.timeout then pcall(hs.window.timeout, 2) end
  if M.menu then M.menu:delete() end
  M.menu = hs.menubar.new(true, "desktops-menu")  -- autosave name: macOS remembers its position
  M.menu:setIcon(monitorIcon(), true)
  M.menu:setTooltip("Desktops")
  M.menu:setMenu(buildMenu)
  M.bindShortcuts()
  return M
end

M.store, M.chrome = store, chrome
M._currentDesktopWindows, M._appHasWindows, M._alive = currentDesktopWindows, appHasWindows, alive
M._windowServerWindows, M._idsOnDesktops = windowServerWindows, idsOnDesktops
M._buildMenu = buildMenu
M._closeWithTabs = function(w, cb) run(function() cb(closeWithTabs(w)) end) end
return M
