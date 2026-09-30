---@mod org.extensions.cli.run The `org` command line: argument parsing and subcommands
---
--- `bin/org` runs `nvim --headless -l lua/org/extensions/cli/main.lua`,
--- which calls |M.main| with the arguments. Every subcommand works on the
--- files of the loaded configuration (`--config`, `$ORG_NVIM_CONFIG` or
--- `stdpath("config")/org-cli.lua`) and writes plain text or, with
--- `--json`, JSON to stdout. Messages go to stderr.

local M = {}

M.USAGE = [[
usage: org [global options] <command> [args]

Commands:
  agenda [day|week|fortnight|month|year|todo [KW]|tags MATCH|KEY]
         [--date DATE] [--span N] [--json|--csv]
  capture [-t KEY] [--list] TEXT...     (TEXT "-" reads stdin)
  clock [status [--short] [--format FMT]|in [--pick N] QUERY|out|cancel]
        [--json]    (QUERY: title words, ID, id:ID or FILE::HEADING)
  search QUERY... [--json]               (org-ql syntax when ql is enabled)
  export FILE BACKEND [-o OUTPUT|--stdout]
  help | version

Global options:
  --config FILE   Lua file calling require("org").setup(), or returning
                  its options table (also $ORG_NVIM_CONFIG; default
                  stdpath("config")/org-cli.lua when it exists)
  --files GLOB    agenda files (repeatable; replaces agenda_files)
  --dir DIR       org_directory
  --json          JSON output (agenda, clock, search, capture --list)
  -v, --verbose   also print org.nvim's messages on stderr
  -q, --quiet     no warnings on stderr (errors are still printed)
]]

-- Options the CLI forces so nothing waits for input.
M.OVERRIDES = {
  clock = {
    auto_clock_resolution = false,
    ask_before_exiting = false,
    persist_query_resume = false,
    persist_query_save = false,
  },
  note_buffer = false,
}

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

--- Where output goes; specs replace these.
M.stdout = function(s)
  io.stdout:write(s)
end
M.stderr = function(s)
  io.stderr:write(s)
end

local state = { quiet = false, verbose = false }

local function out(line)
  M.stdout(line .. "\n")
end

local function err(line)
  M.stderr("org: " .. line .. "\n")
end

local function json(v)
  out(vim.json.encode(v))
end

--- An error that ends the command with exit code `code`.
local function fail(msg, code)
  error({ cli = true, msg = msg, code = code or 1 }, 0)
end

---------------------------------------------------------------------------
-- Headless safety
---------------------------------------------------------------------------

local function no_input(what)
  return function()
    state.prompted = what
    fail("interactive input needed (" .. what .. "); not available in the CLI", 3)
  end
end

--- Replace prompts with errors and route notifications to stderr.
function M.headless()
  vim.fn.input = no_input("input")
  vim.fn.inputlist = no_input("inputlist")
  vim.fn.confirm = no_input("confirm")
  vim.fn.getchar = no_input("getchar")
  vim.fn.getcharstr = no_input("getchar")
  vim.ui.input = no_input("vim.ui.input")
  vim.ui.select = no_input("vim.ui.select")
  vim.notify = function(msg, level)
    level = level or vim.log.levels.INFO
    if (level >= vim.log.levels.WARN and not state.quiet) or state.verbose then
      err(tostring(msg))
    end
  end
end

---------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------

-- flags taking a value
local VALUE_FLAGS = {
  ["--config"] = "config",
  ["--files"] = "files",
  ["--dir"] = "dir",
  ["--date"] = "date",
  ["--span"] = "span",
  ["-t"] = "template",
  ["--template"] = "template",
  ["-o"] = "output",
  ["--output"] = "output",
  ["--format"] = "format",
  ["--pick"] = "pick",
}

local BOOL_FLAGS = {
  ["--json"] = "json",
  ["--csv"] = "csv",
  ["-q"] = "quiet",
  ["--quiet"] = "quiet",
  ["-v"] = "verbose",
  ["--verbose"] = "verbose",
  ["--list"] = "list",
  ["--short"] = "short",
  ["--stdout"] = "stdout",
  ["-h"] = "help",
  ["--help"] = "help",
  ["--version"] = "version",
}

