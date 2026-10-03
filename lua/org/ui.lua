---@mod org.ui Floating windows and Emacs-style key menus

local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.ui")

--- Open a floating window with `lines`.
---@param lines string[]
---@param opts? { title?: string, footer?: string, width?: integer, height?: integer, enter?: boolean, filetype?: string, modifiable?: boolean, relative?: string, row?: integer, col?: integer, border?: string, cursorline?: boolean }
---@return integer buf, integer win
function M.float(lines, opts)
  opts = opts or {}
  require("org.highlights").ensure()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  local width = opts.width
  if not width then
    width = 20
    for _, l in ipairs(lines) do
      width = math.max(width, utils.width(l) + 2)
    end
  end
  -- the title and footer sit in the border, padded by a space on each side:
  -- a window narrower than them cuts them off, even with an explicit width
  if opts.title then
    width = math.max(width, utils.width(opts.title) + 4)
  end
  if opts.footer then
    width = math.max(width, utils.width(opts.footer) + 4)
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(opts.height or #lines, vim.o.lines - 4)
  height = math.max(height, 1)
  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, {
    relative = opts.relative or "editor",
    width = width,
    height = height,
    row = opts.row or math.floor((vim.o.lines - height) / 2) - 1,
    col = opts.col or math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = opts.border or require("org.config").opts.win_border or "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
    footer = opts.footer and (" " .. opts.footer .. " ") or nil,
    footer_pos = opts.footer and "center" or nil,
    zindex = 60,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = opts.cursorline or false
  vim.bo[buf].modifiable = opts.modifiable or false
  return buf, win
end

---@class org.MenuItem
---@field key? string single char (or multi-char in `from_keys`); none on a heading
---@field label string
---@field value any
---@field items? org.MenuItem[] submenu
---@field heading? boolean non-selectable label row
---@field column? integer 2: shown in a right column, on the previous item's line
---@field state? string|boolean a toggle's value, shown right-aligned ("on" / "off" colored)

--- Build a nested menu tree from items with multi-character keys.
--- An item whose key is a strict prefix of other keys becomes a submenu.
---@param entries org.MenuItem[]
---@return org.MenuItem[]
function M.tree_from_keys(entries)
  local root = {}
  local by_prefix = { [""] = root }
  table.sort(entries, function(a, b)
    if #a.key ~= #b.key then
      return #a.key < #b.key
    end
    return a.key < b.key
  end)
  for _, e in ipairs(entries) do
    local parent_key = e.key:sub(1, -2)
    local list = by_prefix[parent_key]
    if not list then
      -- create an implicit group
      local grp = { key = parent_key:sub(-1), label = parent_key .. "…", items = {} }
      local gp = by_prefix[parent_key:sub(1, -2)] or root
      table.insert(gp, grp)
      by_prefix[parent_key] = grp.items
      list = grp.items
    end
    local item = vim.tbl_extend("force", {}, e, { key = e.key:sub(-1) })
    if item.value == nil and not item.heading then
      item.items = item.items or {}
      by_prefix[e.key] = item.items
    end
    table.insert(list, item)
  end
  return root
end

--- Readable names of keys that don't print as themselves.
local KEY_NAMES = { [" "] = "SPC", ["\t"] = "TAB", ["\r"] = "RET" }

---@param k string
---@return string
local function key_name(k)
  if KEY_NAMES[k] then
    return KEY_NAMES[k]
  end
  local b = k:byte()
  if #k == 1 and b and b < 32 then
    return "C-" .. string.char(b + 96)
  end
  return k
end

--- Highlight of a menu item's state: on / off, else a plain value.
local function state_hl(state)
  local s = tostring(state):lower()
  if s == "on" or s == "yes" then
    return "OrgMenuOn"
  elseif s == "off" or s == "no" or s == "none" then
    return "OrgMenuOff"
  end
  return "OrgMenuValue"
end

--- The lines and highlights ({ row0, col_start, col_end, group }) of a menu
--- level. Each item is one cell: its key, its label, then its state
--- (`state`) or the submenu mark, aligned per column. Items with
--- `column = 2` go right of the previous item. A heading starts a new
--- section, after a blank line unless `compact`.
---@param items org.MenuItem[]
---@param footer? string[]
---@param compact? boolean
---@return string[] lines, table[] hls
function M._menu_lines(items, footer, compact)
  local keyw, labelw, rightw = { 1, 1 }, { 0, 0 }, { 0, 0 }
  for _, it in ipairs(items) do
    if not it.heading then
      local c = it.column == 2 and 2 or 1
      keyw[c] = math.max(keyw[c], utils.width(key_name(it.key)))
      labelw[c] = math.max(labelw[c], utils.width(it.label))
      local right = it.state ~= nil and tostring(it.state) or (it.items and "›" or nil)
      if right then
        rightw[c] = math.max(rightw[c], utils.width(right))
      end
    end
  end
  --- One item as text plus highlights relative to its start.
  local function cell(it, c)
    local key = key_name(it.key)
    local text = utils.pad_right(key, keyw[c]) .. "  " .. it.label
    local hls = { { 0, #key, "OrgMenuKey" } }
    if rightw[c] > 0 then
      text = utils.pad_right(text, keyw[c] + 2 + labelw[c])
      local right, group = nil, nil
      if it.state ~= nil then
        right, group = tostring(it.state), state_hl(it.state)
      elseif it.items then
        right, group = "›", "OrgMenuMore"
      end
      if right then
        local pad = string.rep(" ", 2 + rightw[c] - utils.width(right))
        hls[#hls + 1] = { #text + #pad, #text + #pad + #right, group }
        text = text .. pad .. right
      end
    end
    return text, hls
  end
  -- the right column starts after the widest left item of its section
  local col1w, section = {}, 0
  for _, it in ipairs(items) do
    if it.heading then
      section = section + 1
    elseif it.column ~= 2 then
      local text = cell(it, 1):gsub("%s+$", "")
      col1w[section] = math.max(col1w[section] or 0, utils.width(text))
    end
  end
  section = 0
  local lines, hls = {}, {}
  --- Highlights of the last line, shifted by `offset`.
  local function add(cell_hls, offset)
    for _, h in ipairs(cell_hls) do
      hls[#hls + 1] = { #lines - 1, h[1] + offset, h[2] + offset, h[3] }
    end
  end
  for _, it in ipairs(items) do
    if it.heading then
      section = section + 1
      if not compact and #lines > 0 and lines[#lines] ~= "" then
        lines[#lines + 1] = ""
      end
      if it.label ~= "" then
        lines[#lines + 1] = " " .. it.label
        add({ { 1, 1 + #it.label, "OrgMenuHeading" } }, 0)
      end
    elseif it.column == 2 and #lines > 0 and lines[#lines] ~= "" then
      local text, cell_hls = cell(it, 2)
      local prev = utils.pad_right((lines[#lines]:gsub("%s+$", "")), 2 + (col1w[section] or 0) + 4)
      lines[#lines] = prev .. text
      add(cell_hls, #prev)
    else
      local text, cell_hls = cell(it, it.column == 2 and 2 or 1)
      lines[#lines + 1] = "  " .. text
      add(cell_hls, 2)
    end
  end
  if footer and #footer > 0 then
    lines[#lines + 1] = ""
    for _, f in ipairs(footer) do
      lines[#lines + 1] = f
      add({ { 0, #f, "OrgMenuDesc" } }, 0)
    end
  end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%s+$", "")
  end
  return lines, hls
end

--- Show a key-driven menu and return the selected item's value (or the
--- item when it has no value). Blocks until a key is pressed. <BS> goes
--- back from a submenu, <Esc> quits, and so does `q` unless an entry of
--- the menu shown uses it (a user's TODO keyword, template or command key).
---@param opts { title: string, items: org.MenuItem[], footer?: string[] }
---@return any|nil
function M.menu(opts)
  require("org.highlights").ensure()
  local items = opts.items
  local title = opts.title
  local stack = {}
  local bs = { [vim.keycode("<BS>")] = true, ["\8"] = true, ["\127"] = true }
  while true do
    local lines, hls = M._menu_lines(items, opts.footer)
    if #lines > vim.o.lines - 4 then
      -- too tall for the screen: no blank lines between sections
      lines, hls = M._menu_lines(items, opts.footer, true)
    end
    local width = 36
    for _, l in ipairs(lines) do
      width = math.max(width, utils.width(l) + 2)
    end
    local q_quits = M.q_quits(items)
    local quit = q_quits and "q/Esc quit" or "Esc quit"
    local buf, win = M.float(lines, {
      title = title,
      width = width,
      footer = #stack > 0 and ("BS back · " .. quit) or quit,
    })
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
    vim.cmd("redraw")
    local ch = utils.getchar()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if not ch or (ch == "q" and q_quits) then
      return nil
    end
    local chosen
    for _, it in ipairs(items) do
      if not it.heading and it.key == ch then
        chosen = it
        break
      end
    end
    if not chosen and bs[ch] and #stack > 0 then
      items, title = unpack(table.remove(stack))
    elseif not chosen then
      utils.warn("No menu entry for key: " .. key_name(ch))
      return nil
    elseif chosen.items and chosen.value == nil then
      stack[#stack + 1] = { items, title }
      items = chosen.items
      title = title .. " › " .. chosen.label
    else
      if chosen.value ~= nil then
        return chosen.value
      end
      return chosen
    end
  end
end

--- Whether `q` may quit a menu of `items`: only when no entry uses it as
--- its key, so a user-defined `q` (TODO keyword, capture template, agenda
--- command, …) always selects that entry.
---@param items { key?: string, heading?: any }[]
---@return boolean
function M.q_quits(items)
  for _, it in ipairs(items) do
    if not it.heading and it.key == "q" then
      return false
    end
  end
  return true
end

---@class org.Choice
---@field value string what is returned
---@field label? string shown instead of the value
---@field desc? string shown dimmed right of it

--- Keys that pick a choice directly: digits, then letters the list doesn't
--- use for moving (j k g G), editing (e) or quitting (q).
local CHOICE_KEYS = "123456789abcdfhilmnoprstuvwxyz"

--- Pick one of a fixed set of values from a floating list: j/k (or the
--- arrows) move, <CR> or the key shown on a row picks it, `e` (with
--- `edit`) opens the value at the cursor in the command line for changes,
--- <Esc> cancels. Without a UI, or with `ui.choice_prompt = "input"`, it
--- is `utils.input_complete(prompt, values, default)` (Emacs's
--- completing-read). Returns the value, or nil when cancelled.
---@param opts { prompt: string, title?: string, items: (string|org.Choice)[], default?: string, edit?: boolean }
---@return string|nil
function M.choose(opts)
  local items = {}
  for _, it in ipairs(opts.items) do
    items[#items + 1] = type(it) == "table" and it or { value = it }
  end
  if #items == 0 then
    return nil
  end
  local values = vim.tbl_map(function(it)
    return it.value
  end, items)
  local mode = (require("org.config").opts.ui or {}).choice_prompt
  if mode == "input" or (#vim.api.nvim_list_uis() == 0 and not M._force_float) then
    return utils.input_complete(opts.prompt, values, opts.default)
  end
  local labelw, keyed = 0, math.min(#items, #CHOICE_KEYS)
  for _, it in ipairs(items) do
    labelw = math.max(labelw, utils.width(it.label or it.value))
  end
  local lines, hls = {}, {}
  for i, it in ipairs(items) do
    local key = i <= keyed and CHOICE_KEYS:sub(i, i) or " "
    local line = "  " .. key .. "  " .. utils.pad_right(it.label or it.value, labelw)
    hls[#hls + 1] = { i - 1, 2, 3, "OrgMenuKey" }
    if it.desc then
      hls[#hls + 1] = { i - 1, #line + 3, #line + 3 + #it.desc, "OrgMenuDesc" }
      line = line .. "   " .. it.desc
    end
    lines[i] = line:gsub("%s+$", "")
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, utils.width(l) + 2)
  end
  local footer = "j/k move · ↵ select" .. (opts.edit and " · e edit" or "") .. " · q/Esc cancel"
  local title = opts.title or vim.trim((opts.prompt:gsub("[:%s]+$", "")))
  local buf, win = M.float(lines, {
    title = title,
    footer = footer,
    width = width,
    height = math.min(#lines, vim.o.lines - 6),
    cursorline = true,
  })
  vim.wo[win].winhighlight = "CursorLine:OrgMenuSelected"
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  local row = 1
  for i, it in ipairs(items) do
    if it.value == opts.default then
      row = i
    end
  end
  local down = { j = true, [vim.keycode("<Down>")] = true, [vim.keycode("<C-n>")] = true, ["\t"] = true }
  local up = { k = true, [vim.keycode("<Up>")] = true, [vim.keycode("<C-p>")] = true, [vim.keycode("<S-Tab>")] = true }
  local result, editing
  while true do
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    vim.cmd("redraw")
    local ch = utils.getchar()
    if ch == nil or ch == "q" then
      break
    elseif down[ch] then
      row = row % #items + 1
    elseif up[ch] then
      row = (row - 2) % #items + 1
    elseif ch == "g" then
      row = 1
    elseif ch == "G" then
      row = #items
    elseif ch == "\r" or ch == "\n" then
      result = items[row].value
      break
    elseif ch == "e" and opts.edit then
      editing = true
      break
    else
      local i = CHOICE_KEYS:find(ch, 1, true)
      if #ch == 1 and i and i <= keyed then
        result = items[i].value
        break
      end
    end
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if editing then
    return utils.input_complete(opts.prompt, values, items[row].value)
  end
  return result
end

---@class org.HelpRow
---@field [1]? string|string[] key(s)
---@field [2]? string description
---@field heading? string section title; starts a new section

--- Widest key column; longer key lists continue on the next lines.
local HELP_KEYS_MAX = 34

--- Show a read-only help float listing key → description rows, split into
--- sections by `{ heading = "..." }` rows. Sections are separated by a
--- blank line, so `{` / `}` jump between them.
---@param title string
---@param rows org.HelpRow[]
function M.help(title, rows)
  local keycol = 0
  for _, r in ipairs(rows) do
    if not r.heading then
      for _, k in ipairs(type(r[1]) == "table" and r[1] or { r[1] }) do
        keycol = math.max(keycol, utils.width(k))
      end
    end
  end
  -- widest single key, or a few short keys side by side
  for _, r in ipairs(rows) do
    if not r.heading and type(r[1]) == "table" then
      keycol = math.max(keycol, math.min(HELP_KEYS_MAX, utils.width(table.concat(r[1], "  "))))
    end
  end
  local lines, hls = {}, {}
  local function add(line, hl)
    lines[#lines + 1] = line
    for _, h in ipairs(hl or {}) do
      hls[#hls + 1] = { #lines - 1, h[1], h[2], h[3] }
    end
  end
  for _, r in ipairs(rows) do
    if r.heading then
      if #lines > 0 then
        add("")
      end
      add(" " .. r.heading, { { 1, 1 + #r.heading, "Title" } })
    else
      -- pack keys into lines no wider than the key column
      local packed, cur = {}, {}
      for _, k in ipairs(type(r[1]) == "table" and r[1] or { r[1] }) do
        local joined = table.concat(cur, "  ")
        if #cur > 0 and utils.width(joined) + 2 + utils.width(k) > keycol then
          packed[#packed + 1] = cur
          cur = {}
        end
        cur[#cur + 1] = k
      end
      packed[#packed + 1] = cur
      for i, keys in ipairs(packed) do
        local text = table.concat(keys, "  ")
        local line = "   " .. utils.pad_right(text, keycol)
        local hl, col = {}, 3
        for _, k in ipairs(keys) do
          hl[#hl + 1] = { col, col + #k, "Special" }
          col = col + #k + 2
        end
        if i == 1 then
          line = line .. "   " .. (r[2] or "")
        end
        add((line:gsub("%s+$", "")), hl)
      end
    end
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, utils.width(l) + 2)
  end
  local buf, win = M.float(lines, {
    title = title,
    width = width,
    height = math.min(#lines, vim.o.lines - 6),
    cursorline = true,
    footer = "q/Esc close  / search  { } sections",
  })
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  for _, k in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", k, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true })
  end
  return buf, win
end

---------------------------------------------------------------------------
-- Displayed text
---------------------------------------------------------------------------

--- What the buffer hides when it draws Org text: link brackets and paths
--- (`ui.conceal_links`, or `b:org_link_descriptive` from
--- toggle_link_display), emphasis markers (`ui.hide_emphasis_markers`, or
--- `b:org_hide_emphasis_markers`), and entities and sub/superscripts shown
--- as UTF-8 (`ui.pretty_entities`, `#+STARTUP: entitiespretty`,
--- toggle_pretty_entities). Pass the result to |M.visible_text|.
---@param bufnr? integer
---@return table
function M.conceal_opts(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local ui = require("org.config").opts.ui or {}
  local valid = vim.api.nvim_buf_is_valid(bufnr)
  local b = valid and vim.b[bufnr] or {}
  local links = ui.conceal_links ~= false
  if b.org_link_descriptive ~= nil then
    links = b.org_link_descriptive and true or false
  end
  local o = { links = links }
  -- emphasis and entities are drawn by the Org syntax and decorations only
  if valid and vim.bo[bufnr].filetype == "org" then
    o.emphasis = ui.hide_emphasis_markers and true or false
    if b.org_hide_emphasis_markers ~= nil then
      o.emphasis = b.org_hide_emphasis_markers and true or false
    end
    local dui = require("org.ui.decorations").ui_options(bufnr)
    if dui.pretty_entities then
      o.entities = true
      o.scripts = dui.pretty_entities_include_sub_superscripts ~= false and dui.use_sub_superscripts ~= false
      o.braces_only = dui.use_sub_superscripts == "{}"
    end
  end
  return o
end

local EMPH_PRE = "[%s%(%'\"{%-]"
local EMPH_POST = "[%s%-%.,:!?;'\"%)}%[]"

--- The closing marker of emphasis opening at byte i of s (org-emph-re).
local function emphasis_close(s, i)
  local ch = s:sub(i, i)
  local prev = i == 1 and " " or s:sub(i - 1, i - 1)
  local first = s:sub(i + 1, i + 1)
  if not prev:match(EMPH_PRE) or first == "" or first:match("[%s,\"']") then
    return nil
  end
  local j = i + 1
  while true do
    j = s:find(ch, j + 1, true)
    if not j then
      return nil
    end
    local after = s:sub(j + 1, j + 1)
    if not s:sub(j - 1, j - 1):match("[%s,\"']") and (after == "" or after:match(EMPH_POST)) then
      return j
    end
  end
end

--- Byte ranges the decorations never prettify: links, verbatim/code-like
--- spans and plain URLs (like org.ui.decorations).
local function protected_ranges(s)
  local out = {}
  for a, e in s:gmatch("()%[%[.-%]%]()") do
    out[#out + 1] = { a, e - 1 }
  end
  for a, e in s:gmatch("()[=~][^%s=~][^\n]-[=~]()") do
    out[#out + 1] = { a, e - 1 }
  end
  for a, e in s:gmatch("()%a+://%S+()") do
    out[#out + 1] = { a, e - 1 }
  end
  return out
end

local function in_ranges(ranges, pos)
  for _, r in ipairs(ranges) do
    if pos >= r[1] and pos <= r[2] then
      return true
    end
  end
  return false
end

--- The text as the buffer displays it with the conceals of `o`
--- (|M.conceal_opts|): a link shows as its description (or path), hidden
--- emphasis markers and sub/superscript marks and braces are dropped and
--- a pretty entity shows as its character. Like Emacs measuring with
--- org-string-width, which skips invisible text and counts compositions.
---@param s string
---@param o? table
---@return string
function M.visible_text(s, o)
  o = o or M.conceal_opts()
  if not (s:find("[[", 1, true) or (o.emphasis and s:find("[*/_+=~]")) or (o.entities and s:find("[\\_^]"))) then
    return s
  end
  local prot = o.entities and protected_ranges(s) or {}
  local out, drop, i, n = {}, {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local handled = false
    if c == "[" and s:sub(i + 1, i + 1) == "[" then
      -- the link path may hold backslash-escaped brackets
      local k = i + 2
      while k <= n and not s:sub(k, k):match("[%[%]]") do
        k = k + (s:sub(k, k) == "\\" and 2 or 1)
      end
      local after, visible
      if s:sub(k, k + 1) == "]]" then
        after, visible = k + 2, s:sub(i + 2, k - 1)
      elseif s:sub(k, k + 1) == "][" then
        local close = s:find("]]", k + 2, true)
        if close then
          after, visible = close + 2, s:sub(k + 2, close - 1)
        end
      end
      if after then
        out[#out + 1] = o.links and visible or s:sub(i, after - 1)
        i, handled = after, true
      end
    elseif drop[i] then
      out[#out + 1] = o.emphasis and "" or c
      i, handled = i + 1, true
    elseif c:match("[*/_+=~]") then
      local close = emphasis_close(s, i)
      if close then
        if c == "=" or c == "~" then
          -- verbatim and code: shown as typed
          local inner = s:sub(i + 1, close - 1)
          out[#out + 1] = o.emphasis and inner or (c .. inner .. c)
          i = close + 1
        else
          out[#out + 1] = o.emphasis and "" or c
          drop[close] = true
          i = i + 1
        end
        handled = true
      end
    end
    if not handled and o.entities and c == "\\" and not in_ranges(prot, i) then
      local name = s:match("^%a+", i + 1)
      local ents = require("org.entities")
      local sym = name and ents.utf8(name)
      local e = name and i + #name
      if name and not sym then
        local w = s:match("^%a+%d%d?", i + 1)
        sym = w and ents.utf8(w)
        e = sym and i + #w or e
      end
      if sym and vim.fn.strchars(sym) == 1 and not s:sub(e + 1, e + 1):match("%a") then
        out[#out + 1] = sym
        i = s:sub(e + 1, e + 2) == "{}" and e + 3 or e + 1
        handled = true
      end
    end
    if not handled and o.scripts and (c == "_" or c == "^") and i > 1 and s:sub(i - 1, i - 1):match("%S") then
      if not in_ranges(prot, i) then
        if s:sub(i + 1, i + 1) == "{" then
          local close = s:find("}", i + 2, true)
          if close and close > i + 2 then
            out[#out + 1] = s:sub(i + 2, close - 1)
            i, handled = close + 1, true
          end
        elseif not o.braces_only then
          local b = s:match("^%*", i + 1) or s:match("^[+-]?[%w.,\\]*%w", i + 1)
          if b then
            out[#out + 1] = b
            i, handled = i + 1 + #b, true
          end
        end
      end
    end
    if not handled then
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Display width of `s` as the buffer shows it (|M.visible_text|).
---@param s string
---@param o? table conceal options (|M.conceal_opts|)
---@return integer
function M.visible_width(s, o)
  return utils.width(M.visible_text(s, o))
end

--- Byte ranges ({ first, last }, markers included) of the =verbatim= and
--- ~code~ objects of the line `s` (org-emph-re).
---@param s string
---@return integer[][]
function M.verbatim_ranges(s)
  local out, i = {}, 1
  while true do
    i = s:find("[=~]", i)
    if not i then
      return out
    end
    local close = emphasis_close(s, i)
    if close then
      out[#out + 1] = { i, close }
      i = close + 1
    else
      i = i + 1
    end
  end
end

--- Open a buffer in a window according to `mode`.
---@param buf integer
---@param mode "float"|"split"|"vsplit"|"tab"|"current"|nil
---@param opts? { title?: string, width?: number, height?: number }
---@return integer win
function M.open_buffer_window(buf, mode, opts)
  opts = opts or {}
  mode = mode or require("org.config").opts.win_split_mode or "float"
  if mode == "float" then
    -- the size and position follow the editor: computed again on VimResized
    -- (as the extension views do), so the float stays centred and on screen
    local function geometry()
      local width = math.max(math.min(math.floor(vim.o.columns * (opts.width or 0.8)), vim.o.columns - 2), 1)
      local height = math.max(math.min(math.floor(vim.o.lines * (opts.height or 0.7)), vim.o.lines - 4), 1)
      return {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
        col = math.max(math.floor((vim.o.columns - width) / 2), 0),
      }
    end
    local cfg = geometry()
    cfg.border = require("org.config").opts.win_border or "rounded"
    cfg.title = opts.title and (" " .. opts.title .. " ") or nil
    cfg.title_pos = opts.title and "center" or nil
    cfg.zindex = 50
    local win = vim.api.nvim_open_win(buf, true, cfg)
    local group = vim.api.nvim_create_augroup("org.ui.float." .. win, { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        if not vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_del_augroup_by_id, group)
          return
        end
        pcall(vim.api.nvim_win_set_config, win, geometry())
      end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = function()
        vim.schedule(function()
          pcall(vim.api.nvim_del_augroup_by_id, group)
        end)
      end,
    })
    return win
  elseif mode == "split" then
    vim.cmd("botright split")
  elseif mode == "vsplit" then
    vim.cmd("botright vsplit")
  elseif mode == "tab" then
    vim.cmd("tabnew")
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win
end

return M
