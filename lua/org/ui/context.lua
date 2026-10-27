--- Sticky headline context, like nvim-treesitter-context (which needs a
--- tree-sitter parser, so it shows nothing in org buffers): a floating
--- window over the top rows of each org window lists the headlines the
--- first line on screen is under, drawn with the buffer's highlighting.
---
--- Each window has its own context, updated when it scrolls, is resized,
--- shows another buffer or its buffer changes. Working out the context
--- only walks the parents of one headline of the cached parse, and the
--- float is redrawn only when what it shows changed, so scrolling stays
--- cheap. In Insert mode a buffer whose parse is out of date keeps its
--- context until the parse is fresh (on leaving Insert mode).
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("org.context")
local GROUP = "org.context"

local enabled = false

---@class org.context.State
---@field float integer|nil the floating window
---@field buf integer|nil its scratch buffer
---@field sig string|nil what it shows (redrawn only when this changes)
---@field lines integer[] the headline line numbers shown, outermost first
---@field hidden? boolean the float is hidden (no context)

---@type table<integer, org.context.State>
local wins = {}

---@return table
local function opts()
  local ui = require("org.config").opts.ui or {}
  return ui.context or {}
end

--- Whether the context is on.
---@return boolean
function M.enabled()
  return enabled
end

--- Whether nvim-treesitter-context draws its own context for `bufnr`:
--- only when it is installed and on and Neovim has an `org` tree-sitter
--- parser. Then org.nvim leaves the buffer to it, so two floats never
--- cover each other.
local ts_org ---@type boolean|nil
---@param bufnr integer
---@return boolean
local function ts_context_active(bufnr)
  local tsc = package.loaded["treesitter-context"]
  if type(tsc) ~= "table" or type(tsc.enabled) ~= "function" then
    return false
  end
  local ok, on = pcall(tsc.enabled)
  if not ok or not on then
    return false
  end
  if ts_org == nil then
    local okl, added = pcall(vim.treesitter.language.add, "org")
    ts_org = okl and added and true or false
  end
  return ts_org and vim.b[bufnr].org_context ~= true
end

--- Whether `win` is a window the context is drawn for.
---@param win integer
---@return boolean
local function is_source(win)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  return vim.bo[buf].filetype == "org"
    and vim.w[win].org_context ~= false
    and vim.b[buf].org_context ~= false
    and not ts_context_active(buf)
end

--- Close the context of `win`.
---@param win integer
function M.close(win)
  local s = wins[win]
  if not s then
    return
  end
  wins[win] = nil
  if s.float and api.nvim_win_is_valid(s.float) then
    pcall(api.nvim_win_close, s.float, true)
  end
  if s.buf and api.nvim_buf_is_valid(s.buf) then
    pcall(api.nvim_buf_delete, s.buf, { force = true })
  end
end

