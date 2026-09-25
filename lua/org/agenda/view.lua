---@mod org.agenda.view Agenda buffer, window and actions

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local render = require("org.agenda.render")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.agenda")
local ns_marks = vim.api.nvim_create_namespace("org.agenda.marks")

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
    dim_blocked = true, -- true | false | "invisible"
    filters = empty_filters(),
    limits = {},
    marks = {},
    line_items = {},
    line_parts = {},
    day_lines = {},
    info = {},
    restrict = nil,
    new_buffers = {},
  }
end

local states = {} -- agenda bufnr -> state
local S = new_state()
M.state = S

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
--- "+{regexp}") (org-agenda-filter-make-matcher-tag-exp).
local function tag_element(x, tags)
  local op, tag = x:sub(1, 1), x:sub(2)
  local r
  if tag == "" then
    r = #tags > 0
  elseif tag:match("^{.*}$") then
    r = false
    local ok, re = pcall(require("org.agenda.search").compile_emacs_regexp, tag:sub(2, -2))
    if ok then
      for _, t in ipairs(tags) do
        if re:match_str(t) then
          r = true
          break
        end
      end
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
  return function(it)
    local tags = it.tags or {}
    for _, x in ipairs(tag) do
      if not tag_element(x, tags) then
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
    local extra = block.text_search_extra_files or config.opts.agenda.text_search_extra_files or {}
    local seen = {}
    for _, f in ipairs(list) do
      seen[f.filename or ""] = true
    end
    local with_archives = false
    local rest = {}
    for _, e in ipairs(extra) do
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
    dim_blocked = S.dim_blocked,
    restrict = S.restrict and { range = S.restrict.range } or nil,
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
  local buf = S.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  S.line_parts = {}
  for _, h in ipairs(b.hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4], priority = 110 })
    local l = S.line_parts[h[1] + 1] or {}
    l[#l + 1] = { h[2], h[3], h[4] }
    S.line_parts[h[1] + 1] = l
  end
  S.line_hl_groups = b.line_hls
  for lnum, group in pairs(b.line_hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, { line_hl_group = group, priority = 90 })
  end
  M.render_marks()
  update_winbar()
  local ok, cols = pcall(require, "org.agenda.columns")
  if ok then
    pcall(cols.refresh_if_active)
  end
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

--- Echo the outline path of the entry at point (org-agenda-show-outline-path).
local function show_outline_path()
  if not config.opts.agenda.show_outline_path or #vim.api.nvim_list_uis() == 0 then
    return
  end
  local item = M.item_at_cursor()
  if not (item and item.headline) then
    return
  end
  local path = item.headline:outline_path()
  path[#path + 1] = item.headline:plain_title()
  local text = table.concat(path, "/")
  vim.api.nvim_echo({ { text } }, false, {})
end

local function ensure_buf(name)
  for buf, st in pairs(states) do
    if st.name == name and vim.api.nvim_buf_is_valid(buf) then
      use(st)
      return buf, false
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "orgagenda"
  local st = new_state()
  st.buf = buf
  st.name = name
  -- keep settings that persist across agendas (persistent filter)
  if config.opts.agenda.persistent_filter and S then
    st.filters = vim.deepcopy(S.filters)
  end
  states[buf] = st
  use(st)
  setup_mappings(buf)
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      if states[buf] then
        use(states[buf])
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if states[buf] then
        use(states[buf])
      end
      if S.follow then
        vim.schedule(function()
          M.show_item(false)
        end)
      end
      show_outline_path()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local st2 = states[buf]
      states[buf] = nil
      if st2 then
        st2.buf = nil
        st2.win = nil
      end
    end,
  })
  return buf, true
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

