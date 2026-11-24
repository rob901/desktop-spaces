#!/bin/sh
# Install the Desktops menu bar tool into Hammerspoon.
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"
HS="$HOME/.hammerspoon"

if [ ! -d /Applications/Hammerspoon.app ]; then
  echo "Hammerspoon isn't installed. Run: brew install --cask hammerspoon" >&2
  exit 1
fi

mkdir -p "$HS"
ln -sfn "$REPO/hammerspoon/desktops" "$HS/desktops"
echo "Linked $HS/desktops -> $REPO/hammerspoon/desktops"

if [ ! -f "$HS/init.lua" ]; then
  cp "$REPO/hammerspoon/init.lua" "$HS/init.lua"
  echo "Created $HS/init.lua"
elif ! grep -q 'require("desktops")' "$HS/init.lua"; then
  printf '\n' >> "$HS/init.lua"
  cat "$REPO/hammerspoon/init.lua" >> "$HS/init.lua"
  echo "Added Desktops to your existing $HS/init.lua"
else
  echo "$HS/init.lua already loads Desktops"
fi

echo "Now reload Hammerspoon (menu bar hammer icon -> Reload Config)."
