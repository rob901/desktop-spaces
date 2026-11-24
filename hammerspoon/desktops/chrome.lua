-- Chrome: tab capture (AppleScript), profile names (Local State), launch args.
local M = {}

M.bundleID = "com.google.Chrome"
local LOCAL_STATE = os.getenv("HOME") .. "/Library/Application Support/Google/Chrome/Local State"

-- Every Chrome window (all desktops): { {title=, bounds={l,t,r,b}, urls={...}}, ... }
local CAPTURE = [[
if application "Google Chrome" is not running then return {}
tell application "Google Chrome"
  set out to {}
  repeat with w in windows
    if mode of w is "normal" then
      set end of out to {name of w, bounds of w, URL of tabs of w}
    end if
  end repeat
  return out
end tell
]]

function M.capture()
  local ok, result, raw = hs.osascript.applescript(CAPTURE)
  if not ok then
    return nil, "Couldn't read Chrome tabs. Allow Hammerspoon to control Chrome in System Settings → Privacy & Security → Automation. (" .. hs.inspect(raw) .. ")"
  end
  local out = {}
  for _, w in ipairs(result or {}) do
    local urls = w[3]
    if type(urls) ~= "table" then urls = { urls } end
    table.insert(out, { title = w[1], bounds = w[2], urls = urls })
  end
  return out
end

-- Pair each Hammerspoon Chrome window with a captured Chrome window.
-- Bounds identify a window best; the title breaks ties. Each capture is used once.
function M.match(hsWindows, captured)
  local result, used = {}, {}
  local function sameBounds(f, b)
    return b and math.abs(f.x - b[1]) <= 2 and math.abs(f.y - b[2]) <= 2
      and math.abs(f.x + f.w - b[3]) <= 2 and math.abs(f.y + f.h - b[4]) <= 2
  end
  local passes = {
    function(w, c) return sameBounds(w:frame(), c.bounds) and w:title() == c.title end,
    function(w, c) return sameBounds(w:frame(), c.bounds) end,
    function(w, c) return w:title() == c.title end,
  }
  for _, pass in ipairs(passes) do
    for i, w in ipairs(hsWindows) do
      if not result[i] then
        for j, c in ipairs(captured) do
          if not used[j] and pass(w, c) then
            result[i], used[j] = c, true
            break
          end
        end
      end
    end
  end
  return result
end

-- { ["Profile 2"] = "Work", ... }
function M.profiles()
  local data = hs.json.read(LOCAL_STATE)
  local out = {}
  local cache = data and data.profile and data.profile.info_cache or {}
  for folder, info in pairs(cache) do out[folder] = info.name or folder end
  return out
end

-- Best effort: find the profile name in the window title or in the
-- toolbar's profile button. Returns folder, displayName (or nil).
function M.detectProfile(win, profiles)
  local count, only = 0, nil
  for folder in pairs(profiles) do count, only = count + 1, folder end
  if count == 1 then return only, profiles[only] end

  local function pick(text)
    if type(text) ~= "string" or text == "" then return nil end
    local best
    for folder, name in pairs(profiles) do
      if name ~= "" and text:find(name, 1, true) then
        if not best or #name > #profiles[best] then best = folder end
      end
    end
    return best
  end

  local folder = pick(win:title():match(" %- Google Chrome %- (.+)$"))
  if folder then return folder, profiles[folder] end

  -- The avatar button in the toolbar names the profile, e.g. "Work" or "Rob (Work)".
  local ax = hs.axuielement.windowElement(win)
  local found
  local function walk(el, depth)
    if found or depth > 7 or not el then return end
    local role = el:attributeValue("AXRole")
    if role == "AXButton" or role == "AXPopUpButton" then
      for _, attr in ipairs({ "AXDescription", "AXTitle", "AXHelp" }) do
        local f = pick(el:attributeValue(attr))
        if f then found = f return end
      end
    end
    for _, child in ipairs(el:attributeValue("AXChildren") or {}) do walk(child, depth + 1) end
  end
  if ax then walk(ax, 0) end
  if found then return found, profiles[found] end
  return nil
end

function M.launchArgs(profile, urls)
  local args = { "-na", "Google Chrome", "--args" }
  if profile then table.insert(args, "--profile-directory=" .. profile) end
  table.insert(args, "--new-window")
  for _, u in ipairs(urls or {}) do table.insert(args, u) end
  return args
end

return M
