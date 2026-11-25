-- Saved desktop configs (<folder>/<name>.json) and runtime state
-- (<folder>/.state/<name>.json: the window IDs a desktop opened).
-- The folder defaults to ~/.desktops and can be changed in Preferences; the
-- chosen location is remembered in Hammerspoon's settings.
local M = {}

M.defaultHome = os.getenv("HOME") .. "/.desktops"
local HOME_KEY = "desktops.folder"
M.home = hs.settings.get(HOME_KEY) or os.getenv("DESKTOPS_HOME") or M.defaultHome

local function stateDir() return M.home .. "/.state" end

local function ensureDirs()
  hs.fs.mkdir(M.home)
  hs.fs.mkdir(stateDir())
end

local function exists(path) return hs.fs.attributes(path) ~= nil end

function M.configPath(name) return M.home .. "/" .. name .. ".json" end
function M.statePath(name) return stateDir() .. "/" .. name .. ".json" end

-- Trimmed name, or nil plus a reason.
function M.cleanName(name)
  name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil, "Name can't be empty." end
  if not name:match("^[%w _%.%-]+$") or name:sub(1, 1) == "." then
    return nil, "Use letters, numbers, spaces, '-', '_' or '.' (not starting with '.')."
  end
  return name
end

function M.exists(name) return exists(M.configPath(name)) end

-- ---- settings (~/.desktops/.settings.json): menu order ------------------------

local function settingsPath() return M.home .. "/.settings.json" end

function M.loadSettings()
  local s = exists(settingsPath()) and hs.json.read(settingsPath()) or nil
  if type(s) ~= "table" then s = {} end
  if type(s.order) ~= "table" then s.order = {} end
  if type(s.shortcuts) ~= "table" then s.shortcuts = {} end
  return s
end

function M.saveSettings(s)
  ensureDirs()
  return hs.json.write(s, settingsPath(), true, true)
end

-- Saved desktops in the user's order; ones not yet ordered go last, A–Z.
function M.list()
  local found = {}
  if not exists(M.home) then return {} end
  for file in hs.fs.dir(M.home) do
    local name = file:match("^([^%.].*)%.json$")
    if name then found[name] = true end
  end
  local names, seen = {}, {}
  for _, name in ipairs(M.loadSettings().order) do
    if found[name] and not seen[name] then
      table.insert(names, name)
      seen[name] = true
    end
  end
  local rest = {}
  for name in pairs(found) do
    if not seen[name] then table.insert(rest, name) end
  end
  table.sort(rest, function(a, b) return a:lower() < b:lower() end)
  for _, name in ipairs(rest) do table.insert(names, name) end
  return names
end

function M.setOrder(names)
  local s = M.loadSettings()
  s.order = names
  return M.saveSettings(s)
end

