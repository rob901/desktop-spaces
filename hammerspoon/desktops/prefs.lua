-- Preferences window: a macOS-style sidebar with Saved Desktops, Keyboard
-- Shortcuts, Desktops Folder and About pages.
local store = require("desktops.store")

local M = {}
M.version = "0.3"
M.repoURL = "https://github.com/rob901/desktop-spaces"

local view, content
local page = "desktops"
local flash = nil        -- { page=, name=, text=, kind="error"|"ok" } shown once
local ctx = {}           -- { isOpen = fn, onChange = fn, pause = fn(bool) }

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- ---- shortcuts ---------------------------------------------------------------------

local MOD_ORDER = { { "ctrl", "⌃" }, { "alt", "⌥" }, { "shift", "⇧" }, { "cmd", "⌘" } }

function M.formatShortcut(sc)
  if type(sc) ~= "table" or not sc.key then return nil end
  local has, out = {}, ""
  for _, m in ipairs(sc.mods or {}) do has[m] = true end
  for _, pair in ipairs(MOD_ORDER) do
    if has[pair[1]] then out = out .. pair[2] end
  end
  return out .. sc.key:upper()
end

-- Check a recorded shortcut. Returns the cleaned shortcut or nil + reason.
local function checkShortcut(name, mods, key)
  if type(mods) ~= "table" or type(key) ~= "string" then return nil, "That shortcut couldn't be read." end
  local has, clean = {}, {}
  for _, m in ipairs(mods) do has[m] = true end
  for _, pair in ipairs(MOD_ORDER) do
    if has[pair[1]] then table.insert(clean, pair[1]) end
  end
  if not has.ctrl or #clean < 2 then
    return nil, "Use ⌃ Control plus ⇧ Shift, ⌥ Option or ⌘ Command, then a letter, number or F-key."
  end
  local sc = { mods = clean, key = key }
  local label = M.formatShortcut(sc)
  if hs.hotkey.systemAssigned(clean, key) then
    return nil, label .. " is already used by macOS. Try another key."
  end
  for other, existing in pairs(store.shortcuts()) do
    if other ~= name and M.formatShortcut(existing) == label then
      return nil, label .. " is already set for “" .. other .. "”."
    end
  end
  if not hs.hotkey.assignable(clean, key) then
    return nil, label .. " is taken by another app or by macOS. Try another key."
  end
  return sc
end

-- ---- look --------------------------------------------------------------------------