--- The headlines line `lnum` is under, outermost first: the parents of
--- its entry (with the entry's own headline when `lnum` is in its body).
--- Inline tasks and text the `transclusion` extension inserted are left
--- out.
---@param file org.File
---@param lnum integer
---@param foreign table<integer, true>|nil
---@return org.Headline[]
local function ancestors(file, lnum, foreign)
  local out = {}
  local hl = file:headline_at(lnum)
  while hl do
    if hl.line < lnum and not hl.inlinetask and not (foreign and foreign[hl.line]) then
      table.insert(out, 1, hl)
    end
    hl = hl.parent
  end
  return out
end

--- The buffer line drawn `rows` screen lines below line `top` of the
--- current window, a closed fold taking one line.
---@param top integer
---@param rows integer
---@param last integer the buffer's last line
---@return integer
local function line_below(top, rows, last)
  local l = top
  for _ = 1, rows do
    local fend = vim.fn.foldclosedend(l)
    l = (fend ~= -1 and fend or l) + 1
    if l > last then
      return last
    end
  end
  return l
end

--- Keep `max` of `list`, dropping the outermost ("outer") or innermost
--- ("inner") entries.
---@param list org.Headline[]
---@param max integer
---@param scope string
---@return org.Headline[]
local function trim(list, max, scope)
  if #list <= max then
    return list
  end
  if max <= 0 then
    return {}
  end
  if scope == "inner" then
    return vim.list_slice(list, 1, max)
  end
  return vim.list_slice(list, #list - max + 1, #list)
end

local timer ---@type uv.uv_timer_t|nil

--- Parse and update the windows of the current tab page a little after
--- the last change, outside Insert mode (InsertLeave updates them then).
local function refresh_later()
  timer = timer or vim.uv.new_timer()
  if not timer then
    return
  end
  timer:stop()
  timer:start(
    100,
    0,
    vim.schedule_wrap(function()
      if not enabled or api.nvim_get_mode().mode:find("^[iR]") then
        return
      end
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        M.update(win, true)
      end
    end)
  )
end

--- The headlines the context of `win` shows, outermost first, or nil to
--- keep what it shows now: the parse of the buffer is out of date (after
--- an edit) and `parse` is not set; it is parsed a little later.
---@param win integer
---@param parse? boolean parse the buffer when its parse is out of date
---@return org.Headline[]|nil
local function compute(win, parse)
  local buf = api.nvim_win_get_buf(win)
  local files = require("org.files")
  local file = files.cached_buffer(buf)
  if not file then
    if not parse then
      refresh_later()
      return nil
    end
    file = files.get_buffer(buf)
  end
  local o = opts()
  local foreign = require("org.symbols").foreign(buf)
  local height = api.nvim_win_get_height(win)
  -- (at least one line of the window stays visible)
  local max = math.min(tonumber(o.max_lines) or 3, height - 1)
  if max <= 0 then
    return {}
  end
  local scope = o.trim_scope == "inner" and "inner" or "outer"
  local list ---@type org.Headline[]
  api.nvim_win_call(win, function()
    local top = vim.fn.line("w0")
    local last = api.nvim_buf_line_count(buf)
    list = ancestors(file, top, foreign)
    -- the float covers the first rows: what counts is the line under it,
    -- whose context can be shorter (a sibling) than that of the top line
    -- (sizes tried: when it goes back and forth, the shorter one wins)
    local tried = {}
    for _ = 1, max + 1 do
      local n = math.min(#list, max)
      if n == 0 then
        break
      end
      tried[n] = list
      local next_list = ancestors(file, line_below(top, n, last), foreign)
      local m = math.min(#next_list, max)
      if m == n then
        -- the same rows covered: the line under them decides
        list = next_list
        break
      end
      if tried[m] then
        list = m < n and tried[m] or list
        break
      end
      list = next_list
    end
    list = trim(list, max, scope)
  end)
  return list
end

--- The highlighting and decorations (the parser highlighter's groups and
--- concealed text, bullets, hidden stars, numbering, indentation) of line
--- `lnum` of `src`, added to `out`.
---@param out table[]
---@param src integer
---@param lnum integer
local function decoration_marks(out, src, lnum)
  local ok, deco = pcall(require, "org.ui.decorations")
  if not ok then
    return
  end
  for _, m in ipairs(deco.line_marks(src, lnum - 1)) do
    local o = vim.deepcopy(m[2])
    o.ephemeral = nil
    o.id = nil
    o.end_row = nil
    out[#out + 1] = { m[1], o }
  end
end

--- Highlighting of headline lines, per buffer, for its text and conceal
--- level: the outer headlines stay the same while scrolling.
---@type table<integer, { key: string, lines: table<integer, table[]> }>
local mark_cache = {}

--- The marks of line `lnum` of the buffer of `win` (see `decoration_marks`).
---@param win integer
---@param src integer
---@param lnum integer
---@return table[]
local function line_marks(win, src, lnum)
  local key = api.nvim_buf_get_changedtick(src) .. ":" .. vim.wo[win].conceallevel
  local c = mark_cache[src]
  if not c or c.key ~= key then
    c = { key = key, lines = {} }
    mark_cache[src] = c
  end
  local marks = c.lines[lnum]
  if not marks then
    marks = {}
    decoration_marks(marks, src, lnum)
    c.lines[lnum] = marks
  end
  return marks
end

--- Draw `list` in the context float of `win`.
---@param win integer
---@param list org.Headline[]
local function draw(win, list)
  local s = wins[win]
  if #list == 0 then
    -- hidden rather than closed: opening a float costs more than the rest
    if s and s.float and api.nvim_win_is_valid(s.float) and not s.hidden then
      api.nvim_win_set_config(s.float, { hide = true })
    end
    if s then
      s.hidden, s.sig, s.lines = true, nil, {}
    end
    return
  end
  local src = api.nvim_win_get_buf(win)
  local info = vim.fn.getwininfo(win)[1]
  local o = opts()
  local wo = vim.wo[win]
  local gutter = (o.line_numbers ~= false and (wo.number or wo.relativenumber)) and info.textoff or 0
  local blank = info.textoff - gutter
  local lnums = {}
  for i, hl in ipairs(list) do
    lnums[i] = hl.line
  end
  local sig = table.concat({
    src,
    api.nvim_buf_get_changedtick(src),
    info.width,
    info.textoff,
    gutter,
    wo.conceallevel,
    table.concat(lnums, ","),
  }, ":")
  if s and s.sig == sig and not s.hidden and s.float and api.nvim_win_is_valid(s.float) then
    return
  end
  s = s or { lines = {} }
  wins[win] = s
  local buf = s.buf
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.b[buf].org_context_float = true
    s.buf = buf
  end
  local shift = blank + gutter
  local texts = {}
  for i, hl in ipairs(list) do
    local text = api.nvim_buf_get_lines(src, hl.line - 1, hl.line, false)[1] or ""
    local prefix = string.rep(" ", blank)
    if gutter > 0 then
      prefix = prefix .. string.format("%" .. (gutter - 1) .. "d ", hl.line):sub(-gutter)
    end
    texts[i] = prefix .. text
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, hl in ipairs(list) do
    local row = i - 1
    if gutter > 0 then
      api.nvim_buf_set_extmark(buf, ns, row, blank, { end_col = shift, hl_group = "OrgContextLineNumber" })
    end
    for _, m in ipairs(line_marks(win, src, hl.line)) do
      local mo = m[2]
      if shift > 0 then
        mo = vim.tbl_extend("force", mo, { end_col = mo.end_col and (mo.end_col + shift) or nil })
      end
      pcall(api.nvim_buf_set_extmark, buf, ns, row, m[1] + shift, mo)
    end
  end
  api.nvim_buf_set_extmark(buf, ns, #list - 1, 0, { line_hl_group = "OrgContextBottom", priority = 10 })
  local cfg = {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = info.width,
    height = #list,
    focusable = false,
    style = "minimal",
    zindex = tonumber(o.zindex) or 20,
    hide = false,
  }
  local float = s.float
  if float and api.nvim_win_is_valid(float) then
    api.nvim_win_set_config(float, cfg)
  else
    cfg.noautocmd = true
    float = api.nvim_open_win(buf, false, cfg)
    s.float = float
    local fo = vim.wo[float]
    fo.wrap = false
    fo.foldenable = false
    fo.concealcursor = "nvic"
    fo.winhighlight = "NormalFloat:OrgContext"
  end
  vim.wo[float].conceallevel = wo.conceallevel
  s.sig = sig
  s.lines = lnums
  s.hidden = false
end

--- Update the context of `win` (close it when `win` no longer shows an
--- org buffer). Event handlers leave a buffer whose parse is out of date
--- to a parse a little later; `parse` parses it now.
---@param win integer
---@param parse? boolean
function M.update(win, parse)
  if not enabled then
    return
  end
  if not is_source(win) then
    M.close(win)
    return
  end
  local list = compute(win, parse)
  if list then
    draw(win, list)
  end
end

--- Update every window of the current tab page, and close the contexts
--- of windows that are gone.
---@param parse? boolean
function M.update_all(parse)
  for win in pairs(wins) do
    if not api.nvim_win_is_valid(win) then
      M.close(win)
    end
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    M.update(win, parse)
  end
end

--- Update the windows of the current tab page that show `bufnr`.
---@param bufnr integer
---@param parse? boolean
local function update_buf(bufnr, parse)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == bufnr then
      M.update(win, parse)
    end
  end
end

--- The line numbers of the headlines the context of `win` (default the
--- current window) shows, outermost first; empty when it shows none.
---@param win? integer
---@return integer[]
function M.lines(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local s = wins[win]
  if not (s and not s.hidden and s.float and api.nvim_win_is_valid(s.float)) then
    return {}
  end
  return vim.deepcopy(s.lines)
end

--- The context float of `win` (default current), or nil.
---@param win? integer
---@return integer|nil
function M.float(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local s = wins[win]
  return s and not s.hidden and s.float and api.nvim_win_is_valid(s.float) and s.float or nil
end

--- Turn the context on in every window.
function M.enable()
  enabled = true
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized", "TabEnter" }, {
    group = group,
    callback = function()
      M.update_all()
    end,
  })
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "CursorMoved", "FileType" }, {
    group = group,
    callback = function()
      M.update(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function(ev)
      update_buf(ev.buf)
    end,
  })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function(ev)
      update_buf(ev.buf, true)
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "number", "relativenumber", "conceallevel", "numberwidth", "signcolumn", "foldcolumn" },
    callback = function()
      vim.schedule(M.update_all)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      mark_cache[ev.buf] = nil
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win then
        M.close(win)
      end
    end,
  })
  M.update_all(true)
end

--- Turn the context off and close every context float.
function M.disable()
  enabled = false
  pcall(api.nvim_del_augroup_by_name, GROUP)
  for win in pairs(wins) do
    M.close(win)
  end
  mark_cache = {}
end

--- Toggle the context in every window (`:Org context_toggle`); returns
--- the new state.
---@return boolean
function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
  require("org.utils").notify(enabled and "Org context enabled" or "Org context disabled")
  return enabled
end

--- Apply `ui.context.enabled` (setup).
function M.setup()
  if opts().enabled then
    M.enable()
  elseif enabled then
    M.disable()
  end
end

--- Go to a headline of the context of the current window
--- (`:Org context_goto`): the innermost one, or with a count the one that
--- many levels out. Returns false when the window shows no context.
---@return boolean|nil
function M.goto_context()
  local lines = M.lines()
  if #lines == 0 then
    return false
  end
  local n = math.max(1, vim.v.count1)
  local lnum = lines[math.max(1, #lines - n + 1)]
  vim.cmd("normal! m'")
  api.nvim_win_set_cursor(0, { lnum, 0 })
end

return M
