-- Screen snapshots: render buffers in a child Neovim with a fixed-size UI
-- and compare what is drawn (text and highlight groups) with golden files.
--
-- The child is `nvim --embed --headless -u NONE` with only this plugin,
-- driven over msgpack-RPC on its stdio. It attaches a UI with ext_linegrid
-- and ext_hlstate, so each highlight comes with the groups it was made
-- from: a snapshot names groups (OrgTodo, Folded, ...) rather than colors.
-- Concealed text, conceal replacements, folds, extmark highlights and
-- virtual text are all in it as drawn.
--
--   local Screen = require("tests.screen")
--   local screen = Screen.new({ width = 60, height = 8, setup = { ui = { ... } } })
--   screen:org({ "* TODO Task :work:" })
--   screen:expect("todo_headline")   -- tests/fixtures/screen/todo_headline.txt
--   screen:close()
--
-- A snapshot is a "screen WxH" line, a |row| per screen row with each
-- highlighted run written {N:text} (literal { } \ escaped with \), then a
-- legend: "{N} OrgTodo -> @comment.error [bold]" is the group, the links
-- it has up to the first group that isn't org's, and its style flags. A
-- cell combining groups (a folded line, a concealed star) lists them
-- separated by " | ". Blank cells at the end of a row and empty rows at
-- the bottom are left out.
--
-- ORG_UPDATE_SNAPSHOTS=1 writes the golden files instead of comparing;
-- ORG_SCREEN_TIMEOUT (ms, default 10000) bounds every wait on the child.
local uv = vim.uv

local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.dir = root .. "/tests/fixtures/screen"

--- How long to wait for one RPC response (ms).
M.timeout = tonumber(vim.env.ORG_SCREEN_TIMEOUT or "") or 10000

local Screen = {}
Screen.__index = Screen

-- Run in the child before anything else: only this plugin on the
-- runtimepath, no user config or plugins (no matchparen), fixed options.
local BOOTSTRAP = [[
local root, setup, now = ...
if now ~= vim.NIL and now then
  -- a fixed "now" (local time) for os.time() and os.date()
  local time, date = os.time, os.date
  local fixed = time(now)
  os.time = function(t)
    return time(t or now)
  end
  os.date = function(fmt, t)
    return date(fmt, t or fixed)
  end
end
vim.opt.rtp = { root, vim.env.VIMRUNTIME }
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.hidden = true
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.ruler = false
vim.o.showcmd = false
vim.o.showmode = false
vim.o.shortmess = "aoOstTWIcCFS"
vim.o.statusline = "%#StatusLine#"
vim.o.more = false
vim.o.wrap = false
vim.o.number = false
vim.o.signcolumn = "no"
vim.o.cursorline = false
vim.o.list = false
vim.o.mouse = ""
-- no ~ past the end of the buffer: those rows are left out
vim.o.fillchars = "eob: "
-- the screen must not depend on how long a redraw takes
vim.o.redrawtime = 2000
vim.g.mapleader = " "
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")
vim.cmd("colorscheme default")
vim.cmd("runtime plugin/org.lua")
setup = vim.tbl_deep_extend("keep", setup or {}, {
  org_directory = vim.fn.tempname(),
  agenda_files = {},
  clock = { auto_clock_resolution = false, ask_before_exiting = false, persist_query_resume = false },
})
require("org").setup(setup)
]]

-- Write `lines` to a new .org file and edit it, as a user opens one
-- (startup visibility, drawers hidden). 'shortmess' F keeps its name off
-- the screen.
local LOAD = [[
local lines, opts = ...
local path = vim.fn.tempname() .. ".org"
vim.fn.writefile(lines, path)
vim.cmd("silent edit " .. vim.fn.fnameescape(path))
if opts.cursor then
  vim.api.nvim_win_set_cursor(0, opts.cursor)
end
vim.cmd("echo ''")
return path
]]

