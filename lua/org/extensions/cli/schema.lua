---@mod org.extensions.cli.schema Commands, flags and output schemas of `org`
---
--- One description of the command line serves three purposes: the
--- argument parser takes its flags from `M.FLAGS`, each command accepts
--- only the flags listed for it, and `org schema` (or `org help --json`)
--- prints the whole description for scripts and AI agents (`input_schema`
--- of a command is a JSON Schema of its arguments, ready for a tool
--- definition).

local M = {}

--- Version of the JSON output (`version` of every envelope). Bumped only
--- when a key is removed or changes meaning; new keys can appear any time.
M.VERSION = 1

local function obj(props, required)
  local p = vim.empty_dict()
  for k, v in pairs(props) do
    p[k] = v
  end
  if not required then
    required = vim.tbl_keys(props)
    table.sort(required)
  end
  return { type = "object", properties = p, required = required }
end

local function ref(name)
  return { ["$ref"] = "#/$defs/" .. name }
end

local function arr(items)
  return { type = "array", items = items }
end

local function nullable(t)
  return { anyOf = { t, { type = "null" } } }
end

local S = { type = "string" }
local I = { type = "integer" }
local B = { type = "boolean" }
local NS = nullable(S)
local NI = nullable(I)

---------------------------------------------------------------------------
-- Flags
---------------------------------------------------------------------------

--- Every flag: `key` (the parsed name), `names`, `value` (the placeholder
--- of a flag taking a value), `type`, `repeatable`, `global`, `desc`.
M.FLAGS = {
  { key = "config", names = { "--config" }, value = "FILE", global = true, desc = "configuration file (Lua)" },
  {
    key = "files",
    names = { "--files" },
    value = "GLOB",
    repeatable = true,
    global = true,
    desc = "agenda files, replacing agenda_files (comma-separated or repeated)",
  },
  { key = "dir", names = { "--dir" }, value = "DIR", global = true, desc = "org_directory" },
  { key = "json", names = { "--json" }, global = true, desc = "JSON output: one envelope object" },
  { key = "jsonl", names = { "--jsonl" }, global = true, desc = "JSON lines: one object per result" },
  { key = "quiet", names = { "-q", "--quiet" }, global = true, desc = "no warnings on stderr" },
  { key = "verbose", names = { "-v", "--verbose" }, global = true, desc = "also org.nvim's messages on stderr" },
  { key = "help", names = { "-h", "--help" }, global = true, desc = "usage" },
  { key = "version", names = { "--version" }, global = true, desc = "the org.nvim version" },
  { key = "date", names = { "--date" }, value = "DATE", desc = "start date (2026-10-01, +1, fri, ...)" },
  { key = "span", names = { "--span" }, value = "N", desc = "days shown, or day/week/month/year" },
  { key = "csv", names = { "--csv" }, desc = "CSV output (org-batch-agenda-csv)" },
  { key = "template", names = { "-t", "--template" }, value = "KEY", desc = "capture template key" },
  { key = "list", names = { "--list" }, desc = "list the capture templates" },
  {
    key = "field",
    names = { "--field" },
    value = "NAME=VALUE",
    repeatable = true,
    desc = "answer of the template prompt NAME (%^{NAME}, %^{NAME}p, Tags for %^g, a date prompt)",
  },
  {
    key = "input",
    names = { "--input" },
    value = "FILE",
    desc = 'JSON object { "template", "text", "fields" } (FILE - reads stdin)',
  },
  { key = "id", names = { "--id" }, desc = "give the captured entry an ID" },
  { key = "short", names = { "--short" }, desc = "the clock in status_format" },
  { key = "format", names = { "--format" }, value = "FMT", desc = "clock format: %t %e %T %E %f %s" },
  { key = "pick", names = { "--pick" }, value = "N", type = "integer", desc = "take the Nth of several matches" },
  { key = "match", names = { "--match" }, value = "MATCH", desc = 'tags/property match (+work-boss, PRIO="A")' },
  {
    key = "todo",
    names = { "--todo" },
    value = "KW",
    repeatable = true,
    desc = "TODO keyword, or any, open (not done), done, none",
  },
  { key = "tag", names = { "--tag" }, value = "TAG", repeatable = true, desc = "has the tag (inherited too)" },
  {
    key = "property",
    names = { "--property" },
    value = "NAME=VALUE",
    repeatable = true,
    desc = "property equals VALUE (NAME alone: has the property)",
  },
  { key = "level", names = { "--level" }, value = "N", desc = "outline level, or a range 1..2" },
  {
    key = "scheduled",
    names = { "--scheduled" },
    value = "RANGE",
    desc = "scheduled within FROM..TO (either side optional), or any, none",
  },
  { key = "deadline", names = { "--deadline" }, value = "RANGE", desc = "deadline within FROM..TO, or any, none" },
  {
    key = "file",
    names = { "--file" },
    value = "FILE",
    repeatable = true,
    desc = "only this agenda file (path, name or name without .org)",
  },
  { key = "limit", names = { "--limit" }, value = "N", type = "integer", desc = "at most N results" },
  { key = "archived", names = { "--archived" }, desc = "include archived and commented entries" },
  { key = "children", names = { "--children" }, desc = "include the child entries" },
  { key = "create", names = { "--create" }, desc = "create the ID when there is none" },
  { key = "note", names = { "--note" }, value = "TEXT", desc = "text of a log note the change records" },
  { key = "add", names = { "--add" }, value = "TAG", repeatable = true, desc = "add a tag" },
  { key = "remove", names = { "--remove" }, value = "TAG", repeatable = true, desc = "remove a tag" },
  { key = "delete", names = { "--delete" }, desc = "delete the property" },
  {
    key = "force",
    names = { "--force" },
    desc = "write even when a running Neovim has unsaved changes in the file",
  },
  { key = "output", names = { "-o", "--output" }, value = "FILE", desc = "export to FILE" },
  { key = "stdout", names = { "--stdout" }, desc = "export to stdout" },
}

