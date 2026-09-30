---@mod org.extensions.views_util Shared code of the view extensions
---
--- Not an extension itself: the helpers the `kanban`, `timeline`,
--- `heatmap` and `sidebar` extensions share.
---
---   - `collect`: the headlines of a source (agenda files, a buffer, a
---     subtree, files) narrowed by an org-ql query, a tags match or a tag
---   - `Canvas`: lines built from highlighted segments, drawn into a
---     scratch buffer with extmarks
---   - `open` / `close`: the view's window (float, tab, split or current)
---   - `target` / `jump`: from a headline back to its buffer
---   - `watch`: re-render when org files are written or TODO states and
---     clocks change
---   - face helpers for TODO keywords, priorities and tags, and small
---     formatting helpers

local date = require("org.date")
local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Highlights
---------------------------------------------------------------------------

--- Define highlight groups with `default = true` now and after every
--- colorscheme change. `defs` is a table or a function returning one.
---@param augroup integer
---@param defs table<string, table>|fun(): table<string, table>
function M.highlights(augroup, defs)
  local function apply()
    local t = type(defs) == "function" and defs() or defs
    for name, def in pairs(t) do
      def = vim.deepcopy(def)
      if def.default == nil then
        def.default = true
      end
      vim.api.nvim_set_hl(0, name, def)
    end
  end
  apply()
  vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = apply })
end

--- Highlight group of a TODO keyword: its `ui.todo_keyword_faces` face,
--- else OrgDone or OrgTodo.
---@param kw string
---@param todo_cfg? org.TodoConfig
---@return string
function M.todo_group(kw, todo_cfg)
  local faces = (require("org.config").opts.ui or {}).todo_keyword_faces or {}
  if faces[kw] then
    return "orgTodoKw_" .. kw:gsub("[^%w_]", "_")
  end
  todo_cfg = todo_cfg or require("org.todo_keywords").global()
  return todo_cfg:is_done(kw) and "OrgDone" or "OrgTodo"
end

--- Highlight group of a priority cookie.
---@param p string
---@return string
function M.priority_group(p)
  local faces = (require("org.config").opts.ui or {}).priority_faces or {}
  if faces[p] then
    return require("org.highlights").face_group("orgPriorityFace_", p)
  end
  return ({ A = "OrgPriorityA", B = "OrgPriorityB", C = "OrgPriorityC" })[p] or "OrgPriority"
end

--- Highlight group of a tag.
---@param tag string
---@return string
function M.tag_group(tag)
  local faces = (require("org.config").opts.ui or {}).tag_faces or {}
  if faces[tag] then
    return require("org.highlights").face_group("orgTagFace_", tag)
  end
  return "OrgTags"
end

