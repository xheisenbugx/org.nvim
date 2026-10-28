---@mod org.extensions.cli.mcp `org mcp`: the commands as an MCP server
---
--- A Model Context Protocol server on stdin and stdout (JSON-RPC 2.0,
--- one message per line) for AI agents: every command of the command line
--- but `schema`, `help`, `version`, `protocol`, `mcp` and `lsp` is a tool, whose
--- `inputSchema` is the command's `input_schema` (`schema.input_schema`).
--- A tool call runs `org COMMAND ... --json` in a new Neovim, as the shell
--- does, so it reads the files as they are on disk, writes them through
--- the guard and the write hooks and runs in the session server when one
--- listens; its result is the JSON envelope. With `--read-only` (or
--- `extensions.cli.mcp.read_only`) the tools that write are left out.

local schema = require("org.extensions.cli.schema")
local shared = require("org.extensions.cli.shared")

local run = require("org.extensions.cli.run")

local M = {}

local fail = run.fail
local state = shared.state

--- Protocol versions the server speaks, newest first: an `initialize` with
--- one of them gets it back, any other the newest.
M.PROTOCOLS = { "2025-06-18", "2025-03-26", "2024-11-05" }

--- How long a tool call may take (ms) before its Neovim is stopped.
M.TIMEOUT = 600000

