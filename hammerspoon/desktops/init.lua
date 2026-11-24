-- Desktops: save the windows on the current macOS desktop (Space) and
-- reopen them later on another desktop, at the same sizes; close them
-- again and quit apps nothing else is using.
-- Load the Hammerspoon extensions up front rather than on first use.
for _, ext in ipairs({ "hs.webview", "hs.webview.usercontent", "hs.osascript", "hs.dialog", "hs.canvas",
                       "hs.axuielement", "hs.task", "hs.spaces", "hs.menubar", "hs.json", "hs.eventtap" }) do
  require(ext)
end

local store = require("desktops.store")
local chrome = require("desktops.chrome")
local prefs = require("desktops.prefs")

local M = {}

M.launchTimeout = 20      -- seconds to wait for a launched window
M.newWindowAfter = 4      -- running app shows no new window: try "New Window" after this
local NEVER_QUIT = {
  ["com.apple.finder"] = true,
  ["org.hammerspoon.Hammerspoon"] = true,
}
local IGNORE = { ["org.hammerspoon.Hammerspoon"] = true }
local log = hs.logger.new("desktops", "info")

local function alert(msg, secs) hs.alert.show(msg, secs or 2.5) end

-- ---- async helpers ------------------------------------------------------------
-- Commands run as coroutines so waiting for windows doesn't freeze Hammerspoon.

local busy = false

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    busy = false
    log.e(debug.traceback(co, err))
    hs.dialog.blockAlert("Desktops error", tostring(err))
  end
end

local function sleep(secs)
  local co = coroutine.running()
  hs.timer.doAfter(secs, function() resume(co) end)
  coroutine.yield()
end

local function run(fn)
  if busy then alert("Desktops is still working on the last request") return end
  busy = true
  resume(coroutine.create(function() fn(); busy = false end))
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
  local ordered, out = hs.window.orderedWindows(), {}
  for i = #ordered, 1, -1 do
    local w = ordered[i]
    local b = bundleOf(w)
    if onSpace[w:id()] and w:isStandard() and b and not IGNORE[b] then table.insert(out, w) end
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
  if app:bundleID() == chrome.bundleID then
    local wins = chrome.capture()
    return wins == nil or #wins > 0
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