--- Split `argv` into flags and positional words. `--files` repeats;
--- `--flag=value` works too; `--` ends the flags.
---@param argv string[]
---@return table flags, string[] words
function M.parse_args(argv)
  local flags, words = { files = {} }, {}
  local i = 1
  local rest = false
  while i <= #argv do
    local a = argv[i]
    if rest then
      words[#words + 1] = a
    elseif a == "--" then
      rest = true
    else
      local name, value = a:match("^(%-%-[%w-]+)=(.*)$")
      name = name or a
      if VALUE_FLAGS[name] then
        if not value then
          i = i + 1
          value = argv[i]
          if value == nil then
            fail(name .. " needs a value", 2)
          end
        end
        local key = VALUE_FLAGS[name]
        if key == "files" then
          vim.list_extend(flags.files, vim.split(value, ",", { trimempty = true }))
        else
          flags[key] = value
        end
      elseif BOOL_FLAGS[a] then
        flags[BOOL_FLAGS[a]] = true
      elseif a:match("^%-%-?%a") and a ~= "-" then
        fail("unknown option " .. a .. " (see org help)", 2)
      else
        words[#words + 1] = a
      end
    end
    i = i + 1
  end
  return flags, words
end

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

--- The config file to load: `--config`, `$ORG_NVIM_CONFIG`, else
--- `stdpath("config")/org-cli.lua` when it exists.
---@return string|nil
function M.config_file(flags)
  local f = flags.config or vim.env.ORG_NVIM_CONFIG
  if f and f ~= "" then
    f = vim.fn.expand(f)
    if vim.fn.filereadable(f) == 0 then
      fail("config file not found: " .. f, 2)
    end
    return f
  end
  local default = vim.fn.stdpath("config") .. "/org-cli.lua"
  if vim.fn.filereadable(default) == 1 then
    return default
  end
  return nil
end

--- Load the user's configuration with the CLI's overrides forced in, then
--- apply `--files` and `--dir`.
function M.load_config(flags)
  local config = require("org.config")
  local setup = config.setup
  config.setup = function(opts)
    return setup(vim.tbl_deep_extend("force", opts or {}, M.OVERRIDES))
  end
  local file = M.config_file(flags)
  local ok, res = true, nil
  if file then
    ok, res = pcall(dofile, file)
    if not ok then
      config.setup = setup
      fail("error in " .. file .. ": " .. tostring(res), 2)
    end
  end
  local org = require("org")
  if type(res) == "table" then
    org.setup(res)
  else
    org.ensure_setup()
  end
  config.setup = setup
  -- a config that set things up before the override was in place
  for k, v in pairs(M.OVERRIDES) do
    if type(v) == "table" then
      config.opts[k] = config.opts[k] or {}
      for k2, v2 in pairs(v) do
        config.opts[k][k2] = v2
      end
    else
      config.opts[k] = v
    end
  end
  if flags.dir then
    config.opts.org_directory = vim.fn.fnamemodify(vim.fn.expand(flags.dir), ":p")
  end
  if #flags.files > 0 then
    config.opts.agenda_files = vim.tbl_map(function(f)
      return vim.fn.fnamemodify(vim.fn.expand(f), ":p")
    end, flags.files)
  end
end

--- The resolved `extensions.cli` options (its defaults when the extension
--- is not enabled in the loaded configuration).
local function cli_opts()
  return require("org.extensions").opts("cli") or require("org.extensions.cli").defaults
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function iso_day(days)
  if not days then
    return nil
  end
  local d = require("org.date").from_days(days)
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

local function hm(minutes)
  if not minutes then
    return nil
  end
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function short_path(p)
  return p and vim.fn.fnamemodify(p, ":~") or nil
end

--- Load a file into a buffer (filetype org) and return its number.
local function load_buffer(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  if vim.bo[bufnr].filetype ~= "org" then
    vim.bo[bufnr].filetype = "org"
  end
  return bufnr
end

-- Tell a running Neovim (with the cli extension on) that the clock
-- changed: it watches this file and rereads the clock (org.clock.sync).
local function touch_clock_stamp()
  pcall(function()
    local path = require("org.extensions.cli").stamp_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fh = io.open(path, "w")
    if fh then
      fh:write(tostring(vim.uv.hrtime()) .. "\n")
      fh:close()
    end
  end)
end

local function save_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local ok, e = require("org.utils").save_buffer(b)
      if not ok then
        fail("could not save " .. vim.api.nvim_buf_get_name(b) .. ": " .. tostring(e))
      end
    end
  end
end

--- A headline as JSON-friendly data.
local function headline_data(hl)
  local p = hl.planning or {}
  local function ts(t)
    return t and t:to_string() or nil
  end
  return {
    file = hl.file.filename,
    line = hl.line,
    level = hl.level,
    todo = hl.todo,
    priority = hl.priority,
    title = hl:plain_title(),
    tags = hl:get_tags(),
    category = hl:get_category(),
    scheduled = ts(p.scheduled),
    deadline = ts(p.deadline),
    closed = ts(p.closed),
    id = hl.properties.ID,
  }
end

local function headline_line(hl)
  local parts = { string.rep("*", hl.level) }
  if hl.todo then
    parts[#parts + 1] = hl.todo
  end
  if hl.priority then
    parts[#parts + 1] = "[#" .. hl.priority .. "]"
  end
  parts[#parts + 1] = hl:plain_title()
  local tags = hl.tags or {}
  if #tags > 0 then
    parts[#parts + 1] = ":" .. table.concat(tags, ":") .. ":"
  end
  return string.format("%s:%d: %s", short_path(hl.file.filename), hl.line, table.concat(parts, " "))
end

---------------------------------------------------------------------------
-- agenda
---------------------------------------------------------------------------

local SPANS = { day = "day", week = "week", fortnight = 14, month = "month", year = "year" }

--- The agenda view state after opening the view described by `words`.
local function open_agenda(words, flags)
  local agenda = require("org.agenda")
  local config = require("org.config")
  local what = words[1] or "agenda"
  local anchor
  if flags.date then
    local d = require("org.date").read_date(flags.date, require("org.date").today())
    if not d then
      fail("cannot read date " .. flags.date, 2)
    end
    anchor = d:days()
  end
  local span = flags.span and (tonumber(flags.span) or flags.span)
  local label = what
  if what == "agenda" or SPANS[what] then
    span = span or SPANS[what]
    agenda.open({ type = "agenda" }, { span = span, anchor = anchor })
    label = "agenda"
  elseif what == "todo" then
    agenda.open({ type = "todo", keywords = words[2] })
  elseif what == "tags" then
    if not words[2] then
      fail("agenda tags needs a match, e.g. org agenda tags +work", 2)
    end
    agenda.open({ type = "tags", match = words[2] })
  elseif type((config.opts.agenda.custom_commands or {})[what]) == "table" then
    if span then
      config.opts.agenda.span = span
    end
    agenda.open_custom(what)
    label = "custom"
  else
    fail("unknown agenda view " .. what .. " (day, week, month, todo, tags or a custom command key)", 2)
  end
  local S = require("org.agenda.view").state
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    fail("no agenda was built (are agenda_files set? see --files)")
  end
  return S, label
end

--- JSON data of the items of the agenda view `S`.
function M.agenda_items(S)
  local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
  local items = {}
  local day
  for l, line in ipairs(lines) do
    if S.day_lines and S.day_lines[l] then
      day = S.day_lines[l]
    end
    local it = S.line_items[l]
    if it then
      local hl = it.headline
      items[#items + 1] = {
        date = iso_day(it.day or (it.date and it.date.days and it.date:days()) or (hl and day) or nil),
        time = hm(it.time),
        end_time = hm(it.end_time),
        type = it.ts_type or it.type,
        todo = it.todo,
        priority = it.priority,
        title = hl and hl:plain_title() or it.title,
        tags = it.tags or {},
        category = it.category,
        file = it.filename,
        line = it.lnum,
        extra = it.extra and vim.trim(it.extra) ~= "" and vim.trim(it.extra) or nil,
        done = it.done or false,
        text = vim.trim(line),
      }
    end
  end
  return items
end

function M.cmd_agenda(words, flags)
  local S, label = open_agenda(words, flags)
  if flags.csv then
    for _, l in ipairs(require("org.agenda.export").csv_lines()) do
      out(l)
    end
    return 0
  end
  if flags.json then
    local first, last
    for _, d in pairs(S.day_lines or {}) do
      first = math.min(first or d, d)
      last = math.max(last or d, d)
    end
    json({ view = label, start = iso_day(first), ["end"] = iso_day(last), items = M.agenda_items(S) })
    return 0
  end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
    out((l:gsub("%s+$", "")))
  end
  return 0
end

---------------------------------------------------------------------------
-- capture
---------------------------------------------------------------------------

--- The template to capture `text` with: a copy of template `key` that
--- finishes at once and puts the text where `%?` was (unless the template
--- already uses `%i`).
function M.capture_template(key)
  local capture = require("org.capture")
  local tpl = capture.get_template(key)
  if not tpl then
    fail("no capture template " .. key .. " (org capture --list)", 2)
  end
  tpl.immediate_finish = true
  tpl.jump_to_captured = false
  tpl.clock_in = false
  tpl.clock_keep = false
  tpl.clock_resume = false
  if type(tpl.template) == "string" and not tpl.template:find("%%i") then
    local n
    tpl.template, n = tpl.template:gsub("%%%?", "%%i", 1)
    if n == 0 then
      tpl.template = tpl.template .. "%i"
    end
  elseif tpl.template == nil or tpl.template == "" then
    local empty = { entry = "* %i", item = "- %i", checkitem = "- [ ] %i", ["table-line"] = "| %i |" }
    tpl.template = empty[tpl.type or "entry"] or "%i"
  end
  return tpl
end

local function default_template_key()
  local key = cli_opts().capture_template
  if key then
    return key
  end
  local templates = require("org.capture").templates()
  if templates.t then
    return "t"
  end
  local keys = {}
  for k, t in pairs(templates) do
    if type(t) == "table" and (t.template or t.target or t.type) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  if #keys == 0 then
    fail("no capture templates", 2)
  end
  return keys[1]
end

function M.cmd_capture(words, flags)
  local capture = require("org.capture")
  if flags.list then
    local templates = capture.templates()
    local keys = vim.tbl_keys(templates)
    table.sort(keys)
    local list = {}
    for _, k in ipairs(keys) do
      local t = templates[k]
      local desc = type(t) == "table" and t.description or (type(t) == "string" and t) or ""
      list[#list + 1] = { key = k, description = desc, group = type(t) ~= "table" or nil }
    end
    if flags.json then
      json(list)
    else
      for _, t in ipairs(list) do
        out(t.key .. "\t" .. t.description .. (t.group and " (group)" or ""))
      end
    end
    return 0
  end
  local text = table.concat(words, " ")
  if text == "-" then
    text = io.stdin:read("*a") or ""
  end
  text = vim.trim(text)
  if text == "" then
    fail("nothing to capture (org capture [-t KEY] TEXT)", 2)
  end
  local tpl = M.capture_template(flags.template or default_template_key())
  local done, bufnr, line
  local co = coroutine.create(function()
    bufnr, line = capture.capture(tpl, { initial = text })
    done = true
  end)
  local ok, e = coroutine.resume(co)
  if not ok then
    error(e, 0)
  end
  if not done or state.prompted then
    fail("interactive input needed (" .. (state.prompted or "template") .. "); not available in the CLI", 3)
  end
  if not bufnr then
    fail("capture failed")
  end
  save_all()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if flags.json then
    json({ file = path, line = line, template = tpl.key })
  else
    out(string.format("Captured to %s:%d", short_path(path), line or 0))
  end
  return 0
end

---------------------------------------------------------------------------
-- clock
---------------------------------------------------------------------------

--- The running clock as data, or nil.
function M.clock_data()
  local clock = require("org.clock")
  local date = require("org.date")
  local st = clock.restore()
  if not st then
    return nil
  end
  local start = date.parse(st.start)
  local minutes = start and date.elapsed_minutes(start, date.now()) or 0
  local title = st.title or ""
  return {
    active = true,
    title = title,
    file = st.path,
    start = st.start,
    minutes = minutes,
    elapsed = date.duration_to_string(minutes),
    total = (st.total or 0) + minutes,
    effort = st.effort,
  }
end

--- Expand a `--format` string: %t title, %e elapsed, %T total (with past
--- clocks), %E effort, %f file, %s start, %% a percent sign.
function M.format_clock(fmt, c)
  local date = require("org.date")
  local map = {
    t = c.title,
    e = c.elapsed,
    T = date.duration_to_string(c.total or c.minutes),
    E = c.effort and date.duration_to_string(c.effort) or "",
    f = short_path(c.file) or "",
    s = c.start or "",
    ["%"] = "%",
  }
  return (fmt:gsub("%%(.)", function(k)
    return map[k] or ("%" .. k)
  end))
end

--- Headlines of the agenda files matching `query`: an `id:` or ID, a ql
--- query when ql is enabled, else a case-insensitive title substring (an
--- exact title wins).
---
--- Also `FILE::HEADING` (a file of the agenda, by path or name, and a
--- title in it, `*` stars allowed, as in an org link), and a bare ID.
function M.find_headlines(query)
  local files = require("org.files").agenda_files()
  local items = require("org.agenda.items")
  query = vim.trim(query)
  local id = query:match("^id:(.+)$")
  local file_part, head_part = query:match("^(.-)::%**%s*(.+)$")
  if file_part and file_part ~= "" then
    local want = vim.fn.fnamemodify(vim.fn.expand(file_part), ":p")
    local sel = {}
    for _, f in ipairs(files) do
      local name = f.filename
      local tail = vim.fn.fnamemodify(name, ":t")
      if name == want or vim.fn.resolve(name) == vim.fn.resolve(want) or tail == file_part then
        sel[#sel + 1] = f
      elseif vim.fn.fnamemodify(tail, ":r") == file_part then
        sel[#sel + 1] = f
      end
    end
    files, query = sel, head_part
  end
  local found, exact, by_id = {}, {}, {}
  if not id and not file_part and require("org.extensions").enabled("ql") then
    local ok, res = pcall(require("org.extensions.ql").select, files, query)
    if ok and #res > 0 then
      return res
    end
  end
  local q = query:lower()
  items.each_headline(files, { all = true }, function(hl)
    if id then
      if hl.properties.ID == id then
        found[#found + 1] = hl
      end
    else
      local t = hl:plain_title():lower()
      if hl.properties.ID == query then
        by_id[#by_id + 1] = hl
      elseif t == q then
        exact[#exact + 1] = hl
      elseif t:find(q, 1, true) then
        found[#found + 1] = hl
      end
    end
  end)
  return #by_id > 0 and by_id or #exact > 0 and exact or found
end

function M.cmd_clock(words, flags)
  local sub = words[1] or "status"
  local clock = require("org.clock")
  if sub == "status" then
    local c = M.clock_data()
    if flags.json then
      json(c or { active = false })
    elseif flags.format or flags.short then
      if c then
        out(M.format_clock(flags.format or cli_opts().status_format, c))
      end
    elseif c then
      out(string.format("%s  %s  (%s)", c.elapsed, c.title, short_path(c.file)))
    else
      out("No running clock")
    end
    return 0
  elseif sub == "in" then
    local query = table.concat(words, " ", 2)
    if query == "" then
      fail("clock in needs a heading: org clock in QUERY", 2)
    end
    local hls = M.find_headlines(query)
    local pick = flags.pick and tonumber(flags.pick)
    if flags.pick and not (pick and hls[pick]) then
      if #hls == 0 then
        fail("no heading matches " .. query, 1)
      end
      fail(string.format("--pick %s: pick 1 to %d", flags.pick, #hls), 2)
    end
    if #hls == 0 then
      fail("no heading matches " .. query, 1)
    elseif #hls > 1 and not pick then
      local lines = { "several headings match " .. query .. " (org clock in --pick N ...):" }
      for i, hl in ipairs(hls) do
        lines[#lines + 1] = string.format("%3d  %s", i, headline_line(hl))
      end
      fail(table.concat(lines, "\n"), 1)
    end
    local hl = hls[pick or 1]
    clock.restore()
    local bufnr = load_buffer(hl.file.filename)
    local target = require("org.files").get_buffer(bufnr):headline_at(hl.line)
    local st = clock.clock_in({ bufnr = bufnr, lnum = target and target.line or hl.line }, { no_count = true })
    if not st then
      fail("could not clock in")
    end
    save_all()
    touch_clock_stamp()
    if flags.json then
      json(M.clock_data() or { active = false })
    else
      out("Clocked in: " .. hl:plain_title())
    end
    return 0
  elseif sub == "out" or sub == "cancel" then
    local c = M.clock_data()
    if not c then
      if flags.json then
        json({ active = false })
      else
        out("No running clock")
      end
      return 1
    end
    local minutes
    if sub == "out" then
      minutes = clock.clock_out({ note = false })
    else
      clock.clock_cancel()
    end
    save_all()
    touch_clock_stamp()
    if flags.json then
      json({ active = false, title = c.title, file = c.file, minutes = minutes, canceled = sub == "cancel" })
    elseif sub == "out" then
      out(string.format("Clocked out: %s (%s)", c.title, require("org.date").duration_to_string(minutes or 0)))
    else
      out("Clock canceled: " .. c.title)
    end
    return 0
  end
  fail("unknown clock command " .. sub .. " (status, in, out, cancel)", 2)
end

---------------------------------------------------------------------------
-- search
---------------------------------------------------------------------------

function M.cmd_search(words, flags)
  local query = table.concat(words, " ")
  if query == "" then
    fail("search needs a query", 2)
  end
  local hls = {}
  if require("org.extensions").enabled("ql") then
    local ok, res = pcall(require("org.extensions.ql").select, "agenda", query)
    if not ok then
      fail("bad query: " .. tostring(res), 2)
    end
    hls = res
  else
    require("org.agenda").open({ type = "search", match = query })
    local S = require("org.agenda.view").state
    local seen = {}
    local lnums = vim.tbl_keys(S.line_items or {})
    table.sort(lnums)
    for _, l in ipairs(lnums) do
      local hl = S.line_items[l].headline
      if hl and not seen[hl] then
        seen[hl] = true
        hls[#hls + 1] = hl
      end
    end
  end
  if flags.json then
    json(vim.tbl_map(headline_data, hls))
  else
    for _, hl in ipairs(hls) do
      out(headline_line(hl))
    end
  end
  return #hls > 0 and 0 or 1
end

---------------------------------------------------------------------------
-- export
---------------------------------------------------------------------------

function M.cmd_export(words, flags)
  local file, backend = words[1], words[2]
  if not file or not backend then
    fail("usage: org export FILE BACKEND [-o OUTPUT|--stdout]", 2)
  end
  file = vim.fn.fnamemodify(vim.fn.expand(file), ":p")
  if vim.fn.filereadable(file) == 0 then
    fail("no such file: " .. file, 2)
  end
  local export = require("org.export")
  local bufnr = load_buffer(file)
  vim.api.nvim_set_current_buf(bufnr)
  if flags.stdout or flags.output == "-" then
    local ok, text = pcall(export.to_string, backend, { bufnr = bufnr })
    if not ok then
      fail(tostring(text), 1)
    end
    M.stdout(text:sub(-1) == "\n" and text or (text .. "\n"))
    return 0
  end
  local output = flags.output and vim.fn.fnamemodify(vim.fn.expand(flags.output), ":p") or nil
  local res = export.export(backend, { bufnr = bufnr, output = output, async = false })
  if not res then
    fail("export failed")
  end
  out(res)
  return 0
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

M.COMMANDS = {
  agenda = M.cmd_agenda,
  capture = M.cmd_capture,
  clock = M.cmd_clock,
  search = M.cmd_search,
  export = M.cmd_export,
}

--- Run the CLI. Returns the exit code: 0 ok, 1 failure (or nothing
--- found), 2 usage error, 3 input would be needed.
---@param argv string[]
---@return integer
function M.main(argv)
  local ok, code = pcall(function()
    local flags, words = M.parse_args(argv or {})
    state.quiet = flags.quiet or false
    state.verbose = flags.verbose or false
    if flags.version then
      out("org.nvim " .. require("org.version").release)
      return 0
    end
    local cmd = table.remove(words, 1)
    if flags.help or cmd == nil or cmd == "help" then
      M.stdout(M.USAGE)
      return cmd == nil and not flags.help and 2 or 0
    end
    if cmd == "version" then
      out("org.nvim " .. require("org.version").release)
      return 0
    end
    local fn = M.COMMANDS[cmd]
    if not fn then
      fail("unknown command " .. cmd .. " (see org help)", 2)
    end
    M.headless()
    M.load_config(flags)
    return fn(words, flags)
  end)
  if ok then
    return code or 0
  end
  if type(code) == "table" and code.cli then
    err(code.msg)
    return code.code
  end
  err(tostring(code))
  return 1
end

return M