--- The RGB colour (integer) of an attribute of a highlight group,
--- following links, or nil.
---@param name string
---@param attr "fg"|"bg"
---@return integer|nil
function M.color(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl and hl[attr] or nil
end

--- Mix two RGB colours: `t` = 0 is `a`, 1 is `b`.
---@return string "#rrggbb"
function M.blend(a, b, t)
  local function ch(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local out = {}
  for _, shift in ipairs({ 16, 8, 0 }) do
    out[#out + 1] = math.floor(ch(a, shift) * (1 - t) + ch(b, shift) * t + 0.5)
  end
  return string.format("#%02x%02x%02x", out[1], out[2], out[3])
end

---------------------------------------------------------------------------
-- Canvas: text with highlights
---------------------------------------------------------------------------

---@class org.views.Canvas
---@field lines { text: string[], hls: table[] }[]
local Canvas = {}
Canvas.__index = Canvas
M.Canvas = Canvas

---@return org.views.Canvas
function Canvas.new()
  return setmetatable({ lines = {} }, Canvas)
end

--- Start a new line; returns its index (1-based).
function Canvas:line()
  self.lines[#self.lines + 1] = { text = {}, hls = {}, bytes = 0 }
  return #self.lines
end

--- Append `text` to the last line (a new one when there is none), with
--- highlight group(s) `hl`: a name, or a list layered in order (the later
--- ones win on the attributes they set).
---@param text string
---@param hl? string|string[]
function Canvas:put(text, hl)
  if #self.lines == 0 then
    self:line()
  end
  local l = self.lines[#self.lines]
  if text == "" then
    return
  end
  if hl then
    l.hls[#l.hls + 1] = { l.bytes, l.bytes + #text, hl }
  end
  l.text[#l.text + 1] = text
  l.bytes = l.bytes + #text
end

--- Add a whole line of segments `{ { text, hl? }, ... }` (or a string).
function Canvas:add(segments)
  self:line()
  if type(segments) == "string" then
    self:put(segments)
    return #self.lines
  end
  for _, s in ipairs(segments) do
    self:put(s[1], s[2])
  end
  return #self.lines
end

--- The lines as strings.
---@return string[]
function Canvas:strings()
  local out = {}
  for i, l in ipairs(self.lines) do
    out[i] = table.concat(l.text)
  end
  return out
end

--- Replace the text of `buf` with the canvas and highlight it in `ns`.
---@param buf integer
---@param ns integer
function Canvas:draw(buf, ns)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, self:strings())
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, l in ipairs(self.lines) do
    for _, h in ipairs(l.hls) do
      local groups = type(h[3]) == "table" and h[3] or { h[3] }
      for p, g in ipairs(groups) do
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, h[1], {
          end_col = h[2],
          hl_group = g,
          priority = 100 + p,
        })
      end
    end
  end
end

---------------------------------------------------------------------------
-- Collecting headlines
---------------------------------------------------------------------------

local track_ns = vim.api.nvim_create_namespace("org_views_track")

--- Resolve a source at open time. Returns a table remembered by the view
--- and handed to `collect` on every refresh:
---   "agenda"   the agenda files
---   "buffer"   the current buffer
---   "subtree"  the subtree at the cursor (tracked by an extmark)
---   a path or glob, or a list of them
---@param spec any
---@return table|nil source, string|nil err
function M.resolve_source(spec)
  spec = spec or "agenda"
  if spec == "agenda" then
    return { kind = "agenda" }
  end
  if spec == "buffer" or spec == "subtree" then
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "org" then
      return nil, "Not an org buffer"
    end
    if spec == "buffer" then
      return { kind = "buffer", bufnr = buf }
    end
    local hl = require("org.files").get_buffer(buf):headline_at(vim.api.nvim_win_get_cursor(0)[1])
    if not hl then
      return nil, "Not under a headline"
    end
    local mark = vim.api.nvim_buf_set_extmark(buf, track_ns, hl.line - 1, 0, {})
    return { kind = "subtree", bufnr = buf, mark = mark }
  end
  if type(spec) == "string" or type(spec) == "table" then
    return { kind = "files", patterns = type(spec) == "table" and spec or { spec } }
  end
  return nil, "Invalid source: " .. tostring(spec)
end

--- A short name of a source for titles.
function M.source_label(src)
  if src.kind == "agenda" then
    return "agenda files"
  elseif src.kind == "buffer" or src.kind == "subtree" then
    local name = vim.api.nvim_buf_is_valid(src.bufnr) and vim.api.nvim_buf_get_name(src.bufnr) or ""
    name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
    if src.kind == "subtree" then
      local root = M.subtree_root(src)
      return root and (name .. " › " .. root:plain_title()) or name
    end
    return name
  end
  return table.concat(
    vim.tbl_map(function(p)
      return vim.fn.fnamemodify(p, ":t")
    end, src.patterns),
    ", "
  )
end

--- The root headline of a "subtree" source, or nil when it is gone.
function M.subtree_root(src)
  if not vim.api.nvim_buf_is_valid(src.bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(src.bufnr, track_ns, src.mark, {})
  if not pos[1] then
    return nil
  end
  return require("org.files").get_buffer(src.bufnr):headline_at(pos[1] + 1)
end

--- The org files of a resolved source.
---@param src table
---@return org.File[]
function M.files(src)
  local files = require("org.files")
  if src.kind == "agenda" then
    return files.agenda_files()
  elseif src.kind == "buffer" or src.kind == "subtree" then
    if not vim.api.nvim_buf_is_valid(src.bufnr) then
      return {}
    end
    return { files.get_buffer(src.bufnr) }
  end
  local out, seen = {}, {}
  for _, p in ipairs(utils.glob_org_files(src.patterns)) do
    local f = files.get(p)
    if f and not seen[f] then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  return out
end

--- Compile a filter: a string starting with "(" is an org-ql query (the
--- ql extension's query language, loaded on demand), anything else a tags
--- / property match like `work+urgent-home` (`:h org-agenda-match`).
---@param filter string
---@return (fun(hl: org.Headline): boolean)|nil, string|nil err
function M.compile_filter(filter)
  filter = vim.trim(filter or "")
  if filter == "" then
    return nil
  end
  if filter:sub(1, 1) == "(" then
    return M.compile_query(filter)
  end
  return require("org.agenda.search").try_compile(filter)
end

--- Compile an org-ql query (sexp or plain syntax, `:h org-extensions-ql`).
--- The query language is loaded on demand; the ql extension need not be
--- enabled.
---@param q string|table
---@return (fun(hl: org.Headline): boolean)|nil, string|nil err
function M.compile_query(q)
  local ok, query = pcall(require, "org.extensions.ql.query")
  if not ok then
    return nil, "org-ql is not available"
  end
  return query.try_compile(q)
end

--- Headlines of a resolved source, in file order. COMMENT and ARCHIVE
--- subtrees are skipped as in the agenda.
---@param src table from `resolve_source`
--- `query` is an org-ql query, `filter` an org-ql sexp or a tags match
--- (see `compile_filter`) and `tag` a single tag.
---@param opts? { query?: string|table, filter?: string, tag?: string, pred?: fun(hl: org.Headline): boolean }
---@return org.Headline[] headlines, string|nil err
function M.collect(src, opts)
  opts = opts or {}
  local out = {}
  local range
  if src.kind == "subtree" then
    local root = M.subtree_root(src)
    if not root then
      return out, "The subtree is gone"
    end
    range = { root.line, root.end_line }
  end
  local filter, err = M.compile_filter(opts.filter)
  if err then
    return out, err
  end
  local query
  if opts.query and opts.query ~= "" then
    query, err = M.compile_query(opts.query)
    if not query then
      return out, err
    end
  end
  local tag = opts.tag and opts.tag ~= "" and opts.tag or nil
  require("org.agenda.items").each_headline(M.files(src), {}, function(hl)
    if range and (hl.line < range[1] or hl.line > range[2]) then
      return
    end
    if tag and not M.has_tag(hl, tag) then
      return
    end
    if opts.pred and not opts.pred(hl) then
      return
    end
    for _, f in ipairs({ query or false, filter or false }) do
      if f then
        local ok, res = pcall(f, hl)
        if not ok or not res then
          return
        end
      end
    end
    out[#out + 1] = hl
  end)
  return out
end

--- Whether a headline has `tag` (inherited tags count), ignoring case.
function M.has_tag(hl, tag)
  tag = tag:gsub("^[+:]", ""):gsub(":$", ""):lower()
  for _, t in ipairs(hl:get_tags()) do
    if t:lower() == tag then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Headline data
---------------------------------------------------------------------------

--- Effort of a headline in minutes, or nil.
---@param hl org.Headline
---@return integer|nil
function M.effort(hl)
  local v = hl:get_property(require("org.config").opts.effort_property or "Effort")
  return v and date.parse_duration(v) or nil
end

--- A reference to a headline that survives re-parsing: file, line and
--- the headline's text.
---@param hl org.Headline
function M.ref(hl)
  return { filename = hl.file.filename, bufnr = hl.file.bufnr, lnum = hl.line, raw = hl.raw }
end

--- Buffer and line of a headline reference, loading its file when needed.
--- When the line moved, the headline is looked up by its text.
---@param ref { filename?: string, bufnr?: integer, lnum: integer, raw: string }
---@return org.Target|nil
function M.target(ref)
  local bufnr
  if ref.filename then
    bufnr = utils.find_buffer(ref.filename) or utils.load_buffer(ref.filename)
  elseif ref.bufnr and vim.api.nvim_buf_is_valid(ref.bufnr) then
    bufnr = ref.bufnr
  end
  if not bufnr then
    utils.error("Cannot find the file of this entry")
    return nil
  end
  local lnum = ref.lnum
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if line ~= ref.raw then
    lnum = nil
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l == ref.raw then
        lnum = i
        break
      end
    end
    if not lnum then
      utils.warn("Entry has changed or moved; press r to refresh")
      return nil
    end
  end
  return { bufnr = bufnr, lnum = lnum }
end

--- Save the buffers of an edit when `save` is true, or when it is nil and
--- `agenda.save_after_edit` is set.
function M.after_edit(bufnr, save)
  if save == nil then
    save = require("org.config").opts.agenda.save_after_edit
  end
  if save then
    utils.save_buffer_or_warn(bufnr)
  end
end

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------

--- A scratch buffer for a view.
---@param name string buffer name, e.g. "org://kanban"
---@param filetype string
---@return integer
function M.scratch(name, filetype)
  local old = vim.fn.bufnr(name)
  if old ~= -1 and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].filetype = filetype
  return buf
end

local function set_view_options(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.cursorline = false
  wo.colorcolumn = ""
  wo.statuscolumn = ""
end

--- Show `buf` in a window per `layout`: "float" (`opts.width` and
--- `opts.height` as fractions of the editor or columns / lines),
--- "tab", "split", "vsplit" or "current". Returns the window and how to
--- close it again (for `close`).
---@param buf integer
---@param layout string
---@param opts? { width?: number, height?: number, title?: string }
---@return integer win, table how
function M.open(buf, layout, opts)
  opts = opts or {}
  local prev_win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_get_current_buf()
  local how = { layout = layout, prev_win = prev_win, prev_buf = prev_buf }
  local win
  if layout == "float" then
    local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
    local function size(v, total, default)
      v = v or default
      if v <= 1 then
        v = math.floor(total * v)
      end
      return math.max(10, math.min(total - 2, v))
    end
    local w, h = size(opts.width, cols, 0.9), size(opts.height, rows, 0.85)
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = w,
      height = h,
      row = math.floor((rows - h) / 2) - 1,
      col = math.floor((cols - w) / 2),
      style = "minimal",
      border = "rounded",
      title = opts.title and (" " .. opts.title .. " ") or nil,
      title_pos = opts.title and "center" or nil,
      zindex = 45,
    })
  elseif layout == "tab" then
    vim.cmd("tab split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    how.tab = vim.api.nvim_get_current_tabpage()
  elseif layout == "split" or layout == "vsplit" then
    vim.cmd((layout == "vsplit" and "botright vsplit" or "botright split"))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    how.layout = "current"
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  set_view_options(win)
  how.win = win
  return win, how
end

--- Close a view opened by `open`. With `keep_prev`, the previous window
--- is made current.
---@param how table
function M.close(how)
  local win = how.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if how.layout == "current" then
    if how.prev_buf and vim.api.nvim_buf_is_valid(how.prev_buf) and how.prev_buf ~= vim.api.nvim_win_get_buf(win) then
      vim.api.nvim_win_set_buf(win, how.prev_buf)
    else
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    end
    return
  end
  if how.layout == "tab" and #vim.api.nvim_list_tabpages() == 1 then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    return
  end
  if #vim.api.nvim_list_wins() == 1 then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    return
  end
  pcall(vim.api.nvim_win_close, win, true)
  if how.prev_win and vim.api.nvim_win_is_valid(how.prev_win) then
    pcall(vim.api.nvim_set_current_win, how.prev_win)
  end
end

--- Open the headline of `ref` for editing: splits stay open and the
--- file opens in the window the view was opened from; other layouts are
--- closed first.
---@param ref table from `ref`
---@param how? table from `open`
function M.jump(ref, how)
  local target = M.target(ref)
  if not target then
    return
  end
  if how and how.layout ~= "split" and how.layout ~= "vsplit" and how.layout ~= "current" then
    M.close(how)
  elseif how and how.prev_win and vim.api.nvim_win_is_valid(how.prev_win) and how.prev_win ~= how.win then
    vim.api.nvim_set_current_win(how.prev_win)
  end
  utils.set_current_buf(target.bufnr)
  vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
  pcall(vim.cmd, "normal! zv")
end

---------------------------------------------------------------------------
-- Keys and refreshing
---------------------------------------------------------------------------

--- Map buffer keys from a `keys` option (name -> lhs, list of lhs or
--- false) to `handlers[name]`. Handlers run as org actions (in a
--- coroutine, so they may prompt).
---@param buf integer
---@param keys table<string, string|string[]|false>
---@param handlers table<string, function>
---@param label string description prefix
function M.map(buf, keys, handlers, label)
  for name, lhs in pairs(keys or {}) do
    local fn = handlers[name]
    if fn and lhs then
      for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
        vim.keymap.set("n", l, function()
          utils.run(fn)
        end, { buffer = buf, nowait = true, silent = true, desc = label .. ": " .. name:gsub("_", " ") })
      end
    end
  end
end

--- Call `fn` (debounced by `delay` ms) when an org file is written or
--- changed in Normal mode, or a TODO state, property or clock changes.
--- Returns the augroup; delete it to stop.
---@param name string augroup name
---@param fn fun()
---@param delay? integer
---@return integer augroup
function M.watch(name, fn, delay)
  local group = vim.api.nvim_create_augroup(name, { clear = true })
  local pending = false
  local function schedule()
    if pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      pending = false
      fn()
    end, delay or 100)
  end
  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "FileChangedShellPost" }, {
    group = group,
    pattern = { "*.org" },
    callback = schedule,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "OrgTodoStateChange", "OrgClockIn", "OrgClockOut", "OrgClockCancel", "OrgPropertyChanged" },
    callback = schedule,
  })
  return group
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

--- Pad or cut `s` to exactly `width` display cells.
function M.fit(s, width)
  if width <= 0 then
    return ""
  end
  return utils.pad_right(utils.truncate(s, width), width)
end

--- Center `s` in `width` cells.
function M.center(s, width)
  s = utils.truncate(s, width)
  local w = utils.width(s)
  local left = math.floor((width - w) / 2)
  return string.rep(" ", left) .. s .. string.rep(" ", width - w - left)
end

--- Compact duration: 45m, 2h, 1h30m, 160h (minutes are left out from
--- 100 hours on).
---@param minutes number
function M.short_duration(minutes)
  minutes = math.floor(math.abs(minutes) + 0.5)
  if minutes < 60 then
    return minutes .. "m"
  end
  local h, m = math.floor(minutes / 60), minutes % 60
  if m == 0 or h >= 100 then
    return h .. "h"
  end
  return string.format("%dh%02dm", h, m)
end

--- "today", "in 3d", "2d ago" for a day offset from today.
---@param days integer
function M.relative_days(days)
  if days == 0 then
    return "today"
  elseif days == 1 then
    return "tomorrow"
  elseif days == -1 then
    return "yesterday"
  elseif days > 0 then
    return "in " .. days .. "d"
  end
  return -days .. "d ago"
end

--- A headline's title for display: links shown by their description and
--- statistics cookies removed.
function M.title(hl)
  return hl:plain_title()
end

return M