-- commands that are no tools: descriptions, the URL handler (it needs a
-- running Neovim's windows), the server itself and the language server
local NOT_TOOLS = { schema = true, help = true, version = true, protocol = true, mcp = true, lsp = true }

-- flags no tool takes: --force writes over a running Neovim's unsaved
-- changes (the agent gets file_busy and asks the user), --input reads
-- stdin (the protocol's channel), --list and --csv have their own tools
-- or no use in JSON
local HIDDEN_FLAGS = { force = true, input = true, list = true, csv = true }

-- tools that replace or remove what is there (MCP's destructiveHint)
local DESTRUCTIVE = {
  ["clock cancel"] = true,
  ["set todo"] = true,
  ["set tags"] = true,
  ["set priority"] = true,
  ["set property"] = true,
  ["set scheduled"] = true,
  ["set deadline"] = true,
  refile = true,
  archive = true,
  export = true,
}

-- the same arguments give the same result (MCP's idempotentHint)
local IDEMPOTENT = {
  ["set todo"] = true,
  ["set tags"] = true,
  ["set priority"] = true,
  ["set property"] = true,
  ["set scheduled"] = true,
  ["set deadline"] = true,
  id = true,
  export = true,
}

--- The server's instructions to the agent (today's date added when sent).
M.INSTRUCTIONS = table
  .concat({
    "These tools read and change the user's Org mode files (org.nvim: Emacs Org mode for Neovim):",
    "their tasks (TODO headings), agenda, notes, clocks and capture templates.",
    "\n\nFinding things: agenda for what is on a day or week and the open TODO list; headlines to",
    "filter by TODO state, tags, properties and scheduled / deadline ranges; search for words;",
    "show for one heading's full content. templates, keywords and tags tell the user's setup:",
    "read keywords before setting a TODO state the user hasn't used.",
    "\n\nTargets: a tool that changes a heading takes a target. Every heading in a result has a",
    "`target` (id:ID, or FILE:LINE) to pass back as it is; title words or FILE::TITLE work too.",
    "FILE:LINE targets of a file go stale once a write adds or removes lines above them, so after",
    "a write use the targets of its result or look the heading up again (or make an id: with",
    "id create=true before several edits). When several headings match (error ambiguous), pick",
    "one of details.candidates by its target.",
    "\n\nDates (date, scheduled, deadline, FROM..TO) read like Org's date prompt: 2026-10-20,",
    "today, tomorrow, fri, +3 (days), +2w, '2026-10-20 14:00', '14:00-15:30'.",
    "\n\nResults are JSON with empty and null fields left out. A failed call is an error result",
    "{ error, message, details }. file_busy: the user has unsaved changes to that file in Neovim;",
    "ask them to save it, then retry. input_needed: a capture template prompts for",
    "details.prompt; give it in field as NAME=VALUE.",
    "\n\nThese are the user's own notes: before changing or moving entries they didn't ask about,",
    "say what you will do. Prefer capture for new inbox items and add to put a heading under a",
    "given parent.",
  }, " ")
  :gsub(" \n\n", "\n\n")

--- Descriptions of the tools for an agent: what each is for and when to
--- use it (the command's summary when missing).
M.DESCRIPTIONS = {
  agenda = "The agenda. view day / week / fortnight / month / year (default: the configured span from"
    .. " today, or from date) lists what is scheduled, due or happening, overdue items included;"
    .. " view todo lists the open TODO entries (arg: one keyword); view tags or tags-todo lists"
    .. ' the headings matching arg (+work-boss, PRIORITY="A"); a letter runs one of the user\'s'
    .. " custom agenda commands. Start here for 'what do I have today / this week'.",
  search = "Find headings by the words in their title or body (agenda search syntax: +word -word,"
    .. ' {regexp}, "a phrase"), or by a tags/property match. Results are capped (see limit).',
  headlines = "List headings by structure: TODO state (todo: a keyword, open, done, any or none),"
    .. " tags, properties, outline level, a scheduled or deadline range (FROM..TO, either side"
    .. " optional: ..today is due by today) and file. Results are capped (see limit).",
  show = "Everything about one heading: its planning, properties, effort, clock entries and"
    .. " totals, timestamps and body text, and with children=true its sub-headings. Read an entry"
    .. " here before changing it.",
  id = "The ID of a heading; create=true gives it one. An id: target keeps working when the"
    .. " heading moves or lines change.",
  clock_status = "The running clock: what is being timed, since when, the time so far and the effort.",
  clock_in = "Start the clock on a heading (clocking out of a running one first).",
  clock_out = "Stop the running clock, recording the time in the heading's logbook.",
  clock_cancel = "Cancel the running clock, recording nothing.",
  templates = "The user's capture templates: key, description, type and target. Read them to"
    .. " choose capture's template.",
  files = "The agenda files: path, title, category and number of headings.",
  tags = "The tags used in the agenda files (with counts) and those defined in the configuration.",
  keywords = "The TODO keyword sequences (which states are open and which done) and the priority"
    .. " range. Read them before set_todo or add with a keyword the user hasn't used.",
  capture = "Capture with one of the user's capture templates, as they do in Neovim: text fills"
    .. " its %? (or %i), field answers its prompts, and it goes where the template files it"
    .. " (often an inbox). Without template: the default one. Use add instead to put a heading"
    .. " under a parent you choose.",
  ["set_todo"] = "Set a heading's TODO state (none removes it). DONE (or another done keyword)"
    .. " completes it as Org does: logging, and a repeating task moves to its next date instead.",
  ["set_tags"] = 'Replace a heading\'s tags (tags: a:b or a,b; "" clears them), or add / remove'
    .. " some and keep the rest.",
  ["set_priority"] = "Set a heading's priority (A, B, C, ...; none removes it).",
  ["set_property"] = "Set a property of a heading's PROPERTIES drawer, or delete it.",
  ["set_scheduled"] = "Schedule a heading: the day (and time) to start working on it. none removes it.",
  ["set_deadline"] = "Set a heading's deadline: the day it is due. none removes it.",
  note = "Add a timestamped note to a heading's logbook. To add text to its body, use append.",
  refile = "Move a heading, with its sub-headings, under another heading (destination: a"
    .. " target) or to the top level of a file (destination: the file).",
  archive = "Archive a heading as the user has archiving set up (by default: into the archive file).",
  export = "Export an Org file to html, md, latex, pdf, ascii, odt, ... (written next to it, or to"
    .. " output), or with stdout=true return the text.",
  add = "Add a new heading under a parent heading (last child, or first with first=true) or at"
    .. " the end of a file, with an optional TODO keyword, tags, priority, dates, properties and body.",
  append = "Add text to the end of a heading's body (after its planning and drawers, before its" .. " sub-headings).",
  ["set_title"] = "Change a heading's title, keeping its TODO keyword, priority and tags.",
}

--- How many headings `search` and `headlines` return when the call gives
--- no limit; more matches are cut, and the result says so.
M.LIST_LIMIT = 50

--- Does the command change files (export writes its output file)?
local function writes(c)
  return c.writes or c.name == "export"
end

--- The flags of a command its tool takes.
local function tool_flags(c)
  local out = {}
  for _, k in ipairs(c.flags or {}) do
    if not HIDDEN_FLAGS[k] then
      out[#out + 1] = k
    end
  end
  return out
end

--- The tool's name: the command's words joined by `_` (set_todo).
local function tool_name(c)
  return (c.name:gsub(" ", "_"))
end

--- Tool name -> command (schema.COMMANDS entry).
local BY_TOOL = {}
for _, c in ipairs(schema.COMMANDS) do
  if not NOT_TOOLS[c.name] then
    BY_TOOL[tool_name(c)] = c
  end
end

--- The MCP tool definition of a command.
---@param c table a schema.COMMANDS entry
---@return table
function M.tool(c)
  local input = schema.input_schema(c)
  for k in pairs(HIDDEN_FLAGS) do
    input.properties[k] = nil
  end
  for k, p in pairs(input.properties) do
    -- the command line's "--flag: " and stdin are no use to an agent
    p.description = p.description:gsub("^%-%-[%w-]+: ", ""):gsub(';? ?"%-" reads stdin', "")
    if k == "limit" then
      p.description = p.description .. " (default " .. M.LIST_LIMIT .. ")"
    end
  end
  if #input.required == 0 then
    input.required = nil
  end
  local w = writes(c)
  return {
    name = tool_name(c),
    description = M.DESCRIPTIONS[tool_name(c)] or c.summary,
    inputSchema = input,
    annotations = {
      readOnlyHint = not w,
      destructiveHint = w and DESTRUCTIVE[c.name] or false,
      idempotentHint = not w or IDEMPOTENT[c.name] or false,
      openWorldHint = false,
    },
  }
end

--- The tools a server lists: every command's, without those that write
--- when `read_only`.
---@param read_only boolean
---@return table[]
function M.tools(read_only)
  local out = {}
  for _, c in ipairs(schema.COMMANDS) do
    if not NOT_TOOLS[c.name] and not (read_only and writes(c)) then
      out[#out + 1] = M.tool(c)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Tool arguments -> command line
---------------------------------------------------------------------------

local BadArgs = {}

--- An error in the arguments of a tool call: the call's result says so
--- (isError), for the agent to correct.
local function bad(msg)
  error(setmetatable({ msg = msg }, BadArgs), 0)
end

local function word(v, name)
  local t = type(v)
  if t == "string" then
    return v
  elseif t == "number" then
    return v == math.floor(v) and string.format("%d", v) or tostring(v)
  end
  bad(name .. " must be a string, not " .. (v == vim.NIL and "null" or t))
end

--- The words of a value: a list gives one word per item.
local function words_of(v, name)
  if type(v) == "table" then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = word(x, name)
    end
    return out
  end
  return { word(v, name) }
end

local function given(v)
  return v ~= nil and v ~= vim.NIL
end

--- The `org` arguments of a call of command `c`'s tool with `args`
--- (after the global ones): the command's words, its flags and, after
--- `--`, its arguments in order. A command with `--limit` the call
--- doesn't give gets `LIST_LIMIT` + 1, and the cap (`LIST_LIMIT`) is the
--- second result: a result longer than it was cut.
---@param c table a schema.COMMANDS entry
---@param args table|nil the call's `arguments`
---@return string[] argv
---@return integer? cap
function M.argv(c, args)
  if not given(args) then
    args = {}
  end
  if type(args) ~= "table" or (vim.islist(args) and next(args) ~= nil) then
    bad("arguments must be an object")
  end
  ---@cast args table
  local props = M.tool(c).inputSchema.properties
  local unknown = {}
  for k in pairs(args) do
    if not props[k] then
      unknown[#unknown + 1] = tostring(k)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    local known = vim.tbl_keys(props)
    table.sort(known)
    bad(
      string.format(
        "%s takes no argument %s (it takes %s)",
        tool_name(c),
        table.concat(unknown, ", "),
        #known > 0 and table.concat(known, ", ") or "none"
      )
    )
  end
  local argv = vim.split(c.name, " ")
  local cap
  for _, k in ipairs(tool_flags(c)) do
    local v = args[k]
    local f = schema.flag(c, k)
    if k == "limit" and not given(v) then
      v, cap = M.LIST_LIMIT + 1, M.LIST_LIMIT
    end
    local name = f.names[#f.names]
    if given(v) then
      if not f.value then
        if type(v) ~= "boolean" then
          bad(k .. " must be true or false")
        end
        if v then
          argv[#argv + 1] = name
        end
      else
        local ws = words_of(v, k)
        if #ws > 1 and not f.repeatable then
          bad(k .. " takes one value")
        end
        for _, w in ipairs(ws) do
          argv[#argv + 1] = name
          argv[#argv + 1] = w
        end
      end
    end
  end
  argv[#argv + 1] = "--"
  local missing
  for _, a in ipairs(c.args or {}) do
    local v = args[a.name]
    if not given(v) then
      if a.required then
        bad("missing argument " .. a.name)
      end
      missing = missing or a.name
    else
      if missing then
        bad(a.name .. " needs " .. missing .. " too")
      end
      local ws = words_of(v, a.name)
      if #ws > 1 and not a.variadic then
        bad(a.name .. " takes one string")
      end
      for _, w in ipairs(ws) do
        if w == "-" then
          bad('"-" (standard input) is not available to a tool; give the text itself')
        end
        argv[#argv + 1] = w
      end
    end
  end
  return argv, cap
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

-- keys whose value is a path: shortened to ~/... under the home directory
-- (targets read it back)
local PATH_KEYS = { file = true, archive_file = true, output = true }

-- false is what these say when left out
local DROP_FALSE = { archived = true, commented = true, done = true, repeated = true, created = true, canceled = true }

-- lists kept when empty: the result's main list
local KEEP_EMPTY = { items = true }

--- `p` with the home directory written as ~.
---@param p string
---@return string
local function short_path(p)
  local home = vim.uv.os_homedir()
  home = home and vim.fs.normalize(home) or nil
  if home and home ~= "/" and p:sub(1, #home + 1) == home .. "/" then
    return "~" .. p:sub(#home + 1)
  end
  return p
end

--- `v` (decoded JSON) for an agent to read: nulls, empty lists and objects
--- and false flags left out, timestamps as their Org text and ISO start /
--- end, paths under the home directory as ~/..., and every heading (an
--- object with file, line and level) given the `target` that names it.
---@param v any
---@param key? string|integer the key `v` is under
---@return any nil when there is nothing to say
function M.compact(v, key)
  if v == vim.NIL then
    return nil
  elseif type(v) == "string" then
    return PATH_KEYS[key] and short_path(v) or v
  elseif type(v) == "boolean" then
    if v == false and DROP_FALSE[key] then
      return nil
    end
    return v
  elseif type(v) ~= "table" then
    return v
  end
  if vim.islist(v) and (next(v) ~= nil or getmetatable(v) ~= getmetatable(vim.empty_dict())) then
    local out = {}
    for _, x in ipairs(v) do
      out[#out + 1] = M.compact(x)
    end
    if #out == 0 and not KEEP_EMPTY[key] and key ~= nil then
      return nil
    end
    return out
  end
  if type(v.raw) == "string" and v.start ~= nil and v.active ~= nil then
    -- a timestamp: the raw text says the rest
    return { raw = v.raw, start = M.compact(v.start), ["end"] = M.compact(v["end"]) }
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = M.compact(x, k)
  end
  if out.raw_title == out.title then
    out.raw_title = nil
  end
  if out.local_tags and vim.deep_equal(out.local_tags, out.tags) then
    out.local_tags = nil
  end
  if type(v.clock) == "table" and v.clock.count == 0 and not v.clock.running then
    out.clock = nil
  end
  if type(v.type) == "string" and v.date ~= nil and type(v.text) == "string" then
    -- an agenda item: its agenda line says what the other fields say
    out.text = nil
  end
  if type(v.file) == "string" and type(v.line) == "number" and v.level ~= nil then
    out.target = type(v.id) == "string" and ("id:" .. v.id) or (short_path(v.file) .. ":" .. v.line)
  end
  if next(out) == nil and key ~= nil then
    return nil
  end
  return next(out) == nil and vim.empty_dict() or out
end

--- The tools/call result of `env`, the JSON envelope of a run: its data
--- (cut to `cap` items), or its error, compacted.
---@param env table
---@param cap? integer
---@return table
function M.result(env, cap)
  local content = {}
  local function add(v)
    content[#content + 1] = { type = "text", text = type(v) == "string" and v or vim.json.encode(v) }
  end
  if env.ok ~= true then
    local e = type(env.errors) == "table" and env.errors[1] or {}
    add(M.compact({ error = e.code or "failed", message = e.message, details = e.details }))
  else
    local data = env.data
    local cut = cap and type(data) == "table" and vim.islist(data) and #data > cap
    if cut then
      data = vim.list_slice(data, 1, cap)
    end
    local out = M.compact(data)
    if out == nil then
      out = vim.empty_dict()
    end
    add(out)
    if cut then
      add(string.format("Only the first %d results are shown and more match: narrow the query, or give limit.", cap))
    end
  end
  if type(env.warnings) == "table" and #env.warnings > 0 then
    add("Warnings: " .. table.concat(vim.tbl_map(tostring, env.warnings), "; "))
  end
  return { content = content, isError = env.ok ~= true }
end

---------------------------------------------------------------------------
-- Running a tool
---------------------------------------------------------------------------

local MAIN = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")) .. "/main.lua"

local function text_result(text, is_error)
  return { content = { { type = "text", text = text } }, isError = is_error or false }
end

--- Run `org` with `argv` in a new Neovim: its result as a tools/call
--- result (a list cut to `cap`).
---@param server table
---@param argv string[]
---@param cap? integer
---@return table
local function run_org(server, argv, cap)
  local cmd = { vim.v.progpath, "--headless", "-l", MAIN }
  vim.list_extend(cmd, server.global_argv)
  vim.list_extend(cmd, argv)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(M.TIMEOUT)
  end)
  if not ok then
    return text_result("could not start Neovim: " .. tostring(res), true)
  end
  local stdout = vim.trim(res.stdout or "")
  local stderr = vim.trim(res.stderr or "")
  if stderr ~= "" and server.verbose then
    run.stderr(stderr .. "\n")
  end
  local dok, env = pcall(vim.json.decode, stdout)
  if not dok or type(env) ~= "table" or env.ok == nil then
    local why = res.code == 124 and ("timed out after " .. M.TIMEOUT / 1000 .. " s")
      or ("exit code " .. tostring(res.code))
    return text_result("org failed (" .. why .. "): " .. (stderr ~= "" and stderr or stdout), true)
  end
  return M.result(env, cap)
end

---------------------------------------------------------------------------
-- JSON-RPC
---------------------------------------------------------------------------

local RpcError = {}

local function rpc_error(code, message)
  error(setmetatable({ code = code, message = message }, RpcError), 0)
end

local METHODS = {}

function METHODS.initialize(_, params)
  local asked = type(params) == "table" and params.protocolVersion or nil
  local version = vim.tbl_contains(M.PROTOCOLS, asked) and asked or M.PROTOCOLS[1]
  return {
    protocolVersion = version,
    capabilities = { tools = { listChanged = false }, prompts = { listChanged = false } },
    serverInfo = { name = "org.nvim", title = "org.nvim", version = require("org.version").release },
    instructions = M.INSTRUCTIONS .. "\n\nToday is " .. os.date("%Y-%m-%d %A") .. ".",
  }
end

function METHODS.ping()
  return vim.empty_dict()
end

METHODS["tools/list"] = function(server)
  return { tools = M.tools(server.read_only) }
end

METHODS["tools/call"] = function(server, params)
  local name = type(params) == "table" and params.name or nil
  if type(name) ~= "string" then
    rpc_error(-32602, "tools/call needs the name of a tool")
  end
  local c = BY_TOOL[name]
  if not c then
    rpc_error(-32602, "Unknown tool: " .. name)
  end
  if server.read_only and writes(c) then
    return text_result(
      name .. " changes files, and this server is read-only (org mcp --read-only, extensions.cli.mcp.read_only)",
      true
    )
  end
  local ok, argv, cap = pcall(M.argv, c, params.arguments)
  if not ok then
    if getmetatable(argv) == BadArgs then
      ---@cast argv { msg: string }
      return text_result(argv.msg, true)
    end
    error(argv, 0)
  end
  return run_org(server, argv, cap)
end

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------

--- Prompts the server offers (MCP prompts; a client shows them as slash
--- commands): name -> { title, description, text }.
M.PROMPTS = {
  {
    name = "plan_day",
    title = "Plan my day",
    description = "Review today's agenda, deadlines and open tasks, and propose a plan for the day",
    text = table.concat({
      "Help me plan today with my Org files.",
      "Use agenda (view day) for what is scheduled, due or overdue today, clock_status for a running",
      "clock, and agenda (view todo) or headlines (todo open) for the other open tasks.",
      "Then give me: the fixed appointments with their times; what is overdue or due soon;",
      "and a short, realistic plan for the rest of the day, most important first, using efforts",
      "where they are set. Ask before changing anything (rescheduling, marking done).",
    }, " "),
  },
  {
    name = "weekly_review",
    title = "Weekly review",
    description = "A GTD-style weekly review: last week's results, the coming week, stalled and stale tasks",
    text = table.concat({
      "Walk me through a weekly review of my Org files.",
      "Look at the agenda for the coming week (view week), deadlines in the next two weeks",
      "(headlines with deadline ..+14), the open tasks (headlines todo open), the tasks done",
      "recently, and the inbox (the targets of my capture templates).",
      "Report: what got done; what is coming up; overdue or long-scheduled tasks to reschedule,",
      "drop or break down; inbox items still to process; projects without a next action.",
      "Propose the changes as a list and make them only once I agree.",
    }, " "),
  },
  {
    name = "triage_inbox",
    title = "Triage my inbox",
    description = "Go through the captured items and propose where each belongs",
    arguments = {
      { name = "file", description = "the inbox file (default: where the capture templates file entries)" },
    },
    text = table.concat({
      "Help me empty my Org inbox%s.",
      "Read the capture templates to find the inbox if none is given, list its headings, and",
      "look at my files and projects (files, headlines) to know where things go.",
      "For each item propose one action: refile under a heading (name it), schedule or give a",
      "deadline, set a TODO keyword, tags or priority, archive it, or leave it.",
      "Show the proposal as a table, wait for my changes, then carry it out with the tools.",
    }, " "),
  },
}

local PROMPT_BY_NAME = {}
for _, p in ipairs(M.PROMPTS) do
  PROMPT_BY_NAME[p.name] = p
end

METHODS["prompts/list"] = function()
  return {
    prompts = vim.tbl_map(function(p)
      return { name = p.name, title = p.title, description = p.description, arguments = p.arguments }
    end, M.PROMPTS),
  }
end

METHODS["prompts/get"] = function(_, params)
  local name = type(params) == "table" and params.name or nil
  local p = type(name) == "string" and PROMPT_BY_NAME[name] or nil
  if not p then
    rpc_error(-32602, "Unknown prompt: " .. tostring(name))
  end
  ---@cast p -nil
  local args = type(params.arguments) == "table" and params.arguments or {}
  local text = p.text
  if text:find("%s", 1, true) then
    local file = type(args.file) == "string" and args.file ~= "" and (" (" .. args.file .. ")") or ""
    text = text:format(file)
  end
  return {
    description = p.description,
    messages = { { role = "user", content = { type = "text", text = text } } },
  }
end

-- notifications the server takes and does nothing with
for _, n in ipairs({ "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed" }) do
  METHODS[n] = function() end
end

local function response(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

local function error_response(id, code, message)
  return { jsonrpc = "2.0", id = id == nil and vim.NIL or id, error = { code = code, message = message } }
end

--- The response to one decoded message, or nil (a notification, or a
--- response to a request of ours).
local function handle(server, msg)
  if type(msg) ~= "table" or vim.islist(msg) then
    return error_response(nil, -32600, "Invalid Request")
  end
  local id = msg.id
  local notification = id == nil
  if type(msg.method) ~= "string" then
    if msg.result ~= nil or msg.error ~= nil then
      return nil
    end
    return error_response(id, -32600, "Invalid Request")
  end
  local h = METHODS[msg.method]
  if not h then
    if notification then
      return nil
    end
    return error_response(id, -32601, "Method not found: " .. msg.method)
  end
  local params = msg.params
  if params == vim.NIL then
    params = nil
  end
  local ok, result = pcall(h, server, params)
  if notification then
    return nil
  end
  if not ok then
    if getmetatable(result) == RpcError then
      return error_response(id, result.code, result.message)
    end
    return error_response(id, -32603, "Internal error: " .. tostring(result))
  end
  return response(id, result)
end

--- The reply to one line of input (a message or a batch of them), as a
--- line of JSON, or nil.
---@param server table
---@param line string
---@return string|nil
function M.handle_line(server, line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok then
    return vim.json.encode(error_response(nil, -32700, "Parse error"))
  end
  if type(msg) == "table" and vim.islist(msg) then
    if #msg == 0 then
      return vim.json.encode(error_response(nil, -32600, "Invalid Request"))
    end
    local out = {}
    for _, m in ipairs(msg) do
      out[#out + 1] = handle(server, m)
    end
    return #out > 0 and vim.json.encode(out) or nil
  end
  local reply = handle(server, msg)
  return reply and vim.json.encode(reply) or nil
end

--- A server for the flags `org mcp` got: the global arguments every tool
--- call passes on, and whether it is read-only.
---@param flags table
---@return { global_argv: string[], read_only: boolean, verbose: boolean }
function M.server(flags)
  local g = { "--json" }
  if flags.config then
    vim.list_extend(g, { "--config", run.arg_path(flags.config) })
  end
  for _, f in ipairs(flags.files or {}) do
    vim.list_extend(g, { "--files", run.arg_path(f) })
  end
  if flags.dir then
    vim.list_extend(g, { "--dir", run.arg_path(flags.dir) })
  end
  if flags.no_server then
    g[#g + 1] = "--no-server"
  end
  local opts = shared.cli_opts().mcp or {}
  return {
    global_argv = g,
    read_only = flags.read_only or opts.read_only or false,
    verbose = flags.verbose or false,
  }
end

--- Where the server reads its input; specs replace it.
M.read_line = function()
  return io.stdin:read("*l")
end

--- `org mcp`: answer the messages on stdin until it closes.
function M.cmd_mcp(_, flags)
  if state.session then
    fail("org mcp runs from a shell or an MCP client, not in a running Neovim", "usage")
  end
  if state.machine then
    fail("org mcp speaks JSON-RPC on stdout: it takes no --json or --jsonl", "usage")
  end
  local server = M.server(flags)
  -- nothing but the protocol on stdout
  local restore = run.protocol_stdout()
  local ok, e = pcall(function()
    while true do
      local line = M.read_line()
      if line == nil then
        break
      end
      line = line:gsub("\r$", "")
      if line:match("%S") then
        local reply = M.handle_line(server, line)
        if reply then
          run.stdout(reply .. "\n")
          io.stdout:flush()
        end
      end
    end
  end)
  restore()
  if not ok then
    error(e, 0)
  end
  return { text = {} }
end

return M
