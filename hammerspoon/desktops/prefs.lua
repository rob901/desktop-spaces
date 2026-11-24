-- Preferences window: rename, reorder and delete saved desktops.
local store = require("desktops.store")

local M = {}
local view, content

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local CSS = [[
:root { color-scheme: light dark; }
body { font: 13px -apple-system, system-ui; margin: 0; padding: 16px 18px; }
h1 { font-size: 15px; margin: 0 0 4px; }
p.hint { margin: 0 0 12px; opacity: .65; }
ul { list-style: none; margin: 0; padding: 0; border: 1px solid rgba(128,128,128,.35); border-radius: 8px; overflow: hidden; }
li { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-bottom: 1px solid rgba(128,128,128,.2); background: Canvas; cursor: grab; }
li:last-child { border-bottom: none; }
li.over { box-shadow: inset 0 2px 0 AccentColor; }
li.editing { cursor: default; }
.grip { font-size: 20px; line-height: 1; opacity: .5; padding: 0 2px 0 0; user-select: none; }
.num { width: 18px; text-align: right; opacity: .5; font-variant-numeric: tabular-nums; }
input { flex: 1; font: inherit; padding: 3px 6px; border: 1px solid transparent; border-radius: 5px; background: transparent; color: inherit; cursor: inherit; user-select: none; }
input:read-only { pointer-events: none; }
input:not(:read-only) { border-color: AccentColor; outline: none; background: Field; cursor: text; user-select: text; }
.open { font-size: 11px; opacity: .6; }
button { font: inherit; border: 1px solid rgba(128,128,128,.35); background: ButtonFace; color: ButtonText; border-radius: 5px; padding: 1px 9px; cursor: pointer; min-width: 52px; }
button.del { color: #d33; }
.empty { padding: 14px; opacity: .6; cursor: default; }
]]

local JS = [[
function send(msg) { webkit.messageHandlers.prefs.postMessage(msg); }

function startEdit(li) {
  var input = li.querySelector('input'), btn = li.querySelector('button.edit');
  li.classList.add('editing'); li.draggable = false;
  input.readOnly = false; input.focus(); input.select();
  btn.textContent = 'Save';
}
function finishEdit(li, save) {
  var input = li.querySelector('input'), btn = li.querySelector('button.edit');
  if (input.readOnly) return;
  input.readOnly = true; li.classList.remove('editing'); li.draggable = true;
  btn.textContent = 'Edit';
  if (save && input.value.trim() !== input.dataset.name) {
    send({action: 'rename', name: input.dataset.name, to: input.value});
  } else {
    input.value = input.dataset.name;
  }
}

document.querySelectorAll('li[data-name]').forEach(function (li) {
  var input = li.querySelector('input'), btn = li.querySelector('button.edit');
  // mousedown keeps the input's blur from firing before the click is handled
  btn.addEventListener('mousedown', function (e) { e.preventDefault(); });
  btn.addEventListener('click', function () { input.readOnly ? startEdit(li) : finishEdit(li, true); });
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); finishEdit(li, true); }
    if (e.key === 'Escape') { e.preventDefault(); finishEdit(li, false); }
  });
  input.addEventListener('blur', function () { finishEdit(li, true); });
});

var dragged = null;
document.querySelectorAll('li[data-name]').forEach(function (li) {
  li.addEventListener('dragstart', function (e) { dragged = li; e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', li.dataset.name); });
  li.addEventListener('dragover', function (e) { e.preventDefault(); li.classList.add('over'); });
  li.addEventListener('dragleave', function () { li.classList.remove('over'); });
  li.addEventListener('drop', function (e) {
    e.preventDefault(); li.classList.remove('over');
    if (!dragged || dragged === li) return;
    li.parentNode.insertBefore(dragged, li);
    send({action: 'order', names: Array.from(document.querySelectorAll('li[data-name]')).map(function (x) { return x.dataset.name; })});
  });
});
]]

local function render(isOpen)
  local names = store.list()
  local rows = {}
  for i, name in ipairs(names) do
    local n = esc(name)
    table.insert(rows, string.format([[
<li data-name="%s" draggable="true" title="Drag to reorder">
  <span class="grip">⠿</span>
  <span class="num">%d</span>
  <input value="%s" data-name="%s" readonly spellcheck="false">
  %s
  <button class="edit" title="Rename">Edit</button>
  <button class="del" onclick="send({action:'delete', name:this.closest('li').dataset.name})" title="Delete">Delete</button>
</li>]], n, i, n, n, isOpen(name) and '<span class="open">open</span>' or ""))
  end
  local list = #rows > 0 and ("<ul>" .. table.concat(rows) .. "</ul>")
    or '<ul><li class="empty">No saved desktops yet. Use “Save current desktop…” in the menu.</li></ul>'
  return "<!doctype html><html><head><meta charset='utf-8'><style>" .. CSS .. "</style></head><body>"
    .. "<h1>Saved desktops</h1><p class='hint'>Drag rows to set the menu order. Click Edit to rename (Enter saves, Esc cancels).</p>"
    .. list .. "<script>" .. JS .. "</script></body></html>"
end

local function handle(msg, isOpen, onChange)
  local b = msg.body or {}
  if b.action == "rename" then
    local ok, err = store.rename(b.name, b.to or "")
    if not ok then hs.dialog.blockAlert("Can't rename “" .. b.name .. "”", err) end
  elseif b.action == "order" and type(b.names) == "table" then
    store.setOrder(b.names)
  elseif b.action == "delete" then
    local extra = isOpen(b.name) and "\n\nIts windows stay open; they just won't be tracked as this desktop any more." or ""
    local choice = hs.dialog.blockAlert("Delete “" .. b.name .. "”?",
      "This removes the saved desktop. It can't be undone." .. extra, "Delete", "Cancel")
    if choice == "Delete" then store.delete(b.name) end
  end
  if onChange then onChange() end
  if view then view:html(render(isOpen)) end
end

-- isOpen(name) -> bool; onChange() is called after any edit.
function M.show(isOpen, onChange)
  if view then
    view:html(render(isOpen))
    view:show()
    hs.focus()
    if view:hswindow() then view:hswindow():focus() end
    return
  end
  content = hs.webview.usercontent.new("prefs")
  content:setCallback(function(msg) handle(msg, isOpen, onChange) end)
  local screen = hs.screen.mainScreen():frame()
  local w, h = 520, 420
  view = hs.webview.new({ x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 3, w = w, h = h },
    { developerExtrasEnabled = false }, content)
  view:windowTitle("Desktops — Preferences")
    :windowStyle({ "titled", "closable", "resizable" })
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.normal)
    :deleteOnClose(true)
    :windowCallback(function(action) if action == "closing" then view, content = nil, nil end end)
    :html(render(isOpen))
    :show()
  hs.focus()
  if view:hswindow() then view:hswindow():focus() end
end

return M
