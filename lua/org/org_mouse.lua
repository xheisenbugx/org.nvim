---@mod org.org_mouse Better mouse support (org-mouse)
---
--- A port of org-mouse.el, off by default like the Emacs module (which is
--- loaded with (require 'org-mouse)); turn it on with
--- `mouse.org_mouse = true`. `mouse.features` (org-mouse-features) picks
--- the parts:
---   "context-menu"   <RightMouse> shows a menu for what is under the
---                    mouse: headline, TODO keyword, priority, tags,
---                    timestamp, checkbox, link, table, #+STARTUP line,
---                    the Visual selection, else a general menu; and
---                    <C-LeftMouse> dragged moves a subtree
---   "move-tree"      a drag with <RightMouse> moves a subtree
---   "yank-link"      <S-MiddleMouse>, or a drag with <RightMouse>, inserts
---                    the last yank as a link where the mouse is
---   "activate-stars", "activate-bullets", "activate-checkboxes"
---                    clicking headline stars cycles the subtree, a
---                    bullet cycles the item, a checkbox toggles it
--- Moving a subtree: drop it on the same headline to promote (drag left)
--- or demote (drag right) it, on another headline's stars to put it before
--- that one, on its text to make it that one's last child.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

---@return boolean
function M.enabled()
  local m = config.opts.mouse or {}
  return m.org_mouse == true
end

--- Is feature `name` of `mouse.features` on (and org_mouse)?
---@param name string
---@return boolean
function M.feature(name)
  if not M.enabled() then
    return false
  end
  return vim.tbl_contains((config.opts.mouse or {}).features or {}, name)
end

local function get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr or 0, lnum - 1, lnum, false)[1] or ""
end

local function set_line(bufnr, lnum, text)
  vim.api.nvim_buf_set_lines(bufnr or 0, lnum - 1, lnum, false, { text })
end

--- just-one-space at byte `pos` (1-based: the gap before character `pos`)
--- of `s`: the spaces and tabs around it become one space. Returns the new
--- string and the position after that space.
---@param s string
---@param pos integer
---@return string, integer
function M.just_one_space(s, pos)
  local a, b = pos, pos
  while a > 1 and s:sub(a - 1, a - 1):match("[ \t]") do
    a = a - 1
  end
  while b <= #s and s:sub(b, b):match("[ \t]") do
    b = b + 1
  end
  return s:sub(1, a - 1) .. " " .. s:sub(b), a + 1
end

--- Replace bytes [s, e] of line `lnum` by `text`; unless `nosurround`,
--- make one space on both sides (org-mouse-replace-match-and-surround).
function M.replace(lnum, s, e, text, nosurround)
  local line = get_line(0, lnum)
  local new = line:sub(1, s - 1) .. text .. line:sub(e + 1)
  if not nosurround then
    -- the end first: the start stays where it is
    new = M.just_one_space(new, s + #text)
    new = M.just_one_space(new, s)
  end
  set_line(0, lnum, new)
end

--- org-mouse-remove-match-and-spaces: delete bytes [s, e] and make one
--- space there.
function M.remove_match_and_spaces(lnum, s, e)
  local line = get_line(0, lnum)
  local new = M.just_one_space(line:sub(1, s - 1) .. line:sub(e + 1), s)
  set_line(0, lnum, new)
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(s - 1, 0) })
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

