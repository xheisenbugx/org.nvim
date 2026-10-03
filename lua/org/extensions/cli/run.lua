---@mod org.extensions.cli.run The `org` command line: argument parsing and subcommands
---
--- `bin/org` runs `nvim --headless -l lua/org/extensions/cli/main.lua`,
--- which calls |M.main| with the arguments. Every subcommand works on the
--- files of the loaded configuration (`--config`, `$ORG_NVIM_CONFIG` or
--- `stdpath("config")/org-cli.lua`) and writes plain text or, with
--- `--json` / `--jsonl`, JSON to stdout (`org schema` describes it).
--- Messages go to stderr.

local schema = require("org.extensions.cli.schema")
local data = require("org.extensions.cli.data")

local M = {}

M.USAGE = [==[
usage: org [global options] <command> [args]

Read:
  agenda [day|week|fortnight|month|year|todo [KW]|tags MATCH|tags-todo MATCH|KEY]
         [--date DATE] [--span N] [--csv]
  search [QUERY...] [--match MATCH] [--limit N]
  headlines [FILE...] [--todo KW] [--tag TAG] [--property NAME=VALUE]
         [--level N] [--scheduled FROM..TO] [--deadline FROM..TO]
         [--file FILE] [--match MATCH] [--limit N] [--archived]   (alias: query)
  show TARGET [--children]
  clock [status [--short] [--format FMT]]
  templates | files | tags | keywords
  export FILE BACKEND [-o OUTPUT|--stdout]

Write (never prompt; --force writes over unsaved changes in a running Neovim):
  capture [-t KEY] [--field NAME=VALUE] [--input FILE|-] [--id] TEXT...
          (TEXT "-" reads stdin; --list lists the templates)
  clock in [--pick N] TARGET | clock out | clock cancel
  set todo TARGET STATE [--note TEXT]
  set tags TARGET [TAGS] [--add TAG] [--remove TAG]
  set priority TARGET PRIORITY
  set property TARGET NAME [VALUE] [--delete]
  set scheduled TARGET DATE | set deadline TARGET DATE   ("none" removes)
  note TARGET TEXT
  refile TARGET DESTINATION
  archive TARGET
  id TARGET [--create]

  schema [COMMAND] | help [--json] | version

TARGET: id:ID or an ID, FILE:LINE, FILE::TITLE, FILE::#CUSTOM_ID, or title
words (an org-ql query with ql); several matches: --pick N.

Global options:
  --config FILE   Lua file calling require("org").setup(), or returning
                  its options table (also $ORG_NVIM_CONFIG; default
                  stdpath("config")/org-cli.lua when it exists)
  --files GLOB    agenda files (repeatable; replaces agenda_files)
  --dir DIR       org_directory
  --json          JSON envelope { version, ok, command, data, warnings, errors }
  --jsonl         JSON lines: one result per line
  -v, --verbose   also print org.nvim's messages on stderr
  -q, --quiet     no warnings on stderr (errors are still printed)
]==]

-- Options the CLI forces so nothing waits for input.
M.OVERRIDES = {
  clock = {
    auto_clock_resolution = false,
    ask_before_exiting = false,
    persist_query_resume = false,
    persist_query_save = false,
  },
  note_buffer = false,
  read_date_popup_calendar = false,
}

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

local real_stdout = io.stdout

--- Where output goes; specs replace these.
M.stdout = function(s)
  real_stdout:write(s)
end
M.stderr = function(s)
  io.stderr:write(s)
end

local state = {}

local function reset_state()
  state = {
    quiet = false,
    verbose = false,
    machine = false,
    messages = {},
    warnings = {},
    answers = {},
    note = nil,
    prompted = nil,
    touched = false,
  }
end
reset_state()

local function out(line)
  M.stdout(line .. "\n")
end

local function err(line)
  M.stderr("org: " .. line .. "\n")
end

M.out = out

--- An error that ends the command. `ecode` is one of `schema.ERRORS`
--- (its exit code is used), or a number (an exit code, error code
--- `usage` for 2, else `failed`).
---@param msg string
---@param ecode? string|integer
---@param details? table
local function fail(msg, ecode, details)
  local code
  if type(ecode) == "number" then
    code = ecode
    ecode = code == 2 and "usage" or code == 3 and "input_needed" or "failed"
  else
    ecode = ecode or "failed"
    code = (schema.ERRORS[ecode] or schema.ERRORS.failed).exit
  end
  error({ cli = true, msg = msg, code = code, ecode = ecode, details = details }, 0)
end
M.fail = fail

---------------------------------------------------------------------------
-- Headless safety
---------------------------------------------------------------------------

--- The question a prompt asks, without its ": ", default and date hint:
--- "Title [x]: " -> "Title", "Deadline Date+time [2026-10-01]: " -> "Deadline".
function M.prompt_label(p)
  if type(p) == "table" then
    p = p.prompt
  end
  p = vim.trim(tostring(p or ""))
  p = p:gsub(":$", "")
  p = vim.trim(p)
  p = p:gsub("%s*%[[^%]]*%]$", "")
  p = p:gsub("%s*Date%+time$", "")
  return vim.trim(p)
end

--- The `--field` answer to a prompt, or a failure (exit 3).
local function ask(prompt)
  local label = M.prompt_label(prompt)
  local v = state.answers[label:lower()]
  if v == nil and label == "" then
    v = state.answers.date
  end
  if v ~= nil then
    return v
  end
  state.prompted = state.prompted or (label ~= "" and label or "input")
  fail(
    "interactive input needed ("
      .. state.prompted
      .. "); not available in the CLI"
      .. (label ~= "" and (" (answer it with --field '" .. label .. "=...')") or ""),
    "input_needed",
    { prompt = state.prompted }
  )
end

local function no_input(what)
  return function()
    state.prompted = state.prompted or what
    fail("interactive input needed (" .. what .. "); not available in the CLI", "input_needed", { prompt = what })
  end