--- The window layout of the current tab: a tree of splits with buffers.
local function save_layout()
  local function walk(node)
    if node[1] == "leaf" then
      local w = node[2]
      return { "leaf", vim.api.nvim_win_get_buf(w), vim.api.nvim_win_get_cursor(w), w }
    end
    local children = {}
    for _, c in ipairs(node[2]) do
      children[#children + 1] = walk(c)
    end
    return { node[1], children }
  end
  local ok, tree = pcall(function()
    return walk(vim.fn.winlayout())
  end)
  return ok and { tree = tree, current = vim.api.nvim_get_current_win() } or nil
end

--- Rebuild a layout saved by save_layout in the current tab.
local function restore_layout(saved)
  if not saved then
    return false
  end
  pcall(vim.cmd, "silent! only")
  local focus
  local function build(node, win)
    vim.api.nvim_set_current_win(win)
    if node[1] == "leaf" then
      if vim.api.nvim_buf_is_valid(node[2]) then
        vim.api.nvim_win_set_buf(win, node[2])
        pcall(vim.api.nvim_win_set_cursor, win, node[3])
      end
      if node[4] == saved.current then
        focus = win
      end
      return
    end
    local wins = { win }
    for i = 2, #node[2] do
      vim.api.nvim_set_current_win(wins[#wins])
      vim.cmd(node[1] == "row" and "rightbelow vsplit" or "rightbelow split")
      wins[#wins + 1] = vim.api.nvim_get_current_win()
    end
    for i, c in ipairs(node[2]) do
      build(c, wins[i])
    end
  end
  local ok = pcall(build, saved.tree, vim.api.nvim_get_current_win())
  if focus and vim.api.nvim_win_is_valid(focus) then
    vim.api.nvim_set_current_win(focus)
  end
  return ok
end

--- Display the agenda buffer (org-agenda-window-setup).
local function show_buffer()
  local buf = S.buf
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      vim.api.nvim_set_current_win(w)
      S.win = w
      set_win_opts(w)
      return
    end
  end
  local acfg = config.opts.agenda
  local mode = acfg.window or "split"
  if mode == "reorganize-frame" then
    mode = "split"
  elseif mode == "current-window" then
    mode = "current"
  elseif mode == "only-window" then
    mode = "only"
  elseif mode == "other-window" then
    mode = "other"
  elseif mode == "other-tab" or mode == "other-frame" then
    mode = "tab"
  end
  S.prev_win = vim.api.nvim_get_current_win()
  S.prev_buf = vim.api.nvim_get_current_buf()
  S.layout = acfg.restore_windows_after_quit and save_layout() or nil
  S.win_mode = mode
  if mode == "float" then
    S.win = require("org.ui").open_buffer_window(buf, "float", { title = "Org Agenda", width = 0.9, height = 0.85 })
  elseif mode == "split" then
    -- reorganize-frame: two windows, the current one and the agenda
    pcall(vim.cmd, "silent! only")
    S.prev_win = vim.api.nvim_get_current_win()
    S.win = require("org.ui").open_buffer_window(buf, "split")
  elseif mode == "vsplit" or mode == "tab" then
    S.win = require("org.ui").open_buffer_window(buf, mode)
  elseif mode == "only" then
    pcall(vim.cmd, "silent! only")
    vim.api.nvim_set_current_buf(buf)
    S.win = vim.api.nvim_get_current_win()
  elseif mode == "other" then
    local cur = vim.api.nvim_get_current_win()
    local other
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= cur and vim.api.nvim_win_get_config(w).relative == "" then
        other = w
        break
      end
    end
    if not other then
      vim.cmd("rightbelow split")
      other = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_set_buf(other, buf)
    S.win = other
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

--- Filter presets of a view's blocks (org-agenda-*-filter-preset).
local function view_presets(view)
  local p = { tag = {}, category = {}, regexp = {}, effort = {} }
  local function add(kind, v)
    if type(v) == "string" then
      v = { v }
    end
    for _, x in ipairs(v or {}) do
      if not vim.tbl_contains(p[kind], x) then
        p[kind][#p[kind] + 1] = x
      end
    end
  end
  for _, src in ipairs({ view.settings or {}, unpack(view.blocks or {}) }) do
    add("tag", src.tag_filter_preset or src.org_agenda_tag_filter_preset)
    add("category", src.category_filter_preset or src.org_agenda_category_filter_preset)
    add("regexp", src.regexp_filter_preset or src.org_agenda_regexp_filter_preset)
    add("effort", src.effort_filter_preset or src.org_agenda_effort_filter_preset)
  end
  return p
end

--- A buffer name for a view (org-agenda-sticky: "*Org Agenda(KEY)*").
local function buffer_name(view, opts)
  if not config.opts.agenda.sticky then
    return "org://agenda"
  end
  local key = opts.key or view.key
  if not key then
    local b = view.blocks[1] or {}
    key = (b.type == "agenda" and "a") or (b.type == "todo" and "t") or (b.type == "tags" and "m")
      or (b.type == "tags_todo" and "M") or (b.type == "search" and "s") or (b.type == "stuck" and "#") or "a"
    if b.match and b.match ~= "" then
      key = key .. ":" .. b.match
    elseif b.keywords then
      key = key .. ":" .. table.concat(type(b.keywords) == "table" and b.keywords or { b.keywords }, "|")
    end
  end
  return "org://agenda(" .. key .. ")"
end

--- Open a view.
---@param view { blocks: table[], title?: string, multi?: boolean, key?: string }
---@param opts? { anchor?: integer, span?: string|integer, restrict?: table, keep_state?: boolean, key?: string }
function M.open(view, opts)
  opts = opts or {}
  local name = buffer_name(view, opts)
  local prev = S
  local _, created = ensure_buf(name)
  if config.opts.agenda.sticky and not created and S.view and not opts.keep_state then
    -- a sticky agenda is shown as it is (org-agenda-use-sticky-p)
    show_buffer()
    utils.notify("Sticky Agenda buffer, use `r' to refresh")
    return
  end
  S.view = view
  view.presets = view_presets(view)
  if not opts.keep_state then
    local acfg = config.opts.agenda
    S.anchor = opts.anchor
    S.span = opts.span
    S.align = true
    S.log_mode = acfg.start_with_log_mode or false
    S.clockreport = acfg.start_with_clockreport_mode or false
    S.entry_text = acfg.start_with_entry_text_mode or false
    S.follow = acfg.start_with_follow_mode or false
    S.archives = false
    S.inactive = false
    S.time_grid_off = false
    S.no_deadlines = false
    S.dim_blocked = acfg.dim_blocked_tasks
    if S.dim_blocked == nil then
      S.dim_blocked = true
    end
    S.marks = {}
    S.limits = {}
    if acfg.persistent_filter and prev and prev ~= S then
      S.filters = vim.deepcopy(prev.filters)
    elseif not acfg.persistent_filter then
      S.filters = empty_filters()
    end
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
  local ok, cols = pcall(require, "org.agenda.columns")
  if ok then
    pcall(cols.refresh_if_active, true)
  end
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

--- Quit the agenda window (org-agenda-quit). `wipe` also deletes the
--- buffer (org-agenda-Quit).
function M.quit(wipe)
  -- windows switching below may make another agenda buffer current
  local S = S
  S.follow = false
  local win = S.win
  local mode = S.win_mode
  local layout = S.layout
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
    -- the filter display belongs to the agenda, not to the window
    pcall(vim.api.nvim_set_option_value, "winbar", "", { scope = "local", win = win })
  end
  if layout and win and vim.api.nvim_win_is_valid(win) and mode ~= "float" and mode ~= "tab" then
    vim.api.nvim_set_current_win(win)
    restore_layout(layout)
    S.layout = nil
  elseif win and vim.api.nvim_win_is_valid(win) then
    local closable = mode == "float" or mode == "split" or mode == "vsplit" or mode == "other"
    if closable and #vim.api.nvim_list_wins() > 1 then
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
    if S.prev_win and vim.api.nvim_win_is_valid(S.prev_win) then
      pcall(vim.api.nvim_set_current_win, S.prev_win)
    end
  end
  S.win = nil
  if wipe and S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    local b = S.buf
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    S.buf = nil
  end
end

--- org-agenda-exit: quit, kill the agenda buffers and the unmodified
--- buffers the agenda loaded.
function M.exit()
  local loaded = {}
  for _, st in pairs(states) do
    for b in pairs(st.new_buffers or {}) do
      loaded[b] = true
    end
  end
  for b in pairs(S.new_buffers or {}) do
    loaded[b] = true
  end
  M.quit(true)
  for b in pairs(loaded) do
    if vim.api.nvim_buf_is_valid(b) and not vim.bo[b].modified and #vim.fn.win_findbuf(b) == 0 then
      pcall(vim.api.nvim_buf_delete, b, {})
    end
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
    bufnr = utils.find_buffer(item.filename)
    if not bufnr then
      bufnr = utils.load_buffer(item.filename)
      S.new_buffers[bufnr] = true
    end
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
  return w
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

--- After an edit: save when `save_after_edit` is set (Emacs leaves the
--- buffers modified) and rebuild the agenda.
local function finish(bufs)
  if config.opts.agenda.save_after_edit then
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

--- The date in the source of an item: its SCHEDULED/DEADLINE, or the
--- plain timestamp it comes from.
local function source_date(target, item)
  -- only SCHEDULED, DEADLINE and active plain timestamps of date views
  local t = item.type
  if item.sexp or item.inactive or item.log or not item.day
    or not (t == "scheduled" or t == "deadline" or t == "timestamp" or t == "range") then
    return nil, nil
  end
  local file = files.get_buffer(target.bufnr)
  local hl = file:headline_at(target.lnum)
  if not hl then
    return nil, nil
  end
  local kind = kind_of(item)
  if kind == "timestamp" then
    local t = hl.timestamps[item.ts_index or 1]
    return t and t.date, kind
  end
  return hl.planning[kind], kind
end

--- Shift the date of the item at point by `n` days (org-agenda-date-later):
--- the timestamp the item comes from. With
--- org-agenda-move-date-from-past-immediately-to-today, a single step on a
--- past date moves it to today.
function M.shift_item(target, item, n, explicit_count)
  if item.sexp or item.inactive or item.log or not item.day then
    utils.warn("Cannot change this date from the agenda line")
    return
  end
  local d, kind = source_date(target, item)
  if not d then
    utils.warn("No timestamp to shift")
    return
  end
  if not explicit_count and n == 1 and not d.range_end then
    local today = date.today_days()
    if d:days() < today then
      n = today - d:days()
    end
  end
  local t = vim.tbl_extend("force", target, { ts_index = item.ts_index })
  call("org.timestamps", "shift", t, kind, n, "d")
end

--- Change the date of the item at point (org-agenda-date-prompt): the time
--- of the timestamp is kept unless a new one is given.
function M.date_prompt(target, item)
  local d, kind = source_date(target, item)
  if not kind then
    utils.warn("Cannot change this date from the agenda line")
    return
  end
  if kind ~= "timestamp" then
    if kind == "deadline" then
      call("org.timestamps", "deadline", target)
    else
      call("org.timestamps", "schedule", target)
    end
    return
  end
  if not d then
    utils.warn("No timestamp to change")
    return
  end
  local picked = M.pick_date(d, "Change date")
  if not picked or picked.remove then
    return
  end
  local new = d:clone({ year = picked.year, month = picked.month, day = picked.day })
  if picked.hour then
    new.hour, new.min, new.end_hour, new.end_min = picked.hour, picked.min, picked.end_hour, picked.end_min
  end
  if d.range_end then
    new.range_end = d.range_end:add(new:days() - d:days(), "d")
  end
  call("org.timestamps", "set_date", vim.tbl_extend("force", target, { ts_index = item.ts_index }), "timestamp", new)
end

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

--- Change the span (org-agenda-change-time-span): the span starts where
--- `org-agenda-compute-starting-span` puts it for the day at point.
local function set_span(span)
  if not has_agenda_block() then
    require("org.agenda").open_agenda({ span = span, anchor = S.anchor })
    return
  end
  local day = M.day_at_cursor() or S.anchor or date.today_days()
  if span then
    S.anchor = render.starting_day(span, day)
  else
    S.anchor = nil
  end
  S.span = span
  M.redo()
  utils.notify("Switched to " .. tostring(span or current_span()) .. " view")
end

local function shift_anchor(dir)
  if not has_agenda_block() then
    utils.warn("Not in a date-based agenda view")
    return
  end
  local n = math.max(vim.v.count, 1) * dir
  local first = S.info[1] and S.info[1].from
  for _, inf in pairs(S.info) do
    first = inf.from
    break
  end
  S.anchor = render.shift_anchor(current_span(), first or S.anchor or date.today_days(), n)
  M.refresh()
  local l1
  for l in pairs(S.day_lines) do
    if not l1 or l < l1 then
      l1 = l
    end
  end
  if l1 then
    pcall(vim.api.nvim_win_set_cursor, 0, { l1, 0 })
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

local function all_categories_in_view()
  local set = {}
  for _, it in pairs(S.line_items) do
    if it.category and it.category ~= "" then
      set[it.category] = true
    end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

--- Marked entries, parents before children (org-agenda-bulk-action).
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

local function bulk(fn, persistent)
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
  if not persistent then
    S.marks = {}
  end
  finish(vim.tbl_keys(bufs))
  utils.notify(string.format("%d entries processed", n))
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

--- First lines of the agenda blocks.
local function block_starts()
  return S.block_starts or { 1 }
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
    local flags, rest = match:match("^([%*!:]*)%s*(.*)$")
    if rest ~= "" and not rest:match("^[%+%-{]") then
      -- turn a plain phrase into a boolean query term
      rest = rest:find("%s") and ('+"' .. rest .. '"') or ("+" .. rest)
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

---------------------------------------------------------------------------
-- Filters (org-agenda-filter and friends)
---------------------------------------------------------------------------

--- Set the effort filter from "<1:00", ">30", "=0:15", "-<1:00" ("" clears).
function M.set_effort_filter(input)
  input = vim.trim(input or "")
  if input == "" then
    S.filters.effort = {}
  else
    local neg, op, v = input:match("^([%+%-]?)([<>=]?)%s*(.+)$")
    local minutes = v and (tonumber(v) or date.parse_duration(v))
    if not minutes then
      utils.error("Invalid effort: " .. input)
      return
    end
    S.filters.effort = { (neg == "-" and "-" or "+") .. (op ~= "" and op or "<") .. v }
  end
  M.redo()
end

--- Set the tag filter to a list like { "+work", "-home" }.
function M.set_tag_filter(list)
  S.filters.tag = list or {}
  M.redo()
end

--- Parse an org-agenda-filter string ("+work-John<0:10-/plot/") into
--- filter lists. Tags win over categories.
function M.parse_filter(s, negate)
  local tags, cats = {}, {}
  for _, t in ipairs(all_tags_in_view()) do
    tags[t] = true
  end
  for _, c in ipairs(all_categories_in_view()) do
    cats[c] = true
  end
  local out = { tag = {}, category = {}, regexp = {}, effort = {} }
  local function push(list, v)
    if not vim.tbl_contains(list, v) then
      list[#list + 1] = v
    end
  end
  -- a hyphen inside double quotes belongs to the name
  s = s:gsub('"([^"]*)-([^"]*)"', '"%1~~~%2"')
  while true do
    local ws, pm = s:match("^([ \t]*)([%+%-]?)")
    local rest = s:sub(#ws + #pm + 1)
    local name = rest:match("^[^%-%+<>=/ \t]+")
    local eff = not name and rest:match("^[<>=][%d:]+")
    local re, re_full
    if not name and not eff then
      re_full, re = rest:match("^(/([^/]+)/?)")
    end
    if not (name or eff or re) then
      break
    end
    pm = pm ~= "" and pm or "+"
    if negate then
      pm = pm == "+" and "-" or "+"
    end
    if name then
      name = name:gsub("~~~", "-")
      if tags[name] then
        push(out.tag, pm .. name)
      elseif cats[(name:gsub('^"(.*)"$', "%1"))] then
        push(out.category, pm .. name:gsub('^"(.*)"$', "%1"))
      else
        utils.notify(string.format("`%s%s' filter ignored because tag/category is not represented", pm, name))
      end
      s = rest:sub(#name + 1)
    elseif eff then
      push(out.effort, pm .. eff)
      s = rest:sub(#eff + 1)
    else
      push(out.regexp, pm .. re)
      s = rest:sub(#re_full + 1)
    end
  end
  return out
end

--- The current filters as an org-agenda-filter string.
local function filter_string()
  local f = S.filters
  local s = join(f.category) .. join(f.tag)
  if f.effort[1] then
    s = s .. f.effort[1]:gsub("^%+", "")
  end
  if f.regexp[1] then
    s = s .. "/" .. f.regexp[1]:gsub("^%+", "") .. "/"
  end
  return s
end

--- Tag filter from `auto_exclude_function` (org-agenda-auto-exclude-function).
local function auto_exclude()
  local fn = config.opts.agenda.auto_exclude_function
  if type(fn) ~= "function" then
    utils.error("`agenda.auto_exclude_function' is undefined")
    return
  end
  S.filters.tag = {}
  for _, t in ipairs(all_tags_in_view()) do
    local m = fn(t:lower())
    if m then
      S.filters.tag[#S.filters.tag + 1] = m
    end
  end
  M.redo()
end

--- org-agenda-filter-by-tag with a key: a tag selection key, SPC (any tag),
--- `?` (untagged), TAB (completion), `.` (tags of the entry at point), `\`
--- (off), RET (auto exclude), `+`/`-` (filter for/against), q (quit).
function M.filter_by_tag(count)
  local exclude = count == 1
  local accumulate = count == 2
  local keys = {}
  local chars = {}
  for _, f in ipairs(files.agenda_files()) do
    for _, d in ipairs(f:tag_definitions()) do
      if d.key and d.name and not keys[d.key] then
        keys[d.key] = d.name
        chars[#chars + 1] = d.key
      end
    end
  end
  local tag
  while true do
    local prompt = string.format(
      "%s by tag: [%s ]tag-char [TAB]tag [?]untagged %s[\\]off [q]uit",
      exclude and "Exclude[+]" or "Filter[-]",
      table.concat(chars, ""),
      config.opts.agenda.auto_exclude_function and "[RET] " or ""
    )
    local ch = utils.getchar(prompt)
    if not ch or ch == "q" then
      return
    elseif ch == "-" then
      exclude = true
    elseif ch == "+" then
      exclude = false
    elseif ch == "\\" then
      S.filters.tag = {}
      M.redo()
      return
    elseif ch == "\r" then
      if config.opts.agenda.auto_exclude_function then
        auto_exclude()
      else
        S.filters.tag = {}
        M.redo()
      end
      return
    elseif ch == "." then
      local item = M.item_at_cursor()
      S.filters.tag = {}
      for _, t in ipairs(item and item.tags or {}) do
        S.filters.tag[#S.filters.tag + 1] = "+" .. t
      end
      M.redo()
      return
    elseif ch == "\t" then
      tag = utils.input_complete("Tag: ", all_tags_in_view())
      if not tag or tag == "" then
        return
      end
      break
    elseif ch == " " then
      tag = ""
      break
    elseif ch == "?" then
      tag, exclude = "", not exclude
      break
    elseif keys[ch] then
      tag = keys[ch]
      break
    else
      utils.error("Invalid tag selection character " .. ch)
      return
    end
  end
  local new = { (exclude and "-" or "+") .. tag }
  if accumulate then
    vim.list_extend(new, S.filters.tag)
  end
  S.filters.tag = new
  M.redo()
end

--- org-agenda-filter-by-effort: an operator key, then the index of an
--- Effort_ALL value (1..9, 0 = 10th).
function M.filter_by_effort(count)
  local negative = count == 1
  local keep = count == 2
  local op
  while not op do
    local ch = utils.getchar("Effort operator? (> = or <)     or press `_' again to remove filter")
    if not ch then
      return
    elseif ch == "_" then
      S.filters.effort = {}
      M.redo()
      utils.notify("Effort filter removed")
      return
    elseif ch == "<" or ch == ">" or ch == "=" then
      op = ch
    end
  end
  local all = (config.opts.global_properties or {})[(config.opts.effort_property or "Effort") .. "_ALL"]
    or "0 0:10 0:30 1:00 2:00 3:00 4:00 5:00 6:00 7:00"
  local efforts = vim.split(all, "%s+", { trimempty = true })
  local labels = {}
  for i, e in ipairs(efforts) do
    labels[#labels + 1] = string.format("[%d]%s", i % 10, e)
  end
  local idx
  while not idx do
    local ch = utils.getchar("Effort " .. op .. " " .. table.concat(labels, " "))
    if not ch then
      return
    end
    local n = tonumber(ch)
    if n then
      n = n == 0 and 10 or n
      if efforts[n] then
        idx = n
      end
    end
  end
  local new = { (negative and "-" or "+") .. op .. efforts[idx] }
  if keep then
    vim.list_extend(new, S.filters.effort)
  end
  S.filters.effort = new
  M.redo()
end

--- Set a limit (org-agenda-limit-interactively); count > 0 removes them.
function M.limit(count)
  if count and count > 0 then
    S.limits = {}
    M.redo()
    utils.notify("Agenda limits removed")
    return
  end
  local ch = utils.getchar("Number of [e]ntries [t]odos [T]ags [E]ffort? ")
  local names = { e = "max_entries", t = "max_todos", T = "max_tags", E = "max_effort" }
  local name = ch and names[ch]
  if not name then
    return
  end
  local prompt = name == "max_effort" and "How many minutes? " or "How many? "
  local n = tonumber(utils.input({ prompt = prompt }) or "")
  if not n then
    return
  end
  S.limits[name] = n
  M.redo()
end

--- Mark every entry whose agenda line matches `pattern` (Emacs regexp).
function M.mark_regexp(pattern)
  local ok, re = pcall(require("org.agenda.search").compile_emacs_regexp, pattern)
  if not ok then
    ok, re = pcall(vim.regex, "\\c" .. pattern)
  end
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

---------------------------------------------------------------------------
-- Bulk actions (org-agenda-bulk-action)
---------------------------------------------------------------------------

--- Days from today for an entry scattered over `days` days; with
--- `skip_weekends`, weekend days are jumped over.
function M.scatter_distance(days, skip_weekends, rand)
  rand = rand or math.random
  local distance = 1 + (rand(days) - 1)
  if skip_weekends then
    local weekend = {}
    for _, w in ipairs(config.opts.agenda.weekend_days or { 6, 0 }) do
      weekend[w] = true
    end
    local dow = date.today():weekday() % 7
    for _ = 1, distance + 1 do
      while weekend[dow] do
        distance = distance + 1
        dow = (dow + 1) % 7
      end
      dow = (dow + 1) % 7
    end
  end
  return distance
end

--- Read a date for bulk (re)scheduling: a "++N[dwmy]" answer shifts each
--- entry's own date; an empty answer opens the calendar.
local function read_bulk_date(prompt)
  local input = utils.input({ prompt = prompt .. ": " })
  if input == nil then
    return nil
  end
  local n, unit = input:match("^%s*%+%+(%-?%d+)([hdwmy]?)%s*$")
  if n then
    return { shift = tonumber(n), unit = unit ~= "" and unit or "d" }
  end
  if vim.trim(input) == "" then
    local d = M.pick_date(date.today(), prompt)
    return d and { date = d:clone({ active = true }) } or nil
  end
  local d = date.read_date(input, date.today())
  if not d then
    utils.error("Invalid date: " .. input)
    return nil
  end
  return { date = d:clone({ active = true }) }
end

function M.bulk_action()
  if not next(S.marks) then
    local item = M.item_at_cursor()
    if not item then
      utils.warn("No entries are marked")
      return
    end
    S.marks[item_key(item)] = item
  end
  local acfg = config.opts.agenda
  local persistent = acfg.persistent_marks or false
  local custom = acfg.bulk_custom_functions or {}
  local choice
  while true do
    local items = {
      { key = "p", label = (persistent and "Don't persist" or "Persist") .. " marks", value = "p" },
      { key = "$", label = "Archive", value = "$" },
      { key = "A", label = "Archive to archive sibling", value = "A" },
      { key = "t", label = "Change TODO state", value = "t" },
      { key = "+", label = "Add tag", value = "+" },
      { key = "-", label = "Remove tag", value = "-" },
      { key = "s", label = "(Re)schedule (\"++2d\" shifts each date)", value = "s" },
      { key = "d", label = "(Re)set deadline (\"++2d\" shifts each date)", value = "d" },
      { key = "r", label = "Refile", value = "r" },
      { key = "S", label = "Scatter over N days (count: skip weekends)", value = "S" },
      { key = "f", label = "Apply a Lua function", value = "f" },
    }
    local ckeys = vim.tbl_keys(custom)
    table.sort(ckeys)
    for _, k in ipairs(ckeys) do
      local c = custom[k]
      local label = type(c) == "table" and (c.desc or c.description or "Custom") or "Custom"
      items[#items + 1] = { key = k, label = label, value = { custom = k } }
    end
    choice = require("org.ui").menu({
      title = string.format("Bulk (%d marked)", vim.tbl_count(S.marks)),
      items = items,
    })
    if choice == "p" then
      persistent = not persistent
    else
      break
    end
  end
  if not choice then
    return
  end
  local count = vim.v.count
  if choice == "t" then
    local kw = utils.select(vim.list_extend(todo_names(), { "(none)" }), { prompt = "Todo state" })
    if not kw then
      return
    end
    bulk(function(target)
      call("org.todo", "change_state", target, kw ~= "(none)" and kw or nil)
    end, persistent)
  elseif choice == "s" or choice == "d" then
    local kind = choice == "s" and "scheduled" or "deadline"
    local ans = read_bulk_date(choice == "s" and "(Re)Schedule to" or "(Re)Set Deadline to")
    if not ans then
      return
    end
    bulk(function(target)
      if ans.shift then
        local _, _, hl = require("org.edit").resolve_headline(target)
        if hl and hl.planning[kind] then
          call("org.timestamps", "shift", target, kind, ans.shift, ans.unit)
        else
          local d = date.today():add(ans.shift, ans.unit):clone({ active = true })
          call("org.timestamps", "set_date", target, kind, d)
        end
      else
        call("org.timestamps", "set_date", target, kind, ans.date)
      end
    end, persistent)
  elseif choice == "S" then
    local b = S.view and S.view.blocks[1]
    if b and b.type ~= "agenda" and b.type ~= "todo" then
      utils.error(string.format('Can\'t scatter tasks in "%s" agenda view', b.type))
      return
    end
    local prompt = string.format("Scatter tasks across how many %sdays: ", count > 0 and "week" or "")
    local days = tonumber(utils.input({ prompt = prompt, default = "7" }) or "")
    if not days or days < 1 then
      return
    end
    local today = date.today()
    bulk(function(target, item)
      if item.sexp then
        return
      end
      local d = today:add(M.scatter_distance(days, count > 0), "d"):clone({ active = true })
      call("org.timestamps", "set_date", target, "scheduled", d)
    end, persistent)
  elseif choice == "+" or choice == "-" then
    local tag = utils.input_complete(choice == "+" and "Tag to add: " or "Tag to remove: ", all_tags_in_view())
    if not tag or vim.trim(tag) == "" then
      return
    end
    tag = vim.trim(tag):gsub(":", "")
    bulk(function(target)
      add_remove_tag(target, tag, choice == "+")
    end, persistent)
  elseif choice == "r" then
    local ok, refile = pcall(require, "org.refile")
    local dest = ok and refile.pick_target and refile.pick_target({ prompt = "Refile to" })
    if ok and not dest then
      return
    end
    bulk(function(target)
      call("org.refile", "refile", target, { dest = dest })
    end, persistent)
  elseif choice == "$" then
    bulk(function(target)
      call("org.archive", "archive_subtree", target)
    end, persistent)
  elseif choice == "A" then
    bulk(function(target)
      call("org.archive", "archive_to_sibling", target)
    end, persistent)
  elseif choice == "f" then
    local expr = utils.input({ prompt = "Function (Lua, receives target { bufnr, lnum } and the item): " })
    if not expr or vim.trim(expr) == "" then
      return
    end
    local chunk = loadstring("return " .. expr)
    local ok, fn = pcall(chunk or error)
    if not ok or type(fn) ~= "function" then
      utils.error("Not a function: " .. expr)
      return
    end
    bulk(function(target, item)
      fn(target, item)
    end, persistent)
  elseif type(choice) == "table" and choice.custom then
    local c = custom[choice.custom]
    local fn = type(c) == "function" and c or (type(c) == "table" and (c.fn or c[1]))
    if type(fn) ~= "function" then
      utils.error("Invalid bulk action: " .. choice.custom)
      return
    end
    local args = {}
    if type(c) == "table" and type(c.args) == "function" then
      args = c.args() or {}
    end
    bulk(function(target, item)
      fn(target, item, unpack(args))
    end, persistent)
  end
end

---------------------------------------------------------------------------
-- Other commands
---------------------------------------------------------------------------

--- org-agenda-drag-line-forward/backward: move the line at point past the
--- next/previous entry line (the agenda text only, not the files).
function M.drag_line(dir)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local other = lnum + dir
  if not (S.line_items[lnum] and S.line_items[other]) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, math.min(lnum, other) - 1, math.max(lnum, other), false, {
    lines[math.max(lnum, other)],
    lines[math.min(lnum, other)],
  })
  vim.bo[S.buf].modifiable = false
  S.line_items[lnum], S.line_items[other] = S.line_items[other], S.line_items[lnum]
  S.line_parts[lnum], S.line_parts[other] = S.line_parts[other], S.line_parts[lnum]
  for _, l in ipairs({ lnum, other }) do
    vim.api.nvim_buf_clear_namespace(S.buf, ns, l - 1, l)
    for _, h in ipairs(S.line_parts[l] or {}) do
      pcall(vim.api.nvim_buf_set_extmark, S.buf, ns, l - 1, h[1], { end_col = h[2], hl_group = h[3], priority = 110 })
    end
  end
  M.render_marks()
  vim.api.nvim_win_set_cursor(0, { other, 0 })
end

--- Append another agenda view to the current one (org-agenda-append-agenda).
function M.append()
  if not S.view then
    return
  end
  local items = {
    { key = "a", label = "Agenda for current week or day", value = { type = "agenda" } },
    { key = "t", label = "List of all TODO entries", value = { type = "todo" } },
    { key = "m", label = "Match a TAGS/PROP/TODO query", value = "m" },
    { key = "M", label = "Like m, but only TODO entries", value = "M" },
    { key = "s", label = "Search for keywords", value = "s" },
    { key = "S", label = "Like s, but only TODO entries", value = "S" },
    { key = "#", label = "List stuck projects", value = { type = "stuck" } },
  }
  for key, cmd in pairs(config.opts.agenda.custom_commands or {}) do
    if type(cmd) == "table" and (cmd.type or cmd.types or cmd.blocks) then
      items[#items + 1] = { key = key, label = cmd.description or key, value = { custom = key } }
    end
  end
  local choice = require("org.ui").menu({ title = "Append to agenda", items = items })
  if not choice then
    return
  end
  local agenda = require("org.agenda")
  local blocks = {}
  if choice == "m" or choice == "M" then
    local m = utils.input({ prompt = choice == "m" and "Match: " or "Match (TODO only): " })
    if not m or m == "" then
      return
    end
    blocks = { { type = choice == "m" and "tags" or "tags_todo", match = m } }
  elseif choice == "s" or choice == "S" then
    local t = utils.input({ prompt = "Search: " })
    if not t or t == "" then
      return
    end
    blocks = { { type = "search", match = t, todo_only = choice == "S" or nil } }
  elseif type(choice) == "table" and choice.custom then
    local cmd = config.opts.agenda.custom_commands[choice.custom]
    blocks = cmd.type and { cmd } or (cmd.blocks or cmd.types)
  elseif type(choice) == "table" then
    blocks = { choice }
  end
  for _, b in ipairs(blocks) do
    S.view.blocks[#S.view.blocks + 1] = agenda.normalize_block(b)
  end
  S.view.multi = true
  M.redo()
end

--- Redo every agenda buffer (org-agenda-redo-all).
function M.redo_all()
  local cur = S
  for _, st in pairs(states) do
    if st.buf and vim.api.nvim_buf_is_valid(st.buf) and st.view then
      use(st)
      M.refresh()
    end
  end
  use(cur)
end

M.actions = {
  quit = function()
    M.quit(false)
  end,
  quit_kill = function()
    M.quit(true)
  end,
  exit = function()
    M.exit()
  end,
  redo = function()
    local count = vim.v.count
    if count > 0 and S.view then
      local names = todo_names()
      for _, b in ipairs(S.view.blocks) do
        if b.type == "todo" then
          b.keywords = names[count] and { names[count] } or nil
        elseif (b.type == "tags" or b.type == "tags_todo") and not S.view.multi then
          local m = utils.input({ prompt = "Match: ", default = b.match or "" })
          if m then
            b.match = m
          end
        elseif b.type == "search" and not S.view.multi then
          local m = utils.input({ prompt = "Search: ", default = b.match or "" })
          if m then
            b.match = m
          end
        end
      end
    end
    M.redo()
  end,
  redo_all = function()
    M.redo_all()
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
    local d = M.pick_date(date.from_days(M.day_at_cursor() or date.today_days()), "Go to date")
    if not d then
      return
    end
    M.goto_date(d:days())
  end,
  calendar = function()
    local d = M.pick_date(date.from_days(M.day_at_cursor() or date.today_days()), "Calendar")
    if d then
      M.goto_date(d:days())
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
  show_scroll_down = function()
    local w = M.show_item(false)
    if w then
      pcall(vim.api.nvim_win_call, w, function()
        vim.cmd("normal! \x19")
      end)
    end
  end,
  follow_mode = function()
    S.follow = not S.follow
    utils.notify("Follow mode " .. (S.follow and "on" or "off"))
    if S.follow then
      M.show_item(false)
    end
  end,
  todo = on_item(function(target)
    -- org-agenda-todo runs org-todo: fast selection or cycling in the set
    call("org.todo", "select_or_cycle", target)
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
    M.shift_item(target, item, math.max(vim.v.count, 1), vim.v.count > 0)
  end),
  date_earlier = on_item(function(target, item)
    M.shift_item(target, item, -math.max(vim.v.count, 1), true)
  end),
  date_prompt = on_item(function(target, item)
    M.date_prompt(target, item)
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
  attach = function()
    local w = M.show_item(false)
    if w then
      vim.api.nvim_win_call(w, function()
        call("org.attach", "menu")
      end)
    end
  end,
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
    local count = vim.v.count
    if count > 0 then
      -- C-u l: all log items; C-u C-u l: only log items (org-agenda-log-mode)
      S.log_mode = S.log_mode ~= (count == 1 and "all" or "only") and (count == 1 and "all" or "only") or false
    else
      S.log_mode = not S.log_mode
    end
    M.redo()
    utils.notify("Log mode " .. (S.log_mode and "on" or "off"))
  end,
  clockreport_mode = function()
    S.clockreport = not S.clockreport
    M.redo()
    utils.notify("Clock report mode " .. (S.clockreport and "on" or "off"))
  end,
  filter = function()
    local count = vim.v.count
    if count >= 3 then
      auto_exclude()
      return
    end
    local negate = count == 1
    local input = utils.input_complete(
      (negate and "Negative filter" or "Filter") .. " [+cat-tag<0:10-/regexp/]: ",
      function()
        local list = all_categories_in_view()
        vim.list_extend(list, all_tags_in_view())
        return list
      end,
      filter_string()
    )
    if input == nil then
      return
    end
    local keep = count == 2
    if input:match("^%+[%+%-]") then
      input = input:sub(2)
      keep = true
    end
    local f = M.parse_filter(input, negate)
    local cur = S.filters
    S.filters = {
      tag = keep and vim.list_extend(vim.list_slice(cur.tag), f.tag) or f.tag,
      category = keep and vim.list_extend(vim.list_slice(cur.category), f.category) or f.category,
      regexp = keep and vim.list_extend(vim.list_slice(cur.regexp), f.regexp) or f.regexp,
      effort = keep and vim.list_extend(vim.list_slice(cur.effort), f.effort) or f.effort,
      top = cur.top,
    }
    M.redo()
  end,
  filter_tag = function()
    M.filter_by_tag(vim.v.count)
  end,
  filter_category = function()
    local count = vim.v.count
    local f = S.filters
    local by_cat = #f.category > 0 and f.category[1]:sub(1, 1) == "+"
    if by_cat and count == 0 then
      f.category = {}
    else
      local item = M.item_at_cursor()
      if not item then
        utils.error("No category at point")
        return
      end
      if count > 0 then
        table.insert(f.category, 1, "-" .. item.category)
      else
        f.category = { "+" .. item.category }
      end
    end
    M.redo()
  end,
  filter_regexp = function()
    local count = vim.v.count
    local strip, accumulate = count == 1, count == 2
    if #S.filters.regexp > 0 and not accumulate then
      S.filters.regexp = {}
      M.redo()
      utils.notify("Regexp filter removed")
      return
    end
    local input = utils.input({
      prompt = strip and "Hide entries matching regexp: " or "Narrow to entries matching regexp: ",
    })
    if input == nil or input == "" then
      return
    end
    local ok = pcall(require("org.agenda.search").compile_emacs_regexp, input)
    if not ok then
      utils.error("Invalid regexp: " .. input)
      return
    end
    table.insert(S.filters.regexp, 1, (strip and "-" or "+") .. input)
    M.redo()
  end,
  filter_remove = function()
    S.filters = empty_filters()
    M.redo()
    utils.notify("All agenda filters removed")
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
    M.bulk_action()
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
  clockcheck_mode = function()
    S.log_mode = S.log_mode ~= "clockcheck" and "clockcheck" or false
    M.redo()
    utils.notify("Clock check " .. (S.log_mode and "on" or "off"))
  end,
  time_grid = function()
    S.time_grid_off = not S.time_grid_off
    M.redo()
    utils.notify("Time grid " .. (S.time_grid_off and "off" or "on"))
  end,
  reset_view = function()
    set_span(nil)
  end,
  toggle_deadlines = function()
    S.no_deadlines = not S.no_deadlines
    M.redo()
    utils.notify("Deadlines " .. (S.no_deadlines and "hidden" or "shown"))
  end,
  dim_blocked = function()
    S.dim_blocked = not S.dim_blocked
    M.redo()
    utils.notify("Dimming blocked tasks " .. (S.dim_blocked and "on" or "off"))
  end,
  filter_effort = function()
    M.filter_by_effort(vim.v.count)
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
  limit = function()
    M.limit(vim.v.count)
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
    pcall(vim.cmd, "silent! only")
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
  drag_line_forward = function()
    M.drag_line(1)
  end,
  drag_line_backward = function()
    M.drag_line(-1)
  end,
  append = function()
    M.append()
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
  timer_stop = function()
    call("org.timer", "stop")
  end,
  restriction_lock = function()
    local item = M.item_at_cursor()
    local target = item and M.resolve_target(item)
    if not target then
      return
    end
    local agenda = require("org.agenda")
    agenda.set_restriction_lock(target)
    S.restrict = agenda.lock_restriction()
    M.redo()
  end,
  remove_restriction_lock = function()
    require("org.agenda").remove_restriction_lock()
    S.restrict = nil
    M.redo()
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
  columns = function()
    call("org.agenda.columns", "toggle")
  end,
  export = function()
    M.export()
  end,
  help = function()
    require("org.mappings").show_help()
  end,
}

--- Show day `day` (a day number) in the agenda (org-agenda-goto-date).
function M.goto_date(day)
  if not has_agenda_block() then
    require("org.agenda").open_agenda({ anchor = day })
    return
  end
  local span = current_span()
  local first
  for _, inf in pairs(S.info) do
    first = inf
    break
  end
  if not (first and day >= first.from and day <= first.to) then
    S.anchor = render.span_days(span, day) == 1 and day or render.starting_day(span, day)
  end
  M.refresh()
  for l, d in pairs(S.day_lines) do
    if d == day then
      pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
    end
  end
end

--- Write the agenda to a file (org-agenda-write).
function M.export(path)
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  path = path
    or utils.input({ prompt = "Write agenda to file: ", default = vim.fn.expand("~/agenda.txt"), completion = "file" })
  if not path or path == "" then
    return
  end
  local ok, exp = pcall(require, "org.agenda.export")
  if ok and type(exp.write) == "function" then
    return exp.write(path)
  end
  path = vim.fn.expand(path)
  utils.writefile(path, vim.api.nvim_buf_get_lines(S.buf, 0, -1, false))
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