--- org-mouse-end-headline: to the end of the headline, before its tags.
function M.end_headline()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = get_line(0, lnum)
  local s = line:gsub("[ \t]+$", "")
  if s:match(":[A-Za-z]+:$") then
    -- (skip-chars-backward ":A-Za-z") then the spaces
    s = s:gsub("[:A-Za-z]+$", ""):gsub("[ \t]+$", "")
  end
  vim.api.nvim_win_set_cursor(0, { lnum, #s })
  return #s
end

--- Where the mouse is on the line: "beginning" when only spaces and stars
--- are before it, "end" at the end of the line, else "middle"
--- (org-mouse-line-position).
local function line_position(line, col)
  if col > #line then
    return "end"
  elseif line:sub(1, col - 1):match("^[ \t*]*$") then
    return "beginning"
  end
  return "middle"
end

--- org-mouse-insert-heading: a new heading before the line when the mouse
--- is at its beginning, else before the next heading (after the subtree).
---@param col? integer 1-based column (default: the cursor's)
function M.insert_heading(col)
  local lnum, ccol = utils.cursor()
  col = col or ccol
  local line = get_line(0, lnum)
  local parser = require("org.parser")
  if line_position(line, col) == "beginning" then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  else
    -- org-mouse-next-heading
    local n = vim.api.nvim_buf_line_count(0)
    local target
    for l = lnum + 1, n do
      if parser.headline_level(get_line(0, l)) then
        target = l
        break
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    elseif get_line(0, n):match("^[ \t]*$") then
      vim.api.nvim_win_set_cursor(0, { n, 0 })
    else
      vim.api.nvim_buf_set_lines(0, n, n, false, { "" })
      vim.api.nvim_win_set_cursor(0, { n + 1, 0 })
    end
  end
  require("org.structure").meta_return_heading({})
  utils.start_insert()
  return true
end

--- org-mouse-insert-heading at `pos` ({ lnum, col } with a 1-based col).
function M.insert_heading_at(pos)
  local line = get_line(0, pos[1])
  vim.api.nvim_win_set_cursor(0, { pos[1], math.max(math.min(pos[2], #line) - 1, 0) })
  return M.insert_heading(pos[2])
end

--- The checkbox of the item on `line`: its byte range, or nil.
local function checkbox_range(line)
  local pre = line:match("^([ \t]*[-+*][ \t]+)%[[ Xx-]%]")
    or line:match("^([ \t]*%d+[.)][ \t]+)%[[ Xx-]%]")
    or line:match("^([ \t]*[-+*][ \t]+%[@[%w:]+%][ \t]*)%[[ Xx-]%]")
    or line:match("^([ \t]*%d+[.)][ \t]+%[@[%w:]+%][ \t]*)%[[ Xx-]%]")
  if not pre then
    return nil
  end
  return #pre + 1, #pre + 3
end
M.checkbox_range = checkbox_range

--- The bullet of the item on `line` (org-list-full-item-re group 1,
--- with the spaces after it).
local function bullet_end(line)
  local pre = line:match("^[ \t]*[-+*][ \t]+") or line:match("^[ \t]*%d+[.)][ \t]+")
  if line:match("^[ \t]*[-+*][ \t]*$") then
    pre = line
  end
  return pre and #pre or nil
end

--- org-mouse-insert-checkbox: a checkbox on the item at the cursor.
function M.insert_checkbox(lnum)
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = get_line(0, lnum)
  local e = bullet_end(line)
  if not e or checkbox_range(line) or require("org.parser").headline_level(line) then
    return false
  end
  -- (goto-char (match-end 0)) (delete-horizontal-space) (insert " [ ] ")
  local head = line:sub(1, e):gsub("[ \t]+$", "")
  set_line(0, lnum, head .. " [ ] " .. line:sub(e + 1):gsub("^[ \t]+", ""))
  return true
end

--- The lines of the items of the list at the cursor: the item there and
--- its siblings (org-apply-on-list).
local function list_item_lines()
  local lists = require("org.lists")
  local item = lists.item_at(0, vim.api.nvim_win_get_cursor(0)[1])
  local out = {}
  for _, it in ipairs(item and lists.siblings(item) or {}) do
    out[#out + 1] = it.lnum
  end
  table.sort(out)
  return out
end

--- org-mouse-for-each-item
local function for_each_item(fn)
  for _, l in ipairs(list_item_lines()) do
    fn(l)
  end
end
M.for_each_item = for_each_item

--- org-mouse-transform-to-outline: the list items of the entry with the
--- smallest indentation become headlines one level below it.
function M.transform_to_outline()
  local parser = require("org.parser")
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local head = lnum
  while head >= 1 and not parser.headline_level(get_line(0, head)) do
    head = head - 1
  end
  if head < 1 then
    utils.error("Before first headline")
    return false
  end
  local level = parser.headline_level(get_line(0, head))
  local stars = string.rep("*", level) .. "* "
  local n = vim.api.nvim_buf_line_count(0)
  local re = "^([ \t]*)([-+*]) "
  local re2 = "^([ \t]*)(%d+[.)]) "
  local minlevel = 1000
  local l = head + 1
  while l <= n and not parser.headline_level(get_line(0, l)) do
    local ind = get_line(0, l):match(re) or get_line(0, l):match(re2)
    if ind then
      minlevel = math.min(minlevel, #ind)
    end
    l = l + 1
  end
  l = head + 1
  while l <= n and not parser.headline_level(get_line(0, l)) do
    local line = get_line(0, l)
    local ind, bullet = line:match(re)
    if not ind then
      ind, bullet = line:match(re2)
    end
    if ind and #ind == minlevel then
      set_line(0, l, stars .. line:sub(#ind + #bullet + 2))
    end
    l = l + 1
  end
  return true
end

--- org-mouse-timestamp-today: change the timestamp at the cursor with the
--- date prompt, then shift it by `shift` `unit`s (org-timestamp-change).
function M.timestamp_today(shift, unit)
  require("org.timestamps").insert_active({ edit = true })
  if shift then
    M.timestamp_change(shift, unit)
  end
end

--- (org-timestamp-change n 'day|'month) on the timestamp at the cursor.
function M.timestamp_change(n, unit)
  local ts = require("org.timestamps")
  local item = ts.at_cursor()
  if not item then
    return false
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  -- on the day (or month) field of the first date
  local raw = item.raw
  local ds = raw:find("%d%d%d%d%-%d%d%-%d%d")
  if not ds then
    return false
  end
  local col = item.start_col - 1 + ds - 1 + (unit == "month" and 5 or 8)
  vim.api.nvim_win_set_cursor(0, { cur[1], col })
  ts.increment(n, unit == "month" and "m" or "d")
  pcall(vim.api.nvim_win_set_cursor, 0, cur)
  return true
end

--- org-mouse-delete-timestamp: the timestamp at the cursor and the
--- keyword before it (SCHEDULED:, DEADLINE: ...).
function M.delete_timestamp()
  local item = require("org.timestamps").at_cursor()
  if not item then
    return false
  end
  local lnum = item.lnum
  local line = get_line(0, lnum)
  local s = item.start_col
  local head = line:sub(1, s - 1)
  local tail = line:sub(item.end_col + 1)
  -- (skip-chars-backward " :A-Z") then a keyword there is removed
  local k = #head
  while k > 0 and head:sub(k, k):match("[ :A-Z]") do
    k = k - 1
  end
  local rest = head:sub(k + 1)
  local kw = rest:match("^ *[A-Z][A-Z]+:")
  if kw then
    head = head:sub(1, k) .. rest:sub(#kw + 1)
  end
  set_line(0, lnum, head .. tail)
  return true
end

--- org-mouse-yank-link: " [[<last yank>]] " where the mouse is, with the
--- spaces there removed.
---@param lnum integer
---@param col integer 1-based byte column
function M.yank_link(lnum, col)
  local line = get_line(0, lnum)
  local a, b = col, col
  while a > 1 and line:sub(a - 1, a - 1):match("[ \t]") do
    a = a - 1
  end
  while b <= #line and line:sub(b, b):match("[ \t]") do
    b = b + 1
  end
  local kill = vim.fn.getreg('"'):gsub("\n$", "")
  local ins = " [[" .. kill .. "]] "
  set_line(0, lnum, line:sub(1, a - 1) .. ins .. line:sub(b))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, a - 1 + #ins })
  return true
end

--- org-mouse-show-overview: first-level headlines only.
function M.show_overview()
  require("org.fold").overview()
end

--- org-mouse-show-headlines: all headlines (org-cycle twice from overview:
--- CONTENTS).
function M.show_headlines()
  require("org.fold").content()
end

--- org-mouse-move-tree: move the subtree of the headline at `from` to
--- `to` ({ lnum, col } with a 1-based byte col). On the same headline a
--- drag to the right demotes it, to the left promotes it; on another
--- headline's stars (and spaces) it goes before that one, at its level;
--- further right it becomes that headline's last child.
function M.move_tree(from, to)
  local parser = require("org.parser")
  local function heading_of(lnum)
    for l = lnum, 1, -1 do
      if parser.headline_level(get_line(0, l)) then
        return l
      end
    end
    return nil
  end
  local sh, eh = heading_of(from[1]), heading_of(to[1])
  if not (sh and eh) then
    utils.error("Before first headline")
    return false
  end
  if sh == eh then
    vim.api.nvim_win_set_cursor(0, { sh, 0 })
    local later = to[1] > from[1] or (to[1] == from[1] and to[2] >= from[2])
    if later then
      require("org.context").demote_subtree()
    else
      require("org.context").promote_subtree()
    end
    return true
  end
  local src = require("org.files").get_buffer(0):headline_on(sh)
  if eh > sh and eh <= src.end_line then
    utils.warn("Cannot move a subtree into itself")
    return false
  end
  -- a drop right of the stars (or on the text below) makes a child
  local tline = get_line(0, eh)
  local child = to[1] ~= eh or to[2] > #(tline:match("^%*+ ") or tline)
  -- the target headline as a mark that follows the text when the subtree
  -- is cut
  local ns = vim.api.nvim_create_namespace("org.org_mouse.move")
  local mark = vim.api.nvim_buf_set_extmark(0, ns, eh - 1, 0, {})
  local lines = vim.api.nvim_buf_get_lines(0, src.line - 1, src.end_line, false)
  local level = parser.headline_level(lines[1])
  vim.api.nvim_buf_set_lines(0, src.line - 1, src.end_line, false, {})
  local target = vim.api.nvim_buf_get_extmark_by_id(0, ns, mark, {})[1] + 1
  vim.api.nvim_buf_del_extmark(0, ns, mark)
  local tlevel = parser.headline_level(get_line(0, target))
  local insert_at, new_level = target, tlevel
  if child then
    local th = require("org.files").get_buffer(0):headline_on(target)
    insert_at, new_level = th.end_line + 1, tlevel + require("org.structure").level_increment(0)
  end
  local delta = new_level - level
  local out = {}
  for _, l in ipairs(lines) do
    local lv = parser.headline_level(l)
    if lv then
      l = string.rep("*", math.max(lv + delta, 1)) .. l:sub(lv + 1)
    end
    out[#out + 1] = l
  end
  vim.api.nvim_buf_set_lines(0, insert_at - 1, insert_at - 1, false, out)
  vim.api.nvim_win_set_cursor(0, { insert_at, 0 })
  return true
end

--- The message of C-down-mouse-1 (org-mouse-move-tree-start).
M.MOVE_TREE_HELP = "Same line: promote/demote, (***):move before, (text): make a child"

function M.move_tree_start()
  utils.notify(M.MOVE_TREE_HELP)
end

---------------------------------------------------------------------------
-- org-open-at-point with org-mouse (org--mouse-open-at-point)
---------------------------------------------------------------------------

--- What is under the cursor for org-mouse's org-open-at-point: "stars",
--- "checkbox", "bullet" or nil.
---@param line string
---@param col integer 1-based
function M.small_context(line, col)
  local level = require("org.parser").headline_level(line)
  if level then
    if col <= level then
      return "stars"
    end
    return nil
  end
  local cs, ce = checkbox_range(line)
  if cs and col >= cs and col <= ce then
    return "checkbox"
  end
  local b = line:match("^([ \t]*)[-+*][ \t]") or line:match("^([ \t]*)%d+[.)][ \t]")
  if b then
    local bullet = line:match("^[ \t]*([-+*])") or line:match("^[ \t]*(%d+[.)])")
    if col > #b and col <= #b + #bullet then
      return "bullet"
    end
  end
  return nil
end

--- With org-mouse, org-open-at-point on headline stars cycles the subtree,
--- on a checkbox toggles it and on a bullet cycles the item. `mouse`: only
--- where the matching activate-* feature makes the text clickable.
---@param mouse? boolean
---@return boolean handled
function M.open_at_point(mouse)
  if not M.enabled() then
    return false
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local what = M.small_context(line, col)
  if not what then
    return false
  end
  if mouse then
    local feature = ({ stars = "activate-stars", checkbox = "activate-checkboxes", bullet = "activate-bullets" })[what]
    if not M.feature(feature) then
      return false
    end
  end
  if what == "checkbox" then
    require("org.lists").toggle_checkbox()
  else
    require("org.fold").cycle()
  end
  return true
end

---------------------------------------------------------------------------
-- Context menus (org-mouse-context-menu)
---------------------------------------------------------------------------

local function radio(label, selected)
  return (selected and "(*) " or "( ) ") .. label
end

local function toggle(label, selected)
  return (selected and "[X] " or "[ ] ") .. label
end

local function buffer_tags()
  local ok, tags = pcall(require("org.tags").all_tags, 0)
  local out = {}
  for _, t in ipairs(ok and tags or {}) do
    out[#out + 1] = type(t) == "table" and (t.name or t[1]) or t
  end
  out = vim.tbl_filter(function(t)
    return type(t) == "string"
  end, out)
  table.sort(out, function(a, b)
    return require("org.tags").sort_less(a, b)
  end)
  local seen, uniq = {}, {}
  for _, t in ipairs(out) do
    if not seen[t] then
      seen[t], uniq[#uniq + 1] = true, t
    end
  end
  return uniq
end

local function todo_keywords()
  local file = require("org.files").get_buffer(0)
  return vim.tbl_map(function(k)
    return k.name
  end, file.settings.todo.keywords)
end

--- org-mouse-priority-list: A to the lowest priority.
local function priority_list()
  local out = {}
  local lowest = config.opts.priority_lowest or "C"
  if type(lowest) == "string" then
    for c = string.byte("A"), lowest:byte() do
      out[#out + 1] = string.char(c)
    end
  end
  return out
end

--- org-mouse-tag-menu for the headline at the cursor.
local function tag_menu(lnum)
  local file = require("org.files").get_buffer(0)
  local hl = file:headline_at(lnum)
  local cur = hl and hl.tags or {}
  local items = {}
  for _, tag in ipairs(buffer_tags()) do
    local on = vim.tbl_contains(cur, tag)
    items[#items + 1] = {
      toggle(tag, on),
      fn = function()
        require("org.tags").toggle_tag({ bufnr = vim.api.nvim_get_current_buf(), lnum = hl.line }, tag)
      end,
      hint = false,
    }
  end
  vim.list_extend(items, {
    "--",
    {
      "Align Tags Here",
      fn = function()
        require("org.tags").align(0, lnum)
      end,
    },
    {
      "Align Tags in Buffer",
      fn = function()
        require("org.tags").align_all(0)
      end,
    },
    { "Set Tags ...", action = "set_tags" },
  })
  return items
end

--- org-mouse-todo-menu: the TODO keywords, `state` selected.
local function todo_menu(lnum, state)
  local items = {}
  for _, kw in ipairs(todo_keywords()) do
    items[#items + 1] = {
      toggle(kw, kw == state),
      hint = false,
      fn = function()
        require("org.todo").change_state({ bufnr = vim.api.nvim_get_current_buf(), lnum = lnum }, kw)
      end,
    }
  end
  return items
end

--- org-mouse-keyword-replace-menu: replace bytes [s, e] of line `lnum`
--- by one of `keywords` (radio items), or remove them ("None").
local function replace_menu(lnum, s, e, keywords, current, fmt, nosurround, remove_s, remove_e)
  local items = {}
  for _, kw in ipairs(keywords) do
    local label = type(fmt) == "function" and fmt(kw) or (fmt and fmt:format(kw) or kw)
    items[#items + 1] = {
      radio(label, kw == current),
      hint = false,
      fn = function()
        M.replace(lnum, s, e, kw, nosurround)
      end,
    }
  end
  items[#items + 1] = {
    radio("None", not vim.tbl_contains(keywords, current)),
    hint = false,
    fn = function()
      M.remove_match_and_spaces(lnum, remove_s or s, remove_e or e)
    end,
  }
  return items
end

local function grep(args)
  vim.cmd("silent grep! " .. args)
  vim.cmd("copen")
end

local function agenda(cmd)
  return function()
    require("org.agenda").command(cmd)
  end
end

local function sparse_tags(tag)
  return function()
    require("org.agenda.sparse").match(tag)
  end
end

--- org-mouse-popup-global-menu
local function global_menu(ctx)
  local line = ctx.line
  local lists = require("org.lists")
  local at_item = lists.parse_item_line(line) ~= nil and not require("org.parser").headline_level(line)
  local has_box = checkbox_range(line) ~= nil
  local tags = buffer_tags()
  local items = {
    { "Show Overview", fn = M.show_overview },
    { "Show Headlines", fn = M.show_headlines },
    { "Show All", action = "show_everything" },
  }
  if require("org.agenda.sparse").has_highlights(0) then
    items[#items + 1] = {
      "Remove Highlights",
      fn = function()
        require("org.agenda.sparse").clear(0)
      end,
    }
  end
  local check_tags, display_tags = {}, {}
  for _, t in ipairs(tags) do
    check_tags[#check_tags + 1] = { t, fn = sparse_tags(t), hint = false }
    display_tags[#display_tags + 1] = { t, fn = agenda("m " .. t), hint = false }
  end
  vim.list_extend(check_tags, { "--", { "Custom Tag ...", action = "tags_sparse_tree" } })
  vim.list_extend(display_tags, {
    "--",
    {
      "Custom Tag ...",
      fn = function()
        require("org.agenda").command("m")
      end,
    },
  })
  vim.list_extend(items, {
    "--",
    {
      "Check Deadlines",
      fn = function()
        require("org.agenda.sparse").deadlines()
      end,
    },
    {
      "Check TODOs",
      fn = function()
        require("org.agenda.sparse").headlines(function(hl)
          return hl:is_todo()
        end, "TODO entries")
      end,
    },
    { "Check Tags", items = check_tags },
    {
      "Check Phrase ...",
      fn = function()
        local re = utils.input({ prompt = "Regexp: " })
        if re and re ~= "" then
          require("org.agenda.sparse").regexp(re)
        end
      end,
    },
    "--",
    { "Display Agenda", fn = agenda("a") },
    { "Display TODO List", fn = agenda("t") },
    { "Display Tags", items = display_tags },
    { "Display Calendar", action = "goto_calendar" },
  })
  local custom = (config.opts.agenda or {}).custom_commands or {}
  local keys = vim.tbl_keys(custom)
  table.sort(keys)
  if #keys > 0 then
    items[#items + 1] = "--"
    for _, k in ipairs(keys) do
      local c = custom[k]
      local desc = type(c) == "table" and (c.desc or c.description or c[1]) or nil
      local label = type(desc) == "string" and desc or string.format("Agenda Command `%s'", k)
      if #label > 30 then
        label = label:sub(1, 27) .. "..."
      end
      items[#items + 1] = { label, fn = agenda(k), hint = false }
    end
  end
  local tail = {}
  if line:match("^[ \t]*$") then
    tail[#tail + 1] = {
      "Delete Blank Lines",
      fn = function()
        M.delete_blank_lines(ctx.lnum)
      end,
    }
  end
  if at_item and not has_box then
    tail[#tail + 1] = {
      "Insert Checkbox",
      fn = function()
        M.insert_checkbox(ctx.lnum)
      end,
    }
    tail[#tail + 1] = {
      "Insert Checkboxes",
      fn = function()
        for_each_item(M.insert_checkbox)
      end,
    }
  end
  if at_item then
    tail[#tail + 1] = { "Plain List to Outline", fn = M.transform_to_outline }
  end
  items[#items + 1] = "--"
  vim.list_extend(items, tail)
  return items
end

--- delete-blank-lines on line `lnum`: on a blank line among blank lines,
--- all but one go; on a lone blank line, it goes.
function M.delete_blank_lines(lnum)
  local n = vim.api.nvim_buf_line_count(0)
  local s, e = lnum, lnum
  while s > 1 and get_line(0, s - 1):match("^[ \t]*$") do
    s = s - 1
  end
  while e < n and get_line(0, e + 1):match("^[ \t]*$") do
    e = e + 1
  end
  if s == e then
    vim.api.nvim_buf_set_lines(0, s - 1, e, false, {})
  else
    vim.api.nvim_buf_set_lines(0, s - 1, e, false, { "" })
  end
end

--- The word of `line` around byte `col` made of chars in the Lua class
--- `class` (skip-chars-backward, then looking-at): its range and text,
--- when the match ends after `col`.
local function word_at(line, col, class, pat, back)
  -- looking-at from the point itself
  local a, b = line:find("^" .. pat, col)
  if a then
    return a, b, line:sub(a, b)
  end
  local s = col
  while s > 1 and line:sub(s - 1, s - 1):match(class) do
    s = s - 1
  end
  s = s + (back or 0)
  if s < 1 then
    return nil
  end
  a, b = line:find("^" .. pat, s)
  if a and b >= col then
    return a, b, line:sub(a, b)
  end
  return nil
end

--- The headline menu (Headline Menu); `direct` false from the agenda.
local function headline_menu(ctx, direct)
  local lnum = ctx.lnum
  local file = require("org.files").get_buffer(0)
  local hl = file:headline_at(lnum)
  local prio = ctx.line:match("%[#([%w])%]")
    or (type(config.opts.priority_default) == "string" and config.opts.priority_default)
    or tostring(config.opts.priority_default or "B")
  local tags_prios = {}
  for _, p in ipairs(priority_list()) do
    tags_prios[#tags_prios + 1] = {
      radio("Priority " .. p, p == prio),
      hint = false,
      fn = function()
        require("org.priority").set({ bufnr = vim.api.nvim_get_current_buf(), lnum = lnum }, p)
      end,
    }
  end
  tags_prios[#tags_prios + 1] = "--"
  vim.list_extend(tags_prios, tag_menu(lnum))
  local function at_end(then_fn)
    return function()
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      local c = M.end_headline()
      local line = vim.api.nvim_get_current_line()
      vim.api.nvim_set_current_line(line:sub(1, c) .. " " .. line:sub(c + 1))
      vim.api.nvim_win_set_cursor(0, { lnum, c })
      then_fn()
    end
  end
  local items = {
    { "Tags and Priorities", items = tags_prios },
    { "TODO Status", items = todo_menu(lnum, hl and hl.todo) },
  }
  if not direct then
    items[#items + 1] = {
      "Show Tags",
      fn = function()
        utils.notify("Tags are :" .. table.concat(hl and hl.tags or {}, ":") .. ":")
      end,
    }
    items[#items + 1] = {
      "Show Priority",
      fn = function()
        require("org.priority").show({ bufnr = vim.api.nvim_get_current_buf(), lnum = lnum })
      end,
    }
  else
    items[#items + 1] = "--"
    items[#items + 1] = {
      "New Heading",
      fn = function()
        M.insert_heading(ctx.col)
      end,
    }
  end
  vim.list_extend(items, {
    {
      "Set Deadline",
      fn = at_end(function()
        require("org.timestamps").deadline()
      end),
      active = function()
        return not get_line(0, lnum):find("DEADLINE:", 1, true)
      end,
    },
    {
      "Schedule Task",
      fn = at_end(function()
        require("org.timestamps").schedule()
      end),
      active = function()
        return not get_line(0, lnum):find("SCHEDULED:", 1, true)
      end,
    },
    {
      "Insert Timestamp",
      fn = at_end(function()
        vim.api.nvim_win_set_cursor(0, { lnum, vim.api.nvim_win_get_cursor(0)[2] + 1 })
        require("org.timestamps").insert_active()
      end),
    },
    "--",
    { "Archive Subtree", action = "archive_subtree" },
    { "Cut Subtree", action = "cut_special" },
    { "Copy Subtree", action = "copy_special" },
  })
  if direct then
    items[#items + 1] = { "Paste Subtree", action = "paste_special" }
  end
  local function sort(key)
    return function()
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      require("org.structure").sort(key)
    end
  end
  vim.list_extend(items, {
    {
      "Sort Children",
      items = {
        { "Alphabetically", fn = sort("a") },
        { "Numerically", fn = sort("n") },
        { "By Time/Date", fn = sort("t") },
        "--",
        { "Reverse Alphabetically", fn = sort("A") },
        { "Reverse Numerically", fn = sort("N") },
        { "Reverse By Time/Date", fn = sort("T") },
      },
    },
    "--",
    {
      "Move Trees",
      fn = function() end,
      active = function()
        return false
      end,
    },
  })
  return items
end

--- The special marks of a table's first column, with Emacs's labels.
local TABLE_MARKS = { " ", "!", "^", "_", "$", "#", "*", "'" }
local TABLE_MARK_LABELS = {
  [" "] = "( ) Nothing Special",
  ["!"] = "(!) Column Names",
  ["^"] = "(^) Field Names Above",
  ["_"] = "(^) Field Names Below",
  ["$"] = "($) Formula Parameters",
  ["#"] = "(#) Recalculation: Auto",
  ["*"] = "(*) Recalculation: Manual",
  ["'"] = "(') Recalculation: None",
}

local function table_menu()
  local function t(name)
    return { action = name }
  end
  local function e(label, spec)
    spec[1] = label
    return spec
  end
  return {
    e("Align Table", t("context_action")),
    e("Blank Field", t("table_blank_field")),
    e("Edit Field", t("table_edit_field")),
    "--",
    {
      "Column",
      items = {
        e("Move Column Left", t("meta_left")),
        e("Move Column Right", t("meta_right")),
        e("Delete Column", t("shift_meta_left")),
        e("Insert Column", t("shift_meta_right")),
        "--",
        {
          toggle("Enable Narrowing", config.opts.table_limit_column_width ~= false),
          fn = function()
            config.opts.table_limit_column_width = not (config.opts.table_limit_column_width ~= false)
          end,
        },
      },
    },
    {
      "Row",
      items = {
        e("Move Row Up", t("meta_up")),
        e("Move Row Down", t("meta_down")),
        e("Delete Row", t("shift_meta_up")),
        e("Insert Row", t("shift_meta_down")),
        e("Sort lines in region", t("table_sort")),
        "--",
        e("Insert Hline", t("table_insert_hline")),
      },
    },
    {
      "Rectangle",
      items = {
        e("Copy Rectangle", t("copy_special")),
        e("Cut Rectangle", t("cut_special")),
        e("Paste Rectangle", t("paste_special")),
        e("Fill Rectangle", t("table_wrap_region")),
      },
    },
    "--",
    e("Set Column Formula", t("table_formula")),
    e("Set Field Formula", { action = "table_formula", count = 4 }),
    e("Edit Formulas", t("table_edit_formulas")),
    "--",
    e("Recalculate Line", t("table_recalculate")),
    e("Recalculate All", { action = "table_recalculate", count = 4 }),
    e("Iterate All", { action = "table_recalculate", count = 16 }),
    "--",
    e("Toggle Recalculate Mark", t("table_rotate_marks")),
    e("Sum Column/Rectangle", t("table_sum")),
    e("Field Info", t("table_field_info")),
    e("Debug Formulas", t("table_formula_debugger")),
  }
end

--- The context of a click at `ctx.col` (1-based, past the end = #line + 1)
--- of line `ctx.lnum`, and its menu items; the cursor is on the click.
---@param ctx { lnum: integer, col: integer, line: string, visual?: { text: string, s: integer[], e: integer[] } }
---@param direct? boolean false for a menu from the agenda
---@return string kind, (org.MenuEntry|string)[] items
function M.context_items(ctx, direct)
  if direct == nil then
    direct = true
  end
  local line, col, lnum = ctx.line, ctx.col, ctx.lnum
  local parser = require("org.parser")
  if ctx.visual then
    local text = ctx.visual.text
    local vs, ve = ctx.visual.s, ctx.visual.e
    return "region",
      {
        {
          "Sparse Tree",
          fn = function()
            require("org.agenda.sparse").regexp("\\V" .. text:gsub("\\", "\\\\"))
          end,
        },
        {
          "Find in Buffer",
          fn = function()
            vim.cmd("lvimgrep /\\V" .. vim.fn.escape(text, "/\\") .. "/j %")
            vim.cmd("lopen")
          end,
        },
        {
          "Grep in Current Dir",
          fn = function()
            grep("-rnH -e " .. vim.fn.shellescape(text) .. " ./*")
          end,
        },
        {
          "Grep in Parent Dir",
          fn = function()
            grep("-rnH -e " .. vim.fn.shellescape(text) .. " ../*")
          end,
        },
        "--",
        {
          "Convert to Link",
          fn = function()
            -- the end first, so the start stays put
            vim.api.nvim_buf_set_text(0, ve[1] - 1, ve[2], ve[1] - 1, ve[2], { "]]" })
            vim.api.nvim_buf_set_text(0, vs[1] - 1, vs[2] - 1, vs[1] - 1, vs[2] - 1, { "[[" })
          end,
        },
        {
          "Insert Link Here",
          fn = function()
            M.yank_link(lnum, col)
          end,
        },
      }
  end
  local startup = line:match("^[ \t]*#%+[Ss][Tt][Aa][Rr][Tt][Uu][Pp]: (.*)$")
  if startup then
    local opts = vim.split(startup, "%s+", { trimempty = true })
    local items = {}
    for _, name in ipairs(M.STARTUP_OPTIONS) do
      local on = vim.tbl_contains(opts, name)
      items[#items + 1] = {
        toggle(name, on),
        hint = false,
        fn = function()
          local new = vim.tbl_filter(function(o)
            return o ~= name
          end, opts)
          if not on then
            new[#new + 1] = name
          end
          table.sort(new, function(a, b)
            return utils.string_lessp(a, b)
          end)
          local l = get_line(0, lnum)
          local prefix = l:match("^([ \t]*#%+[Ss][Tt][Aa][Rr][Tt][Uu][Pp]: )")
          set_line(0, lnum, prefix .. table.concat(new, " "))
          -- org-mode-restart
          local buf = vim.api.nvim_get_current_buf()
          vim.b[buf].org_attached = nil
          vim.b[buf].did_ftplugin = nil
          vim.bo[buf].filetype = "org"
        end,
      }
    end
    return "startup", items
  end
  -- at the end of the line, or in the white space ending it
  local rest = line:sub(col)
  if col > #line or (#rest >= 2 and rest:match("^[ \t]+$") and line:sub(col - 1, col - 1):match("[ \t]")) then
    return "global", global_menu(ctx)
  end
  local cs, ce = checkbox_range(line)
  if cs and col >= cs and col <= ce and not parser.headline_level(line) then
    local function set_all(mark)
      return function()
        for_each_item(function(l)
          local text = get_line(0, l)
          local a, b = checkbox_range(text)
          if a then
            if mark == false then
              M.remove_match_and_spaces(l, a, b)
            else
              set_line(0, l, text:sub(1, a - 1) .. mark .. text:sub(b + 1))
            end
          end
        end)
      end
    end
    return "checkbox",
      {
        { "Toggle", action = "toggle_checkbox" },
        {
          "Remove",
          fn = function()
            M.remove_match_and_spaces(lnum, cs, ce)
          end,
        },
        "--",
        { "All Clear", fn = set_all("[ ]") },
        { "All Set", fn = set_all("[X]") },
        {
          "All Toggle",
          fn = function()
            for_each_item(function(l)
              vim.api.nvim_win_set_cursor(0, { l, 0 })
              if checkbox_range(get_line(0, l)) then
                require("org.lists").toggle_checkbox()
              end
            end)
          end,
        },
        { "All Remove", fn = set_all(false) },
      }
  end
  local _, _, word = word_at(line, col, "[%w_]", "%f[%w_][%w_]+")
  if word and vim.tbl_contains(todo_keywords(), word) then
    local items = todo_menu(lnum, word)
    vim.list_extend(items, {
      "--",
      {
        "Check TODOs",
        fn = function()
          require("org.agenda.sparse").headlines(function(hl)
            return hl:is_todo()
          end, "TODO entries")
        end,
      },
      { "List all TODO keywords", fn = agenda("t") },
      { "List only " .. word, fn = agenda("T " .. word) },
    })
    return "todo", items
  end
  local ks, ke, kw = word_at(line, col, "[A-Z]", "%f[%w_][A-Z]+:")
  if kw and (kw == "DEADLINE:" or kw == "SCHEDULED:") then
    local items = replace_menu(lnum, ks, ke, { "DEADLINE:", "SCHEDULED:" }, kw)
    vim.list_extend(items, {
      "--",
      {
        "Check Deadlines",
        fn = function()
          require("org.agenda.sparse").deadlines()
        end,
      },
    })
    return "planning", items
  end
  local ps, pe = word_at(line, col, "[%[%]A-Z#]", "%[#[A-Z]%]")
  if ps then
    local cur = line:sub(ps + 2, ps + 2)
    return "priority", replace_menu(lnum, ps + 2, ps + 2, priority_list(), cur, "Priority %s", true, ps, pe)
  end
  vim.api.nvim_win_set_cursor(0, { lnum, math.max(math.min(col, #line) - 1, 0) })
  local link = require("org.links").link_at_cursor()
  if link and link.lnum == lnum then
    local s, e = link.start_col, link.end_col
    return "link",
      {
        { "Open", action = "open_at_point" },
        {
          "Open in Neovim",
          fn = function()
            require("org.links").open_at_point(4)
          end,
        },
        "--",
        {
          "Copy link",
          fn = function()
            vim.fn.setreg('"', line:sub(s, e))
          end,
        },
        {
          "Cut link",
          fn = function()
            vim.fn.setreg('"', line:sub(s, e))
            M.remove_match_and_spaces(lnum, s, e)
          end,
        },
        "--",
        {
          "Grep for TODOs",
          fn = function()
            local path = (link.path or link.target or ""):gsub("::.*$", "")
            grep("-nH -i " .. vim.fn.shellescape("todo\\|fixme") .. " " .. vim.fn.fnameescape(path) .. "*")
          end,
        },
      }
  end
  local _, _, tag = word_at(line, col, "[%w_]", ":[%w_]+:", -1)
  if tag then
    tag = tag:sub(2, -2)
    local items = {
      { string.format("Display ‘%s’", tag), fn = agenda("m " .. tag), hint = false },
      { string.format("Sparse Tree ‘%s’", tag), fn = sparse_tags(tag), hint = false },
      "--",
    }
    vim.list_extend(items, tag_menu(lnum))
    return "tags", items
  end
  if require("org.timestamps").at_cursor() then
    local ts = require("org.timestamps")
    local function change(n, unit)
      return function()
        M.timestamp_change(n, unit)
      end
    end
    local function today(n, unit)
      return function()
        M.timestamp_today(n, unit)
      end
    end
    return "timestamp",
      {
        { "Show Day", action = "open_at_point" },
        {
          "Change Timestamp",
          fn = function()
            ts.insert_active({ edit = true })
          end,
        },
        { "Delete Timestamp", fn = M.delete_timestamp },
        {
          "Compute Time Range",
          action = "evaluate_time_range",
          active = function()
            local it = ts.at_cursor()
            return it ~= nil and it.date.range_end ~= nil
          end,
        },
        "--",
        { "Set for Today", fn = today() },
        { "Set for Tomorrow", fn = today(1, "day") },
        { "Set in 1 Week", fn = today(7, "day") },
        { "Set in 2 Weeks", fn = today(14, "day") },
        { "Set in a Month", fn = today(1, "month") },
        "--",
        { "+ 1 Day", fn = change(1, "day") },
        { "+ 1 Week", fn = change(7, "day") },
        { "+ 1 Month", fn = change(1, "month") },
        "--",
        { "- 1 Day", fn = change(-1, "day") },
        { "- 1 Week", fn = change(-7, "day") },
        { "- 1 Month", fn = change(-1, "month") },
      }
  end
  local tbl = require("org.table").find(0, lnum)
  if tbl then
    local ms, mark = line:match("^[ \t]*|() *([#*$!_^/']) *|")
    local mcol = ms and line:find("[#*$!_^/']", ms)
    if mark and mcol and col >= ms and col <= line:find("|", mcol, true) then
      return "table-special",
        replace_menu(lnum, mcol, mcol, TABLE_MARKS, mark, function(m)
          return TABLE_MARK_LABELS[m]
        end, true)
    end
    return "table", table_menu()
  end
  if parser.headline_level(line) and col <= #line then
    return "headline", headline_menu(ctx, direct)
  end
  return "global", global_menu(ctx)
end

--- Emacs's org-startup-options, in its order.
M.STARTUP_OPTIONS = vim.split(
  table.concat({
    "fold overview nofold showall show2levels show3levels show4levels show5levels",
    "showeverything content indent noindent num nonum hidestars showstars odd oddeven align",
    "noalign shrink descriptivelinks literallinks inlineimages noinlineimages linkpreviews",
    "nolinkpreviews latexpreview nolatexpreview customtime logdone lognotedone nologdone",
    "lognoteclock-out nolognoteclock-out logrepeat lognoterepeat logdrawer nologdrawer",
    "logstatesreversed nologstatesreversed nologrepeat logreschedule lognotereschedule",
    "nologreschedule logredeadline lognoteredeadline nologredeadline logrefile lognoterefile",
    "nologrefile fninline nofninline fnlocal fnauto fnprompt fnconfirm fnplain fnadjust",
    "nofnadjust fnanon constcgs constSI noptag hideblocks nohideblocks hidedrawers",
    "nohidedrawers beamer entitiespretty entitiesplain",
  }, " "),
  " "
)

--- The context menu for the cursor position, or the Visual selection.
function M.context_menu_at_cursor()
  local visual = M.visual_region()
  local lnum, col = utils.cursor()
  M.show_context_menu({ lnum = lnum, col = col, line = vim.api.nvim_get_current_line(), visual = visual })
  return true
end

--- Show the context menu for `ctx` (org-mouse-show-context-menu).
function M.show_context_menu(ctx, direct)
  local kind, items = M.context_items(ctx, direct)
  local menu = require("org.menu")
  menu.define("]OrgMouse", items)
  M.last_kind = kind
  menu.popup("]OrgMouse")
  return kind
end

---------------------------------------------------------------------------
-- The agenda (org-mouse-agenda-context-menu)
---------------------------------------------------------------------------

--- The agenda menu of org-mouse (away from an entry).
function M.agenda_items()
  local defs = require("org.menu_defs")
  local P = defs.predicates
  local function A(label, name, active)
    return { label, agenda = name, active = active }
  end
  local view = require("org.agenda.view")
  return {
    {
      "Agenda Files",
      items = vim.tbl_map(function(f)
        return {
          utils.abbreviate(f),
          hint = false,
          fn = function()
            utils.open_file(f)
          end,
        }
      end, require("org.files").agenda_file_paths()),
    },
    "--",
    A("Undo", "undo", function()
      return #view.undo_list > 0
    end),
    A("Rebuild Buffer", "redo"),
    A("New Diary Entry", "diary_entry", P.agenda_view),
    "--",
    A("Goto Today", "today", P.agenda_view),
    A("Display Calendar", "calendar", P.agenda_view),
    {
      "Calendar Commands",
      items = {
        A("Phases of the Moon", "phases_of_moon", P.agenda_view),
        A("Sunrise/Sunset", "sunrise_sunset", P.agenda_view),
        A("Holidays", "holidays", P.agenda_view),
        A("Convert", "convert_date", P.agenda_view),
        "--",
        {
          "Create iCalendar file",
          fn = function()
            require("org.export.icalendar").combine_agenda_files({})
          end,
        },
      },
    },
    "--",
    A("Day View", "day_view", P.agenda_view),
    A("Week View", "week_view", P.agenda_view),
    "--",
    A("Show Logbook entries", "log_mode", P.agenda_view),
    A("Include Diary", "toggle_diary", P.agenda_view),
    A("Use Time Grid", "time_grid", P.agenda_view),
    A("Follow Mode", "follow_mode"),
    "--",
    A("Quit", "quit"),
    A("Exit and Release Buffers", "exit"),
  }
end

--- <RightMouse> in the agenda: on an entry, the context menu of its
--- headline at the same distance from the end of the line
--- (org-mouse-do-remotely), else the agenda menu.
---@param lnum integer
---@param col integer 1-based column of the click
function M.agenda_context_menu(lnum, col)
  local view = require("org.agenda.view")
  local menu = require("org.menu")
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(col - 1, 0) })
  local item = view.item_at_cursor()
  local target = item and item.headline and item.type ~= "diary" and view.resolve_target(item)
  if not target then
    menu.define("]OrgMouse", M.agenda_items())
    M.last_kind = "agenda"
    menu.popup("]OrgMouse")
    return "agenda"
  end
  local anticol = #vim.api.nvim_get_current_line() - (col - 1)
  local bufnr = target.bufnr
  local hlnum = target.lnum
  local agenda_win = vim.api.nvim_get_current_win()
  local items
  local kind
  vim.api.nvim_buf_call(bufnr, function()
    local line = get_line(bufnr, hlnum)
    local c = math.max(#line - anticol, 0) + 1
    kind, items = M.context_items({ lnum = hlnum, col = c, line = line }, false)
  end)
  -- every entry runs in the entry's buffer, at its headline; the agenda
  -- is rebuilt afterwards
  local function remote(list)
    local out = {}
    for _, e in ipairs(list) do
      if type(e) == "table" and e.items then
        out[#out + 1] = vim.tbl_extend("force", e, { items = remote(e.items) })
      elseif type(e) == "table" and not e.title then
        local run = e
        out[#out + 1] = {
          e[1],
          hint = false,
          active = e.active,
          fn = function()
            vim.api.nvim_buf_call(bufnr, function()
              local win = vim.fn.bufwinid(bufnr)
              if win ~= -1 then
                vim.api.nvim_win_set_cursor(win, { hlnum, 0 })
              end
              local saved = vim.api.nvim_win_get_cursor(0)
              pcall(vim.api.nvim_win_set_cursor, 0, { hlnum, 0 })
              if run.action then
                require("org.actions").run(run.action)
              elseif run.fn then
                run.fn()
              end
              pcall(vim.api.nvim_win_set_cursor, 0, saved)
            end)
            if vim.api.nvim_win_is_valid(agenda_win) then
              vim.api.nvim_win_call(agenda_win, function()
                view.redo()
              end)
            end
          end,
        }
      else
        out[#out + 1] = e
      end
    end
    return out
  end
  menu.define("]OrgMouse", remote(items))
  M.last_kind = kind
  menu.popup("]OrgMouse")
  return kind
end

---------------------------------------------------------------------------
-- Mouse keys
---------------------------------------------------------------------------

--- The mouse position as { lnum, col } in the current window (col is
--- 1-based and #line + 1 past the end of the line), or nil.
function M.mouse_pos()
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or pos.line == 0 then
    return nil
  end
  if pos.winid ~= vim.api.nvim_get_current_win() then
    pcall(vim.api.nvim_set_current_win, pos.winid)
  end
  return { pos.line, pos.column, screen = { pos.screenrow, pos.screencol }, win = pos.winid }
end

--- The mouse position at the release of a drag that started at `p` (from
--- `mouse_pos`), without changing windows: nil outside any window, and
--- `other` set when the drag ended in another window (whose line numbers
--- must not be used on the buffer of the press).
---@param p table
---@return table|nil
function M.release_pos(p)
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or pos.line == 0 then
    return nil
  end
  local other = p.win ~= nil and pos.winid ~= p.win
  return { pos.line, pos.column, screen = { pos.screenrow, pos.screencol }, win = pos.winid, other = other }
end

--- The Visual selection as the region of a context menu.
function M.visual_region()
  local m = vim.fn.mode()
  if not (m == "v" or m == "V" or m == "\22") then
    return nil
  end
  local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  local lines = vim.fn.getregion(s, e, { type = m })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { text = table.concat(lines, "\n"), s = { s[2], s[3] }, e = { e[2], e[3] } }
end

M._press = nil

--- <RightMouse>: remember the press; without a feature using right drags,
--- show the context menu now.
function M.right_press()
  local visual = M.visual_region()
  local p = M.mouse_pos()
  if not p then
    return
  end
  M._press = { p = p, visual = visual }
  if not (M.feature("yank-link") or M.feature("move-tree")) then
    M.right_release(true)
  end
end

--- <RightRelease>: a click shows the context menu, a drag moves a subtree
--- (move-tree) or inserts the last yank as a link there (yank-link).
function M.right_release(now)
  local press = M._press
  M._press = nil
  if not press then
    return
  end
  local p = press.p
  local r = not now and M.release_pos(p) or p
  if r.other then
    -- a drag into another window: nothing to do in this buffer
    return
  end
  local dragged = r[1] ~= p[1] or r[2] ~= p[2]
  if dragged and M.feature("move-tree") then
    M.move_tree({ p[1], p[2] }, { r[1], r[2] })
    return
  elseif dragged and M.feature("yank-link") then
    M.yank_link(r[1], math.min(r[2], #get_line(0, r[1]) + 1))
    return
  end
  if not M.feature("context-menu") then
    return
  end
  if vim.bo.filetype == "orgagenda" then
    M.agenda_context_menu(p[1], p[2])
    return
  end
  local line = get_line(0, p[1])
  if not press.visual then
    pcall(vim.api.nvim_win_set_cursor, 0, { p[1], math.max(math.min(p[2], #line) - 1, 0) })
  end
  M.show_context_menu({ lnum = p[1], col = p[2], line = line, visual = press.visual })
end

--- <C-LeftMouse> / <C-LeftRelease>: drag a subtree.
function M.ctrl_press()
  M._ctrl_press = M.mouse_pos()
  M.move_tree_start()
end

function M.ctrl_release()
  local p = M._ctrl_press
  M._ctrl_press = nil
  local r = p and M.release_pos(p)
  if r and not r.other and (p[1] ~= r[1] or p[2] ~= r[2]) then
    M.move_tree({ p[1], p[2] }, { r[1], r[2] })
  end
end

--- <S-MiddleMouse>: insert the last yank as a link where clicked.
function M.shift_middle()
  local p = M.mouse_pos()
  if p then
    M.yank_link(p[1], math.min(p[2], #get_line(0, p[1]) + 1))
  end
end

--- Is the mouse inside the Visual selection (org-mouse-in-region-p)?
function M.click_in_selection()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= vim.api.nvim_get_current_win() or pos.line == 0 then
    return false
  end
  local m = vim.fn.mode()
  local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  local l, c = pos.line, pos.column
  if m == "V" then
    return l >= s[2] and l <= e[2]
  elseif m == "\22" then
    local c1, c2 = math.min(s[3], e[3]), math.max(s[3], e[3])
    return l >= s[2] and l <= e[2] and c >= c1 and c <= c2
  end
  -- characterwise, its last character included
  if l < s[2] or l > e[2] then
    return false
  end
  return not ((l == s[2] and c < s[3]) or (l == e[2] and c > e[3]))
end

--- Buffer-local mouse keys of org-mouse in an org buffer.
function M.attach(bufnr)
  if not M.enabled() then
    return
  end
  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = bufnr, desc = "org-mouse: " .. desc })
  end
  -- org-mouse-down-mouse: a click inside the selection keeps it
  vim.keymap.set("x", "<LeftMouse>", function()
    return M.click_in_selection() and "" or "<LeftMouse>"
  end, { buffer = bufnr, expr = true, desc = "org-mouse: keep the selection on a click in it" })
  if M.feature("context-menu") or M.feature("move-tree") or M.feature("yank-link") then
    map({ "n", "x" }, "<RightMouse>", M.right_press, "context menu")
    map({ "n", "x" }, "<RightDrag>", "<Nop>", "drag")
    map({ "n", "x" }, "<RightRelease>", function()
      M.right_release()
    end, "context menu / drag")
  end
  if M.feature("context-menu") then
    map("n", "<C-LeftMouse>", M.ctrl_press, "move tree start")
    map("n", "<C-LeftDrag>", "<Nop>", "move tree")
    map("n", "<C-LeftRelease>", M.ctrl_release, "move tree")
  end
  if M.feature("yank-link") then
    map("n", "<S-MiddleMouse>", M.shift_middle, "yank link")
  end
end

--- Mouse keys of org-mouse in the agenda: <RightMouse> context menu,
--- <C-ScrollWheelUp/Down> earlier / later, a horizontal right drag earlier
--- (left) or later (right).
function M.attach_agenda(bufnr)
  if not M.enabled() then
    return
  end
  local view = require("org.agenda.view")
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = "org-mouse: " .. desc })
  end
  map("<RightMouse>", function()
    M._press = { p = M.mouse_pos() }
    M.move_tree_start()
  end, "context menu")
  map("<RightDrag>", "<Nop>", "drag")
  map("<RightRelease>", function()
    local press = M._press
    M._press = nil
    local r = press and press.p and M.release_pos(press.p)
    if not r then
      return
    end
    local p = press.p
    -- in another window only the screen positions mean something here
    if p.screen[2] ~= r.screen[2] and p.screen[1] == r.screen[1] or (not r.other and p[2] ~= r[2]) then
      -- org-mouse-get-gesture
      view.run_action(r.screen[2] < p.screen[2] and "earlier" or "later")
      return
    end
    M.agenda_context_menu(p[1], p[2])
  end, "context menu / earlier-later gesture")
  map("<C-ScrollWheelUp>", function()
    view.run_action("earlier")
  end, "earlier")
  map("<C-ScrollWheelDown>", function()
    view.run_action("later")
  end, "later")
end

return M