end

--- Replace prompts with `--field` answers or errors, and route
--- notifications to stderr (and the JSON envelope).
function M.headless()
  local utils = require("org.utils")
  vim.fn.input = function(opts)
    return ask(opts)
  end
  vim.fn.inputlist = no_input("inputlist")
  vim.fn.confirm = no_input("confirm")
  vim.fn.getchar = no_input("getchar")
  vim.fn.getcharstr = no_input("getchar")
  vim.ui.input = function(opts, cb)
    cb(ask(opts))
  end
  vim.ui.select = no_input("vim.ui.select")
  utils.input = function(opts)
    return ask(opts)
  end
  utils.input_complete = function(prompt)
    return ask(prompt)
  end
  -- a log note the command records: --note, else an empty note (the
  -- entry is logged with its time only, as C-c C-c on an empty note)
  utils.input_note = function()
    return state.note or ""
  end
  utils.confirm = no_input("confirm")
  utils.getchar = no_input("getchar")
  vim.notify = function(msg, level)
    level = level or vim.log.levels.INFO
    msg = tostring(msg)
    state.messages[#state.messages + 1] = { msg = msg, level = level }
    if level >= vim.log.levels.WARN then
      state.warnings[#state.warnings + 1] = msg
    end
    local show
    if state.machine then
      show = state.verbose
    else
      show = (level >= vim.log.levels.WARN and not state.quiet) or state.verbose
    end
    if show then
      err(msg)
    end
  end
end

---------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------

-- repeatable flags whose values may also be comma-separated
local COMMA = { files = true, todo = true, tag = true, add = true, remove = true }

--- Split `argv` into flags and positional words. Repeatable flags give
--- lists; `--flag=value` works too; `--` ends the flags.
---@param argv string[]
---@return table flags, string[] words
function M.parse_args(argv)
  local flags, words = {}, {}
  for _, f in ipairs(schema.FLAGS) do
    if f.repeatable then
      flags[f.key] = {}
    end
  end
  local given = {}
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
      local f = schema.BY_NAME[name]
      if f and f.value then
        if not value then
          i = i + 1
          value = argv[i]
          if value == nil then
            fail(name .. " needs a value", "usage", { flag = name })
          end
        end
        if f.repeatable then
          if COMMA[f.key] then
            vim.list_extend(flags[f.key], vim.split(value, ",", { trimempty = true }))
          else
            table.insert(flags[f.key], value)
          end
        else
          flags[f.key] = value
        end
        given[f.key] = name
      elseif f and not value then
        flags[f.key] = true
        given[f.key] = name
      elseif a:match("^%-%-?%a") and a ~= "-" then
        fail("unknown option " .. a .. " (see org help)", "unknown_option", { option = a })
      else
        words[#words + 1] = a
      end
    end
    i = i + 1
  end
  flags._given = given
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
    f = require("org.utils").expand_vars(f)
    if vim.fn.filereadable(f) == 0 then
      fail("config file not found: " .. f, "config", { file = f })
    end
    return f
  end
  local default = vim.fn.stdpath("config") .. "/org-cli.lua"
  if vim.fn.filereadable(default) == 1 then
    return default
  end
  return nil
end

--- A path from the command line, absolute.
local function arg_path(p)
  return vim.fs.normalize(vim.fn.fnamemodify(require("org.utils").expand_vars(p), ":p"))
end
M.arg_path = arg_path

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
      fail("error in " .. file .. ": " .. tostring(res), "config", { file = file })
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
    config.opts.org_directory = arg_path(flags.dir) .. "/"
  end
  if #flags.files > 0 then
    config.opts.agenda_files = vim.tbl_map(arg_path, flags.files)
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

local function short_path(p)
  return p and require("org.utils").abbreviate(p) or nil
end
M.short_path = short_path

--- Load a file into a buffer (filetype org) and return its number.
local function load_buffer(path)
  local bufnr = require("org.utils").load_buffer(path)
  if vim.bo[bufnr].filetype ~= "org" then
    vim.bo[bufnr].filetype = "org"
  end
  return bufnr
end
M.load_buffer = load_buffer

-- Tell a running Neovim (with the cli extension on) that files changed:
-- it watches this file, rereads changed files and the clock
-- (org.clock.sync).
local function touch_stamp()
  pcall(function()
    local path = require("org.extensions.cli").stamp_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fh = io.open(path, "wb")
    if fh then
      fh:write(tostring(vim.uv.hrtime()) .. "\n")
      fh:close()
    end
  end)
end

--- Swap files a Neovim editing `path` would have ('directory').
local function swap_files(path)
  local full = arg_path(path)
  local tail = vim.fn.fnamemodify(full, ":t")
  local head = vim.fn.fnamemodify(full, ":h")
  local win = vim.fn.has("win32") == 1
  local out = {}
  for _, d in ipairs(vim.split(vim.o.directory, ",", { trimempty = true })) do
    local percent = d:match("//$") or d:match("\\\\$")
    local dir = d:gsub("[/\\]+$", "")
    local base
    if dir == "." or dir == "" then
      dir, base = head, "." .. tail
    elseif percent then
      base = full:gsub(win and "[/\\:]" or "/", "%%")
    else
      base = tail
    end
    for _, ext in ipairs({ ".swp", ".swo", ".swn" }) do
      out[#out + 1] = dir .. "/" .. base .. ext
    end
  end
  return out
end

--- Fail with `file_busy` when a running Neovim has unsaved changes in
--- `path` (its swap file says so), unless --force.
---@param path string
---@param flags table
function M.guard(path, flags)
  if not path or flags.force then
    return
  end
  local me = vim.fn.getpid()
  for _, sw in ipairs(swap_files(path)) do
    if vim.uv.fs_stat(sw) then
      local ok, info = pcall(vim.fn.swapinfo, sw)
      if ok and type(info) == "table" and not info.error and info.dirty == 1 and info.pid ~= me then
        local alive = info.pid and info.pid > 0 and vim.uv.kill(info.pid, 0) == 0
        if alive then
          fail(
            string.format(
              "%s has unsaved changes in a running Neovim (pid %d); save it there or use --force",
              path,
              info.pid
            ),
            "file_busy",
            { file = arg_path(path), pid = info.pid, swap = sw }
          )
        end
      end
    end
  end
end

--- Save every modified buffer (through utils.save_buffer: the write hooks
--- run) and tell a running Neovim.
function M.save_all(flags)
  local utils = require("org.utils")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        M.guard(name, flags or {})
        local ok, e = utils.save_buffer(b)
        if not ok then
          fail("could not save " .. name .. ": " .. tostring(e), "failed", { file = name })
        end
        state.touched = true
      end
    end
  end
  if state.touched then
    touch_stamp()
  end
end

--- Fail with `input_needed` when a prompt was refused during the command.
function M.check_prompted()
  if state.prompted then
    fail(
      "interactive input needed (" .. state.prompted .. "); not available in the CLI",
      "input_needed",
      { prompt = state.prompted }
    )
  end
end

--- Fail with org.nvim's own warnings and errors as the message.
function M.fail_with_messages(default, ecode)
  M.check_prompted()
  local msgs = {}
  for _, m in ipairs(state.messages) do
    if m.level >= vim.log.levels.WARN then
      msgs[#msgs + 1] = m.msg
    end
  end
  fail(#msgs > 0 and msgs[#msgs] or default, ecode or "failed", { messages = msgs })
end

--- Forget the messages so far (fail_with_messages reports the ones a
--- step adds).
function M.mark_messages()
  state.messages = {}
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
M.headline_line = headline_line

local function int_flag(flags, key)
  local v = flags[key]
  if v == nil then
    return nil
  end
  local n = tonumber(v)
  if not n or n < 1 or n ~= math.floor(n) then
    fail(string.format("%s needs a positive whole number, not %s", schema.BY_KEY[key].names[1], v), "bad_value")
  end
  return n
end
M.int_flag = int_flag

---------------------------------------------------------------------------
-- Headings by query
---------------------------------------------------------------------------

--- The org files a `FILE` of a query names: agenda files by path, name or
--- name without extension, else the file itself when it exists.
local function files_named(name, files)
  local want = arg_path(name)
  local sel = {}
  for _, f in ipairs(files) do
    local fname = f.filename or ""
    local tail = vim.fn.fnamemodify(fname, ":t")
    if
      fname == want
      or vim.fn.resolve(fname) == vim.fn.resolve(want)
      or tail == name
      or vim.fn.fnamemodify(tail, ":r") == name
    then
      sel[#sel + 1] = f
    end
  end
  if #sel == 0 and vim.fn.filereadable(want) == 1 then
    local f = require("org.files").get(want)
    if f then
      sel[1] = f
    end
  end
  return sel
end
M.files_named = files_named

--- Headlines matching `query`: an `id:` or ID, `FILE:LINE` (the entry
--- containing that line of any org file), `FILE::#CUSTOM_ID`,
--- `FILE::HEADING` (a file of the agenda, by path or name, or any org
--- file, and a title in it, `*` stars allowed, as in an org link), a ql
--- query when ql is enabled, else a case-insensitive title substring (an
--- exact title wins).
function M.find_headlines(query)
  local files = require("org.files").agenda_files()
  local items = require("org.agenda.items")
  query = vim.trim(query)
  local id = query:match("^id:(.+)$")
  local file_part, head_part = query:match("^(.-)::(.+)$")
  if not file_part then
    local f, l = query:match("^(.-[^:]):(%d+)$")
    if f and vim.fn.filereadable(arg_path(f)) == 1 then
      local file = require("org.files").get(arg_path(f))
      local hl = file and file:headline_at(tonumber(l))
      return { hl }
    end
  end
  if file_part and file_part ~= "" then
    files = files_named(file_part, files)
    local cid = head_part:match("^#(.+)$")
    if cid then
      local found = {}
      items.each_headline(files, { all = true }, function(hl)
        if hl.properties.CUSTOM_ID == cid then
          found[#found + 1] = hl
        end
      end)
      return found
    end
    query = vim.trim((head_part:gsub("^%*+%s*", "")))
  else
    file_part = nil
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

--- The one headline `query` names (`--pick N` among several), or a
--- `not_found` / `ambiguous` failure.
---@return org.Headline
function M.resolve_target(query, flags)
  query = vim.trim(query or "")
  if query == "" then
    fail("a heading is needed (id:ID, FILE:LINE, FILE::TITLE or title words)", "usage")
  end
  local hls = M.find_headlines(query)
  local pick = int_flag(flags, "pick")
  if #hls == 0 then
    fail("no heading matches " .. query, "not_found", { query = query })
  end
  if pick and not hls[pick] then
    fail(string.format("--pick %s: pick 1 to %d", flags.pick, #hls), "usage", { count = #hls })
  end
  if #hls > 1 and not pick then
    local lines = { "several headings match " .. query .. " (--pick N):" }
    local candidates = {}
    for i, hl in ipairs(hls) do
      lines[#lines + 1] = string.format("%3d  %s", i, headline_line(hl))
      candidates[i] = data.headline(hl)
    end
    fail(table.concat(lines, "\n"), "ambiguous", { query = query, candidates = candidates })
  end
  return hls[pick or 1]
end

--- The buffer target of a headline found on disk: (bufnr, lnum).
function M.open_target(hl, flags)
  M.guard(hl.file.filename, flags)
  local bufnr = load_buffer(hl.file.filename)
  local file = require("org.files").get_buffer(bufnr)
  local target = file:headline_at(hl.line)
  if not target then
    fail("the heading moved: " .. headline_line(hl), "failed")
  end
  return bufnr, target.line
end

--- The headline at (bufnr, lnum) of the current buffer text.
function M.headline_at(bufnr, lnum)
  return require("org.files").get_buffer(bufnr):headline_at(lnum)
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
      fail("cannot read date " .. flags.date, "bad_value", { date = flags.date })
    end
    anchor = d:days()
  end
  local span = flags.span and (tonumber(flags.span) or flags.span)
  local label, key = what, vim.NIL
  if what == "agenda" or SPANS[what] then
    span = span or SPANS[what]
    agenda.open({ type = "agenda" }, { span = span, anchor = anchor })
    label = "agenda"
  elseif what == "todo" then
    agenda.open({ type = "todo", keywords = words[2] })
  elseif what == "tags" or what == "tags-todo" then
    if not words[2] then
      fail("agenda " .. what .. " needs a match, e.g. org agenda tags +work", "usage")
    end
    local ok, e = require("org.agenda.search").try_compile(words[2])
    if not ok then
      fail("bad match " .. words[2] .. ": " .. tostring(e), "bad_value", { match = words[2] })
    end
    agenda.open({ type = what == "tags" and "tags" or "tags_todo", match = words[2] })
  elseif type((config.opts.agenda.custom_commands or {})[what]) == "table" then
    if span then
      config.opts.agenda.span = span
    end
    agenda.open_custom(what)
    label, key = "custom", what
  else
    fail(
      "unknown agenda view " .. what .. " (day, week, month, todo, tags or a custom command key)",
      "usage",
      { view = what }
    )
  end
  local S = require("org.agenda.view").state
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    fail("no agenda was built (are agenda_files set? see --files)", "failed")
  end
  return S, label, key
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
      local d = it.day or (type(it.date) == "table" and it.date.days and it.date:days()) or (hl and day) or nil
      local extra = it.extra and vim.trim(it.extra) ~= "" and vim.trim(it.extra) or nil
      items[#items + 1] = {
        date = data.iso_day(d),
        time = data.hm(it.time),
        end_time = data.hm(it.end_time),
        type = data.nn(it.ts_type or it.type),
        todo = data.nn(it.todo),
        priority = data.nn(it.priority),
        title = hl and hl:plain_title() or it.title or "",
        tags = it.tags or {},
        category = data.nn(it.category),
        file = data.path(it.filename),
        line = data.nn(it.lnum),
        id = hl and data.nn(hl.properties.ID) or vim.NIL,
        level = data.nn(it.level),
        timestamp = data.timestamp(it.date),
        extra = data.nn(extra),
        done = it.done or false,
        text = vim.trim(line),
      }
    end
  end
  return items
end

function M.cmd_agenda(words, flags)
  local S, label, key = open_agenda(words, flags)
  if flags.csv then
    if state.machine then
      fail("--csv and --json/--jsonl exclude each other", "usage")
    end
    return { text = require("org.agenda.export").csv_lines() }
  end
  if state.machine then
    local first, last
    for _, d in pairs(S.day_lines or {}) do
      first = math.min(first or d, d)
      last = math.max(last or d, d)
    end
    local items = M.agenda_items(S)
    return {
      data = { view = label, key = key, start = data.iso_day(first), ["end"] = data.iso_day(last), items = items },
      stream = items,
    }
  end
  local text = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
    text[#text + 1] = (l:gsub("%s+$", ""))
  end
  return { text = text }
end

---------------------------------------------------------------------------
-- search, headlines, show
---------------------------------------------------------------------------

local function headline_result(hls, limit)
  if limit and #hls > limit then
    hls = vim.list_slice(hls, 1, limit)
  end
  local list = vim.tbl_map(data.headline, hls)
  local text = vim.tbl_map(headline_line, hls)
  return { data = list, text = text, code = #hls > 0 and 0 or 1 }
end

local function match_predicate(match)
  local pred, e = require("org.agenda.search").try_compile(match)
  if not pred then
    fail("bad match " .. match .. ": " .. tostring(e), "bad_value", { match = match })
  end
  return pred
end

function M.cmd_search(words, flags)
  local query = table.concat(words, " ")
  local limit = int_flag(flags, "limit")
  local hls = {}
  if flags.match then
    local pred = match_predicate(flags.match)
    require("org.agenda.items").each_headline(require("org.files").agenda_files(), {}, function(hl)
      if pred(hl) and (query == "" or hl:plain_title():lower():find(query:lower(), 1, true)) then
        hls[#hls + 1] = hl
      end
    end)
    return headline_result(hls, limit)
  end
  if query == "" then
    fail("search needs a query (or --match MATCH)", "usage")
  end
  if require("org.extensions").enabled("ql") then
    local ok, res = pcall(require("org.extensions.ql").select, "agenda", query)
    if not ok then
      fail("bad query: " .. tostring(res), "bad_value", { query = query })
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
  return headline_result(hls, limit)
end

--- A `FROM..TO` day range (either side optional; a single date is that
--- day), `any` or `none`, as a predicate on a timestamp (or nil).
local function date_range(spec, flag)
  local date = require("org.date")
  if spec == "any" then
    return function(ts)
      return ts ~= nil
    end
  elseif spec == "none" then
    return function(ts)
      return ts == nil
    end
  end
  local a, b = spec:match("^(.-)%.%.(.-)$")
  if not a then
    a, b = spec, spec
  end
  local function day(s)
    s = vim.trim(s)
    if s == "" then
      return nil
    end
    local d = date.read_date(s, date.today())
    if not d then
      fail(string.format("%s: cannot read date %s", flag, s), "bad_value", { date = s })
    end
    return d:days()
  end
  local from, to = day(a), day(b)
  return function(ts)
    if not ts then
      return false
    end
    local n = ts:days()
    return (not from or n >= from) and (not to or n <= to)
  end
end

local function level_range(spec)
  local a, b = spec:match("^(%d*)%.%.(%d*)$")
  if not a then
    a = spec:match("^(%d+)$")
    b = a
  end
  if not a then
    fail("--level needs N or FROM..TO, not " .. spec, "bad_value")
  end
  local from, to = tonumber(a), tonumber(b)
  return function(n)
    return (not from or n >= from) and (not to or n <= to)
  end
end

--- A predicate on headlines from the filters of `org headlines`.
function M.headline_filter(flags)
  local preds = {}
  if #flags.todo > 0 then
    local want = flags.todo
    preds[#preds + 1] = function(hl)
      for _, w in ipairs(want) do
        if
          (w == "any" and hl.todo)
          or (w == "open" and hl:is_todo())
          or (w == "done" and hl:is_done())
          or (w == "none" and not hl.todo)
          or hl.todo == w
        then
          return true
        end
      end
      return false
    end
  end
  for _, t in ipairs(flags.tag) do
    preds[#preds + 1] = function(hl)
      return vim.tbl_contains(hl:get_tags(), t)
    end
  end
  for _, p in ipairs(flags.property) do
    local name, value = p:match("^([^=]+)=(.*)$")
    name = (name or p):upper()
    preds[#preds + 1] = function(hl)
      local v = hl:get_property(name, false)
      if value then
        return v == value
      end
      return v ~= nil
    end
  end
  if flags.level then
    local ok = level_range(flags.level)
    preds[#preds + 1] = function(hl)
      return ok(hl.level)
    end
  end
  for _, kind in ipairs({ "scheduled", "deadline" }) do
    if flags[kind] then
      local ok = date_range(flags[kind], "--" .. kind)
      preds[#preds + 1] = function(hl)
        return ok(hl.planning[kind])
      end
    end
  end
  if flags.match then
    preds[#preds + 1] = match_predicate(flags.match)
  end
  return function(hl)
    for _, p in ipairs(preds) do
      if not p(hl) then
        return false
      end
    end
    return true
  end
end

function M.cmd_headlines(words, flags)
  local files
  if #words > 0 then
    files = {}
    for _, w in ipairs(words) do
      local p = arg_path(w)
      local f = vim.fn.filereadable(p) == 1 and require("org.files").get(p) or nil
      if not f then
        fail("no such file: " .. p, "bad_value", { file = p })
      end
      files[#files + 1] = f
    end
  else
    files = require("org.files").agenda_files()
  end
  if #flags.file > 0 then
    local sel, seen = {}, {}
    for _, name in ipairs(flags.file) do
      local named = files_named(name, files)
      if #named == 0 then
        fail("no agenda file " .. name, "bad_value", { file = name })
      end
      for _, f in ipairs(named) do
        if not seen[f] then
          seen[f] = true
          sel[#sel + 1] = f
        end
      end
    end
    files = sel
  end
  local pred = M.headline_filter(flags)
  local hls = {}
  require("org.agenda.items").each_headline(files, { all = flags.archived or false }, function(hl)
    if pred(hl) then
      hls[#hls + 1] = hl
    end
  end)
  return headline_result(hls, int_flag(flags, "limit"))
end

function M.cmd_show(words, flags)
  local hl = M.resolve_target(table.concat(words, " "), flags)
  local entry = data.entry(hl, { children = flags.children })
  local text = { headline_line(hl) }
  local function ts(label, t)
    if t then
      text[#text + 1] = label .. t:to_string()
    end
  end
  ts("  SCHEDULED: ", hl.planning.scheduled)
  ts("  DEADLINE: ", hl.planning.deadline)
  ts("  CLOSED: ", hl.planning.closed)
  local keys = vim.tbl_keys(hl.properties)
  table.sort(keys)
  for _, k in ipairs(keys) do
    text[#text + 1] = "  :" .. k .. ": " .. hl.properties[k]
  end
  if entry.clock.count > 0 then
    text[#text + 1] = "  clocked: " .. entry.clock.total .. " (" .. entry.clock.count .. " clocks)"
  end
  if entry.body ~= "" then
    text[#text + 1] = ""
    vim.list_extend(text, vim.split(entry.body, "\n", { plain = true }))
  end
  return { data = entry, text = text }
end

---------------------------------------------------------------------------
-- templates, files, tags, keywords
---------------------------------------------------------------------------

function M.cmd_templates()
  local capture = require("org.capture")
  local templates = capture.templates()
  local keys = vim.tbl_keys(templates)
  table.sort(keys)
  local list, text = {}, {}
  for _, k in ipairs(keys) do
    local t = templates[k]
    local group = type(t) ~= "table"
    local desc = type(t) == "table" and t.description or (type(t) == "string" and t) or ""
    local target = vim.NIL
    if not group then
      local ok, p = pcall(capture.target_path, t)
      target = ok and data.path(p) or vim.NIL
    end
    list[#list + 1] = {
      key = k,
      description = desc,
      type = group and vim.NIL or (t.type or "entry"),
      target = target,
      group = group,
    }
    text[#text + 1] = k .. "\t" .. desc .. (group and " (group)" or "")
  end
  return { data = list, text = text }
end

function M.cmd_files()
  local list, text = {}, {}
  for _, f in ipairs(require("org.files").agenda_files()) do
    list[#list + 1] = {
      file = data.path(f.filename),
      title = data.nn(f:title()),
      category = data.nn(f:category()),
      headlines = #f.headlines,
    }
    text[#text + 1] = f.filename
  end
  return { data = list, text = text }
end

function M.cmd_tags()
  local counts, defined = {}, {}
  local tags = require("org.tags")
  local function define(defs)
    for _, d in ipairs(defs or {}) do
      if type(d) == "table" and d.name and not d.name:match("^[{}]") then
        defined[d.name] = true
      end
    end
  end
  pcall(function()
    define(tags.option_definitions())
  end)
  for _, f in ipairs(require("org.files").agenda_files()) do
    pcall(function()
      define(f:tag_definitions())
    end)
    for _, t in ipairs(f.settings.filetags or {}) do
      counts[t] = (counts[t] or 0) + 1
    end
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        counts[t] = (counts[t] or 0) + 1
      end
    end
  end
  local names = {}
  for k in pairs(counts) do
    names[#names + 1] = k
  end
  for k in pairs(defined) do
    if not counts[k] then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  local list, text = {}, {}
  for _, n in ipairs(names) do
    list[#list + 1] = { name = n, count = counts[n] or 0, defined = defined[n] or false }
    text[#text + 1] = string.format("%s\t%d", n, counts[n] or 0)
  end
  return { data = list, text = text }
end

function M.cmd_keywords()
  local cfg = require("org.todo_keywords").global()
  local sequences, todo, done = {}, {}, {}
  for _, seq in ipairs(cfg.sequences) do
    local s = {}
    for _, kw in ipairs(seq) do
      s[#s + 1] = { name = kw.name, done = kw.done or false, key = data.nn(kw.key) }
      table.insert(kw.done and done or todo, kw.name)
    end
    sequences[#sequences + 1] = s
  end
  local o = require("org.config").opts
  local priority = {
    highest = tostring(o.priority_highest),
    lowest = tostring(o.priority_lowest),
    default = tostring(o.priority_default),
  }
  local text = {}
  for _, s in ipairs(sequences) do
    local parts = {}
    local bar = false
    for _, kw in ipairs(s) do
      if kw.done and not bar then
        parts[#parts + 1] = "|"
        bar = true
      end
      parts[#parts + 1] = kw.name
    end
    text[#text + 1] = table.concat(parts, " ")
  end
  text[#text + 1] = string.format("priorities: %s-%s (default %s)", priority.highest, priority.lowest, priority.default)
  return { data = { sequences = sequences, todo = todo, done = done, priority = priority }, text = text }
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
    fail("no capture template " .. key .. " (org templates)", "bad_value", { template = key })
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
    fail("no capture templates", "bad_value")
  end
  return keys[1]
end

local function read_stdin()
  return io.stdin:read("*a") or ""
end
M.read_stdin = function()
  return read_stdin()
end

--- `NAME=VALUE` pairs of `--field` (and an `--input` object's `fields`)
--- as prompt answers, by lowercased name.
local function set_answers(fields, input_fields)
  for k, v in pairs(input_fields or {}) do
    state.answers[tostring(k):lower()] = tostring(v)
  end
  for _, f in ipairs(fields or {}) do
    local k, v = f:match("^([^=]+)=(.*)$")
    if not k then
      fail("--field needs NAME=VALUE, not " .. f, "bad_value", { field = f })
    end
    state.answers[vim.trim(k):lower()] = v
  end
end

function M.cmd_capture(words, flags)
  local capture = require("org.capture")
  if flags.list then
    return M.cmd_templates()
  end
  local input = {}
  if flags.input then
    local text = flags.input == "-" and M.read_stdin() or nil
    if not text then
      local p = arg_path(flags.input)
      local lines = vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or nil
      if not lines then
        fail("no such file: " .. p, "bad_value", { file = p })
      end
      text = table.concat(lines, "\n")
    end
    local ok, obj = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if not ok or type(obj) ~= "table" or vim.islist(obj) and next(obj) ~= nil then
      fail("--input needs a JSON object { template, text, fields }", "bad_value")
    end
    input = obj
  end
  set_answers(flags.field, type(input.fields) == "table" and input.fields or nil)
  local text = table.concat(words, " ")
  if text == "-" then
    text = M.read_stdin()
  elseif text == "" and input.text then
    text = tostring(input.text)
  end
  text = vim.trim(text)
  local key = flags.template or input.template or default_template_key()
  local tpl = M.capture_template(tostring(key))
  local prompts = type(tpl.template) == "string" and tpl.template:find("%^", 1, true)
  if text == "" and next(state.answers) == nil and not prompts then
    fail("nothing to capture (org capture [-t KEY] TEXT)", "usage")
  end
  local ok_target, target = pcall(capture.target_path, tpl)
  if ok_target and target then
    M.guard(target, flags)
  end
  M.mark_messages()
  local done, bufnr, line
  local co = coroutine.create(function()
    bufnr, line = capture.capture(tpl, { initial = text })
    done = true
  end)
  local ok, e = coroutine.resume(co)
  if not ok then
    error(e, 0)
  end
  if not done then
    vim.wait(5000, function()
      return done or state.prompted ~= nil
    end, 10)
  end
  M.check_prompted()
  if not done or not bufnr then
    M.fail_with_messages("capture failed")
  end
  local hl = (tpl.type or "entry") == "entry" and M.headline_at(bufnr, line) or nil
  local id
  if hl then
    id = hl.properties.ID
    if flags.id and not id then
      id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
      hl = M.headline_at(bufnr, hl.line)
    end
  end
  M.save_all(flags)
  local path = data.path(vim.api.nvim_buf_get_name(bufnr))
  return {
    data = {
      file = path,
      line = line,
      template = tpl.key or tostring(key),
      type = tpl.type or "entry",
      id = data.nn(id),
      headline = hl and data.headline(hl) or vim.NIL,
    },
    text = { string.format("Captured to %s:%d", short_path(path), line or 0) },
  }
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
  local start = date.parse(st.start) or date.parse("[" .. tostring(st.start) .. "]")
  local minutes = start and date.elapsed_minutes(start, date.now()) or 0
  local title = st.title or ""
  local line, id = vim.NIL, vim.NIL
  local ok, bufnr, lnum = pcall(clock.find_open_clock)
  if ok and bufnr and lnum then
    local hl = M.headline_at(bufnr, lnum)
    if hl then
      line, id = hl.line, data.nn(hl.properties.ID)
    end
  end
  return {
    active = true,
    title = title,
    file = data.path(st.path),
    line = line,
    id = id,
    start = st.start,
    start_iso = start and data.iso(start) or vim.NIL,
    minutes = minutes,
    elapsed = date.duration_to_string(minutes),
    total = (st.total or 0) + minutes,
    effort = data.nn(st.effort),
  }
end

local NO_CLOCK = {
  active = false,
  title = vim.NIL,
  file = vim.NIL,
  line = vim.NIL,
  id = vim.NIL,
  start = vim.NIL,
  start_iso = vim.NIL,
  minutes = vim.NIL,
  elapsed = vim.NIL,
  total = vim.NIL,
  effort = vim.NIL,
}

--- Expand a `--format` string: %t title, %e elapsed, %T total (with past
--- clocks), %E effort, %f file, %s start, %% a percent sign.
function M.format_clock(fmt, c)
  local date = require("org.date")
  local effort = c.effort ~= vim.NIL and c.effort or nil
  local map = {
    t = c.title,
    e = c.elapsed,
    T = date.duration_to_string(c.total or c.minutes),
    E = effort and date.duration_to_string(effort) or "",
    f = c.file ~= vim.NIL and short_path(c.file) or "",
    s = c.start or "",
    ["%"] = "%",
  }
  return (fmt:gsub("%%(.)", function(k)
    return map[k] or ("%" .. k)
  end))
end

function M.cmd_clock_status(_, flags)
  local c = M.clock_data()
  local text
  if flags.format or flags.short then
    text = c and { M.format_clock(flags.format or cli_opts().status_format, c) } or {}
  elseif c then
    text = { string.format("%s  %s  (%s)", c.elapsed, c.title, short_path(c.file)) }
  else
    text = { "No running clock" }
  end
  return { data = c or NO_CLOCK, text = text }
end

function M.cmd_clock_in(words, flags)
  local clock = require("org.clock")
  local query = table.concat(words, " ")
  if query == "" then
    fail("clock in needs a heading: org clock in TARGET", "usage")
  end
  local hl = M.resolve_target(query, flags)
  clock.restore()
  local bufnr, lnum = M.open_target(hl, flags)
  M.mark_messages()
  local st = clock.clock_in({ bufnr = bufnr, lnum = lnum }, { no_count = true })
  if not st then
    M.fail_with_messages("could not clock in")
  end
  M.save_all(flags)
  touch_stamp()
  return { data = M.clock_data() or NO_CLOCK, text = { "Clocked in: " .. hl:plain_title() } }
end

local function clock_stop(cancel, flags)
  local clock = require("org.clock")
  local c = M.clock_data()
  if not c then
    if state.machine then
      fail("no running clock", "no_clock")
    end
    return { text = { "No running clock" }, code = 1 }
  end
  if c.file ~= vim.NIL then
    M.guard(c.file, flags)
  end
  local minutes
  if cancel then
    clock.clock_cancel()
  else
    minutes = clock.clock_out({ note = false })
  end
  M.save_all(flags)
  touch_stamp()
  local text
  if cancel then
    text = { "Clock canceled: " .. c.title }
  else
    text = { string.format("Clocked out: %s (%s)", c.title, data.duration(minutes)) }
  end
  return {
    data = {
      active = false,
      title = c.title,
      file = c.file,
      minutes = data.nn(minutes),
      duration = minutes and data.duration(minutes) or vim.NIL,
      canceled = cancel,
    },
    text = text,
  }
end

function M.cmd_clock_out(_, flags)
  return clock_stop(false, flags)
end

function M.cmd_clock_cancel(_, flags)
  return clock_stop(true, flags)
end

---------------------------------------------------------------------------
-- export
---------------------------------------------------------------------------

function M.cmd_export(words, flags)
  local file, backend = words[1], words[2]
  if not file or not backend then
    fail("usage: org export FILE BACKEND [-o OUTPUT|--stdout]", "usage")
  end
  file = arg_path(file)
  if vim.fn.filereadable(file) == 0 then
    fail("no such file: " .. file, "bad_value", { file = file })
  end
  local export = require("org.export")
  local bufnr = load_buffer(file)
  vim.api.nvim_set_current_buf(bufnr)
  if flags.stdout or flags.output == "-" then
    local ok, text = pcall(export.to_string, backend, { bufnr = bufnr })
    if not ok then
      fail(tostring(text), "failed")
    end
    return {
      data = { file = file, backend = backend, output = vim.NIL, text = text },
      raw = text:sub(-1) == "\n" and text or (text .. "\n"),
    }
  end
  local output = flags.output and arg_path(flags.output) or nil
  M.mark_messages()
  local res = export.export(backend, { bufnr = bufnr, output = output, async = false })
  if not res then
    M.fail_with_messages("export failed")
  end
  res = vim.fs.normalize(res)
  return { data = { file = file, backend = backend, output = data.path(res), text = vim.NIL }, text = { res } }
end

---------------------------------------------------------------------------
-- schema, help, version
---------------------------------------------------------------------------

function M.cmd_schema(words)
  local name = #words > 0 and table.concat(words, " ") or nil
  local doc = schema.describe(name)
  if not doc then
    fail("unknown command " .. name, "unknown_command", { command = name })
  end
  return { data = doc, raw = vim.json.encode(doc) .. "\n" }
end

function M.cmd_version()
  local v = require("org.version").release
  return { data = { version = v }, text = { "org.nvim " .. v } }
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

local function write_cmd(name)
  return function(...)
    return require("org.extensions.cli.write")[name](...)
  end
end

--- Command name (as in `schema.COMMANDS`) -> function(words, flags)
--- returning { data, text, raw, stream, code }.
M.COMMANDS = {
  agenda = M.cmd_agenda,
  search = M.cmd_search,
  headlines = M.cmd_headlines,
  show = M.cmd_show,
  id = write_cmd("cmd_id"),
  ["clock status"] = M.cmd_clock_status,
  ["clock in"] = M.cmd_clock_in,
  ["clock out"] = M.cmd_clock_out,
  ["clock cancel"] = M.cmd_clock_cancel,
  templates = M.cmd_templates,
  files = M.cmd_files,
  tags = M.cmd_tags,
  keywords = M.cmd_keywords,
  capture = M.cmd_capture,
  ["set todo"] = write_cmd("cmd_set_todo"),
  ["set tags"] = write_cmd("cmd_set_tags"),
  ["set priority"] = write_cmd("cmd_set_priority"),
  ["set property"] = write_cmd("cmd_set_property"),
  ["set scheduled"] = write_cmd("cmd_set_scheduled"),
  ["set deadline"] = write_cmd("cmd_set_deadline"),
  note = write_cmd("cmd_note"),
  refile = write_cmd("cmd_refile"),
  archive = write_cmd("cmd_archive"),
  export = M.cmd_export,
  schema = M.cmd_schema,
  version = M.cmd_version,
}

--- The command `words` start with: its schema entry and the remaining
--- words. `clock` alone is `clock status`.
local function find_command(words)
  local first = words[1]
  if first == "clock" and (words[2] == nil or not schema.BY_COMMAND["clock " .. words[2]]) then
    if words[2] ~= nil then
      fail("unknown clock command " .. words[2] .. " (status, in, out, cancel)", "usage", { command = "clock" })
    end
    return schema.BY_COMMAND["clock status"], {}
  end
  if first == "set" then
    local c = words[2] and schema.BY_COMMAND["set " .. words[2]]
    if not c then
      fail("set needs what to set: todo, tags, priority, property, scheduled or deadline", "usage", { command = "set" })
    end
    return c, vim.list_slice(words, 3)
  end
  local two = words[2] and schema.BY_COMMAND[first .. " " .. words[2]]
  if two then
    return two, vim.list_slice(words, 3)
  end
  local c = schema.BY_COMMAND[first]
  if not c then
    fail("unknown command " .. tostring(first) .. " (see org help)", "unknown_command", { command = first })
  end
  return c, vim.list_slice(words, 2)
end

--- The JSON envelope.
local function envelope(command, ok, payload, errors)
  return {
    version = schema.VERSION,
    ok = ok,
    command = command or vim.NIL,
    data = payload == nil and vim.NIL or payload,
    warnings = state.warnings,
    errors = errors or {},
  }
end

local function emit(command, res, flags)
  if flags.jsonl then
    local stream = res.stream or (type(res.data) == "table" and vim.islist(res.data) and res.data) or nil
    if stream then
      for _, v in ipairs(stream) do
        out(vim.json.encode(v))
      end
    else
      out(vim.json.encode(res.data == nil and vim.NIL or res.data))
    end
  else
    out(vim.json.encode(envelope(command, true, res.data)))
  end
end

--- Run the CLI. Returns the exit code: 0 ok, 1 failure (or nothing
--- found), 2 usage error, 3 input would be needed, 4 file busy.
---@param argv string[]
---@return integer
function M.main(argv)
  reset_state()
  local command
  local saved_write = io.write
  local ok, code = pcall(function()
    -- a quick look for --json, so that argument errors are JSON too
    for _, a in ipairs(argv or {}) do
      if a == "--" then
        break
      end
      if a == "--json" or a == "--jsonl" then
        state.machine = true
        state.jsonl = a == "--jsonl"
      end
    end
    local flags, words = M.parse_args(argv or {})
    state.quiet = flags.quiet or false
    state.verbose = flags.verbose or false
    state.machine = flags.json or flags.jsonl or false
    state.jsonl = flags.jsonl or false
    state.note = flags.note
    if state.machine then
      -- nothing but the JSON on stdout
      io.write = function(...)
        return io.stderr:write(...)
      end
    end
    if flags.version and #words == 0 then
      words = { "version" }
    end
    if words[1] == nil or words[1] == "help" then
      if state.machine then
        words = vim.list_extend({ "schema" }, vim.list_slice(words, 2))
      else
        M.stdout(M.USAGE)
        return words[1] == nil and not flags.help and 2 or 0
      end
    end
    if flags.help and not state.machine then
      M.stdout(M.USAGE)
      return 0
    end
    local cmd, rest = find_command(words)
    command = cmd.name
    if flags.help then
      emit(command, M.cmd_schema(vim.split(command, " ")), flags)
      return 0
    end
    local allowed = schema.allowed(cmd)
    for key, name in pairs(flags._given) do
      if not allowed[key] then
        fail(
          string.format("%s is not an option of %s (see org schema %s)", name, cmd.name, cmd.name),
          "unknown_option",
          {
            option = name,
          }
        )
      end
    end
    if command == "schema" or command == "version" then
      local res = M.COMMANDS[command](rest, flags)
      if state.machine then
        emit(command, res, flags)
      elseif res.raw then
        M.stdout(res.raw)
      else
        for _, l in ipairs(res.text or {}) do
          out(l)
        end
      end
      return 0
    end
    M.headless()
    M.load_config(flags)
    local res = M.COMMANDS[command](rest, flags) or {}
    if state.machine then
      emit(command, res, flags)
      return 0
    end
    if res.raw then
      M.stdout(res.raw)
    else
      for _, l in ipairs(res.text or {}) do
        out(l)
      end
    end
    return res.code or 0
  end)
  io.write = saved_write
  if ok then
    return code or 0
  end
  local e = code
  if type(e) ~= "table" or not e.cli then
    e = { msg = tostring(e), code = 1, ecode = "internal" }
  end
  if state.machine then
    local errobj = { code = e.ecode or "failed", message = e.msg, details = e.details or vim.empty_dict() }
    out(vim.json.encode(envelope(command, false, nil, { errobj })))
    if state.verbose then
      err(e.msg)
    end
  else
    err(e.msg)
  end
  return e.code
end

return M