M.BY_NAME = {}
M.BY_KEY = {}
for _, f in ipairs(M.FLAGS) do
  M.BY_KEY[f.key] = f
  for _, n in ipairs(f.names) do
    M.BY_NAME[n] = f
  end
end

---------------------------------------------------------------------------
-- Types of the output
---------------------------------------------------------------------------

M.DEFS = {
  Timestamp = obj({
    raw = S,
    date = S,
    time = NS,
    end_time = NS,
    start = S,
    ["end"] = NS,
    active = B,
    repeater = NS,
    warning = NS,
  }),
  Headline = obj({
    file = S,
    line = I,
    end_line = I,
    level = I,
    id = NS,
    custom_id = NS,
    todo = NS,
    todo_type = nullable({ enum = { "todo", "done" } }),
    priority = NS,
    title = S,
    raw_title = S,
    tags = arr(S),
    local_tags = arr(S),
    category = NS,
    outline_path = arr(S),
    scheduled = nullable(ref("Timestamp")),
    deadline = nullable(ref("Timestamp")),
    closed = nullable(ref("Timestamp")),
    archived = B,
    commented = B,
  }),
  Entry = {
    allOf = {
      ref("Headline"),
      obj({
        properties = { type = "object", additionalProperties = S },
        effort_minutes = NI,
        clock = obj({
          count = I,
          running = B,
          minutes = I,
          total = S,
          subtree_minutes = I,
          subtree_total = S,
          entries = arr(obj({
            start = ref("Timestamp"),
            ["end"] = nullable(ref("Timestamp")),
            minutes = NI,
            line = I,
          })),
        }),
        timestamps = arr(ref("Timestamp")),
        body = S,
        children = nullable(arr(ref("Entry"))),
      }),
    },
  },
  AgendaItem = obj({
    date = NS,
    time = NS,
    end_time = NS,
    type = NS,
    todo = NS,
    priority = NS,
    title = S,
    tags = arr(S),
    category = NS,
    file = NS,
    line = NI,
    id = NS,
    level = NI,
    timestamp = nullable(ref("Timestamp")),
    extra = NS,
    done = B,
    text = S,
  }),
  Clock = obj({
    active = B,
    title = NS,
    file = NS,
    line = NI,
    id = NS,
    start = NS,
    start_iso = NS,
    minutes = NI,
    elapsed = NS,
    total = NI,
    effort = NI,
  }, { "active" }),
  Change = obj({
    headline = ref("Headline"),
    field = S,
    old = vim.empty_dict(),
    new = vim.empty_dict(),
  }),
  Error = obj({
    code = { enum = {} },
    message = S,
    details = { type = "object" },
  }, { "code", "message" }),
}

