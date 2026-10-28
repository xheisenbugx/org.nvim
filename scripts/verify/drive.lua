-- Verify a feature in a running Neovim, the way a user drives it: keys
-- typed, the screen read, the files on disk checked. The recipes in
-- scripts/verify/recipes/<area>.lua are what the feature map of the
-- verify-org skill (.claude/skills/verify-org/) points at; a coding agent
-- runs them after a change, and writes a new scenario for what it changed.
--
--   nvim --headless --clean -l scripts/verify/drive.lua [--out DIR] <recipe>[:<scenario>] ...
--
-- (`make verify RECIPE=agenda`, several space-separated; a scenario is
-- chosen by its name or the start of it.) Each scenario runs in its own
-- child Neovim with an 80x24 UI (tests/screen.lua: only this plugin, no
-- user config), with HOME and the XDG directories in a scratch directory,
-- so nothing touches the real notes, ID database or clock state. The clock
-- is fixed (M.now, moved on by a `wait` step).
--
-- Evidence goes to DIR (default: a new org-verify-* directory in the
-- system's temporary directory, printed at the end):
-- <recipe>/<NN>-<scenario>/<NN>-<step>.txt, the screen as text after every
-- step with the cursor, mode and buffer above it, and report.md, the steps
-- of every scenario with PASS / FAIL. The exit status is 1 when a
-- scenario failed.
--
-- A recipe returns a list of scenarios:
--
--   {
--     name = "mark a TODO done from the agenda",
--     files = { ["todo.org"] = { "* TODO Renew the passport", "  SCHEDULED: <2026-10-12 Mon>" } },
--     open = "todo.org",            -- edited first (else an empty buffer), cursor at `cursor`
--     setup = { agenda_files = { "{{dir}}/*.org" } },
--     steps = { { key = "{{global.agenda}}a" }, { expect = { screen = "Renew the passport" } } },
--   }
--
-- `files` are written to the scenario directory; "{{dir}}" in `setup`
-- (any string in it) is that directory. org_directory and
-- default_notes_file are in it too unless `setup` sets them. `width`,
-- `height` and `now` change the screen and the clock. A step is one of
--   key    = keys (nvim_input notation, <leader> is Space) with tutor
--            placeholders: {{org.todo}}, {{global.agenda}},
--            {{agenda.quit}}, ... resolved to the key mapped by default
--            (an action without one becomes ":Org <name><CR>")
--   type   = text typed a character at a time
--   cmd    = an Ex command
--   at     = text: the cursor to the first line of the current buffer
--            containing it, at `col` (text on that line) or at the text
--   wait   = minutes the clock moves on
--   lua    = Lua run in the child (its arguments: the scenario directory)
--   expect = what must hold, waited for up to `timeout` ms (default 3000):
--            screen = text (or a list) on the screen, no_screen = text
--            (or a list) not on it, line = a Lua pattern the cursor line
--            matches, buffer = a pattern some line of the current buffer
--            matches, file = { "name", pattern } (a line of the file on
--            disk matches) or { "name", lines = { ... } } (the whole
--            file), filetype = 'filetype', mode = nvim_get_mode().mode,
--            lua = code returning true when it holds
-- and any step can take `note` (a line in the report) and `allow_error`.
-- A step fails when it leaves an error behind: v:errmsg, or a
-- vim.notify() at level ERROR, unless it has `allow_error = true`.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/?.lua;" .. root .. "/scripts/?.lua;" .. package.path

local Screen = require("tests.screen")
local record = require("playground.record")

local M = {}

M.width, M.height = 80, 24
--- The fixed "now" of a scenario (local time), a Monday.
M.now = { year = 2026, month = 10, day = 12, hour = 9, min = 0 }
--- How long an `expect` waits for what it expects (ms).
M.timeout = 3000
M.recipes_dir = root .. "/scripts/verify/recipes"

-- Child setup on top of tests/screen.lua's: a status line with the buffer
-- name, the mode shown, the Neovim parsers, a clock moved by `wait`, and
-- errors kept for the step that made them.
local SETUP = [[
local parsers = ...
for _, dir in ipairs(parsers) do
  vim.opt.rtp:append(dir)
end
vim.o.laststatus = 2
vim.o.statusline = "%#StatusLine# %t%=%l:%c "
vim.o.showmode = true
vim.o.cmdheight = 2
vim.o.timeout = false
vim.o.updatetime = 20
_G.__verify_offset = 0
local time, date = os.time, os.date
os.time = function(t)
  return time(t) + (t and 0 or _G.__verify_offset)
end
os.date = function(fmt, t)
  return date(fmt, t or os.time())
end
_G.__verify_errors = {}
local notify = vim.notify
vim.notify = function(msg, level, ...)
  if level == vim.log.levels.ERROR then
    table.insert(_G.__verify_errors, tostring(msg))
  end
  return notify(msg, level, ...)
end
]]

-- Edit the scenario's first file.
local OPEN = [[
local path, cursor = ...
vim.cmd("silent edit " .. vim.fn.fnameescape(path))
if cursor ~= vim.NIL then
  pcall(vim.api.nvim_win_set_cursor, 0, cursor)
end
vim.cmd("echo ''")
]]

-- A key with its placeholders resolved as the tutor shows them.
local RENDER = [[
local keys = ...
return (keys:gsub("{{([%w_%.]+)}}", function(ref)
  local key = require("org.tutor").render_line("{{" .. ref .. "}}")
  if key:match("^:Org ") then
    return key .. "<CR>"
  end
  return key
end))
]]

-- The cursor to the first line containing `text`.
local AT = [[
local text, col = ...
for lnum, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  local s = line:find(text, 1, true)
  if s then
    local c = s
    if col ~= vim.NIL then
      c = line:find(col, 1, true) or s
    end
    vim.api.nvim_win_set_cursor(0, { lnum, c - 1 })
    return true
  end
end
return false
]]

-- Where the child is: cursor, mode, buffer, filetype, the cursor line and
-- the errors since the last call.
local STATE = [[
local cur = vim.api.nvim_win_get_cursor(0)
local errors = _G.__verify_errors
_G.__verify_errors = {}
if vim.v.errmsg ~= "" then
  table.insert(errors, vim.v.errmsg)
  vim.v.errmsg = ""
end
local name = vim.api.nvim_buf_get_name(0)
return {
  lnum = cur[1],
  col = cur[2],
  mode = vim.api.nvim_get_mode().mode,
  buffer = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]",
  filetype = vim.bo.filetype,
  line = vim.api.nvim_get_current_line(),
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
  errors = errors,
}
]]

