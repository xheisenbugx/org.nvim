---@mod org.agenda.view Agenda buffer, window and actions

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local render = require("org.agenda.render")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.agenda")
local ns_marks = vim.api.nvim_create_namespace("org.agenda.marks")

--- Agenda state (one agenda buffer, like Emacs' single-agenda default).
local S = {
  buf = nil,
  win = nil,
  win_mode = nil,
  prev_win = nil,
  prev_buf = nil,
  view = nil,
  anchor = nil, -- day number; nil = today
  span = nil, -- span override from v* keys
  log_mode = false, -- false | true | "all"
  clockreport = false,
  follow = false,
  entry_text = false,
  archives = false, -- false | "trees" | "files"
  inactive = false,
  time_grid_off = false,
  filters = { tags = { include = {}, exclude = {} }, category = nil, regexp = nil },
  marks = {},
  line_items = {},
  day_lines = {},
  info = {},
  restrict = nil,
}
M.state = S

local function reset_filters()
  S.filters = { tags = { include = {}, exclude = {} }, category = nil, regexp = nil, effort = nil, top = nil }
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

local function filter_desc()
  local f = S.filters
  local parts = {}
  for t in pairs(f.tags.include) do
    parts[#parts + 1] = "+" .. t
  end
  for t in pairs(f.tags.exclude) do
    parts[#parts + 1] = "-" .. t
  end
  table.sort(parts)
  if f.category then
    parts[#parts + 1] = "<" .. f.category .. ">"
  end
  if f.regexp then
    parts[#parts + 1] = (f.regexp.neg and "-" or "") .. "{" .. f.regexp.pattern .. "}"
  end
  if f.effort then
    parts[#parts + 1] = "Effort" .. f.effort.op .. date.format_duration(f.effort.minutes)
  end
  if f.top then
    parts[#parts + 1] = "^" .. f.top.title
  end
  return table.concat(parts, " ")
end

local function item_filter()
  local f = S.filters
  local active = next(f.tags.include) or next(f.tags.exclude) or f.category or f.regexp or f.effort or f.top
  if not active then
    return nil
  end
  local re = f.regexp and vim.regex("\\c" .. f.regexp.pattern)
  return function(it)
    local tags = {}
    for _, t in ipairs(it.tags or {}) do
      tags[t] = true
    end
    for t in pairs(f.tags.include) do
      if not tags[t] then
        return false
      end
    end
    for t in pairs(f.tags.exclude) do
      if tags[t] then
        return false
      end
    end
    if f.category and it.category ~= f.category then
      return false
    end
    if re then
      local text = (it.todo and (it.todo .. " ") or "") .. it.title
      local m = re:match_str(text) ~= nil
      if m == f.regexp.neg then
        return false
      end
    end
    if f.effort and not M.effort_matches(it, f.effort) then
      return false
    end
    if f.top and M.top_key(it) ~= f.top.key then
      return false
    end
    return true
  end
end

--- Effort of an item in minutes (nil when it has none).
local function item_effort(it)
  if not it.headline then
    return nil
  end
  local v = it.headline:get_property(config.opts.effort_property or "Effort")
  return v and date.parse_duration(v) or nil
end

--- org-agenda-filter-by-effort: entries without an effort count as
--- infinitely long (org-sort-agenda-noeffort-is-high).
function M.effort_matches(it, f)
  local e = item_effort(it) or math.huge
  if f.op == "<" then
    return e < f.minutes
  elseif f.op == ">" then
    return e > f.minutes
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

local function clocking_pred()
  local ok, clock = pcall(require, "org.clock")
  if not ok or type(clock.active) ~= "function" then
    return nil
  end
  local ok2, a = pcall(clock.active)
  if not ok2 or not a then
    return nil
  end
  local af = a.file or a.filename
  af = af and vim.fs.normalize(af)
  return function(it)
    return it.filename ~= nil and af ~= nil and vim.fs.normalize(it.filename) == af and it.lnum == a.lnum
  end
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
  if pats then
    local out = {}
    for _, p in ipairs(utils.glob_org_files(pats)) do
      local f = files.get(p)
      if f then
        out[#out + 1] = f
      end
    end
    return out
  end
  return files.agenda_files()
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

local function todo_names()
  local seen, out = {}, {}
  local function add(cfg)
    for _, n in ipairs(cfg:names()) do
      if not seen[n] then
        seen[n] = true
        out[#out + 1] = n
      end
    end
  end
  add(require("org.todo_keywords").global())
  for _, f in ipairs(files.agenda_files()) do
    add(f.settings.todo)
  end
  return out
end
M.todo_names = todo_names

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

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
    align = true,
    span = S.span,
    span_set = S.span ~= nil,
    log_mode = S.log_mode,
    clockreport = S.clockreport,
    entry_text = S.entry_text,
    archives = S.archives,
    inactive = S.inactive,
    time_grid_off = S.time_grid_off,
    restrict = S.restrict and { range = S.restrict.range } or nil,
    filter = item_filter(),
    filter_desc = filter_desc(),
    files_for = files_for,
    todo_names = todo_names(),
    is_clocking = clocking_pred(),
  }
  return render.view(S.view, ctx)
end

local function win_width()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    return vim.api.nvim_win_get_width(S.win)
  end
  return vim.o.columns
end

--- Re-render into the agenda buffer.
function M.refresh()
  if not S.view or not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  local b = M.build(win_width())
  S.line_items = b.items
  S.day_lines = b.day_lines or {}
  S.info = b.info or {}
  local buf = S.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(b.hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4], priority = 110 })
  end
  for lnum, group in pairs(b.line_hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, { line_hl_group = group, priority = 90 })
  end
  M.render_marks()
end

function M.render_marks()
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(S.buf, ns_marks, 0, -1)
  for lnum, item in pairs(S.line_items) do
    if S.marks[item_key(item)] then
      pcall(vim.api.nvim_buf_set_extmark, S.buf, ns_marks, lnum - 1, 0, {
        virt_text = { { ">", "OrgAgendaMark" } },
        virt_text_pos = "overlay",
        priority = 200,
      })
    end
  end
end

---------------------------------------------------------------------------
-- Buffer & window
---------------------------------------------------------------------------

local setup_mappings

local function ensure_buf()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    return S.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "org://agenda")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "orgagenda"
  S.buf = buf
  setup_mappings(buf)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if S.follow then
        vim.schedule(function()
          M.show_item(false)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      S.buf = nil
      S.win = nil
    end,
  })
  return buf
end

local function set_win_opts(win)
  local o = { scope = "local", win = win }
  vim.api.nvim_set_option_value("number", false, o)
  vim.api.nvim_set_option_value("relativenumber", false, o)
  vim.api.nvim_set_option_value("signcolumn", "no", o)
  vim.api.nvim_set_option_value("wrap", false, o)
  vim.api.nvim_set_option_value("cursorline", true, o)
  vim.api.nvim_set_option_value("foldenable", false, o)
  vim.api.nvim_set_option_value("spell", false, o)
  vim.api.nvim_set_option_value("list", false, o)
  vim.api.nvim_set_option_value("colorcolumn", "", o)
end

local function show_buffer()
  local buf = ensure_buf()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      vim.api.nvim_set_current_win(w)
      S.win = w
      return
    end
  end
  local mode = config.opts.agenda.window or "current"
  S.prev_win = vim.api.nvim_get_current_win()
  S.prev_buf = vim.api.nvim_get_current_buf()
  S.win_mode = mode
  if mode == "float" then
    S.win = require("org.ui").open_buffer_window(buf, "float", { title = "Org Agenda", width = 0.9, height = 0.85 })
  elseif mode == "split" or mode == "vsplit" or mode == "tab" then
    S.win = require("org.ui").open_buffer_window(buf, mode)
  else
    vim.api.nvim_set_current_buf(buf)
    S.win = vim.api.nvim_get_current_win()
  end
  set_win_opts(S.win)
end

local function first_item_line()
  local lines = vim.tbl_keys(S.line_items)
  table.sort(lines)
  return lines[1]
end

--- Open a view.
---@param view { blocks: table[], title?: string }
---@param opts? { anchor?: integer, span?: string|integer, restrict?: table, keep_state?: boolean }
function M.open(view, opts)
  opts = opts or {}
  S.view = view
  if not opts.keep_state then
    local acfg = config.opts.agenda
    S.anchor = opts.anchor
    S.span = opts.span
    S.log_mode = acfg.start_with_log_mode or false
    S.clockreport = acfg.start_with_clockreport_mode or false
    S.entry_text = acfg.start_with_entry_text_mode or false
    S.follow = acfg.start_with_follow_mode or false
    S.archives = false
    S.inactive = false
    S.time_grid_off = false
    S.marks = {}
    reset_filters()
    S.restrict = opts.restrict
  end
  show_buffer()
  M.refresh()
  -- cursor: today's header in agenda views, else first item
  local target
  local today = date.today_days()
  for lnum, d in pairs(S.day_lines) do
    if d == today and (not target or lnum < target) then
      target = lnum
    end
  end
  target = target or first_item_line() or 1
  pcall(vim.api.nvim_win_set_cursor, S.win, { target, 0 })
end

--- Rebuild the view (re-reading files), keeping the cursor on the same entry.
function M.redo(opts)
  opts = opts or {}
  if not S.view then
    return
  end
  local item = M.item_at_cursor()
  local key = item and item_key(item)
  local lnum = S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_cursor(S.win)[1] or 1
  M.refresh()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    local target
    if key then
      for l, it in pairs(S.line_items) do
        if item_key(it) == key and (not target or math.abs(l - lnum) < math.abs(target - lnum)) then
          target = l
        end
      end
    end
    target = target or math.min(lnum, vim.api.nvim_buf_line_count(S.buf))
    pcall(vim.api.nvim_win_set_cursor, S.win, { target, 0 })
  end
end

function M.quit(wipe)
  S.follow = false
  local win = S.win
  local mode = S.win_mode
  if win and vim.api.nvim_win_is_valid(win) then
    if (mode == "float" or mode == "split" or mode == "vsplit") and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    elseif mode == "tab" and #vim.api.nvim_list_tabpages() > 1 then
      vim.api.nvim_set_current_win(win)
      vim.cmd("tabclose")
    else
      if S.prev_buf and vim.api.nvim_buf_is_valid(S.prev_buf) and S.prev_buf ~= S.buf then
        vim.api.nvim_win_set_buf(win, S.prev_buf)
      else
        vim.api.nvim_win_call(win, function()
          vim.cmd("enew")
        end)
      end
    end
  end
  if S.prev_win and vim.api.nvim_win_is_valid(S.prev_win) then
    pcall(vim.api.nvim_set_current_win, S.prev_win)
  end
  S.win = nil
  if wipe and S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    pcall(vim.api.nvim_buf_delete, S.buf, { force = true })
    S.buf = nil
  end
end

---------------------------------------------------------------------------
-- Items at cursor & targets
---------------------------------------------------------------------------

function M.item_at_cursor()
  if not S.buf or vim.api.nvim_get_current_buf() ~= S.buf then
    if S.win and vim.api.nvim_win_is_valid(S.win) then
      return S.line_items[vim.api.nvim_win_get_cursor(S.win)[1]]
    end
    return nil
  end
  return S.line_items[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Buffer + headline line for an item, loading the file if needed.
---@return org.Target|nil
function M.resolve_target(item)
  local bufnr
  if item.filename then
    bufnr = utils.load_buffer(item.filename)
  elseif item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    bufnr = item.bufnr
  end
  if not bufnr then
    utils.error("Cannot find the file of this entry")
    return nil
  end
  local lnum = item.lnum
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if line ~= item.raw then
    lnum = nil
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == item.raw then
        lnum = i
        break
      end
    end
    if not lnum then
      utils.warn("Entry has changed or moved; press r to refresh the agenda")
      return nil
    end
  end
  return { bufnr = bufnr, lnum = lnum }
end

local function other_window()
  local cur = S.win and vim.api.nvim_win_is_valid(S.win) and S.win or vim.api.nvim_get_current_win()
  if S.prev_win and S.prev_win ~= cur and vim.api.nvim_win_is_valid(S.prev_win) then
    local cfg = vim.api.nvim_win_get_config(S.prev_win)
    if cfg.relative == "" then
      return S.prev_win
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= cur and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  -- create one
  local w
  vim.api.nvim_win_call(cur, function()
    vim.cmd("rightbelow vsplit")
    w = vim.api.nvim_get_current_win()
  end)
  vim.api.nvim_set_current_win(cur)
  return w
end

local function open_in_window(win, target, item)
  vim.api.nvim_win_call(win, function()
    if item.filename then
      utils.open_file(item.filename, target.lnum)
    else
      vim.api.nvim_set_current_buf(target.bufnr)
      vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
    end
    pcall(vim.cmd, "normal! zv")
  end)
end

--- Show the entry in another window (focus = jump there).
function M.show_item(focus)
  local item = M.item_at_cursor()
  if not item then
    return
  end
  local target = M.resolve_target(item)
  if not target then
    return
  end
  local is_float = S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_config(S.win).relative ~= ""
  if is_float and focus then
    M.quit(false)
    local w = vim.api.nvim_get_current_win()
    open_in_window(w, target, item)
    return
  end
  local w = other_window()
  open_in_window(w, target, item)
  if focus then
    vim.api.nvim_set_current_win(w)
  end
end

--- Open the entry in the agenda window itself (RET).
function M.switch_to()
  local item = M.item_at_cursor()
  if not item then
    return
  end
  local target = M.resolve_target(item)
  if not target then
    return
  end
  local is_float = S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_config(S.win).relative ~= ""
  S.follow = false
  if is_float then
    M.quit(false)
  end
  open_in_window(vim.api.nvim_get_current_win(), target, item)
end

---------------------------------------------------------------------------
-- Editing entries from the agenda
---------------------------------------------------------------------------

local function call(mod, fn, ...)
  local ok, m = pcall(require, mod)
  if not ok or type(m[fn]) ~= "function" then
    utils.error(string.format("org agenda: %s.%s is not available", mod, fn))
    return nil
  end
  return m[fn](...)
end
M.call = call

local function finish(bufs)
  if config.opts.agenda.save_after_edit ~= false then
    for _, b in ipairs(bufs or {}) do
      utils.save_buffer(b)
    end
  end
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    local win = S.win
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_current_win, win)
    end
    M.redo()
  end
end

--- Wrap `fn(target, item)` as an action on the entry at point.
local function on_item(fn)
  return function()
    local item = M.item_at_cursor()
    if not item then
      utils.warn("No agenda entry on this line")
      return
    end
    local target = M.resolve_target(item)
    if not target then
      return
    end
    fn(target, item)
    finish({ target.bufnr })
  end
end

local function kind_of(item)
  if item.type == "deadline" then
    return "deadline"
  elseif item.type == "timestamp" or item.type == "range" then
    return "timestamp"
  end
  return "scheduled"
end

local function pick_date(default, prompt)
  local ok, cal = pcall(require, "org.calendar")
  if ok and cal.pick then
    return cal.pick({ default = default, prompt = prompt })
  end
  local input = utils.input({ prompt = (prompt or "Date") .. ": " })
  if not input then
    return nil
  end
  return date.read_date(input, default)
end
M.pick_date = pick_date

local function move_to_item(dir)
  if not S.buf then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(S.buf)
  local l = lnum + dir
  while l >= 1 and l <= count do
    if S.line_items[l] then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
    l = l + dir
  end
end

local function set_span(span)
  if not has_agenda_block() then
    require("org.agenda").open_agenda({ span = span, anchor = S.anchor })
    return
  end
  S.span = span
  M.redo()
end

local function shift_anchor(dir)
  if not has_agenda_block() then
    utils.warn("Not in a date-based agenda view")
    return
  end
  local n = math.max(vim.v.count, 1) * dir
  S.anchor = render.shift_anchor(current_span(), S.anchor or date.today_days(), n)
  M.refresh()
  local first
  for l in pairs(S.day_lines) do
    if not first or l < first then
      first = l
    end
  end
  if first then
    pcall(vim.api.nvim_win_set_cursor, 0, { first, 0 })
  end
end

local function all_tags_in_view()
  local set = {}
  for _, it in pairs(S.line_items) do
    for _, t in ipairs(it.tags or {}) do
      set[t] = true
    end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

local function marked_items()
  local list = vim.tbl_values(S.marks)
  table.sort(list, function(a, b)
    local fa, fb = a.filename or "", b.filename or ""
    if fa ~= fb then
      return fa < fb
    end
    return a.lnum > b.lnum
  end)
  return list
end

local function bulk(fn)
  local list = marked_items()
  local bufs = {}
  local n = 0
  for _, item in ipairs(list) do
    local target = M.resolve_target(item)
    if target then
      fn(target, item)
      bufs[target.bufnr] = true
      n = n + 1
    end
  end
  S.marks = {}
  finish(vim.tbl_keys(bufs))
  utils.notify(string.format("Bulk action applied to %d entries", n))
end

local function add_remove_tag(target, tag, add)
  local file = files.get_buffer(target.bufnr)
  local hl = file:headline_at(target.lnum)
  if not hl then
    return
  end
  local tags = vim.deepcopy(hl.tags)
  local idx
  for i, t in ipairs(tags) do
    if t == tag then
      idx = i
    end
  end
  if add and not idx then
    tags[#tags + 1] = tag
  elseif not add and idx then
    table.remove(tags, idx)
  else
    return
  end
  require("org.edit").update_headline(target.bufnr, hl.line, { tags = tags })
end

--- Day of the line at the cursor: the item's day, else the nearest date
--- header above (nil outside date-based blocks).
function M.day_at_cursor()
  local item = M.item_at_cursor()
  if item and item.day then
    return item.day
  end
  if not S.win or not vim.api.nvim_win_is_valid(S.win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(S.win)[1]
  for l = lnum, 1, -1 do
    if S.day_lines[l] then
      return S.day_lines[l]
    end
  end
  return nil
end

local function toggle(field, label, value)
  if S[field] then
    S[field] = false
  else
    S[field] = value == nil and true or value
  end
  M.redo()
  utils.notify(label .. (S[field] and " on" or " off"))
end

--- Move to the next/previous line for which `pred(lnum)` holds.
local function move_to_line(dir, pred)
  if not S.buf then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(S.buf)
  local l = lnum + dir
  while l >= 1 and l <= count do
    if pred(l) then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return true
    end
    l = l + dir
  end
  return false
end

--- First lines of the agenda blocks (line 1 and the lines after separators).
local function block_starts()
  local out = { 1 }
  local sep = config.opts.agenda.block_separator or "─"
  for l, line in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
    if line ~= "" and line:gsub(vim.pesc(sep), "") == "" then
      out[#out + 1] = l + 1
    end
  end
  return out
end

--- The first query block (search / tags) of the view.
local function query_block()
  for _, b in ipairs(S.view and S.view.blocks or {}) do
    if b.type == "search" or b.type == "tags" or b.type == "tags_todo" then
      return b
    end
  end
end

--- org-agenda-manipulate-query: add a term to a search or tags view.
---@param sign "+"|"-"
---@param regexp boolean
---@param term? string prompted for when nil
function M.manipulate_query(sign, regexp, term)
  local b = query_block()
  if not b and has_agenda_block() then
    -- like Emacs: in a date agenda, [ ] { } include inactive timestamps
    S.inactive = true
    M.redo()
    utils.notify("Display now includes inactive timestamps as well")
    return
  elseif not b then
    utils.warn("Can only manipulate a search or tags query")
    return
  end
  if not term then
    local what = regexp and "regexp" or (b.type == "search" and "word" or "tag")
    local prompt = string.format("%s %s: ", sign == "+" and "Add" or "Exclude", what)
    if regexp or b.type == "search" then
      term = utils.input({ prompt = prompt })
    else
      term = utils.input_complete(prompt, all_tags_in_view())
    end
  end
  if not term or vim.trim(term) == "" then
    return
  end
  term = vim.trim(term)
  local add = sign .. (regexp and ("{" .. term .. "}") or term)
  local match = b.match or ""
  if b.type == "search" then
    match = vim.trim(match)
    local flags, rest = match:match("^([%*!]*)%s*(.*)$")
    if rest ~= "" and not rest:match("^[%+%-{]") then
      -- turn a plain phrase into a boolean query term
      rest = rest:find("%s") and ("+{\\V" .. rest:gsub("\\", "\\\\") .. "}") or ("+" .. rest)
    end
    b.match = vim.trim(flags .. rest .. " " .. add)
  else
    local tags_part, todo_part = match:match("^(.-)(/.*)$")
    b.match = (tags_part or match) .. add .. (todo_part or "")
  end
  M.redo()
end

local function org_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      out[#out + 1] = b
    end
  end
  return out
end

--- Links in an entry's headline and body (headline first).
function M.entry_links(target)
  local file = files.get_buffer(target.bufnr)
  local hl = file:headline_at(target.lnum)
  if not hl then
    return {}
  end
  local links = require("org.links")
  local out = {}
  for i = hl.line, hl.body_end do
    vim.list_extend(out, links.parse_links(file.lines[i] or ""))
  end
  return out
end

--- Set the effort filter from "<1:00", ">30", "=0:15" ("" clears).
function M.set_effort_filter(input)
  input = vim.trim(input or "")
  if input == "" then
    S.filters.effort = nil
  else
    local op, v = input:match("^([<>=]?)%s*(.+)$")
    local minutes = v and (tonumber(v) or date.parse_duration(v))
    if not minutes then
      utils.error("Invalid effort: " .. input)
      return
    end
    S.filters.effort = { op = op ~= "" and op or "<", minutes = minutes }
  end
  M.redo()
end

--- Mark every entry whose agenda line matches `pattern` (Vim regexp).
function M.mark_regexp(pattern)
  local ok, re = pcall(vim.regex, "\\c" .. pattern)
  if not ok then
    utils.error("Invalid regexp: " .. pattern)
    return 0
  end
  local n = 0
  for lnum, item in pairs(S.line_items) do
    local line = vim.api.nvim_buf_get_lines(S.buf, lnum - 1, lnum, false)[1] or ""
    if re:match_str(line) then
      S.marks[item_key(item)] = item
      n = n + 1
    end
  end
  M.render_marks()
  utils.notify(string.format("%d entries marked", n))
  return n
end

M.actions = {
  quit = function()
    M.quit(false)
  end,
  exit = function()
    M.quit(true)
  end,
  redo = function()
    local count = vim.v.count
    if count > 0 and S.view then
      local names = todo_names()
      for _, b in ipairs(S.view.blocks) do
        if b.type == "todo" then
          b.keywords = names[count] and { names[count] } or nil
        end
      end
    end
    M.redo()
  end,
  later = function()
    shift_anchor(1)
  end,
  earlier = function()
    shift_anchor(-1)
  end,
  today = function()
    if not has_agenda_block() then
      require("org.agenda").open_agenda({})
      return
    end
    S.anchor = nil
    M.redo()
    for l, d in pairs(S.day_lines) do
      if d == date.today_days() then
        pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
      end
    end
  end,
  goto_date = function()
    local d = pick_date(date.from_days(S.anchor or date.today_days()), "Go to date")
    if not d then
      return
    end
    if not has_agenda_block() then
      require("org.agenda").open_agenda({ anchor = d:days() })
      return
    end
    S.anchor = d:days()
    M.refresh()
    for l, day in pairs(S.day_lines) do
      if day == d:days() then
        pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
      end
    end
  end,
  day_view = function()
    set_span("day")
  end,
  week_view = function()
    set_span("week")
  end,
  fortnight_view = function()
    set_span("fortnight")
  end,
  month_view = function()
    set_span("month")
  end,
  year_view = function()
    set_span("year")
  end,
  ["goto"] = function()
    M.show_item(true)
  end,
  switch_to = function()
    M.switch_to()
  end,
  show = function()
    M.show_item(false)
  end,
  follow_mode = function()
    S.follow = not S.follow
    utils.notify("Follow mode " .. (S.follow and "on" or "off"))
    if S.follow then
      M.show_item(false)
    end
  end,
  todo = on_item(function(target, item)
    local f = files.get_buffer(target.bufnr)
    if f.settings.todo.has_fast_keys then
      call("org.todo", "select", target)
    else
      call("org.todo", "cycle_next", target)
    end
  end),
  todo_next = on_item(function(target)
    call("org.todo", "cycle_next", target)
  end),
  todo_prev = on_item(function(target)
    call("org.todo", "cycle_prev", target)
  end),
  priority = on_item(function(target)
    call("org.priority", "set", target)
  end),
  priority_up = on_item(function(target)
    call("org.priority", "shift", target, 1)
  end),
  priority_down = on_item(function(target)
    call("org.priority", "shift", target, -1)
  end),
  set_tags = on_item(function(target)
    call("org.tags", "set_tags", target)
  end),
  schedule = on_item(function(target)
    call("org.timestamps", "schedule", target)
  end),
  deadline = on_item(function(target)
    call("org.timestamps", "deadline", target)
  end),
  date_later = on_item(function(target, item)
    call("org.timestamps", "shift", target, kind_of(item), math.max(vim.v.count, 1), "d")
  end),
  date_earlier = on_item(function(target, item)
    call("org.timestamps", "shift", target, kind_of(item), -math.max(vim.v.count, 1), "d")
  end),
  date_prompt = on_item(function(target, item)
    if kind_of(item) == "deadline" then
      call("org.timestamps", "deadline", target)
    else
      call("org.timestamps", "schedule", target)
    end
  end),
  clock_in = on_item(function(target)
    call("org.clock", "clock_in", target)
  end),
  clock_out = function()
    call("org.clock", "clock_out")
    finish({})
  end,
  clock_cancel = function()
    call("org.clock", "clock_cancel")
    finish({})
  end,
  clock_goto = function()
    call("org.clock", "goto_clock")
  end,
  set_effort = on_item(function(target)
    call("org.properties", "set_effort", target)
  end),
  refile = on_item(function(target)
    call("org.refile", "refile", target)
  end),
  archive = on_item(function(target)
    call("org.archive", "archive_subtree", target)
  end),
  toggle_archive_tag = on_item(function(target)
    call("org.archive", "toggle_archive_tag", target)
  end),
  add_note = on_item(function(target)
    local ok, todo = pcall(require, "org.todo")
    if ok and todo.add_note then
      todo.add_note(target)
      return
    end
    local note = utils.input({ prompt = "Note: " })
    if note and vim.trim(note) ~= "" then
      local edit = require("org.edit")
      local ts = date.now():clone({ active = false }):to_string()
      edit.add_log_entry(target.bufnr, target.lnum, edit.log_lines("- Note taken on " .. ts, note))
    end
  end),
  log_mode = function()
    S.log_mode = not S.log_mode
    M.redo()
    utils.notify("Log mode " .. (S.log_mode and "on" or "off"))
  end,
  clockreport_mode = function()
    S.clockreport = not S.clockreport
    M.redo()
    utils.notify("Clock report mode " .. (S.clockreport and "on" or "off"))
  end,
  filter_tag = function()
    local cur = {}
    for t in pairs(S.filters.tags.include) do
      cur[#cur + 1] = "+" .. t
    end
    for t in pairs(S.filters.tags.exclude) do
      cur[#cur + 1] = "-" .. t
    end
    local input = utils.input_complete(
      "Filter tags (+tag -tag, empty clears): ",
      all_tags_in_view(),
      table.concat(cur, " ")
    )
    if input == nil then
      return
    end
    S.filters.tags = { include = {}, exclude = {} }
    for sign, tag in input:gmatch("([%+%-]?)([^%s%+%-]+)") do
      if sign == "-" then
        S.filters.tags.exclude[tag] = true
      else
        S.filters.tags.include[tag] = true
      end
    end
    M.redo()
  end,
  filter_category = function()
    if S.filters.category then
      S.filters.category = nil
    else
      local item = M.item_at_cursor()
      if not item then
        utils.warn("No entry at point to take the category from")
        return
      end
      S.filters.category = item.category
    end
    M.redo()
  end,
  filter_regexp = function()
    local input = utils.input({ prompt = "Filter regexp (prefix - to exclude, empty clears): " })
    if input == nil then
      return
    end
    if input == "" then
      S.filters.regexp = nil
    else
      local neg = input:sub(1, 1) == "-"
      local pattern = neg and input:sub(2) or input
      local ok = pcall(vim.regex, pattern)
      if not ok then
        utils.error("Invalid regexp: " .. pattern)
        return
      end
      S.filters.regexp = { pattern = pattern, neg = neg }
    end
    M.redo()
  end,
  filter_remove = function()
    reset_filters()
    M.redo()
  end,
  mark = function()
    local item = M.item_at_cursor()
    if item then
      S.marks[item_key(item)] = item
      M.render_marks()
    end
    move_to_item(1)
  end,
  unmark = function()
    local item = M.item_at_cursor()
    if item then
      S.marks[item_key(item)] = nil
      M.render_marks()
    end
    move_to_item(1)
  end,
  unmark_all = function()
    S.marks = {}
    M.render_marks()
  end,
  bulk_action = function()
    if not next(S.marks) then
      utils.warn("No entries are marked (use m)")
      return
    end
    local choice = require("org.ui").menu({
      title = string.format("Bulk action (%d marked)", vim.tbl_count(S.marks)),
      items = {
        { key = "t", label = "Change TODO state", value = "t" },
        { key = "s", label = "Schedule", value = "s" },
        { key = "d", label = "Deadline", value = "d" },
        { key = "S", label = "Shift scheduled date by N days", value = "S" },
        { key = "+", label = "Add tag", value = "+" },
        { key = "-", label = "Remove tag", value = "-" },
        { key = "p", label = "Set priority", value = "p" },
        { key = "r", label = "Refile", value = "r" },
        { key = "$", label = "Archive", value = "$" },
        { key = "A", label = "Archive to archive sibling", value = "A" },
        { key = "a", label = "Toggle ARCHIVE tag", value = "a" },
        { key = "f", label = "Apply a Lua function", value = "f" },
      },
    })
    if not choice then
      return
    end
    if choice == "t" then
      local kw = utils.select(vim.list_extend(todo_names(), { "(none)" }), { prompt = "New TODO state" })
      if not kw then
        return
      end
      bulk(function(target)
        call("org.todo", "change_state", target, kw ~= "(none)" and kw or nil)
      end)
    elseif choice == "s" or choice == "d" then
      local d = pick_date(date.today(), choice == "s" and "Schedule" or "Deadline")
      if not d then
        return
      end
      local kind = choice == "s" and "scheduled" or "deadline"
      d = d:clone({ active = true })
      bulk(function(target)
        local ok, ts = pcall(require, "org.timestamps")
        if ok and ts.set_date then
          ts.set_date(target, kind, d)
        else
          require("org.edit").set_planning(target.bufnr, target.lnum, kind, d)
        end
      end)
    elseif choice == "S" then
      local n = tonumber(utils.input({ prompt = "Shift by days: " }) or "")
      if not n then
        return
      end
      bulk(function(target)
        call("org.timestamps", "shift", target, "scheduled", n, "d")
      end)
    elseif choice == "+" or choice == "-" then
      local tag = utils.input_complete(choice == "+" and "Add tag: " or "Remove tag: ", all_tags_in_view())
      if not tag or vim.trim(tag) == "" then
        return
      end
      tag = vim.trim(tag):gsub(":", "")
      bulk(function(target)
        add_remove_tag(target, tag, choice == "+")
      end)
    elseif choice == "p" then
      local p = utils.input({ prompt = "Priority (A-Z, space removes): " })
      if p == nil then
        return
      end
      bulk(function(target)
        call("org.priority", "set", target, p)
      end)
    elseif choice == "r" then
      local ok, refile = pcall(require, "org.refile")
      local dest = ok and refile.pick_target and refile.pick_target({ prompt = "Refile marked entries to" })
      if ok and not dest then
        return
      end
      bulk(function(target)
        call("org.refile", "refile", target, { dest = dest })
      end)
    elseif choice == "$" then
      bulk(function(target)
        call("org.archive", "archive_subtree", target)
      end)
    elseif choice == "A" then
      bulk(function(target)
        call("org.archive", "archive_to_sibling", target)
      end)
    elseif choice == "a" then
      bulk(function(target)
        call("org.archive", "toggle_archive_tag", target)
      end)
    elseif choice == "f" then
      local expr = utils.input({ prompt = "Function (Lua, receives target { bufnr, lnum }): " })
      if not expr or vim.trim(expr) == "" then
        return
      end
      local chunk = loadstring("return " .. expr)
      local ok, fn = pcall(chunk or error)
      if not ok or type(fn) ~= "function" then
        utils.error("Not a function: " .. expr)
        return
      end
      bulk(function(target)
        fn(target)
      end)
    end
  end,
  entry_text_mode = function()
    toggle("entry_text", "Entry text mode")
  end,
  archives_mode = function()
    toggle("archives", "Archived trees", "trees")
  end,
  archives_files_mode = function()
    S.archives = S.archives ~= "files" and "files" or false
    M.redo()
    utils.notify("Archived trees and archive files " .. (S.archives and "on" or "off"))
  end,
  inactive_mode = function()
    toggle("inactive", "Inactive timestamps")
  end,
  log_all_mode = function()
    toggle("log_mode", "Log mode (all entries)", "all")
  end,
  time_grid = function()
    S.time_grid_off = not S.time_grid_off
    M.redo()
    utils.notify("Time grid " .. (S.time_grid_off and "off" or "on"))
  end,
  reset_view = function()
    set_span(nil)
  end,
  filter_effort = function()
    local input = utils.input({ prompt = "Effort filter (<1:00, >30, =0:15; empty clears): " })
    if input == nil then
      return
    end
    M.set_effort_filter(input)
  end,
  filter_top_headline = function()
    if S.filters.top then
      S.filters.top = nil
    else
      local item = M.item_at_cursor()
      if not item or not item.headline then
        utils.warn("No entry at point to take the top headline from")
        return
      end
      local h = item.headline
      while h.parent do
        h = h.parent
      end
      S.filters.top = { key = M.top_key(item), title = h:plain_title() }
    end
    M.redo()
  end,
  query_add = function()
    M.manipulate_query("+", false)
  end,
  query_subtract = function()
    M.manipulate_query("-", false)
  end,
  query_add_re = function()
    M.manipulate_query("+", true)
  end,
  query_subtract_re = function()
    M.manipulate_query("-", true)
  end,
  mark_all = function()
    for _, item in pairs(S.line_items) do
      S.marks[item_key(item)] = item
    end
    M.render_marks()
    utils.notify(string.format("%d entries marked", vim.tbl_count(S.marks)))
  end,
  toggle_mark = function()
    local item = M.item_at_cursor()
    if item then
      local k = item_key(item)
      S.marks[k] = not S.marks[k] and item or nil
      M.render_marks()
    end
    move_to_item(1)
  end,
  toggle_mark_all = function()
    for _, item in pairs(S.line_items) do
      local k = item_key(item)
      S.marks[k] = not S.marks[k] and item or nil
    end
    M.render_marks()
  end,
  mark_regexp = function()
    local input = utils.input({ prompt = "Mark entries matching regexp: " })
    if not input or input == "" then
      return
    end
    M.mark_regexp(input)
  end,
  kill = on_item(function(target)
    local file = files.get_buffer(target.bufnr)
    local hl = file:headline_at(target.lnum)
    if not hl then
      return
    end
    local n = hl.end_line - hl.line + 1
    local limit = config.opts.agenda.confirm_kill
    if limit == nil then
      limit = 1
    end
    if limit and n > limit then
      local name = vim.fn.fnamemodify(file.filename or "", ":t")
      if not utils.confirm(string.format('Delete entry with %d lines in "%s"?', n, name)) then
        return
      end
    end
    vim.api.nvim_buf_set_lines(target.bufnr, hl.line - 1, hl.end_line, false, {})
    utils.notify("Agenda item and source killed")
  end),
  open_link = function()
    local item = M.item_at_cursor()
    if not item then
      utils.warn("No agenda entry on this line")
      return
    end
    local target = M.resolve_target(item)
    if not target then
      return
    end
    local list = M.entry_links(target)
    if #list == 0 then
      utils.warn("No link to open here")
      return
    end
    local link = list[1]
    if #list > 1 then
      link = utils.select(list, {
        prompt = "Open link",
        format_item = function(l)
          return l.desc and (l.desc .. " (" .. l.target .. ")") or l.target
        end,
      })
      if not link then
        return
      end
    end
    require("org.links").open(link.target, { bufnr = target.bufnr })
  end,
  set_property = on_item(function(target)
    call("org.properties", "set_property", target)
  end),
  show_tags = function()
    local item = M.item_at_cursor()
    if not item then
      return
    end
    local tags = item.tags or {}
    utils.notify(#tags > 0 and ("Tags are :" .. table.concat(tags, ":") .. ":") or "No tags associated with this line")
  end,
  recenter = function()
    M.show_item(false)
    pcall(vim.api.nvim_win_call, other_window(), function()
      vim.cmd("normal! zz")
    end)
  end,
  delete_other_windows = function()
    pcall(vim.cmd, "only")
  end,
  save_all = function()
    local n = 0
    for _, b in ipairs(org_buffers()) do
      if vim.bo[b].modified then
        utils.save_buffer(b)
        n = n + 1
      end
    end
    utils.notify(string.format("Saved %d org buffer(s)", n))
  end,
  next_date_line = function()
    move_to_line(1, function(l)
      return S.day_lines[l] ~= nil
    end)
  end,
  prev_date_line = function()
    move_to_line(-1, function(l)
      return S.day_lines[l] ~= nil
    end)
  end,
  forward_block = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    for _, l in ipairs(block_starts()) do
      if l > lnum and l <= vim.api.nvim_buf_line_count(S.buf) then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
        return
      end
    end
  end,
  backward_block = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local starts = block_starts()
    for i = #starts, 1, -1 do
      if starts[i] < lnum then
        vim.api.nvim_win_set_cursor(0, { starts[i], 0 })
        return
      end
    end
  end,
  archive_default = on_item(function(target, item)
    if not utils.confirm('Archive "' .. item.title .. '"?') then
      return
    end
    call("org.archive", "archive_subtree", target)
  end),
  archive_sibling = on_item(function(target)
    call("org.archive", "archive_to_sibling", target)
  end),
  timer = function()
    call("org.timer", "countdown")
  end,
  next_item = function()
    move_to_item(1)
  end,
  prev_item = function()
    move_to_item(-1)
  end,
  capture = function()
    local day = has_agenda_block() and M.day_at_cursor() or nil
    call("org.capture", "prompt", { date = day and date.from_days(day) or nil })
  end,
  export = function()
    M.export()
  end,
  help = function()
    require("org.mappings").show_help()
  end,
}

--- Write the agenda text to a file (.html gets a simple HTML page).
function M.export(path)
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  path = path or utils.input({ prompt = "Export agenda to: ", default = vim.fn.expand("~/agenda.txt"), completion = "file" })
  if not path or path == "" then
    return
  end
  path = vim.fn.expand(path)
  local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
  if path:match("%.html?$") then
    local esc = vim.tbl_map(function(l)
      return (l:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end, lines)
    local out = {
      "<!DOCTYPE html>",
      "<html><head><meta charset=\"utf-8\"><title>Org Agenda</title>",
      "<style>body{font-family:monospace;white-space:pre}</style></head><body>",
    }
    vim.list_extend(out, esc)
    vim.list_extend(out, { "</body></html>" })
    lines = out
  end
  utils.writefile(path, lines)
  utils.notify("Agenda written to " .. path)
end

---------------------------------------------------------------------------
-- Mappings
---------------------------------------------------------------------------

setup_mappings = function(buf)
  local maps = config.opts.mappings.agenda or {}
  local all = {}
  for name, value in pairs(maps) do
    for _, lhs in ipairs(config.lhs_list(value)) do
      all[#all + 1] = { name = name, lhs = lhs }
    end
  end
  for _, m in ipairs(all) do
    local fn = M.actions[m.name]
    if fn then
      -- nowait unless the key is a prefix of another agenda mapping
      local prefix_of_other = false
      local kc = vim.keycode(m.lhs)
      for _, o in ipairs(all) do
        local ok = vim.keycode(o.lhs)
        if o ~= m and #ok > #kc and ok:sub(1, #kc) == kc then
          prefix_of_other = true
        end
      end
      vim.keymap.set("n", m.lhs, function()
        utils.run(fn)
      end, { buffer = buf, nowait = not prefix_of_other, desc = "org agenda: " .. m.name:gsub("_", " ") })
    end
  end
end

return M