---------------------------------------------------------------------------
-- Error codes and exit codes
---------------------------------------------------------------------------

--- Stable error codes and their exit codes.
M.ERRORS = {
  usage = { exit = 2, desc = "bad or missing arguments" },
  unknown_command = { exit = 2, desc = "no such command" },
  unknown_option = { exit = 2, desc = "no such option, or not one of this command" },
  bad_value = { exit = 2, desc = "a value that cannot be read or names nothing (date, keyword, template, file, ...)" },
  config = { exit = 2, desc = "the configuration file is missing or fails" },
  not_found = { exit = 1, desc = "no heading matches the target" },
  ambiguous = { exit = 1, desc = "several headings match: details.candidates, retry with --pick N" },
  no_clock = { exit = 1, desc = "no running clock" },
  failed = { exit = 1, desc = "org.nvim refused or failed (details.messages has its messages)" },
  internal = { exit = 1, desc = "an unexpected Lua error" },
  input_needed = { exit = 3, desc = "the command would have to ask (details.prompt names the question)" },
  file_busy = { exit = 4, desc = "a running Neovim has unsaved changes in the file (details.file); --force writes" },
}
do
  local codes = vim.tbl_keys(M.ERRORS)
  table.sort(codes)
  M.DEFS.Error.properties.code.enum = codes
end

M.EXIT_CODES = {
  ["0"] = "done",
  ["1"] = "failed, or nothing found in text mode (search, clock out without a clock)",
  ["2"] = "bad usage",
  ["3"] = "input needed",
  ["4"] = "file busy in a running Neovim",
}

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local TARGET = {
  name = "target",
  required = true,
  desc = "a heading: id:ID or an ID, FILE:LINE, FILE::TITLE, FILE::#CUSTOM_ID, or title words / an org-ql query",
}
-- a TARGET with nothing after it, which takes all the words
local TARGET_REST = vim.tbl_extend("force", TARGET, { rest = true })

local function change(field, value_schema)
  return {
    allOf = {
      ref("Change"),
      obj({ field = { const = field }, old = value_schema, new = value_schema }),
    },
  }
end