-- Rename a desktop: its config, its state and its place in the order.
function M.rename(old, new)
  local name, why = M.cleanName(new)
  if not name then return nil, why end
  if name == old then return true end
  if not M.exists(old) then return nil, "“" .. old .. "” no longer exists." end
  if M.exists(name) and name:lower() ~= old:lower() then
    return nil, "A desktop named “" .. name .. "” already exists."
  end
  local cfg, err = M.load(old)
  if not cfg then return nil, err end
  local order = M.list()
  for i, n in ipairs(order) do if n == old then order[i] = name end end

  -- Move the old file aside, write the new one, and only then delete the old
  -- copy (this also handles case-only renames on macOS's case-insensitive disk).
  local oldPath = M.configPath(old)
  local aside = M.home .. "/.renaming-" .. old .. ".json"
  os.rename(oldPath, aside)
  cfg.name = name
  if not M.save(cfg) then
    os.rename(aside, oldPath)
    return nil, "Couldn't write " .. M.configPath(name)
  end
  os.remove(aside)
  if exists(M.statePath(old)) then
    local tmp = M.statePath(old) .. ".renaming"
    os.rename(M.statePath(old), tmp)
    os.rename(tmp, M.statePath(name))
  end
  local s = M.loadSettings()
  s.order = order
  s.shortcuts[name], s.shortcuts[old] = s.shortcuts[old], nil
  M.saveSettings(s)
  return true
end

function M.delete(name)
  os.remove(M.configPath(name))
  M.clearState(name)
  local order = {}
  for _, n in ipairs(M.list()) do if n ~= name then table.insert(order, n) end end
  local s = M.loadSettings()
  s.order = order
  s.shortcuts[name] = nil
  M.saveSettings(s)
end

-- ---- keyboard shortcuts: { [name] = { mods = {"ctrl","shift"}, key = "d" } } ----

function M.shortcuts() return M.loadSettings().shortcuts end

function M.setShortcut(name, shortcut)
  local s = M.loadSettings()
  s.shortcuts[name] = shortcut
  return M.saveSettings(s)
end

-- ---- moving the desktops folder -------------------------------------------------

local function shellQuote(p) return "'" .. p:gsub("'", "'\\''") .. "'" end

-- Move one file or folder; falls back to /bin/mv across disks.
local function move(src, dst)
  if os.rename(src, dst) then return true end
  local _, ok = hs.execute("/bin/mv " .. shellQuote(src) .. " " .. shellQuote(dst))
  return ok
end

local function isDir(p)
  local a = hs.fs.attributes(p)
  return a and a.mode == "directory"
end

-- Move everything to a new folder and use it from now on.
-- Returns true, or nil and a reason (nothing is moved if a check fails).
function M.moveHome(target)
  target = (target or ""):gsub("/+$", "")
  if target == "" then return nil, "No folder chosen." end
  local from = M.home
  if target == from then return true end
  if target:sub(1, #from + 1) == from .. "/" then
    return nil, "The new folder can't be inside the current one."
  end
  hs.fs.mkdir(target)
  if not isDir(target) then return nil, "Couldn't create " .. target end

  -- Refuse rather than overwrite saved desktops already in the target.
  local clashes = {}
  if exists(from) then
    for file in hs.fs.dir(from) do
      if file:match("^[^%.].*%.json$") and exists(target .. "/" .. file) then
        table.insert(clashes, (file:gsub("%.json$", "")))
      end
    end
  end
  if #clashes > 0 then
    table.sort(clashes)
    return nil, "The new folder already has saved desktops with these names: "
      .. table.concat(clashes, ", ") .. ". Move or rename them first."
  end

  local failed = {}
  if exists(from) then
    for file in hs.fs.dir(from) do
      local src, dst = from .. "/" .. file, target .. "/" .. file
      if file == "." or file == ".." then
        -- skip
      elseif file == ".state" or file == ".backup" then
        hs.fs.mkdir(dst)
        for inner in hs.fs.dir(src) do
          if inner ~= "." and inner ~= ".." and not move(src .. "/" .. inner, dst .. "/" .. inner) then
            table.insert(failed, file .. "/" .. inner)
          end
        end
        os.remove(src)
      elseif file:match("%.json$") then
        if not move(src, dst) then table.insert(failed, file) end
      end
    end
  end

  M.home = target
  hs.settings.set(HOME_KEY, target ~= M.defaultHome and target or nil)
  os.remove(from)  -- only succeeds if nothing else was left in it
  if #failed > 0 then
    return nil, "Now using " .. target .. ", but these couldn't be moved: " .. table.concat(failed, ", ")
  end
  return true
end

function M.load(name)
  local cfg = hs.json.read(M.configPath(name))
  if type(cfg) ~= "table" or type(cfg.windows) ~= "table" then
    return nil, "Couldn't read " .. M.configPath(name)
  end
  return cfg
end

-- Keep the previous version before overwriting: ~/.desktops/.backup/<name>.json
function M.backup(name)
  local cfg = M.load(name)
  if not cfg then return end
  ensureDirs()
  hs.fs.mkdir(M.home .. "/.backup")
  hs.json.write(cfg, M.home .. "/.backup/" .. name .. ".json", true, true)
end

function M.save(cfg)
  ensureDirs()
  return hs.json.write(cfg, M.configPath(cfg.name), true, true)
end

-- state = { windows = { {id = 123, index = 1}, ... } }  (index into cfg.windows)
function M.loadState(name)
  local st = exists(M.statePath(name)) and hs.json.read(M.statePath(name)) or nil
  if type(st) ~= "table" then st = {} end
  st.windows = st.windows or {}
  return st
end

-- When this Mac last started up. Window IDs start over after a restart, so
-- state saved before then describes windows that no longer exist.
local bootTime
function M.bootTime()
  if not bootTime then
    local out = hs.execute("/usr/sbin/sysctl -n kern.boottime") or ""
    bootTime = tonumber(out:match("sec = (%d+)")) or 0
  end
  return bootTime
end

function M.saveState(name, st)
  ensureDirs()
  if #st.windows == 0 then return M.clearState(name) end
  st.boot = M.bootTime()
  return hs.json.write(st, M.statePath(name), true, true)
end

function M.clearState(name)
  os.remove(M.statePath(name))
end

return M