-- Start the entry's window and wait for it to appear. Returns the window or nil.
local function launchAndWait(entry, taken)
  local before = {}
  for _, w in ipairs(hs.window.allWindows()) do before[w:id()] = true end

  local bundle = entry.type == "chrome" and chrome.bundleID or entry.bundle_id
  local app = bundle and hs.application.get(bundle)
  if entry.type == "chrome" then
    local argv = { "/usr/bin/open" }
    for _, a in ipairs(chrome.launchArgs(entry.profile, entry.urls)) do argv[#argv + 1] = a end
    runTask(argv)
  elseif entry.launch then
    runTask(entry.launch)
  elseif app then
    newWindow(app)
  elseif bundle then
    hs.application.launchOrFocusByBundleID(bundle)
  else
    hs.application.launchOrFocus(entry.app)
  end

  local triedNew = entry.type == "chrome" or entry.launch ~= nil or app ~= nil
  local start = hs.timer.secondsSinceEpoch()
  while hs.timer.secondsSinceEpoch() - start < M.launchTimeout do
    sleep(0.25)
    local found = {}
    for _, w in ipairs(hs.window.allWindows()) do
      if not before[w:id()] and not taken[w:id()] and w:isStandard() and belongs(w, entry) then
        table.insert(found, w)
      end
    end
    if #found > 0 then
      for _, w in ipairs(found) do
        if entry.title and w:title() == entry.title then return w end
      end
      return found[1]
    end
    -- App launched but restored no window: ask it for one.
    if not triedNew and hs.timer.secondsSinceEpoch() - start > M.newWindowAfter then
      triedNew = true
      local a = bundle and hs.application.get(bundle) or hs.application.get(entry.app)
      if a then newWindow(a) end
    end
  end
  return nil
end

-- ---- state ---------------------------------------------------------------------

local function liveState(name)
  local st = store.loadState(name)
  local live = {}
  for _, e in ipairs(st.windows) do
    if alive(e.id) then table.insert(live, e) end
  end
  st.windows = live
  return st
end

function M.isOpen(name) return #liveState(name).windows > 0 end

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
  end

  local warnings = {}
  local chromeWins = {}
  for _, w in ipairs(wins) do
    if bundleOf(w) == chrome.bundleID then table.insert(chromeWins, w) end
  end
  local captured, profiles, matched = {}, {}, {}
  if #chromeWins > 0 then
    local err
    captured, err = chrome.capture()
    if not captured then
      captured = {}
      table.insert(warnings, err)
    end
    profiles = chrome.profiles()
    local pairsFound = chrome.match(chromeWins, captured)
    for i, w in ipairs(chromeWins) do matched[w:id()] = pairsFound[i] end
  end

  local cfg = { name = name, saved = os.date("%Y-%m-%d %H:%M"), windows = {} }
  local state = { windows = {} }
  for i, w in ipairs(wins) do
    local app = w:application()
    local entry
    if app:bundleID() == chrome.bundleID then
      local c = matched[w:id()]
      local folder, display = chrome.detectProfile(w, profiles)
      if not c then table.insert(warnings, "Couldn't read the tabs of Chrome window “" .. w:title() .. "”.") end
      if not folder then
        local known = {}
        for f, n in pairs(profiles) do table.insert(known, n .. " = " .. f) end
        table.insert(warnings, "Chrome window “" .. w:title() .. "”: couldn't tell which profile it uses. "
          .. "Set \"profile\" in the file (" .. table.concat(known, ", ") .. ").")
      end
      entry = { type = "chrome", profile = folder, profile_name = display,
                urls = c and c.urls or {}, title = w:title() }
    else
      entry = { type = "app", app = app:name(), bundle_id = app:bundleID(), title = w:title() }
    end
    entry.frame = frameOf(w)
    table.insert(cfg.windows, entry)
    table.insert(state.windows, { id = w:id(), index = i })
  end

  if not store.save(cfg) then hs.dialog.blockAlert("Can't save", "Couldn't write " .. store.configPath(name)) return end
  store.saveState(name, state)
  if #warnings > 0 then
    hs.dialog.blockAlert("Saved “" .. name .. "” with warnings", table.concat(warnings, "\n\n"))
  else
    alert("Saved “" .. name .. "” (" .. #wins .. " windows)")
  end
end

function M.open(name)
  run(function()
    local cfg, err = store.load(name)
    if not cfg then hs.dialog.blockAlert("Can't open “" .. name .. "”", err) return end
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
    local placed, taken, failed = {}, {}, {}
    for i, entry in ipairs(cfg.windows) do
      local win = launchAndWait(entry, taken)
      if win then
        place(win, entry.frame)
        taken[win:id()] = true
        table.insert(placed, { id = win:id(), index = i, win = win })
        store.saveState(name, { windows = (function()
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
    for _, p in ipairs(placed) do place(p.win, cfg.windows[p.index].frame) end
    if placed[#placed] then placed[#placed].win:focus() end

    if #failed > 0 then
      hs.dialog.blockAlert("Opened “" .. name .. "” with problems",
        "These windows didn't appear within " .. M.launchTimeout .. " seconds:\n" .. table.concat(failed, "\n"))
    else
      alert("Opened “" .. name .. "”")
    end
  end)
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

    local apps, keep, closed = {}, {}, 0
    for _, e in ipairs(st.windows) do
      local w = hs.window.get(e.id)
      local entry = cfg.windows[e.index] or {}
      if w then
        local app = w:application()
        local b = app and app:bundleID()
        if b then
          apps[b] = app
          if entry.keep_running then keep[b] = true end
        end
        if w:close() then closed = closed + 1 end
      end
    end
    store.clearState(name)

    -- Give windows a moment to finish closing (up to 3s), then quit apps
    -- that have nothing left open anywhere.
    local quit, pending = {}, {}
    for b, app in pairs(apps) do
      if not keep[b] and not NEVER_QUIT[b] then pending[b] = app end
    end
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
    alert("Closed “" .. name .. "”: " .. closed .. " window(s)"
      .. (#quit > 0 and ("; quit " .. table.concat(quit, ", ")) or ""), 3.5)
  end)
end

-- ---- menu bar --------------------------------------------------------------------

local function buildMenu()
  local items = {
    { title = "Save current desktop…", fn = function() M.saveCurrent() end },
    { title = "-" },
  }
  local names = store.list()
  local closeItems = {}
  if #names == 0 then
    table.insert(items, { title = "No saved desktops yet", disabled = true })
  end
  for _, name in ipairs(names) do
    local open = M.isOpen(name)
    table.insert(items, { title = name, checked = open, fn = function() M.open(name) end })
    table.insert(closeItems, { title = name, disabled = not open, fn = function() M.close(name) end })
  end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Close", menu = closeItems, disabled = #names == 0 })
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Preferences…", fn = function() prefs.show(M.isOpen) end })
  table.insert(items, { title = "Open desktops folder", fn = function()
    hs.fs.mkdir(store.home)
    hs.task.new("/usr/bin/open", nil, { store.home }):start()
  end })
  table.insert(items, { title = "Reload", fn = hs.reload })
  return items
end

-- A small monitor outline, drawn as a template image so it follows the
-- menu bar's light/dark appearance.
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

function M.start()
  if M.menu then M.menu:delete() end
  M.menu = hs.menubar.new()
  M.menu:setIcon(monitorIcon(), true)
  M.menu:setTooltip("Desktops")
  M.menu:setMenu(buildMenu)
  return M
end

M.store, M.chrome = store, chrome
M._currentDesktopWindows, M._appHasWindows, M._alive = currentDesktopWindows, appHasWindows, alive
M._windowServerWindows, M._idsOnDesktops = windowServerWindows, idsOnDesktops
return M
