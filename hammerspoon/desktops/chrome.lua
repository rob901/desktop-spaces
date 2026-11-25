-- Chrome: profile names (Local State), which profile a window uses, launch args.
-- Tabs aren't saved; a window reopens as a new window in its profile.
local M = {}

M.bundleID = "com.google.Chrome"
local LOCAL_STATE = os.getenv("HOME") .. "/Library/Application Support/Google/Chrome/Local State"

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

-- Without --new-window, Chrome opens the profile the way its Profiles menu
-- does, so the profile's "On startup" pages load. --new-window forces a plain
-- new window: used when URLs are given, or as a fallback when the profile
-- already has a window open and Chrome just brought that one forward.
function M.launchArgs(profile, urls, forceNewWindow)
  local args = { "-na", "Google Chrome", "--args" }
  if profile then table.insert(args, "--profile-directory=" .. profile) end
  if forceNewWindow or (urls and #urls > 0) then table.insert(args, "--new-window") end
  for _, u in ipairs(urls or {}) do table.insert(args, u) end
  return args
end

return M