--- A new directory in the system's temporary directory. Not
--- vim.fn.tempname(): Neovim deletes those when it exits, and the
--- evidence (and a failed scenario's files) must outlive the run.
---@param prefix string
---@return string
function M.mkdtemp(prefix)
  local tmp = vim.uv.os_tmpdir() or "/tmp"
  local dir = assert(vim.uv.fs_mkdtemp(tmp .. "/" .. prefix .. "XXXXXX"))
  return vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
end

--- The screen as plain text, trailing blanks and empty last rows left out.
---@param screen table tests/screen.lua's Screen
---@return string[]
function M.plain(screen)
  local out = {}
  for r = 1, screen.rows or 0 do
    local cells = {}
    for c, cell in ipairs(screen.grid[r] or {}) do
      cells[c] = cell[1]
    end
    out[r] = (table.concat(cells):gsub("%s+$", ""))
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

-- `value` with "{{dir}}" in every string replaced by `dir`.
local function subst(value, dir)
  if type(value) == "string" then
    return (value:gsub("{{dir}}", function()
      return dir
    end))
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = subst(v, dir)
    end
    return out
  end
  return value
end

local function list(v)
  if v == nil then
    return {}
  end
  return type(v) == "table" and v or { v }
end

--- The lines of a file, without their line ends. A CR before the LF is
--- left out too: on Windows a new file written by `:write` (a `cmd`
--- step) gets 'fileformat' dos, as it does for a user.
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return vim.split((s:gsub("\r?\n$", "")), "\r?\n")
end

--- Why `expect` doesn't hold (nil when it does).
---@param e table the expectation
---@param text string the screen as text
---@param state table STATE's result
---@param dir string the scenario directory
---@param screen table the child
---@return string?
local function unmet(e, text, state, dir, screen)
  for _, s in ipairs(list(e.screen)) do
    if not text:find(s, 1, true) then
      return ("screen has no %q"):format(s)
    end
  end
  for _, s in ipairs(list(e.no_screen)) do
    if text:find(s, 1, true) then
      return ("screen still has %q"):format(s)
    end
  end
  if e.line and not state.line:find(e.line) then
    return ("cursor line %q doesn't match %q"):format(state.line, e.line)
  end
  if e.buffer then
    local found = false
    for _, l in ipairs(state.lines) do
      found = found or l:find(e.buffer) ~= nil
    end
    if not found then
      return ("no line of %s matches %q"):format(state.buffer, e.buffer)
    end
  end
  if e.file then
    local lines = read_file(dir .. "/" .. e.file[1])
    if not lines then
      return ("%s isn't on disk"):format(e.file[1])
    end
    if e.file.lines then
      if not vim.deep_equal(lines, e.file.lines) then
        return ("%s is\n    %s"):format(e.file[1], table.concat(lines, "\n    "))
      end
    elseif e.file[2] then
      local found = false
      for _, l in ipairs(lines) do
        found = found or l:find(e.file[2]) ~= nil
      end
      if not found then
        return ("no line of %s on disk matches %q"):format(e.file[1], e.file[2])
      end
    end
  end
  if e.filetype and state.filetype ~= e.filetype then
    return ("filetype is %q, not %q"):format(state.filetype, e.filetype)
  end
  if e.mode and state.mode ~= e.mode then
    return ("mode is %q, not %q"):format(state.mode, e.mode)
  end
  if e.lua and not screen:lua(e.lua, dir) then
    return "lua: " .. e.lua
  end
end

--- One line describing `step`, for file names and the report.
local function describe(step)
  for _, k in ipairs({ "key", "type", "cmd", "at", "wait", "lua" }) do
    if step[k] ~= nil then
      return k .. " " .. tostring(step[k])
    end
  end
  if step.expect then
    local parts = {}
    for k, v in pairs(step.expect) do
      if k ~= "timeout" then
        parts[#parts + 1] = k
          .. "="
          .. (type(v) == "table" and table.concat(vim.tbl_map(tostring, v), ",") or tostring(v))
      end
    end
    table.sort(parts)
    return "expect " .. table.concat(parts, " ")
  end
  return "note"
end

local function slug(s)
  return (s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 40))
end

local function write(path, lines)
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

--- The directories of the tree-sitter parsers Neovim ships, for the child.
--- Under `make test` the runtimepath is only the plugin and $VIMRUNTIME,
--- which leaves out lib/nvim/parser (beside share/nvim/runtime): without
--- it a `lua` buffer's ftplugin (vim.treesitter.start()) fails in the
--- child and its error blocks it on a Press ENTER prompt.
local function parser_dirs()
  local dirs = record.parser_dirs()
  local runtime = vim.fs.normalize(vim.env.VIMRUNTIME or "")
  local lib = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(runtime))) .. "/lib/nvim"
  if runtime ~= "" and vim.uv.fs_stat(lib .. "/parser") and not vim.tbl_contains(dirs, lib) then
    dirs[#dirs + 1] = lib
  end
  return dirs
end

--- Wait for the child's screen to stop changing. A busy machine (a full
--- parallel `make test`) can keep a child working through typed keys past
--- tests/screen.lua's timeout, so a second wait is allowed before a
--- screen that never settles fails the step.
---@param screen table
local function settle(screen)
  local ok, err = pcall(screen.snapshot, screen)
  if not ok and tostring(err):find("didn't settle", 1, true) then
    ok, err = pcall(screen.snapshot, screen)
  end
  if not ok then
    error(err, 0)
  end
