-- Record the tutor lessons as terminal recordings for the playground page
-- of the website (scripts/site/build.lua → playground.html).
--
--   nvim --headless --clean -l scripts/playground/record.lua [outdir] [lesson...]
--
-- (`make playground` runs it with a throwaway XDG_DATA_HOME, writing
-- docs/playground/<lesson>.cast.) Each lesson of tutor/org/ is opened with
-- `:Org tutor <lesson> reset` in a child Neovim with an 80x24 UI (the one
-- the screen snapshots use, tests/screen.lua) and played through by the
-- steps in scripts/playground/lessons/<lesson>.lua. After every key the
-- screen is redrawn and the rows that changed are written out as
-- asciicast v2 (https://docs.asciinema.org/manual/asciicast/v2/): "o"
-- events of plain ANSI escapes (cursor moves, 24-bit SGR colors), an "i"
-- event per key typed and an "m" marker where each exercise starts, so any
-- asciicast player can play the file.
--
-- Recordings are reproducible: the clock is fixed (2026-10-12 09:00, moved
-- on only by a step's `wait`), the event times come from the steps rather
-- than the wall clock (whole milliseconds), the screen is taken once it
-- has settled, and messages show the data directory as
-- ~/.local/share/nvim wherever it is. The header's "generator" names the
-- Neovim version (its default colorscheme gives the colors) and a hash of
-- the lesson and its steps (M.source_hash). A lesson file is a list of
-- exercises:
--
--   { id = "1.2", steps = { { at = "Apples", col = "Apples" }, { key = "{{org.meta_return}}" },
--                           { type = "Pears" }, { key = "<Esc>" } } }
--
-- `id` is the exercise number of the tutor headline ("intro": the top of
-- the file, `hold` seconds), scrolled to the top before the steps run.
-- A step is one of
--   at   = text: put the cursor on the next line starting with it (in the
--          lesson: from the exercise on, past stars and a TODO keyword;
--          in another buffer such as the agenda: containing it), at
--          `col` (text on that line) or where `text` is; `whole = true`
--          searches the lesson from the top
--   key  = keys, nvim_input notation with tutor placeholders
--          ({{org.cycle}}), shown as one key
--   type = text typed a character at a time
--   wait = minutes the clock moves on
--
-- After each exercise the tutor's check of it (lua/org/tutor/lessons/)
-- must pass, or the recording fails. ORG_PLAYGROUND_EXERCISES=intro,1.2
-- plays only those exercises, ORG_PLAYGROUND_STEPS=<dir> reads the step
-- files from another directory, and ORG_PLAYGROUND_DEBUG=1 (or 2) prints
-- the screen after each exercise (or step) to stderr.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/?.lua;" .. root .. "/scripts/?.lua;" .. package.path

local Screen = require("tests.screen")

local M = {}

M.width, M.height = 80, 24
--- The fixed "now" of the recordings (local time).
M.now = { year = 2026, month = 10, day = 12, hour = 9, min = 0 }

-- Milliseconds between events of the recording (event times are kept in
-- whole milliseconds, so they add up exactly).
local PACE = { key = 900, char = 90, after_type = 500, at = 700, exercise = 1600, settle = 50 }

-- Child setup on top of tests/screen.lua's: a status line with the file
-- name, the mode shown, quick tutor marks, and a clock moved by `wait`.
local SETUP = [[
vim.o.laststatus = 2
vim.o.statusline = "%#StatusLine# %t%=%l:%c "
vim.o.showmode = true
vim.o.showcmd = true
vim.o.cmdheight = 2
vim.o.wrap = false
vim.o.timeout = false
require("org.tutor").debounce_ms = 1
-- messages show the data directory as on a default install, not where
-- the recording ran: every way a message can spell it (the resolved path,
-- as given, with ~ for the home directory), longest first so a shorter one
-- doesn't match inside a longer one (/private/var/... on macOS)
local utils = require("org.utils")
local data = vim.fs.normalize(vim.fn.stdpath("data"))
local real = vim.fs.normalize(vim.uv.fs_realpath(data) or data)
local forms, seen = {}, {}
for _, p in ipairs({ real, data, vim.fn.fnamemodify(real, ":~"), vim.fn.fnamemodify(data, ":~"), utils.abbreviate(real), utils.abbreviate(data) }) do
  if not seen[p] then
    seen[p] = true
    forms[#forms + 1] = p
  end
end
table.sort(forms, function(a, b)
  return #a > #b
end)
local notify = vim.notify
vim.notify = function(msg, ...)
  if type(msg) == "string" then
    -- a mark first, so a shorter spelling can't match in what replaced a
    -- longer one
    for _, p in ipairs(forms) do
      msg = msg:gsub(vim.pesc(p), "\1")
    end
    msg = msg:gsub("\1", "~/.local/share/nvim")
  end
  return notify(msg, ...)
end
_G.__pg_offset = 0
local time, date = os.time, os.date
os.time = function(t)
  return time(t) + (t and 0 or _G.__pg_offset)
end
os.date = function(fmt, t)
  return date(fmt, t or os.time())
end
]]

-- Resolve the placeholders of a key with the tutor's own rendering.
local RENDER = [[
return require("org.tutor").render({ ... })[1]
]]

-- Scroll an exercise headline to the top of the window.
local GOTO_EXERCISE = [[
local id = ...
if id == "intro" then
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! zt")
  return true
end
for lnum, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if line:match("^%*+ " .. vim.pesc(id) .. " ") then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("normal! zt")
    vim.b.pg_exercise = lnum
    return true
  end
end
return false
]]

-- Put the cursor on the next line that starts with `text` (in an org
-- buffer: from the exercise on, leading stars, blanks and a TODO keyword
-- left out; elsewhere, such as the agenda: anywhere in the line).
local AT = [[
local text, col, whole = ...
local org = vim.bo.filetype == "org"
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for lnum = org and not whole and (vim.b.pg_exercise or 1) or 1, #lines do
  local line = lines[lnum]
  local found
  if org then
    local rest = line:gsub("^[%s%*]*", ""):gsub("^%u%u+%s+", "")
    found = vim.startswith(rest, text) or vim.startswith((line:gsub("^[%s%*]*", "")), text)
  else
    found = line:find(text, 1, true) ~= nil
  end
  if found then
    local c
    if col ~= vim.NIL and col then
      c = line:find(col, 1, true) - 1
    else
      c = (line:find(text, 1, true) or 1) - 1
    end
    vim.api.nvim_win_set_cursor(0, { lnum, c })
    return true
  end
end
return false
]]

-- The tutor's check of an exercise: true, false, or nil when it has none.
local CHECK = [[
local buf, id = ...
local res = require("org.tutor").refresh(buf)[id]
if res == nil then
  return vim.NIL
end
return res
]]

--- A recorder: the child Neovim, the screen it last drew and the events.
local Rec = {}
Rec.__index = Rec

function M.new()
  -- installed before the UI attaches: the mode info (cursor shapes) and
  -- default colors are sent once, on attach
  local handlers = {
    _grid_cursor_goto = function(s, _, row, col)
      s.cursor = { row, col }
    end,
    _default_colors_set = function(s, fg, bg)
      if fg >= 0 then
        s.default_fg = fg
      end
      if bg >= 0 then
        s.default_bg = bg
      end
    end,
    _mode_info_set = function(s, _, info)
      s.mode_info = info
    end,
    _mode_change = function(s, _, idx)
      s.mode_idx = idx
    end,
  }
  local screen = Screen.new({ width = M.width, height = M.height, now = M.now, handlers = handlers })
  local self = setmetatable({ screen = screen, t = 0, events = {}, drawn = {}, cursor = { 0, 0 } }, Rec)
  screen.default_fg, screen.default_bg = screen.default_fg or 0xe0e2ea, screen.default_bg or 0x14161b
  screen:lua(SETUP)
  return self
end

local function hex(n)
  return string.format("#%06x", n)
end

-- The SGR parameters of attr `id`.
function Rec:sgr(id)
  local a = id ~= 0 and self.screen.attrs[id]
  if not a then
    return "0"
  end
  local rgb = a.rgb
  local p = { "0" }
  if rgb.bold then
    p[#p + 1] = "1"
  end
  if rgb.italic then
    p[#p + 1] = "3"
  end
  if rgb.underline or rgb.undercurl or rgb.underdouble or rgb.underdotted or rgb.underdashed then
    p[#p + 1] = "4"
  end
  if rgb.strikethrough then
    p[#p + 1] = "9"
  end
  local fg, bg = rgb.foreground, rgb.background
  if rgb.reverse then
    fg, bg = bg or self.screen.default_bg, fg or self.screen.default_fg
  end
  local function color(base, n)
    return string.format("%d;2;%d;%d;%d", base, bit.rshift(n, 16), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
  end
  -- the default colors are the theme's (in the header)
  if fg and fg ~= self.screen.default_fg then
    p[#p + 1] = color(38, fg)
  end
  if bg and bg ~= self.screen.default_bg then
    p[#p + 1] = color(48, bg)
  end
  return table.concat(p, ";")
end

-- Row `r` of the screen as text with SGR escapes.
function Rec:row(r)
  local cells = self.screen.grid[r] or {}
  local out, cur = {}, nil
  local last = #cells
  -- trailing default blanks are left to the erase-line at the end
  while last > 0 and cells[last][1] == " " and cells[last][2] == 0 do
    last = last - 1
  end
  for c = 1, last do
    local text, id = cells[c][1], cells[c][2]
    if text ~= "" then -- the second cell of a double-width character
      local s = self:sgr(id)
      if s ~= cur then
        out[#out + 1] = "\27[" .. s .. "m"
        cur = s
      end
      out[#out + 1] = text
    end
  end
  if cur and cur ~= "0" then
    out[#out + 1] = "\27[0m"
  end
  return table.concat(out) .. "\27[K"
end

function Rec:cursor_shape()
  local s = self.screen
  local info = s.mode_info and s.mode_idx and s.mode_info[s.mode_idx + 1]
  local shape = info and info.cursor_shape or "block"
  return shape == "vertical" and 6 or shape == "horizontal" and 4 or 2
end

--- Wait until the screen stops changing, then write the rows that differ
--- from the last ones written.
function Rec:frame()
  local s = self.screen
  local prev, stable = nil, 0
  local deadline = vim.uv.hrtime() + Screen.timeout * 1e6
  while stable < 8 do
    -- a "fast" request: answered also while the child waits in a prompt
    s:request("nvim_get_mode")
    vim.wait(25)
    local rows = {}
    for r = 1, M.height do
      rows[r] = self:row(r)
    end
    local sig = table.concat(rows, "\n")
      .. "|"
      .. tostring(s.cursor and s.cursor[1])
      .. ","
      .. tostring(s.cursor and s.cursor[2])
      .. "|"
      .. tostring(s.mode_idx)
      .. "|"
      .. s.flushes
    if sig == prev then
      stable = stable + 1
    else
      stable, prev = 0, sig
    end
    self.rows = rows
    if vim.uv.hrtime() > deadline then
      error("playground: the screen didn't settle", 2)
    end
  end
  local out = {}
  for r = 1, M.height do
    if self.rows[r] ~= self.drawn[r] then
      out[#out + 1] = "\27[" .. r .. ";1H" .. self.rows[r]
      self.drawn[r] = self.rows[r]
    end
  end
  local cursor = s.cursor or { 0, 0 }
  local shape = self:cursor_shape()
  if shape ~= self.shape then
    out[#out + 1] = "\27[" .. shape .. " q"
    self.shape = shape
  end
  out[#out + 1] = "\27[" .. (cursor[1] + 1) .. ";" .. (cursor[2] + 1) .. "H"
  local data = table.concat(out)
  if data ~= self.last_cursor_only then
    self:event("o", data)
  end
  self.last_cursor_only = #out == 1 and data or nil
end

function Rec:event(kind, data)
  self.events[#self.events + 1] = { self.t, kind, data }
end

-- A key as the lesson shows it: placeholders resolved.
function Rec:render(keys)
  self.keys = self.keys or {}
  if not self.keys[keys] then
    self.keys[keys] = self.screen:lua(RENDER, keys)
  end
  return self.keys[keys]
end

-- For nvim_input: the leader is Space (tests/screen.lua), and a < that
-- doesn't start a key name (<< or the agenda's <) is <lt>.
local function input_keys(keys)
  keys = keys:gsub("<[Ll]eader>", "<Space>")
  local out, i = {}, 1
  while i <= #keys do
    local name = keys:match("^<[%w%-]+>", i)
    if name and vim.keycode(name) ~= name then
      out[#out + 1] = name
      i = i + #name
    else
      local ch = keys:sub(i, i)
      out[#out + 1] = ch == "<" and "<lt>" or ch
      i = i + 1
    end
  end
  return table.concat(out)
end

function Rec:key(keys)
  self:event("i", keys)
  self.screen:input(input_keys(keys))
  self.t = self.t + PACE.settle
  self:frame()
  self.t = self.t + PACE.key
end

function Rec:type(text)
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    self:event("i", ch)
    self.screen:input(ch == "<" and "<lt>" or ch)
    self.t = self.t + PACE.settle
    self:frame()
    self.t = self.t + PACE.char
  end
  self.t = self.t + PACE.after_type
end

-- With ORG_PLAYGROUND_DEBUG=1, the screen at the end of each exercise as
-- plain text on stderr (=2: after every step).
function Rec:debug(label, level)
  if tonumber(vim.env.ORG_PLAYGROUND_DEBUG or "0") < (level or 1) then
    return
  end
  local lines = {}
  for r = 1, M.height do
    local row = {}
    for _, cell in ipairs(self.screen.grid[r] or {}) do
      row[#row + 1] = cell[1]
    end
    lines[#lines + 1] = "|" .. table.concat(row):gsub("%s+$", "")
  end
  io.stderr:write(("-- %s\n%s\n"):format(label, table.concat(lines, "\n")))
end

--- Play one exercise.
function Rec:exercise(lesson, ex, title)
  self:event("m", title)
  if not self.screen:lua(GOTO_EXERCISE, ex.id) then
    error(("playground: %s: no exercise %s in the lesson"):format(lesson, ex.id), 0)
  end
  self:frame()
  self.t = self.t + (ex.hold and math.floor(ex.hold * 1000 + 0.5) or PACE.exercise)
  for _, step in ipairs(ex.steps or {}) do
    if step.at then
      if not self.screen:lua(AT, step.at, step.col or vim.NIL, step.whole or false) then
        error(("playground: %s %s: no line with %q"):format(lesson, ex.id, step.at), 0)
      end
      self:frame()
      self.t = self.t + PACE.at
    elseif step.key then
      self:key(self:render(step.key))
    elseif step.type then
      self:type(step.type)
    elseif step.wait then
      self.screen:lua("_G.__pg_offset = _G.__pg_offset + ...", step.wait * 60)
      self.t = self.t + PACE.key
    end
    self:debug(lesson .. " " .. ex.id .. " " .. vim.inspect(step), 2)
  end
  self.t = self.t + PACE.exercise
  self:debug(lesson .. " " .. ex.id)
  -- the recording must show the exercise done: its check passes
  local passed = self.screen:lua(CHECK, self.buf, ex.id)
  if passed == false then
    error(("playground: %s %s: the steps don't pass the exercise's check"):format(lesson, ex.id), 0)
  end
end

--- Milliseconds as the seconds of an event time: 8300 → "8.3", written
--- out rather than by vim.json.encode, which gives 8.300000000000001.
---@param ms integer
---@return string
function M.seconds(ms)
  local s = ("%d.%03d"):format(math.floor(ms / 1000), ms % 1000):gsub("0+$", ""):gsub("%.$", "")
  return s
end

--- The exercise titles of a lesson file, by number.
function M.titles(path)
  local out = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local id, title = line:match("^%*+ (%d+%.%d+) (.-)%s*$")
    if id then
      out[id] = id .. " " .. title
    end
  end
  return out
end

--- The steps file of a lesson (scripts/playground/lessons/<name>.lua).
--- ORG_PLAYGROUND_STEPS: another directory of step files (the spec's).
function M.steps_path(name)
  local dir = vim.env.ORG_PLAYGROUND_STEPS
  if not dir or dir == "" then
    dir = root .. "/scripts/playground/lessons"
  end
  return dir .. "/" .. name .. ".lua"
end

--- The steps of a lesson.
function M.steps(name)
  return dofile(M.steps_path(name))
end

--- What a recording is made from: the SHA-256 of the lesson
--- (tutor/org/<name>.org) and its steps file, line endings normalized
--- (a Windows checkout may have CRLF). In the cast header, so a spec
--- notices a recording older than its lesson.
---@param name string
---@return string
function M.source_hash(name)
  local parts = {}
  for _, path in ipairs({ root .. "/tutor/org/" .. name .. ".org", M.steps_path(name) }) do
    local f = assert(io.open(path, "rb"))
    parts[#parts + 1] = (f:read("*a"):gsub("\r\n", "\n"))
    f:close()
  end
  return vim.fn.sha256(table.concat(parts, "\f"))
end

--- Record lesson `name`; returns the asciicast text. `only`: the ids of
--- the exercises to play (default: all).
---@param name string
---@param only? table<string, boolean>
function M.record(name, only)
  local src = root .. "/tutor/org/" .. name .. ".org"
  local titles = M.titles(src)
  local self = M.new()
  local ok, err = pcall(function()
    -- keys are resolved up front: a prompt open later answers only
    -- "fast" requests
    for _, ex in ipairs(M.steps(name)) do
      for _, step in ipairs(ex.steps or {}) do
        if step.key then
          self:render(step.key)
        end
      end
    end
    self.nvim = self.screen:lua('return (vim.fn.execute("version"):match("NVIM (v%S+)"))')
    self.screen:cmd("Org tutor " .. name .. " reset")
    self.buf = self.screen:lua("return vim.api.nvim_get_current_buf()")
    -- the copy's full path isn't part of the recording
    self.screen:cmd("echo ''")
    for _, ex in ipairs(M.steps(name)) do
      if not only or only[ex.id] then
        self:exercise(name, ex, ex.title or titles[ex.id] or ex.id)
      end
    end
    if #self.screen.errors > 0 then
      error("playground: bad redraw events: " .. table.concat(self.screen.errors, "; "), 0)
    end
  end)
  self.screen:close()
  if not ok then
    error(err, 0)
  end
  -- written by hand: the keys in a fixed order
  local palette = table.concat({
    "#07080d",
    "#ffc0b9",
    "#b3f6c0",
    "#fce094",
    "#a6dbff",
    "#ffcaff",
    "#8cf8f7",
    "#eef1f8",
    "#4f5258",
    "#ffc0b9",
    "#b3f6c0",
    "#fce094",
    "#a6dbff",
    "#ffcaff",
    "#8cf8f7",
    "#eef1f8",
  }, ":")
  -- "generator": the Neovim that drew it (its default colorscheme gives
  -- the colors) and what it was made from (M.source_hash)
  local header = string.format(
    '{"version":2,"width":%d,"height":%d,"title":%s,"env":{"TERM":"xterm-256color","SHELL":"nvim"},'
      .. '"theme":{"fg":"%s","bg":"%s","palette":"%s"},"generator":{"nvim":%s,"source":"%s"}}',
    M.width,
    M.height,
    vim.json.encode("org.nvim tutor: " .. name),
    hex(self.screen.default_fg),
    hex(self.screen.default_bg),
    palette,
    vim.json.encode(self.nvim or ""),
    M.source_hash(name)
  )
  local out = { header }
  -- start with a clear screen and the cursor hidden until the first frame
  table.insert(self.events, 1, { 0, "o", "\27[2J\27[H" })
  for _, e in ipairs(self.events) do
    out[#out + 1] = "[" .. M.seconds(e[1]) .. "," .. vim.json.encode(e[2]) .. "," .. vim.json.encode(e[3]) .. "]"
  end
  return table.concat(out, "\n") .. "\n"
end

--- The tutor lessons (tutor/org/*.org), sorted.
function M.lessons()
  local out = {}
  for _, f in ipairs(vim.fn.glob(root .. "/tutor/org/*.org", false, true)) do
    out[#out + 1] = vim.fn.fnamemodify(f, ":t:r")
  end
  table.sort(out)
  return out
end

if _G.arg and _G.arg[0] and _G.arg[0]:match("playground[\\/]record%.lua$") then
  local outdir = _G.arg[1] or (root .. "/docs/playground")
  local names = { unpack(_G.arg, 2) }
  if #names == 0 then
    names = M.lessons()
  end
  vim.fn.mkdir(outdir, "p")
  -- ORG_PLAYGROUND_EXERCISES=intro,1.2: only these (a quick check)
  local only
  if vim.env.ORG_PLAYGROUND_EXERCISES and vim.env.ORG_PLAYGROUND_EXERCISES ~= "" then
    only = {}
    for id in vim.env.ORG_PLAYGROUND_EXERCISES:gmatch("[^,%s]+") do
      only[id] = true
    end
  end
  local failed = false
  for _, name in ipairs(names) do
    local ok, cast = pcall(M.record, name, only)
    if ok then
      local path = outdir .. "/" .. name .. ".cast"
      local f = assert(io.open(path, "wb"))
      f:write(cast)
      f:close()
      local n = select(2, cast:gsub("\n", ""))
      io.stdout:write(
        ("playground: %s: %d events, %.1f KB → %s\n"):format(
          name,
          n - 1,
          #cast / 1024,
          vim.fn.fnamemodify(path, ":~:.")
        )
      )
    else
      io.stderr:write(tostring(cast) .. "\n")
      failed = true
    end
  end
  os.exit(failed and 1 or 0)
end

return M