--- Every command: `name` (words), `summary`, `args`, `flags` (keys of
--- M.FLAGS besides the global ones), `writes`, `output` (schema of `data`)
--- and `jsonl` (schema of one `--jsonl` line, when the output is a list).
--- An argument is one word, except a last one that is `variadic` (a list
--- of words) or `rest` (free text: the remaining words, joined).
M.COMMANDS = {
  {
    name = "agenda",
    summary = "The agenda: a date span, the TODO list, a tags match or a custom command",
    args = {
      {
        name = "view",
        desc = "day, week, fortnight, month, year, todo [KW], tags MATCH, tags-todo MATCH or a custom command key",
      },
      { name = "arg", desc = "the keyword of todo, the match of tags" },
    },
    flags = { "date", "span", "csv" },
    output = obj({
      view = S,
      key = NS,
      start = NS,
      ["end"] = NS,
      items = arr(ref("AgendaItem")),
    }),
    jsonl = ref("AgendaItem"),
  },
  {
    name = "search",
    summary = "Headings matching words (agenda search syntax, or org-ql with ql) or a tags/property --match",
    args = { { name = "query", variadic = true, desc = "search words" } },
    flags = { "match", "limit" },
    output = arr(ref("Headline")),
    jsonl = ref("Headline"),
  },
  {
    name = "headlines",
    aliases = { "query" },
    summary = "Headings of the agenda files (or of FILEs) passing every filter",
    args = { { name = "files", variadic = true, desc = "org files to read instead of the agenda files" } },
    flags = { "todo", "tag", "property", "level", "scheduled", "deadline", "file", "match", "limit", "archived" },
    output = arr(ref("Headline")),
    jsonl = ref("Headline"),
  },
  {
    name = "show",
    summary = "The full data of one heading: properties, planning, clocks, body",
    args = { TARGET_REST },
    flags = { "children", "pick" },
    output = ref("Entry"),
  },
  {
    name = "id",
    summary = "The ID of a heading (--create makes one)",
    args = { TARGET_REST },
    flags = { "create", "pick", "force" },
    writes = true,
    output = obj({ id = NS, created = B, headline = ref("Headline") }),
  },
  {
    name = "clock status",
    summary = "The running clock",
    flags = { "short", "format" },
    output = ref("Clock"),
  },
  {
    name = "clock in",
    summary = "Clock in a heading",
    args = { TARGET_REST },
    flags = { "pick", "force" },
    writes = true,
    output = ref("Clock"),
  },
  {
    name = "clock out",
    summary = "Clock out of the running clock",
    flags = { "force" },
    writes = true,
    output = obj({ active = B, title = S, file = S, minutes = NI, duration = NS, canceled = B }),
  },
  {
    name = "clock cancel",
    summary = "Cancel the running clock (removes its CLOCK line)",
    flags = { "force" },
    writes = true,
    output = obj({ active = B, title = S, file = S, minutes = NI, duration = NS, canceled = B }),
  },
  {
    name = "templates",
    summary = "The capture templates",
    output = arr(obj({ key = S, description = S, type = NS, target = NS, group = B })),
    jsonl = obj({ key = S, description = S, type = NS, target = NS, group = B }),
  },
  {
    name = "files",
    summary = "The agenda files",
    output = arr(obj({ file = S, title = NS, category = NS, headlines = I })),
    jsonl = obj({ file = S, title = NS, category = NS, headlines = I }),
  },
  {
    name = "tags",
    summary = "Tags used in the agenda files and defined in the configuration",
    output = arr(obj({ name = S, count = I, defined = B })),
    jsonl = obj({ name = S, count = I, defined = B }),
  },
  {
    name = "keywords",
    summary = "TODO keyword sequences and the priority range",
    output = obj({
      sequences = arr(arr(obj({ name = S, done = B, key = NS }))),
      todo = arr(S),
      done = arr(S),
      priority = obj({ highest = S, lowest = S, default = S }),
    }),
  },
  {
    name = "capture",
    summary = "Capture TEXT with a template, without prompting",
    args = { { name = "text", variadic = true, desc = 'the text (in place of %? or %i); "-" reads stdin' } },
    flags = { "template", "field", "input", "id", "list", "force" },
    writes = true,
    output = obj({
      file = S,
      line = I,
      template = S,
      type = S,
      id = NS,
      headline = nullable(ref("Headline")),
    }),
  },
  {
    name = "set todo",
    summary = 'Set the TODO keyword ("" or none removes it)',
    args = { TARGET, { name = "state", required = true, desc = "a TODO keyword, or none" } },
    flags = { "note", "pick", "force" },
    writes = true,
    output = { allOf = { change("todo", NS), obj({ repeated = B }) } },
  },
  {
    name = "set tags",
    summary = "Set the tags (a:b or a,b; empty clears), or --add / --remove some",
    args = { TARGET, { name = "tags", desc = "the new tags" } },
    flags = { "add", "remove", "pick", "force" },
    writes = true,
    output = change("tags", arr(S)),
  },
  {
    name = "set priority",
    summary = 'Set the priority ("" or none removes it)',
    args = { TARGET, { name = "priority", required = true, desc = "A, B, C (or a number with #+PRIORITIES)" } },
    flags = { "pick", "force" },
    writes = true,
    output = change("priority", NS),
  },
  {
    name = "set property",
    summary = "Set a property (or --delete it)",
    args = {
      TARGET,
      { name = "name", required = true },
      { name = "value", rest = true, desc = "the value (not with --delete)" },
    },
    flags = { "delete", "pick", "force" },
    writes = true,
    output = change("property", NS),
  },
  {
    name = "set scheduled",
    summary = 'Set the SCHEDULED date ("" or none removes it)',
    args = {
      TARGET,
      {
        name = "date",
        required = true,
        rest = true,
        desc = "a date as the date prompt reads it, or a <...> timestamp",
      },
    },
    flags = { "note", "pick", "force" },
    writes = true,
    output = change("scheduled", nullable(ref("Timestamp"))),
  },
  {
    name = "set deadline",
    summary = 'Set the DEADLINE date ("" or none removes it)',
    args = {
      TARGET,
      {
        name = "date",
        required = true,
        rest = true,
        desc = "a date as the date prompt reads it, or a <...> timestamp",
      },
    },
    flags = { "note", "pick", "force" },
    writes = true,
    output = change("deadline", nullable(ref("Timestamp"))),
  },
  {
    name = "note",
    summary = 'Add a note to the logbook of a heading (TEXT "-" reads stdin)',
    args = { TARGET, { name = "text", required = true, variadic = true } },
    flags = { "pick", "force" },
    writes = true,
    output = change("note", NS),
  },
  {
    name = "refile",
    summary = "Move a heading under another heading, or to the top level of a file",
    args = { TARGET, { name = "destination", required = true, desc = "a heading (as TARGET) or an org file" } },
    flags = { "note", "pick", "force" },
    writes = true,
    output = obj({ headline = ref("Headline"), from = obj({ file = S, line = I }) }),
  },
  {
    name = "archive",
    summary = "Archive a heading (archive_default_command)",
    args = { TARGET_REST },
    flags = { "pick", "force" },
    writes = true,
    output = obj({
      title = S,
      from = obj({ file = S, line = I }),
      archive_file = NS,
      headline = nullable(ref("Headline")),
    }),
  },
  {
    name = "export",
    summary = "Export a file with a back-end (html, md, latex, pdf, ascii, ...)",
    args = { { name = "file", required = true }, { name = "backend", required = true } },
    flags = { "output", "stdout" },
    output = obj({ file = S, backend = S, output = NS, text = NS }),
  },
  {
    name = "schema",
    summary = "This description of the command line, as JSON",
    args = { { name = "command", variadic = true, desc = "only this command" } },
    output = { type = "object" },
  },
  {
    name = "help",
    summary = "Usage (with --json: the same as schema)",
    args = { { name = "command", variadic = true } },
    output = { type = "object" },
  },
  {
    name = "version",
    summary = "The org.nvim version",
    output = obj({ version = S }),
  },
}

