---@mod org.extensions.cli.run The `org` command line: argument parsing and subcommands
---
--- `bin/org` runs `nvim --headless -l lua/org/extensions/cli/main.lua`,
--- which calls |M.main| with the arguments. Every subcommand works on the
--- files of the loaded configuration (`--config`, `$ORG_NVIM_CONFIG` or
--- `stdpath("config")/org-cli.lua`) and writes plain text or, with
--- `--json` / `--jsonl`, JSON to stdout (`org schema` describes it).
--- Messages go to stderr.
---
--- This file holds the usage text, output, failures, the command table and
--- `main`; the rest loads from org/extensions/cli/: headless (prompts and
--- notifications), args (arguments and configuration), target (headings
--- by query), save (guarding and saving files), read (agenda, search,
--- headlines, show), info (templates, files, tags, keywords, schema,
--- version), capture (capture and protocol), clock, export and session
--- (the session server). The write commands are in write.lua, the MCP
--- server (`org mcp`) in mcp.lua.

local schema = require("org.extensions.cli.schema")
local shared = require("org.extensions.cli.shared")

local M = {}
-- The parts add their functions to this table and require it back, so it
-- must be in package.loaded before they load.
package.loaded["org.extensions.cli.run"] = M

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
  protocol URL   an org-protocol:// URL (capture, store-link, open-source)
  clock in [--pick N] TARGET | clock out | clock cancel
  add PARENT TITLE [--todo KW] [--priority P] [--tag TAG] [--scheduled DATE]
         [--deadline DATE] [--property NAME=VALUE] [--body TEXT] [--first]
         (PARENT: a heading, or an org file for a top-level heading)
  append TARGET TEXT   text at the end of the body (TEXT "-" reads stdin)
  set title TARGET TITLE
  set todo TARGET STATE [--note TEXT]
  set tags TARGET [TAGS] [--add TAG] [--remove TAG]
  set priority TARGET PRIORITY
  set property TARGET NAME [VALUE] [--delete]
  set scheduled TARGET DATE [--note TEXT]   ("none" removes)
  set deadline TARGET DATE [--note TEXT]
  note TARGET TEXT
  refile TARGET DESTINATION
  archive TARGET
  id TARGET [--create]

  mcp [--read-only]   the commands as the tools of an MCP server for AI
                      agents (JSON-RPC on stdin and stdout)

  schema [COMMAND] | help [--json] | version

TARGET: id:ID or an ID, FILE:LINE, FILE::TITLE, FILE::#CUSTOM_ID, or title
words (an org-ql query with ql); several matches: --pick N.

Arguments are one word each, except a last one of free text (TEXT, QUERY,
DATE, a property VALUE, a TARGET with nothing after it), which takes the
remaining words: quote a TARGET of several words that other arguments
follow. A word left over is an error, never dropped.

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
  --no-server     run here even when a Neovim session server listens

With a Neovim session server running (remote.enabled, :h org-remote) every
command but export runs in that Neovim, on its buffers and its clock;
$ORG_NVIM_SERVER is its address ("none": never).
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

-- One table for the run's lifetime (the parts hold it), reset in place
-- by every command.
local state = {}

local function reset_state()
  for k in pairs(state) do
    state[k] = nil
  end
  for k, v in pairs({
    quiet = false,
    verbose = false,
    machine = false,
    messages = {},
    warnings = {},
    answers = {},
    note = nil,
    prompted = nil,
    touched = false,
    -- run by the session server (M.serve): in the client's directory,
    -- leaving buffers with unsaved changes unsaved
    session = false,
    cwd = nil,
    dirty_before = {},
  }) do
    state[k] = v
  end
end
reset_state()

local function out(line)
  M.stdout(line .. "\n")
end

local function err(line)
  M.stderr("org: " .. line .. "\n")
end

M.out = out