local CSS = [==[
:root {
  color-scheme: light dark;
  --window: #ececec; --sidebar: #e3e3e3; --card: #ffffff; --line: rgba(0,0,0,.09);
  --text: #1d1d1f; --dim: rgba(0,0,0,.5); --sel: #0a63d6; --accent: #0a7aff; --danger: #e5383b;
  --field: #ffffff; --chip: rgba(0,0,0,.05);
}
@media (prefers-color-scheme: dark) {
  :root {
    --window: #1e1e1e; --sidebar: #262626; --card: #2c2c2e; --line: rgba(255,255,255,.08);
    --text: #f5f5f7; --dim: rgba(255,255,255,.5); --sel: #0a58ca; --accent: #2f8cff; --danger: #ff5a5f;
    --field: #1c1c1e; --chip: rgba(255,255,255,.07);
  }
}
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body { font: 13px -apple-system, BlinkMacSystemFont, system-ui; color: var(--text); background: var(--window);
       display: flex; overflow: hidden; -webkit-user-select: none; cursor: default; }

nav { width: 200px; flex: none; background: var(--sidebar); border-right: 1px solid var(--line); padding: 14px 10px; }
nav .item { display: flex; align-items: center; gap: 9px; padding: 5px 8px; border-radius: 6px; margin-bottom: 2px; }
nav .item.sel { background: var(--sel); color: #fff; }
.icon { width: 22px; height: 22px; border-radius: 6px; display: grid; place-items: center; flex: none; }
.icon svg { width: 14px; height: 14px; stroke: #fff; fill: none; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }

main { flex: 1; overflow-y: auto; padding: 22px 28px 28px; }
section { display: none; }
section.sel { display: block; }
h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; letter-spacing: -.2px; }
p.sub { margin: 0 0 18px; color: var(--dim); line-height: 1.4; }
h2 { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .4px; color: var(--dim); margin: 22px 4px 6px; }

.card { background: var(--card); border-radius: 10px; border: 1px solid var(--line); overflow: hidden; }
.row { display: flex; align-items: center; gap: 10px; min-height: 42px; padding: 6px 12px; position: relative; }
.row + .row::before { content: ""; position: absolute; top: 0; left: 12px; right: 0; border-top: 1px solid var(--line); }
.row .grow { flex: 1; min-width: 0; }
.row .label { font-weight: 500; }
.row .note { color: var(--dim); font-size: 12px; }
.empty { padding: 16px; color: var(--dim); }

.badge { font-size: 11px; padding: 1px 7px; border-radius: 9px; background: var(--chip); color: var(--dim); }
.badge.open { background: rgba(52,199,89,.18); color: #28a745; }

button { font: inherit; font-size: 12.5px; border: 1px solid var(--line); background: var(--chip); color: var(--text);
         border-radius: 6px; padding: 3px 11px; min-width: 56px; }
button:active { filter: brightness(.92); }
button.primary { background: var(--accent); color: #fff; border-color: transparent; }
button.danger { color: var(--danger); }

/* saved desktops */
.grip { font-size: 18px; line-height: 1; color: var(--dim); padding-right: 2px; cursor: grab; }
#desktop-list .row { cursor: grab; }
#desktop-list .row.editing { cursor: default; }
#desktop-list .row.over { box-shadow: inset 0 2px 0 var(--accent); }
input.name { flex: 1; min-width: 0; font: inherit; font-weight: 500; color: inherit; background: transparent;
             border: 1px solid transparent; border-radius: 5px; padding: 3px 6px; margin-left: -6px; pointer-events: none; }
input.name:not([readonly]) { pointer-events: auto; background: var(--field); border-color: var(--accent);
             outline: 3px solid rgba(10,122,255,.25); -webkit-user-select: text; cursor: text; }

/* shortcut recorder */
.recorder { display: inline-flex; align-items: center; justify-content: center; gap: 6px; width: 150px; height: 26px;
            border-radius: 6px; border: 1px solid var(--line); background: var(--field); font-size: 12.5px; position: relative; }
.recorder .text { color: var(--dim); }
.recorder.set .text { color: var(--text); font-weight: 500; letter-spacing: 1.5px; }
.recorder.rec { border-color: var(--accent); outline: 3px solid rgba(10,122,255,.25); }
.recorder.rec .text { color: var(--accent); }
.recorder .clear { position: absolute; right: 6px; width: 15px; height: 15px; border-radius: 50%; background: var(--dim);
                   color: var(--card); font-size: 10px; line-height: 15px; text-align: center; }
.msg { font-size: 12px; margin-top: 3px; }
.msg.error { color: var(--danger); }
.msg.ok { color: #28a745; }
.banner { display: flex; gap: 10px; align-items: flex-start; padding: 10px 12px; border-radius: 10px; margin-bottom: 16px;
          background: rgba(255,159,10,.13); border: 1px solid rgba(255,159,10,.35); line-height: 1.4; }
.banner b { font-weight: 600; }
.keys { color: var(--dim); line-height: 1.6; padding: 10px 12px; }
kbd { font: 12px -apple-system; padding: 1px 5px; border-radius: 4px; border: 1px solid var(--line); background: var(--chip); }

/* folder */
.path { font: 12px ui-monospace, Menlo, monospace; word-break: break-all; -webkit-user-select: text; cursor: text; }
.buttons { display: flex; gap: 8px; padding: 10px 12px; }

/* about */
.about { text-align: center; padding-top: 30px; }
.about .appicon { width: 84px; height: 84px; border-radius: 20px; margin: 0 auto 14px; display: grid; place-items: center;
                  background: linear-gradient(160deg, #3b9bff, #0a5fd6); box-shadow: 0 6px 18px rgba(10,95,214,.35); }
.about .appicon svg { width: 48px; height: 48px; stroke: #fff; fill: none; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
.about h1 { font-size: 22px; }
.about .version { color: var(--dim); margin-bottom: 14px; }
.about p { max-width: 380px; margin: 0 auto 18px; line-height: 1.45; color: var(--dim); }
a { color: var(--accent); text-decoration: none; cursor: pointer; }
a:hover { text-decoration: underline; }
]==]

local ICONS = {
  desktops = '<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="9" rx="1.5"/><path d="M8 11.5v2.5M5 14h6"/></svg>',
  shortcuts = '<svg viewBox="0 0 16 16"><rect x="1" y="4" width="14" height="8.5" rx="1.5"/><path d="M4 7h.01M6.5 7h.01M9 7h.01M11.5 7h.01M5 10h6"/></svg>',
  folder = '<svg viewBox="0 0 16 16"><path d="M1.5 4.5a1 1 0 0 1 1-1h3.3l1.5 1.5h6.2a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z"/></svg>',
  about = '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.5"/><path d="M8 7.2v4M8 4.8h.01"/></svg>',
}
local PAGES = {
  { id = "desktops", title = "Saved Desktops", color = "#0a7aff" },
  { id = "shortcuts", title = "Keyboard Shortcuts", color = "#8e8e93" },
  { id = "folder", title = "Desktops Folder", color = "#30b0e8" },
  { id = "about", title = "About", color = "#8e8e93" },
}

-- ---- behavior (runs in the page) -----------------------------------------------------

local JS = [==[
function send(msg) { webkit.messageHandlers.prefs.postMessage(msg); }

// sidebar
document.querySelectorAll('nav .item').forEach(function (item) {
  item.addEventListener('click', function () {
    document.querySelectorAll('nav .item, main section').forEach(function (el) { el.classList.remove('sel'); });
    item.classList.add('sel');
    document.getElementById('page-' + item.dataset.page).classList.add('sel');
    stopRec();
    send({action: 'page', page: item.dataset.page});
  });
});
document.querySelectorAll('a[data-url]').forEach(function (a) {
  a.addEventListener('click', function (e) { e.preventDefault(); send({action: 'link', url: a.dataset.url}); });
});

// saved desktops: rename
function startEdit(row) {
  var input = row.querySelector('input.name'), btn = row.querySelector('button.edit');
  row.classList.add('editing'); row.draggable = false;
  input.readOnly = false; input.focus(); input.select();
  btn.textContent = 'Save'; btn.classList.add('primary');
}
function finishEdit(row, save) {
  var input = row.querySelector('input.name'), btn = row.querySelector('button.edit');
  if (input.readOnly) return;
  input.readOnly = true; row.classList.remove('editing'); row.draggable = true;
  btn.textContent = 'Edit'; btn.classList.remove('primary');
  if (save && input.value.trim() !== input.dataset.name) send({action: 'rename', name: input.dataset.name, to: input.value});
  else input.value = input.dataset.name;
}
document.querySelectorAll('#desktop-list .row[data-name]').forEach(function (row) {
  var input = row.querySelector('input.name'), btn = row.querySelector('button.edit');
  btn.addEventListener('mousedown', function (e) { e.preventDefault(); });
  btn.addEventListener('click', function () { input.readOnly ? startEdit(row) : finishEdit(row, true); });
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); finishEdit(row, true); }
    if (e.key === 'Escape') { e.preventDefault(); finishEdit(row, false); }
  });
  input.addEventListener('blur', function () { finishEdit(row, true); });
  row.querySelector('button.del').addEventListener('click', function () { send({action: 'delete', name: row.dataset.name}); });
});

// saved desktops: drag to reorder
var dragged = null;
document.querySelectorAll('#desktop-list .row[data-name]').forEach(function (row) {
  row.addEventListener('dragstart', function (e) { dragged = row; e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', row.dataset.name); });
  row.addEventListener('dragover', function (e) { e.preventDefault(); row.classList.add('over'); });
  row.addEventListener('dragleave', function () { row.classList.remove('over'); });
  row.addEventListener('drop', function (e) {
    e.preventDefault(); row.classList.remove('over');
    if (!dragged || dragged === row) return;
    row.parentNode.insertBefore(dragged, row);
    send({action: 'order', names: Array.from(document.querySelectorAll('#desktop-list .row[data-name]')).map(function (x) { return x.dataset.name; })});
  });
});

// keyboard shortcuts: recorder
var recording = null;
var SYMBOLS = [['ctrlKey', '⌃'], ['altKey', '⌥'], ['shiftKey', '⇧'], ['metaKey', '⌘']];
function held(e) { return SYMBOLS.filter(function (p) { return e[p[0]]; }).map(function (p) { return p[1]; }).join(''); }
function setText(rec, text) { rec.querySelector('.text').textContent = text; }
function startRec(rec) {
  stopRec(); recording = rec;
  rec.classList.add('rec'); setText(rec, 'Type shortcut…');
  send({action: 'recording', on: true});
}
function stopRec() {
  if (!recording) return;
  recording.classList.remove('rec');
  setText(recording, recording.dataset.display || 'Record Shortcut');
  recording = null;
  send({action: 'recording', on: false});
}
function keyName(code) {
  var m;
  if ((m = /^Key([A-Z])$/.exec(code))) return m[1].toLowerCase();
  if ((m = /^Digit([0-9])$/.exec(code))) return m[1];
  if ((m = /^F([0-9]{1,2})$/.exec(code))) return 'f' + m[1];
  return null;
}
function showMsg(rec, text) {
  var msg = rec.closest('.row').querySelector('.msg');
  msg.className = 'msg error'; msg.textContent = text;
}
document.querySelectorAll('.recorder').forEach(function (rec) {
  rec.addEventListener('click', function (e) {
    if (e.target.classList.contains('clear')) { send({action: 'clearShortcut', name: rec.dataset.name}); return; }
    recording === rec ? stopRec() : startRec(rec);
  });
});
document.addEventListener('mousedown', function (e) { if (recording && !e.target.closest('.recorder')) stopRec(); });
document.addEventListener('keydown', function (e) {
  if (!recording) return;
  e.preventDefault(); e.stopPropagation();
  var mods = held(e);
  if (e.key === 'Escape' && !mods) { stopRec(); return; }
  if ((e.key === 'Backspace' || e.key === 'Delete') && !mods) { send({action: 'clearShortcut', name: recording.dataset.name}); return; }
  var key = keyName(e.code);
  if (!key) { setText(recording, (mods || '') + '…'); return; }   // only modifiers so far
  if (!e.ctrlKey || mods.length < 2) {
    showMsg(recording, 'Use ⌃ Control plus ⇧ Shift, ⌥ Option or ⌘ Command, then a letter, number or F-key.');
    setText(recording, 'Type shortcut…');
    return;
  }
  var list = [];
  if (e.ctrlKey) list.push('ctrl'); if (e.altKey) list.push('alt'); if (e.shiftKey) list.push('shift'); if (e.metaKey) list.push('cmd');
  send({action: 'shortcut', name: recording.dataset.name, mods: list, key: key});
}, true);
document.addEventListener('keyup', function (e) {
  if (recording) { var mods = held(e); setText(recording, mods ? mods + '…' : 'Type shortcut…'); }
}, true);

// folder
document.querySelectorAll('[data-action]').forEach(function (b) {
  b.addEventListener('click', function () { send({action: b.dataset.action}); });
});
]==]

-- ---- pages ---------------------------------------------------------------------------

local function flashFor(pageId, name)
  if flash and flash.page == pageId and flash.name == name then
    return string.format('<div class="msg %s">%s</div>', flash.kind or "error", esc(flash.text))
  end
  return name and '<div class="msg"></div>' or ""
end

local function desktopsPage(names)
  local rows = {}
  for _, name in ipairs(names) do
    local n = esc(name)
    local open = ctx.isOpen and ctx.isOpen(name)
    table.insert(rows, string.format([[
<div class="row" data-name="%s" draggable="true" title="Drag to reorder">
  <span class="grip">⠿</span>
  <input class="name" value="%s" data-name="%s" readonly spellcheck="false">
  %s
  <button class="edit">Edit</button>
  <button class="del danger">Delete</button>
</div>]], n, n, n, open and '<span class="badge open">Open</span>' or ""))
  end
  local list = #rows > 0 and table.concat(rows)
    or '<div class="empty">No saved desktops yet. Use “Save current desktop…” in the menu bar.</div>'
  return [[<h1>Saved Desktops</h1>
<p class="sub">Drag to set the order they appear in the menu. Edit renames a desktop; Delete removes the saved copy (open windows stay open).</p>
<div class="card" id="desktop-list">]] .. list .. "</div>" .. flashFor("desktops", "*")
end

local function shortcutsPage(names)
  local shortcuts = store.shortcuts()
  local rows = {}
  for _, name in ipairs(names) do
    local display = M.formatShortcut(shortcuts[name])
    table.insert(rows, string.format([[
<div class="row">
  <div class="grow"><div class="label">%s</div>%s</div>
  <div class="recorder%s" data-name="%s" data-display="%s" title="Click, then press the keys">
    <span class="text">%s</span>%s
  </div>
</div>]], esc(name), flashFor("shortcuts", name), display and " set" or "", esc(name), esc(display or ""),
      esc(display or "Record Shortcut"), display and '<span class="clear" title="Clear">✕</span>' or ""))
  end
  local list = #rows > 0 and table.concat(rows)
    or '<div class="empty">Save a desktop first, then give it a shortcut here.</div>'
  return [[<h1>Keyboard Shortcuts</h1>
<p class="sub">Press a desktop's shortcut to jump to it. If it isn't open yet, it opens on the desktop you're on.</p>
<div class="card">]] .. list .. [[</div>
<h2>Recording</h2>
<div class="card"><div class="keys">
Click a box, then press <kbd>⌃ Control</kbd> + <kbd>⇧ Shift</kbd> (or <kbd>⌥ Option</kbd> / <kbd>⌘ Command</kbd>) and a letter, number or F-key.<br>
<kbd>esc</kbd> cancels · <kbd>delete</kbd> clears · shortcuts macOS or other apps already use are refused.<br>
Your shortcuts pause while you record, so you can re-record one you already use.
</div></div>]]
end

local function folderPage()
  local isDefault = store.home == store.defaultHome
  return [[<h1>Desktops Folder</h1>
<p class="sub">Where saved desktops, their backups and these settings are stored. Choosing a new folder moves everything there.</p>
<div class="card">
  <div class="row"><div class="grow"><div class="note">Location</div><div class="path">]] .. esc(store.home) .. [[</div></div>
  ]] .. (isDefault and '<span class="badge">Default</span>' or "") .. [[</div>
  <div class="buttons">
    <button class="primary" data-action="chooseFolder">Change…</button>
    <button data-action="revealFolder">Show in Finder</button>
    ]] .. (isDefault and "" or '<button data-action="defaultFolder">Use Default</button>') .. [[
  </div>
</div>]] .. flashFor("folder", "*")
end

local function aboutPage()
  return [[<div class="about">
  <div class="appicon">]] .. ICONS.desktops .. [[</div>
  <h1>Desktops</h1>
  <div class="version">Version ]] .. M.version .. [[</div>
  <p>Save the windows on a macOS desktop and bring them back later at the same sizes. Close a desktop to quit the apps nothing else is using.</p>
  <p><a data-url="]] .. M.repoURL .. [[">github.com/rob901/desktop-spaces</a></p>
  <p style="font-size:12px">Runs on <a data-url="https://www.hammerspoon.org">Hammerspoon</a>.</p>
</div>]]
end

local function render()
  local names = store.list()
  local nav, sections = {}, {}
  local bodies = { desktops = desktopsPage(names), shortcuts = shortcutsPage(names),
                   folder = folderPage(), about = aboutPage() }
  for _, p in ipairs(PAGES) do
    local sel = p.id == page and " sel" or ""
    table.insert(nav, string.format('<div class="item%s" data-page="%s"><span class="icon" style="background:%s">%s</span>%s</div>',
      sel, p.id, p.color, ICONS[p.id], p.title))
    table.insert(sections, string.format('<section id="page-%s" class="%s">%s</section>', p.id, sel, bodies[p.id]))
  end
  flash = nil
  return "<!doctype html><html><head><meta charset='utf-8'><style>" .. CSS .. "</style></head><body>"
    .. "<nav>" .. table.concat(nav) .. "</nav><main>" .. table.concat(sections) .. "</main>"
    .. "<script>" .. JS .. "</script></body></html>"
end

local function refresh() if view then view:html(render()) end end

-- ---- messages from the page ------------------------------------------------------------

local function chooseFolder()
  local picked = hs.dialog.chooseFileOrFolder("Choose a folder for your saved desktops",
    store.home, false, true, false)
  local path = picked and (picked["1"] or picked[1])
  if not path then return end
  path = path:gsub("^file://", "")
  local ok, err = store.moveHome(path)
  flash = { page = "folder", name = "*", kind = ok and "ok" or "error",
            text = ok and ("Moved to " .. store.home) or err }
end

local function handle(msg)
  local b = msg.body or {}
  local changed = true
  if b.action == "page" then
    page = b.page
    return
  elseif b.action == "recording" then
    if ctx.pause then ctx.pause(b.on == true) end
    return
  elseif b.action == "link" and type(b.url) == "string" and b.url:match("^https://") then
    hs.urlevent.openURL(b.url)
    return
  elseif b.action == "rename" then
    local ok, err = store.rename(b.name, b.to or "")
    if not ok then flash = { page = "desktops", name = "*", text = "Can't rename “" .. b.name .. "”: " .. err } end
  elseif b.action == "order" and type(b.names) == "table" then
    store.setOrder(b.names)
    changed = false
  elseif b.action == "delete" then
    local extra = ctx.isOpen and ctx.isOpen(b.name)
      and "\n\nIts windows stay open; they just won't be tracked as this desktop any more." or ""
    local choice = hs.dialog.blockAlert("Delete “" .. b.name .. "”?",
      "This removes the saved desktop. It can't be undone." .. extra, "Delete", "Cancel")
    if choice == "Delete" then store.delete(b.name) end
  elseif b.action == "shortcut" then
    local sc, err = checkShortcut(b.name, b.mods, b.key)
    if sc then
      store.setShortcut(b.name, sc)
    else
      flash = { page = "shortcuts", name = b.name, text = err }
    end
  elseif b.action == "clearShortcut" then
    store.setShortcut(b.name, nil)
  elseif b.action == "chooseFolder" then
    chooseFolder()
  elseif b.action == "revealFolder" then
    hs.fs.mkdir(store.home)
    hs.task.new("/usr/bin/open", nil, { store.home }):start()
    return
  elseif b.action == "defaultFolder" then
    local ok, err = store.moveHome(store.defaultHome)
    flash = { page = "folder", name = "*", kind = ok and "ok" or "error",
              text = ok and ("Moved back to " .. store.home) or err }
  end
  if changed and ctx.onChange then ctx.onChange() end
  refresh()
end

-- isOpen(name) -> bool; onChange() is called after any edit (it re-registers
-- shortcuts); pause(bool) pauses them while one is being recorded.
function M.show(isOpen, onChange, pause)
  ctx = { isOpen = isOpen, onChange = onChange, pause = pause }
  if view then
    refresh()
    view:show()
    hs.focus()
    if view:hswindow() then view:hswindow():focus() end
    return
  end
  content = hs.webview.usercontent.new("prefs")
  content:setCallback(handle)
  local screen = hs.screen.mainScreen():frame()
  local w, h = 780, 540
  view = hs.webview.new({ x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 3, w = w, h = h },
    { developerExtrasEnabled = false }, content)
  view:windowTitle("Desktops Preferences")
    :windowStyle({ "titled", "closable", "miniaturizable", "resizable" })
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.normal)
    :deleteOnClose(true)
    :windowCallback(function(action)
      if action == "closing" then
        view, content = nil, nil
        if ctx.pause then ctx.pause(false) end
      end
    end)
    :html(render())
    :show()
  hs.focus()
  if view:hswindow() then view:hswindow():focus() end
end

M._checkShortcut = checkShortcut
M._render = render
return M
