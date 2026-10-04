---@mod org.agenda.view Agenda buffer, window and actions
---
--- This file holds the agenda state, the highlights and the rendering; it
--- loads the rest from org/agenda/view/: window (open, quit), show (the
--- entry at the cursor), edit (changing entries, remote undo), commands,
--- filters, bulk, actions (the action table), calendar and mappings.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local render = require("org.agenda.render")
local utils = require("org.utils")

local M = {}
-- The parts in org/agenda/view/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.agenda.view"] = M

local ns = vim.api.nvim_create_namespace("org.agenda")
local ns_marks = vim.api.nvim_create_namespace("org.agenda.marks")
-- the new dates shown after a date change (org-agenda-show-new-time)
local ns_newtime = vim.api.nvim_create_namespace("org.agenda.newtime")

local function empty_filters()
  return { tag = {}, category = {}, regexp = {}, effort = {}, top = nil }
end

--- State of one agenda buffer. Without `agenda.sticky` there is a single
--- agenda buffer (like Emacs); with it, one buffer per agenda command.
local function new_state()
  return {
    buf = nil,
    win = nil,
    win_mode = nil,
    prev_win = nil,
    prev_buf = nil,
    layout = nil, -- window layout to restore (org-agenda-restore-windows-after-quit)
    name = "org://agenda",
    key = nil,
    view = nil,
    anchor = nil, -- first day of the agenda span; nil = computed from today
    span = nil, -- span override from v* keys
    align = true,
    log_mode = false, -- false | true | "all" | "clockcheck"
    clockreport = false,
    follow = false,
    entry_text = false,
    archives = false, -- false | "trees" | "files"
    inactive = false,
    time_grid_off = false,
    no_deadlines = false,
    include_diary = nil, -- nil = agenda.include_diary (`D` toggles it)
    dim_blocked = true, -- true | false | "invisible"
    filters = empty_filters(),
    limits = {},
    marks = {},
    line_items = {},
    line_parts = {},
    line_hl_groups = {},
    line_ctx = nil, -- line -> render context of its item (for change_all_lines)
    day_lines = {},
    info = {},
    restrict = nil,
    new_buffers = {},
  }
end

local states = {} -- agenda bufnr -> state
local S = new_state()
M.state = S

--- The state of agenda buffer `buf` (nil when it is none).
---@param buf integer
---@return table|nil
function M.state_of(buf)
  return states[buf]
end

--- Agenda option `name` for the view of `state` (default: the current
--- agenda): set in its custom command's `settings`, else the global
--- `agenda.<name>`. For what Emacs reads once per agenda, under the
--- command's let-bound options (org-agenda-finalize, org-agenda-mode);
--- options of a block of a composite command don't count there.
---@param name string
---@param state? table
function M.command_option(name, state)
  state = state or S
  local s = state.view and state.view.settings
  if s and s[name] ~= nil then
    return s[name]
  end
  return config.opts.agenda[name]
end

-- Highlights are drawn for the visible lines only, from `line_parts` (byte
-- ranges { start_col, end_col, group, priority? } per line) of the
-- buffer's state: writing an extmark for every range of a large agenda
-- costs more than building it. The few line highlights (`line_hl_groups`,
-- line -> group) are extmarks, as an ephemeral one has no line_hl_group.
local set_extmark = vim.api.nvim_buf_set_extmark
local ns_line = vim.api.nvim_create_namespace("org.agenda.line")

--- Set the line highlight of line `l` of `buf` to `group` (nil: none).
local function set_line_hl(buf, l, group)
  vim.api.nvim_buf_clear_namespace(buf, ns_line, l - 1, l)
  if group then
    pcall(set_extmark, buf, ns_line, l - 1, 0, { line_hl_group = group, priority = 90 })
  end
end

local function draw_hls(buf, row, st)
  local parts = st.line_parts[row + 1]
  if parts then
    for _, h in ipairs(parts) do
      pcall(set_extmark, buf, ns, row, h[1], {
        end_col = h[2],
        hl_group = h[3],
        priority = h[4] or 110,
        ephemeral = true,
      })
    end
  end