-- tostring() of a failure is its message: org.nvim code that catches an
-- error and reports it (code blocks evaluated during an export, ...)
-- then says what went wrong
local Failure = {
  __tostring = function(e)
    return e.msg
  end,
}

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
  error(setmetatable({ cli = true, msg = msg, code = code, ecode = ecode, details = details }, Failure), 0)
end
M.fail = fail

shared.state = state
shared.err = err

require("org.extensions.cli.headless")
require("org.extensions.cli.args")
require("org.extensions.cli.target")
require("org.extensions.cli.save")
require("org.extensions.cli.read")
require("org.extensions.cli.info")
require("org.extensions.cli.capture")
require("org.extensions.cli.clock")
require("org.extensions.cli.export")

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
  protocol = M.cmd_protocol,
  add = write_cmd("cmd_add"),
  append = write_cmd("cmd_append"),
  ["set title"] = write_cmd("cmd_set_title"),
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
  mcp = function(...)
    return require("org.extensions.cli.mcp").cmd_mcp(...)
  end,
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
      fail(
        "set needs what to set: title, todo, tags, priority, property, scheduled or deadline",
        "usage",
        { command = "set" }
      )
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

--- The message for words a command has no argument for: nothing is ever
--- dropped (a TARGET of several words followed by other arguments has
--- to be quoted).
local function too_many(cmd, rest, max)
  local extra = table.concat(vim.list_slice(rest, max + 1), " ")
  if max == 0 then
    return string.format("%s takes no arguments, not %s", cmd.name, extra)
  end
  local names = vim.tbl_map(function(a)
    return a.name:upper()
  end, cmd.args)
  local msg = string.format("%s takes %s, not also %s", cmd.name, table.concat(names, " "), extra)
  if cmd.args[1].name == "target" then
    msg = msg .. " (quote a TARGET of several words)"
  end
  return msg
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

require("org.extensions.cli.session")

local session_begin = shared.session_begin

--- Run the CLI. Returns the exit code: 0 ok, 1 failure (or nothing
--- found), 2 usage error, 3 input would be needed, 4 file busy.
--- `opts.session`: run by the session server for a client in `opts.cwd`
--- (see |M.serve|).
---@param argv string[]
---@param opts? { session?: boolean, cwd?: string }
---@return integer
function M.main(argv, opts)
  opts = opts or {}
  reset_state()
  state.session = opts.session or false
  state.cwd = opts.cwd
  local command
  local saved_write = io.write
  local restore, unwatch
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
    if state.session then
      -- a Neovim's own stdout may be its UI's channel: never write there
      local function session_write(...)
        local put = state.machine and M.stderr or M.stdout
        for i = 1, select("#", ...) do
          put(tostring((select(i, ...))))
        end
        return io.stdout
      end
      io.write = session_write
    elseif state.machine then
      -- nothing but the JSON on stdout
      local function stderr_write(...)
        return io.stderr:write(...)
      end
      io.write = stderr_write
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
    local max = schema.max_words(cmd)
    if max and #rest > max then
      fail(too_many(cmd, rest, max), "usage", { command = command, extra = vim.list_slice(rest, max + 1) })
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
    if state.session then
      restore = session_begin(flags)
    else
      -- the configuration may enable the session server: not here
      require("org.remote").inhibit = true
      M.headless()
      M.load_config(flags)
      local forwarded = M.forward(argv or {}, command, flags)
      if forwarded then
        return forwarded
      end
      -- one write command at a time: two that edit the same file would
      -- each write it over the other's change
      if cmd.writes then
        M.lock_writes()
      end
    end
    unwatch = M.watch_disk()
    local cok, res = pcall(M.COMMANDS[command], rest, flags)
    -- a write that didn't happen is the failure, whatever came of it
    M.check_disk_changed()
    if not cok then
      error(res, 0)
    end
    res = res or {}
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
  if unwatch then
    unwatch()
  end
  M.unlock_writes()
  if restore then
    restore()
  end
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