end

--- Play scenario `sc`, writing its evidence to `evidence`.
---@param sc table
---@param evidence string a directory
---@return { ok: boolean, dir?: string, steps: { text: string, ok: boolean, why?: string, note?: string }[] }
function M.run(sc, evidence)
  vim.fn.mkdir(evidence, "p")
  local dir = M.mkdtemp("org-verify-files-")
  -- the child's home and XDG directories, never the real ones
  local saved = {}
  for _, var in ipairs({ "HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME" }) do
    saved[var] = vim.env[var]
    local d = dir .. "/.env/" .. var:lower()
    vim.fn.mkdir(d, "p")
    vim.env[var] = d
  end
  for name, lines in pairs(sc.files or {}) do
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. name), "p")
    write(dir .. "/" .. name, lines)
  end
  local setup = vim.tbl_deep_extend("keep", subst(sc.setup or {}, dir), {
    org_directory = dir,
    default_notes_file = dir .. "/notes.org",
  })
  local result = { ok = true, steps = {} }
  local screen
  local ok, err = pcall(function()
    screen =
      Screen.new({ width = sc.width or M.width, height = sc.height or M.height, now = sc.now or M.now, setup = setup })
    screen:lua(SETUP, parser_dirs())
    if sc.open then
      screen:lua(OPEN, dir .. "/" .. sc.open, sc.cursor or vim.NIL)
    end
    for i, step in ipairs(sc.steps) do
      local text = describe(step)
      local why
      if step.key then
        screen:input(record.input_keys(screen:lua(RENDER, step.key)))
      elseif step.type then
        for ch in step.type:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          screen:input(ch == "<" and "<lt>" or ch)
        end
      elseif step.cmd then
        local cok, cerr = pcall(screen.cmd, screen, step.cmd)
        if not cok then
          why = tostring(cerr)
        end
      elseif step.at then
        if not screen:lua(AT, step.at, step.col or vim.NIL) then
          why = ("no line has %q"):format(step.at)
        end
      elseif step.wait then
        screen:lua("_G.__verify_offset = _G.__verify_offset + ... * 60", step.wait)
      elseif step.lua then
        screen:lua(step.lua, dir)
      end
      settle(screen)
      local lines = M.plain(screen)
      local state = screen:lua(STATE)
      if step.expect and not why then
        local deadline = vim.uv.hrtime() + (step.expect.timeout or M.timeout) * 1e6
        while true do
          why = unmet(step.expect, table.concat(lines, "\n"), state, dir, screen)
          if not why or vim.uv.hrtime() > deadline then
            break
          end
          vim.wait(50)
          settle(screen)
          lines = M.plain(screen)
          local again = screen:lua(STATE)
          vim.list_extend(again.errors, state.errors)
          state = again
        end
      end
      if not why and #state.errors > 0 and not step.allow_error then
        why = "error: " .. table.concat(state.errors, " | ")
      end
      local header = {
        ("step %d: %s"):format(i, text),
        ("buffer %s (%s), cursor %d:%d, mode %s"):format(
          state.buffer,
          state.filetype,
          state.lnum,
          state.col,
          state.mode
        ),
      }
      if why then
        header[#header + 1] = "FAIL: " .. why
      end
      header[#header + 1] = ("-"):rep(sc.width or M.width)
      write(("%s/%02d-%s.txt"):format(evidence, i, slug(text)), vim.list_extend(header, lines))
      result.steps[#result.steps + 1] = { text = text, ok = not why, why = why, note = step.note }
      if why then
        result.ok = false
        break
      end
    end
  end)
  if screen then
    screen:close()
  end
  for var, v in pairs(saved) do
    vim.env[var] = v
  end
  if not ok then
    result.ok = false
    result.steps[#result.steps + 1] = { text = "the child Neovim", ok = false, why = tostring(err) }
  end
  if result.ok then
    vim.fn.delete(dir, "rf")
  else
    result.dir = dir
  end
  return result
end

--- The scenarios of recipe `name`.
---@param name string
---@return table[]
function M.recipe(name)
  return dofile(M.recipes_dir .. "/" .. name .. ".lua")
end

--- Every recipe's name.
---@return string[]
function M.recipes()
  local out = {}
  for name, kind in vim.fs.dir(M.recipes_dir) do
    if kind == "file" and name:match("%.lua$") then
      out[#out + 1] = name:gsub("%.lua$", "")
    end
  end
  table.sort(out)
  return out
end

--- Run `targets` ("recipe" or "recipe:scenario"; none: every recipe),
--- writing evidence and report.md to `out`. Returns whether all passed.
---@param targets string[]
---@param out string
---@return boolean
function M.main(targets, out)
  if #targets == 0 then
    targets = M.recipes()
  end
  local report, passed, failed = { "# verify-org report", "" }, 0, 0
  for _, target in ipairs(targets) do
    local name, only = target:match("^([^:]+):?(.*)$")
    local n = 0
    for _, sc in ipairs(M.recipe(name)) do
      if only == "" or vim.startswith(sc.name, only) then
        n = n + 1
        local res = M.run(sc, ("%s/%s/%02d-%s"):format(out, name, n, slug(sc.name)))
        if res.ok then
          passed = passed + 1
        else
          failed = failed + 1
        end
        local status = res.ok and "PASS" or "FAIL"
        io.stdout:write(("%s %s: %s\n"):format(status, name, sc.name))
        report[#report + 1] = ("## %s %s: %s"):format(status, name, sc.name)
        report[#report + 1] = ""
        for i, s in ipairs(res.steps) do
          report[#report + 1] = ("%d. %s %s%s"):format(
            i,
            s.ok and "ok" or "FAIL",
            s.text,
            s.note and (" (" .. s.note .. ")") or ""
          )
          if s.why then
            report[#report + 1] = "   " .. s.why:gsub("\n", "\n   ")
            io.stdout:write("  step " .. i .. ": " .. s.text .. "\n  " .. s.why:gsub("\n", "\n  ") .. "\n")
          end
        end
        if res.dir then
          report[#report + 1] = "   files left in " .. res.dir
        end
        report[#report + 1] = ""
      end
    end
    if n == 0 then
      failed = failed + 1
      io.stdout:write(("FAIL %s: no scenario matches %q\n"):format(name, only))
    end
  end
  write(out .. "/report.md", report)
  io.stdout:write(("verify: %d passed, %d failed; evidence in %s\n"):format(passed, failed, out))
  return failed == 0
end

if _G.arg and _G.arg[0] and _G.arg[0]:match("verify[\\/]drive%.lua$") then
  local targets, out = {}, nil
  local i = 1
  while i <= #_G.arg do
    if _G.arg[i] == "--out" then
      out = _G.arg[i + 1]
      i = i + 2
    else
      targets[#targets + 1] = _G.arg[i]
      i = i + 1
    end
  end
  out = out and vim.fs.normalize(out) or M.mkdtemp("org-verify-")
  vim.fn.mkdir(out, "p")
  os.exit(M.main(targets, out) and 0 or 1)
end

return M