end

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    return states[buf] ~= nil
  end,
  on_line = function(_, _, buf, row)
    local st = states[buf]
    if st then
      draw_hls(buf, row, st)
    end
  end,
})

--- Redraw lines `first`..`last` (1-based) of agenda buffer `buf` after
--- their highlight data changed.
local ns_touch = vim.api.nvim_create_namespace("org.agenda.touch")
local function redraw_lines(buf, first, last)
  -- adding and removing a highlight marks its lines for redraw
  -- (nvim__redraw with a range is experimental, and asserts without a UI)
  local ok, id = pcall(set_extmark, buf, ns_touch, first - 1, 0, { end_row = last, hl_group = "Normal" })
  if ok then
    pcall(vim.api.nvim_buf_del_extmark, buf, ns_touch, id)
  end
end

--- Make `state` the current agenda state.
local function use(state)
  S = state
  M.state = state
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function item_key(item)
  return (item.filename or tostring(item.bufnr)) .. ":" .. item.lnum .. ":" .. item.raw
end

local function has_agenda_block()
  if not S.view then
    return false
  end
  for _, b in ipairs(S.view.blocks) do
    if b.type == "agenda" then
      return true
    end
  end
  return false
end
M.has_agenda_block = has_agenda_block

local function current_span()
  if S.span then
    return S.span
  end
  if S.view then
    for _, b in ipairs(S.view.blocks) do
      if b.type == "agenda" then
        return b.span or config.opts.agenda.span or "week"
      end
    end
  end
  return config.opts.agenda.span or "week"
end

--- Filter presets of the view (org-agenda-tag-filter-preset, ...).
local function presets()
  local p = S.view and S.view.presets or {}
  return p
end

local function join(list)
  return table.concat(list or {}, "")
end