M.BY_COMMAND = {}
for _, c in ipairs(M.COMMANDS) do
  M.BY_COMMAND[c.name] = c
  for _, a in ipairs(c.aliases or {}) do
    M.BY_COMMAND[a] = c
  end
end

--- Flags a command accepts (the global ones too).
---@return table<string, boolean>
function M.allowed(cmd)
  local ok = {}
  for _, f in ipairs(M.FLAGS) do
    if f.global then
      ok[f.key] = true
    end
  end
  for _, k in ipairs(cmd and cmd.flags or {}) do
    ok[k] = true
  end
  return ok
end

--- The most words a command takes, or nil when its last argument takes
--- all the remaining ones (`variadic` or `rest`).
---@return integer|nil
function M.max_words(cmd)
  local args = cmd.args or {}
  local last = args[#args]
  if last and (last.variadic or last.rest) then
    return nil
  end
  return #args
end

local function flag_doc(f)
  return {
    name = f.names[#f.names],
    aliases = #f.names > 1 and vim.list_slice(f.names, 1, #f.names - 1) or {},
    value = f.value or vim.NIL,
    repeatable = f.repeatable or false,
    description = f.desc,
  }
end

--- JSON Schema of a command's arguments (keys: args by name, flags by key).
local function input_schema(c)
  local props, required = vim.empty_dict(), {}
  for _, a in ipairs(c.args or {}) do
    local t = a.variadic and arr(S) or { type = "string" }
    props[a.name] = vim.tbl_extend("force", t, { description = a.desc or a.name })
    if a.required then
      required[#required + 1] = a.name
    end
  end
  for _, k in ipairs(c.flags or {}) do
    local f = M.BY_KEY[k]
    local t
    if not f.value then
      t = { type = "boolean" }
    elseif f.repeatable then
      t = arr(S)
    else
      t = { type = f.type or "string" }
    end
    t.description = f.names[#f.names] .. ": " .. f.desc
    props[k] = t
  end
  return { type = "object", properties = props, required = required }
end

local function usage_of(c)
  local parts = { "org", c.name }
  for _, a in ipairs(c.args or {}) do
    local n = a.name:upper() .. (a.variadic and "..." or "")
    parts[#parts + 1] = a.required and n or ("[" .. n .. "]")
  end
  for _, k in ipairs(c.flags or {}) do
    local f = M.BY_KEY[k]
    parts[#parts + 1] = "[" .. f.names[#f.names] .. (f.value and (" " .. f.value) or "") .. "]"
  end
  return table.concat(parts, " ")
end

local function command_doc(c)
  local flags = {}
  for _, k in ipairs(c.flags or {}) do
    flags[#flags + 1] = flag_doc(M.BY_KEY[k])
  end
  local args = {}
  for _, a in ipairs(c.args or {}) do
    args[#args + 1] = {
      name = a.name,
      required = a.required or false,
      variadic = a.variadic or false,
      description = a.desc or vim.NIL,
    }
  end
  return {
    name = c.name,
    aliases = c.aliases or {},
    summary = c.summary,
    usage = usage_of(c),
    args = args,
    flags = flags,
    writes = c.writes or false,
    input_schema = input_schema(c),
    output = c.output,
    jsonl = c.jsonl or vim.NIL,
  }
end

--- The description `org schema` prints (`only`: one command's name).
---@param only? string
---@return table|nil
function M.describe(only)
  local commands = {}
  for _, c in ipairs(M.COMMANDS) do
    if not only or c.name == only or vim.tbl_contains(c.aliases or {}, only) then
      commands[#commands + 1] = command_doc(c)
    end
  end
  if only and #commands == 0 then
    return nil
  end
  local globals = {}
  for _, f in ipairs(M.FLAGS) do
    if f.global then
      globals[#globals + 1] = flag_doc(f)
    end
  end
  local errors = vim.empty_dict()
  for k, v in pairs(M.ERRORS) do
    errors[k] = { exit = v.exit, description = v.desc }
  end
  return {
    name = "org",
    description = "org.nvim (Emacs Org mode for Neovim) from the shell. Every command takes --json "
      .. "(an envelope { version, ok, command, data, warnings, errors }) or --jsonl.",
    version = M.VERSION,
    targets = TARGET.desc,
    envelope = obj({
      version = I,
      ok = B,
      -- null for an error before a command is known (an unknown command
      -- or option, a flag without its value)
      command = NS,
      data = vim.empty_dict(),
      warnings = arr(S),
      errors = arr(ref("Error")),
    }),
    global_flags = globals,
    commands = commands,
    error_codes = errors,
    exit_codes = M.EXIT_CODES,
    ["$defs"] = M.DEFS,
  }
end

return M
