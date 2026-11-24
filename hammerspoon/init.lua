-- Lets the `hs` command-line tool talk to Hammerspoon.
require("hs.ipc")

-- Desktops menu bar tool (linked from ~/projects/desktop-spaces/hammerspoon/desktops)
local ok, err = pcall(function()
  desktops = require("desktops")
  desktops.start()
end)
if not ok then
  print("Desktops failed to load: " .. tostring(err))
  hs.alert.show("Desktops failed to load — see Hammerspoon console")
end