--- The active filters as a string, like the Emacs mode line.
function M.filter_desc()
  local f = S.filters
  local p = presets()
  local parts = {}
  local function add(label, list)
    local all = vim.list_extend(vim.list_slice(list or {}), {})
    if #all > 0 then
      parts[#parts + 1] = label .. join(all)
    end
  end
  local tag = vim.list_extend(vim.list_slice(p.tag or {}), f.tag)
  local cat = vim.list_extend(vim.list_slice(p.category or {}), f.category)
  local re = vim.list_extend(vim.list_slice(p.regexp or {}), f.regexp)
  local eff = vim.list_extend(vim.list_slice(p.effort or {}), f.effort)
  add("Cat:", cat)
  add("Tag:", tag)
  if #re > 0 then
    local r = {}
    for _, x in ipairs(re) do
      r[#r + 1] = x:sub(1, 1) .. "{" .. x:sub(2) .. "}"
    end
    parts[#parts + 1] = "Re:" .. join(r)
  end
  if #eff > 0 then
    parts[#parts + 1] = "Effort:" .. join(eff)
  end
  if f.top then
    parts[#parts + 1] = "Top:" .. f.top.title
  end
  local limits = {}
  for _, k in ipairs({ "max_entries", "max_todos", "max_tags", "max_effort" }) do
    if S.limits[k] then
      limits[#limits + 1] = k:gsub("max_", "") .. "=" .. tostring(S.limits[k])
    end
  end
  if #limits > 0 then
    parts[#parts + 1] = "Limit:" .. table.concat(limits, ",")
  end
  return table.concat(parts, " ")
end

--- Effort of an item in minutes (nil when it has none).
local function item_effort(it)
  return require("org.agenda.items").effort(it)
end

--- org-agenda-compare-effort: `<` means <=, `>` means >=; entries without
--- an effort count as infinitely long (org-agenda-sort-noeffort-is-high).
function M.effort_matches(it, f)
  local e = item_effort(it)
  if not e then
    e = config.opts.agenda.sort_noeffort_is_high ~= false and math.huge or -1
  end
  if f.op == "<" then
    return e <= f.minutes
  elseif f.op == ">" then
    return e >= f.minutes
  end
  return e == f.minutes
end

--- Identifies the top-level headline an item belongs to.
function M.top_key(it)
  local h = it.headline
  if not h then
    return nil
  end
  while h.parent do
    h = h.parent
  end
  return (it.filename or tostring(it.bufnr)) .. ":" .. h.line
end

--- Test of one tag filter element ("+tag", "-tag", "+" = any tag,
--- "+{regexp}") (org-agenda-filter-make-matcher-tag-exp). With `groups`
--- (group_tags on), a group tag stands for itself and its members
--- (org-agenda-filter-expand-tags): "+Group" needs any of them, "-Group"
--- none.
local function any_regexp(re_src, tags)
  local ok, re = pcall(require("org.agenda.search").compile_emacs_regexp, re_src)
  if ok then
    for _, t in ipairs(tags) do
      if re:match_str(t) then
        return true
      end
    end
  end
  return false
end

local function tag_element(x, tags, groups)
  local op, tag = x:sub(1, 1), x:sub(2)
  local r
  local group = groups and tag ~= "" and not tag:match("^{.*}$") and require("org.tags").expand_group(tag, groups)
  if tag == "" then
    r = #tags > 0
  elseif tag:match("^{.*}$") then
    r = any_regexp(tag:sub(2, -2), tags)
  elseif group then
    r = false
    for _, t in ipairs(tags) do
      if group.names[t] then
        r = true
        break
      end
    end
    for _, re in ipairs(group.regexps) do
      r = r or any_regexp(re, tags)
    end
  else
    r = vim.tbl_contains(tags, tag)
  end
  if op == "-" then
    return not r
  end
  return r
end

--- The text a regexp filter is matched against (Emacs 'txt).
local function item_txt(it)
  local t = (it.todo and (it.todo .. " ") or "") .. (it.priority and ("[#" .. it.priority .. "] ") or "")
  t = t .. (it.display_title or it.title or "")
  local tags = render.tags_string(it)
  return tags and (t .. " " .. tags) or t
end

--- The predicate hiding items according to the filters and presets.
local function item_filter()
  local f = S.filters
  local p = presets()
  local tag = vim.list_extend(vim.list_slice(p.tag or {}), f.tag)
  local cat = vim.list_extend(vim.list_slice(p.category or {}), f.category)
  local regexp = vim.list_extend(vim.list_slice(p.regexp or {}), f.regexp)
  local effort = vim.list_extend(vim.list_slice(p.effort or {}), f.effort)
  if #tag == 0 and #cat == 0 and #regexp == 0 and #effort == 0 and not f.top then
    return nil
  end
  -- several positive categories: any of them (Emacs `or')
  local npos = 0
  for _, x in ipairs(cat) do
    if x:sub(1, 1) == "+" then
      npos = npos + 1
    end
  end
  local res = {}
  local search = require("org.agenda.search")
  for _, x in ipairs(regexp) do
    local ok, re = pcall(search.compile_emacs_regexp, x:sub(2))
    res[#res + 1] = { neg = x:sub(1, 1) == "-", re = ok and re or nil }
  end
  local efs = {}
  for _, x in ipairs(effort) do
    local op, v = x:sub(2, 2), x:sub(3)
    efs[#efs + 1] = { neg = x:sub(1, 1) == "-", op = op, minutes = date.parse_duration(v) or tonumber(v) or 0 }
  end
  local groups = #tag > 0 and require("org.tags").match_groups() or nil
  if groups and vim.tbl_isempty(groups) then
    groups = nil
  end
  return function(it)
    local tags = it.tags or {}
    for _, x in ipairs(tag) do
      if not tag_element(x, tags, groups) then
        return false
      end
    end
    if #cat > 0 then
      local ok = npos <= 1
      for _, x in ipairs(cat) do
        local r = it.category == x:sub(2)
        if x:sub(1, 1) == "-" then
          r = not r
        end
        if npos > 1 then
          ok = ok or r
        elseif not r then
          ok = false
        end
      end
      if not ok then
        return false
      end
    end
    if #res > 0 then
      local txt = item_txt(it)
      for _, r in ipairs(res) do
        local m = r.re and r.re:match_str(txt) ~= nil or false
        if m == r.neg then
          return false
        end
      end
    end
    for _, e in ipairs(efs) do
      if M.effort_matches(it, e) == e.neg then
        return false
      end
    end
    if f.top and M.top_key(it) ~= f.top.key then
      return false
    end
    return true
  end
end

local function clocking_pred()
  local ok, clock = pcall(require, "org.clock")
  if not ok or type(clock.active) ~= "function" then
    return nil
  end
  if not clock.state then
    return nil
  end
  -- the headline holding the open CLOCK: line
  local ok2, bufnr, clnum = pcall(clock.find_open_clock)
  if not ok2 or not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(clnum)
  if not hl then
    return nil
  end
  local path = vim.fs.normalize(clock.state.path)
  return function(it)
    return it.filename ~= nil and vim.fs.normalize(it.filename) == path and it.lnum == hl.line
  end
end

--- Add the files of `extra` (org-agenda-text-search-extra-files: paths
--- or globs, "agenda-archives" for the archive files of `list`) to the
--- file list `list`, skipping files already there.
function M.add_extra_files(list, extra)
  local seen = {}
  for _, f in ipairs(list) do
    seen[f.filename or ""] = true
  end
  local with_archives = false
  local rest = {}
  for _, e in ipairs(extra or {}) do
    if e == "agenda-archives" then
      with_archives = true
    else
      rest[#rest + 1] = e
    end
  end
  if with_archives then
    for _, f in ipairs(M.archive_files(list)) do
      if not seen[f.filename or ""] then
        seen[f.filename or ""] = true
        list[#list + 1] = f
      end
    end
  end
  if #rest > 0 then
    for _, p in ipairs(utils.glob_org_files(rest)) do
      local f = files.get(p)
      if f and not seen[f.filename or ""] then
        seen[f.filename or ""] = true
        list[#list + 1] = f
      end
    end
  end
  return list
end

--- Files for a block, honoring restriction and per-block `files`.
local function files_for_block(block)
  if S.restrict then
    if S.restrict.bufnr and vim.api.nvim_buf_is_valid(S.restrict.bufnr) then
      return { files.get_buffer(S.restrict.bufnr) }
    elseif S.restrict.filename then
      local f = files.get(S.restrict.filename)
      return f and { f } or {}
    end
  end
  local pats = block.files or block.org_agenda_files
  local list
  if pats then
    list = {}
    for _, p in ipairs(utils.glob_org_files(pats)) do
      local f = files.get(p)
      if f then
        list[#list + 1] = f
      end
    end
  else
    list = files.agenda_files()
  end
  -- org-agenda-text-search-extra-files for the search view
  if block.type == "search" then
    M.add_extra_files(list, block.text_search_extra_files or config.opts.agenda.text_search_extra_files)
  end
  return list
end

--- Archive files belonging to `list` (org-add-archive-files): the files
--- named by `#+ARCHIVE:`, ARCHIVE properties and `archive_location`.
function M.archive_files(list)
  local archive = require("org.archive")
  local seen, out = {}, {}
  for _, f in ipairs(list) do
    seen[f.filename or ""] = true
  end
  for _, f in ipairs(list) do
    if f.filename then
      local locs = { f.settings.archive ~= "" and f.settings.archive or nil, config.opts.archive_location }
      for _, hl in ipairs(f.headlines) do
        if hl.properties.ARCHIVE then
          locs[#locs + 1] = hl.properties.ARCHIVE
        end
      end
      for _, loc in pairs(locs) do
        local path = archive.parse_location(loc, f.filename).filename
        if path and not seen[path] then
          seen[path] = true
          local af = utils.exists(path) and files.get(path) or nil
          if af then
            out[#out + 1] = af
          end
        end
      end
    end
  end
  return out
end

local function files_for(block)
  local list = files_for_block(block)
  if S.archives == "files" then
    list = vim.list_extend(vim.list_slice(list), M.archive_files(list))
  end
  return list
end

--- TODO keywords of the agenda files, for `N r` (org-todo-keywords-for-agenda:
--- collected file by file, each new keyword pushed to the front).
local function todo_names()
  local seen, out = {}, {}
  local list = files.agenda_files()
  local cfgs = {}
  for _, f in ipairs(list) do
    cfgs[#cfgs + 1] = f.settings.todo
  end
  if #cfgs == 0 then
    cfgs[1] = require("org.todo_keywords").global()
  end
  for _, cfg in ipairs(cfgs) do
    for _, n in ipairs(cfg:names()) do
      if not seen[n] then
        seen[n] = true
        table.insert(out, 1, n)
      end
    end
  end
  return out
end
M.todo_names = todo_names

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local ns_restrict = vim.api.nvim_create_namespace("org.agenda.restrict")

--- The line range of a subtree restriction, following edits of its
--- buffer like Emacs's org-agenda-restrict-begin/end markers: an extmark
--- on the subtree's headline, whose subtree is taken from the current
--- text.
---@return integer[]|nil
local function restrict_range()
  local r = S.restrict
  if not (r and r.range) then
    return nil
  end
  local bufnr = r.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return r.range
  end
  if not r.mark then
    -- a copy: the restriction may be shared with the caller
    r = vim.tbl_extend("force", {}, r)
    S.restrict = r
    r.mark = vim.api.nvim_buf_set_extmark(bufnr, ns_restrict, r.range[1] - 1, 0, {})
    return r.range
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_restrict, r.mark, {})
  if pos[1] then
    local hl = files.get_buffer(bufnr):headline_at(pos[1] + 1)
    if hl and hl.line == pos[1] + 1 then
      r.range = { hl.line, hl.end_line }
    end
  end
  return r.range
end

--- Replace the restriction of the current agenda, dropping the extmark of
--- the old one.
local function set_restrict(r)
  local old = S.restrict
  if old and old.mark and old.bufnr and vim.api.nvim_buf_is_valid(old.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, old.bufnr, ns_restrict, old.mark)
  end
  S.restrict = r
end

--- Compute the rendered view (without touching buffers).
function M.build(width)
  local now = date.now()
  local today = now:days()
  local ctx = {
    today = today,
    now = now.hour * 60 + now.min,
    width = width or 100,
    anchor = S.anchor or today,
    anchor_set = S.anchor ~= nil,
    align = S.align ~= false,
    span = S.span,
    span_set = S.span ~= nil,
    log_mode = S.log_mode,
    clockreport = S.clockreport,
    entry_text = S.entry_text,
    archives = S.archives,
    inactive = S.inactive,
    time_grid_off = S.time_grid_off,
    no_deadlines = S.no_deadlines,
    include_diary = S.include_diary,
    dim_blocked = S.dim_blocked,
    restrict = S.restrict and { range = restrict_range() } or nil,
    filter = item_filter(),
    files_for = files_for,
    todo_names = todo_names(),
    is_clocking = clocking_pred(),
    limits = S.limits,
  }
  return render.view(S.view, ctx)
end

local function win_width()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    return vim.api.nvim_win_get_width(S.win)
  end
  return vim.o.columns
end

--- Show the active filters in the window bar (Emacs shows them in the
--- mode line).
local function update_winbar()
  if not (S.win and vim.api.nvim_win_is_valid(S.win)) then
    return
  end
  if vim.api.nvim_win_get_config(S.win).relative ~= "" then
    return
  end
  local desc = M.filter_desc()
  local value = desc ~= "" and ("%#OrgAgendaFilter#" .. desc:gsub("%%", "%%%%")) or ""
  pcall(vim.api.nvim_set_option_value, "winbar", value, { scope = "local", win = S.win })
end

--- Functions called after each render with the agenda buffer, the render
--- builder (`lines`, `items`, and anything a grouper added) and the view
--- state; used by extensions to set keys on what they drew. name -> fn.
---@type table<string, fun(buf: integer, b: table, state: table)>
M.refresh_hooks = {}

--- Re-render into the agenda buffer.
function M.refresh()
  if not S.view or not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  local b = M.build(win_width())
  S.line_items = b.items
  S.day_lines = b.day_lines or {}
  S.info = b.info or {}
  S.block_starts = b.block_starts or { 1 }
  S.entry_text_lines = b.entry_text_lines or {}
  S.line_ctx = b.line_ctx or {}
  local buf = S.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns_newtime, 0, -1)
  -- drawn by the decoration provider
  local parts = {}
  for _, h in ipairs(b.hls) do
    local row = h[1] + 1
    local l = parts[row]
    if not l then
      l = {}
      parts[row] = l
    end
    l[#l + 1] = { h[2], h[3], h[4], h[5] }
  end
  S.line_parts = parts
  S.line_hl_groups = b.line_hls
  vim.api.nvim_buf_clear_namespace(buf, ns_line, 0, -1)
  for lnum, group in pairs(b.line_hls) do
    set_line_hl(buf, lnum, group)
  end
  M.render_marks()
  update_winbar()
  for _, fn in pairs(M.refresh_hooks) do
    local hok, err = pcall(fn, buf, b, S)
    if not hok then
      utils.error("agenda refresh hook: " .. tostring(err))
    end
  end
  local ok, cols = pcall(require, "org.agenda.columns")
  if ok then
    pcall(cols.refresh_if_active)
  end
  M.fit_window()
  -- hooks: org-agenda-filter-hook after the filters changed, else
  -- org-agenda-finalize-hook after the agenda was built
  local sig = vim.inspect(S.filters)
  local event = (S.filter_sig ~= nil and sig ~= S.filter_sig) and "OrgAgendaFilter" or "OrgAgendaFinalize"
  S.filter_sig = sig
  local data = { buf = buf, filters = vim.deepcopy(S.filters), filter = M.filter_desc() }
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = event, data = data, modeline = false })
end

--- With `agenda.window = "split"` (reorganize-frame), fit the agenda
--- window to its lines, between the fractions of the editor height of
--- `agenda.window_frame_fractions` (org-agenda-fit-window-to-buffer);
--- { 1.0, 1.0 } makes it the only window.
function M.fit_window()
  local win = S.win
  if S.win_mode ~= "split" or not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  local fr = config.opts.agenda.window_frame_fractions or { 0.5, 0.75 }
  local lo, hi = tonumber(fr[1]) or 0.5, tonumber(fr[2]) or 0.75
  if lo == 1 and hi == 1 then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("silent! only")
    end)
    return
  end
  if #vim.api.nvim_tabpage_list_wins(0) < 2 then
    return
  end
  local total = vim.o.lines - vim.o.cmdheight
  local n = vim.api.nvim_buf_line_count(S.buf)
  local height = math.max(math.floor(total * lo), math.min(n, math.floor(total * hi)))
  pcall(vim.api.nvim_win_set_height, win, math.max(height, 1))
end

function M.render_marks()
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(S.buf, ns_marks, 0, -1)
  for lnum, item in pairs(S.line_items) do
    if S.marks[item_key(item)] then
      pcall(vim.api.nvim_buf_set_extmark, S.buf, ns_marks, lnum - 1, 0, {
        virt_text = { { config.opts.agenda.bulk_mark_char or ">", "OrgAgendaMark" } },
        virt_text_pos = "overlay",
        priority = 200,
      })
    end
  end
end

-- Local functions and tables the parts below use (the current state is
-- M.state there, kept equal to S by use())
local shared = require("org.agenda.view.shared")
shared.clocking_pred = clocking_pred
shared.current_span = current_span
shared.empty_filters = empty_filters
shared.has_agenda_block = has_agenda_block
shared.item_key = item_key
shared.item_txt = item_txt
shared.join = join
shared.new_state = new_state
shared.ns_line = ns_line
shared.ns_newtime = ns_newtime
shared.redraw_lines = redraw_lines
shared.set_line_hl = set_line_hl
shared.set_restrict = set_restrict
shared.states = states
shared.todo_names = todo_names
shared.use = use

require("org.agenda.view.window")
require("org.agenda.view.show")
require("org.agenda.view.edit")
require("org.agenda.view.commands")
require("org.agenda.view.filters")
require("org.agenda.view.bulk")
require("org.agenda.view.actions")
require("org.agenda.view.calendar")
require("org.agenda.view.mappings")

return M
