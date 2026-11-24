-- Saved desktop configs (~/.desktops/<name>.json) and runtime state
-- (~/.desktops/.state/<name>.json: the window IDs a desktop opened).
local M = {}

M.home = os.getenv("DESKTOPS_HOME") or (os.getenv("HOME") .. "/.desktops")

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
  M.setOrder(order)
  return true
end

function M.delete(name)
  os.remove(M.configPath(name))
  M.clearState(name)
  local order = {}
  for _, n in ipairs(M.list()) do if n ~= name then table.insert(order, n) end end
  M.setOrder(order)
end

function M.load(name)
  local cfg = hs.json.read(M.configPath(name))
  if type(cfg) ~= "table" or type(cfg.windows) ~= "table" then
    return nil, "Couldn't read " .. M.configPath(name)
  end
  return cfg
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

function M.saveState(name, st)
  ensureDirs()
  if #st.windows == 0 then return M.clearState(name) end
  return hs.json.write(st, M.statePath(name), true, true)
end

function M.clearState(name)
  os.remove(M.statePath(name))
end

return M