-- The UI names the group a link ends at (Title, DiagnosticError), the same
-- for many org groups. Turn each org group that is a link into a copy of
-- what it resolves to, so the screen names the org group itself, and
-- return the links each one had. Groups defined later (per-buffer TODO
-- keywords) are handled by the next call.
local FLATTEN = [[
_G.__screen_links = _G.__screen_links or {}
local links = _G.__screen_links
for name, def in pairs(vim.api.nvim_get_hl(0, {})) do
  if def.link and name:match("^[oO]rg") then
    local chain, d = {}, def
    -- up to the first group that isn't org's: further links are
    -- Neovim's defaults, which change between versions
    while d.link and #chain < 10 do
      local target = d.link
      chain[#chain + 1] = target
      if links[target] then
        vim.list_extend(chain, links[target])
        break
      end
      if not target:match("^[oO]rg") then
        break
      end
      d = vim.api.nvim_get_hl(0, { name = target })
    end
    local resolved = vim.api.nvim_get_hl(0, { name = name, link = false })
    resolved.default = nil
    vim.api.nvim_set_hl(0, name, resolved)
    links[name] = chain
  end
end
return links
]]

--- Start a child Neovim with a `width` x `height` screen.
--- `setup` is passed to require("org").setup(); `now` ({ year, month,
--- day, hour, min }, local time) fixes what os.time() and os.date() say.
---@param opts? { width?: integer, height?: integer, setup?: table, now?: table }
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    width = opts.width or 80,
    height = opts.height or 24,
    msgid = 0,
    responses = {},
    grid = {},
    attrs = {},
    flushes = 0,
    stderr = {},
    errors = {},
  }, Screen)
  self.stdin, self.stdout, self.stderr_pipe = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local handle, err = uv.spawn(vim.v.progpath, { ---@diagnostic disable-line: missing-fields
    args = { "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" },
    stdio = { self.stdin, self.stdout, self.stderr_pipe },
  }, function(code, signal)
    self.exited = { code = code, signal = signal }
  end)
  if not handle then
    error("screen: can't start " .. vim.v.progpath .. ": " .. tostring(err))
  end
  self.handle = handle
  local unpacker = vim.mpack.Unpacker()
  self.stdout:read_start(function(rerr, data)
    if rerr or not data then
      self.eof = true
      return
    end
    local pos = 1
    while pos <= #data do
      local msg
      msg, pos = unpacker(data, pos)
      if msg == nil then
        break
      end
      self:_receive(msg)
    end
  end)
  self.stderr_pipe:read_start(function(_, data)
    if data then
      self.stderr[#self.stderr + 1] = data
    end
  end)
  local ok, e = pcall(function()
    self:request("nvim_exec_lua", BOOTSTRAP, { root, opts.setup or vim.empty_dict(), opts.now or vim.NIL })
    self:request("nvim_ui_attach", self.width, self.height, { ext_linegrid = true, ext_hlstate = true, rgb = true })
  end)
  if not ok then
    self:close()
    error(e, 0)
  end
  return self
end

function Screen:_receive(msg)
  local kind = msg[1]
  if kind == 1 then
    self.responses[msg[2]] = { err = msg[3], result = msg[4] }
  elseif kind == 2 and msg[2] == "redraw" then
    for _, batch in ipairs(msg[3]) do
      local name = batch[1]
      local handler = self["_" .. name]
      if handler then
        for i = 2, #batch do
          local ok, err = pcall(handler, self, unpack(batch[i]))
          if not ok then
            self.errors[#self.errors + 1] = name .. ": " .. tostring(err)
          end
        end
      end
    end
  elseif kind == 0 then
    -- the child doesn't call us: answer anyway so it never waits
    self.stdin:write(vim.mpack.encode({ 1, msg[2], "screen: no requests", vim.NIL }))
  end
end

local function blank_row(w)
  local row = {}
  for c = 1, w do
    row[c] = { " ", 0 }
  end
  return row
end

function Screen:_grid_resize(_, w, h)
  self.cols, self.rows = w, h
  self.grid = {}
  for r = 1, h do
    self.grid[r] = blank_row(w)
  end
end

function Screen:_grid_clear()
  for r = 1, self.rows or 0 do
    self.grid[r] = blank_row(self.cols)
  end
end

function Screen:_grid_line(_, row, col, cells)
  local line = self.grid[row + 1]
  if not line then
    return
  end
  local hl = 0
  local c = col + 1
  for _, cell in ipairs(cells) do
    if cell[2] ~= nil then
      hl = cell[2]
    end
    for _ = 1, (cell[3] or 1) do
      line[c] = { cell[1], hl }
      c = c + 1
    end
  end
end

function Screen:_grid_scroll(_, top, bot, left, right, rows)
  local from, to, step
  if rows > 0 then
    from, to, step = top + 1, bot - rows, 1
  else
    from, to, step = bot, top + 1 - rows, -1
  end
  for r = from, to, step do
    for c = left + 1, right do
      self.grid[r][c] = self.grid[r + rows][c]
    end
  end
end

function Screen:_hl_attr_define(id, rgb, _, info)
  self.attrs[id] = { rgb = rgb, info = info }
end

function Screen:_flush()
  self.flushes = self.flushes + 1
end

--- Call API function `method` in the child and return its result.
function Screen:request(method, ...)
  if self.exited then
    error("screen: the child Neovim has exited: " .. table.concat(self.stderr), 2)
  end
  self.msgid = self.msgid + 1
  local id = self.msgid
  self.stdin:write(vim.mpack.encode({ 0, id, method, { ... } }))
  local done = vim.wait(M.timeout, function()
    return self.responses[id] ~= nil or self.exited ~= nil or self.eof
  end, 2)
  local res = self.responses[id]
  self.responses[id] = nil
  if not res then
    local why = done and "the child Neovim exited" or ("no answer after " .. M.timeout .. " ms (blocked on a prompt?)")
    error("screen: " .. method .. ": " .. why .. " " .. table.concat(self.stderr), 2)
  end
  if res.err ~= vim.NIL and res.err ~= nil then
    local e = res.err
    error("screen: " .. method .. ": " .. (type(e) == "table" and tostring(e[2]) or tostring(e)), 2)
  end
  return res.result
end

--- Run Lua `code` in the child with `...` as its arguments.
function Screen:lua(code, ...)
  return self:request("nvim_exec_lua", code, { ... })
end

--- Run an Ex command in the child.
function Screen:cmd(command)
  return self:request("nvim_command", command)
end

--- Type `keys` (nvim_input notation) in the child.
function Screen:input(keys)
  return self:request("nvim_input", keys)
end

--- Open `lines` as an org file; returns its path. `opts.cursor` =
--- {lnum, col0}, else the first line.
function Screen:org(lines, opts)
  return self:lua(LOAD, lines, opts or vim.empty_dict())
end

-- The highlight of attr `id`, for the legend: the groups it was combined
-- from, separated by |, as ext_hlstate lists them, each with the links it
-- had up to the first non-org group, then its style flags in []. No
-- colors: those come from the colorscheme.
local STYLES = { "bold", "italic", "underline", "undercurl", "underdouble", "strikethrough", "reverse" }

function Screen:_describe(id)
  local a = self.attrs[id]
  if not a then
    return "?" .. tostring(id)
  end
  local names, prev = {}, nil
  for _, i in ipairs(a.info or {}) do
    local n = i.hi_name or i.ui_name
    if n and n ~= "" and n ~= prev then
      prev = n
      local chain = self.links and self.links[n]
      names[#names + 1] = chain and (n .. " -> " .. table.concat(chain, " -> ")) or n
    end
  end
  local desc = #names > 0 and table.concat(names, " | ") or "-"
  local styles = {}
  for _, s in ipairs(STYLES) do
    if a.rgb[s] then
      styles[#styles + 1] = s
    end
  end
  if a.rgb.blend then
    styles[#styles + 1] = "blend=" .. a.rgb.blend
  end
  if #styles > 0 then
    desc = desc .. " [" .. table.concat(styles, ", ") .. "]"
  end
  return desc
end

-- A cell that looks like an empty one: a space without a background or
-- a line through or under it.
function Screen:_blank(cell)
  if cell[1] ~= " " then
    return false
  end
  local a = cell[2] ~= 0 and self.attrs[cell[2]]
  if not a then
    return true
  end
  local rgb = a.rgb
  return not (rgb.background or rgb.reverse or rgb.underline or rgb.undercurl or rgb.underdouble or rgb.strikethrough)
end

local function escape(s)
  return (s:gsub("[{}\\]", "\\%0"))
end

--- The screen as text: each row between | |, a highlighted run as
--- {N:text}, then a legend of what N is. Trailing unhighlighted blanks and
--- the rows after the last one with anything on it are left out.
function Screen:render()
  local legend, keys, order = {}, {}, {}
  local out = {}
  for r = 1, self.rows or 0 do
    local cells = self.grid[r]
    local last = 0
    for c = #cells, 1, -1 do
      if not self:_blank(cells[c]) then
        last = c
        break
      end
    end
    local parts, run_hl, run = {}, nil, {}
    local function close()
      if run_hl == nil then
        return
      end
      local text = escape(table.concat(run))
      if run_hl == 0 then
        parts[#parts + 1] = text
      else
        parts[#parts + 1] = "{" .. run_hl .. ":" .. text .. "}"
      end
      run = {}
    end
    for c = 1, last do
      local text, id = cells[c][1], cells[c][2]
      local key = 0
      if id ~= 0 then
        local desc = self:_describe(id)
        -- attrs equal for the snapshot (same groups and styles) share a key
        key = keys[desc]
        if not key then
          order[#order + 1] = desc
          key = #order
          keys[desc] = key
        end
      end
      if key ~= run_hl then
        close()
        run_hl = key
      end
      run[#run + 1] = text
    end
    close()
    out[r] = "|" .. table.concat(parts) .. "|"
  end
  while #out > 0 and out[#out] == "||" do
    out[#out] = nil
  end
  local lines = { string.format("screen %dx%d", self.cols or 0, self.rows or 0) }
  vim.list_extend(lines, out)
  lines[#lines + 1] = ""
  for i, desc in ipairs(order) do
    legend[#legend + 1] = string.format("{%d} %s", i, desc)
  end
  vim.list_extend(lines, legend)
  return table.concat(lines, "\n") .. "\n"
end

--- Redraw the child until two renders in a row agree (deferred work such
--- as scheduled decorations has run), and return the render.
function Screen:snapshot()
  local deadline = uv.hrtime() + M.timeout * 1e6
  local prev
  while true do
    self.links = self:lua(FLATTEN)
    self:cmd("redraw")
    local flushes = self.flushes
    -- the redraw's events come before its answer; one more round trip
    -- lets scheduled callbacks in the child run
    self:request("nvim_eval", "1")
    local cur = self:render()
    if cur == prev and flushes == self.flushes then
      return cur
    end
    if uv.hrtime() > deadline then
      error("screen: the screen didn't settle within " .. M.timeout .. " ms", 2)
    end
    prev = cur
    vim.wait(5)
  end
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return (s:gsub("\r\n", "\n"))
end

local function write(path, s)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

--- A line diff of `a` and `b`, for a failure message.
local function diff(expected, actual)
  local d = (vim.text and vim.text.diff or vim.diff)(expected, actual, { ctxlen = 3 })
  return type(d) == "string" and d or ""
end

--- Compare the screen with the golden file tests/fixtures/screen/<name>.txt.
--- With ORG_UPDATE_SNAPSHOTS=1, (re)write it instead. A missing golden
--- file fails and says how to create it.
function Screen:expect(name)
  local actual = self:snapshot()
  if #self.errors > 0 then
    error("screen: bad redraw events: " .. table.concat(self.errors, "; "), 2)
  end
  local path = M.dir .. "/" .. name .. ".txt"
  local update = vim.env.ORG_UPDATE_SNAPSHOTS
  if update == "1" or update == "true" then
    if read(path) ~= actual then
      write(path, actual)
    end
    return actual
  end
  local expected = read(path)
  if not expected then
    error(
      string.format(
        "screen: no golden file %s; run with ORG_UPDATE_SNAPSHOTS=1 to create it from this screen:\n%s",
        vim.fn.fnamemodify(path, ":."),
        actual
      ),
      2
    )
  end
  if expected ~= actual then
    error(
      string.format(
        "screen: %s differs from tests/fixtures/screen/%s.txt "
          .. "(ORG_UPDATE_SNAPSHOTS=1 rewrites it if the change is intended):\n%s",
        name,
        name,
        diff(expected, actual)
      ),
      2
    )
  end
  return actual
end

--- Quit the child, and kill it if it doesn't.
function Screen:close()
  if self.closed then
    return
  end
  self.closed = true
  if not self.exited then
    pcall(function()
      self.stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qall!" } }))
    end)
    vim.wait(1000, function()
      return self.exited ~= nil
    end, 5)
  end
  if not self.exited and self.handle then
    pcall(self.handle.kill, self.handle, "sigkill")
    vim.wait(1000, function()
      return self.exited ~= nil
    end, 5)
  end
  for _, h in ipairs({ self.stdin, self.stdout, self.stderr_pipe, self.handle }) do
    if h and not h:is_closing() then
      h:close()
    end
  end
end

return M
