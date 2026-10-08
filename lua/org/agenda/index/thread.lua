---@mod org.agenda.index.thread The agenda index's worker side
---
--- The parse of a headline's parts and of its section (parser.LAZY_FIELDS),
--- made into the records the index keeps, either on the main thread or in
--- a worker thread (`agenda.index.threads`, vim.uv.new_work).
---
--- A worker thread's Lua state has only part of `vim` (vim.split,
--- vim.list_extend, vim.uv, ...: no vim.api, vim.fn or vim.regex), so this
--- module, and what the section parse reaches (org.parser, org.date,
--- org.todo_keywords), must not need more. The rest comes from the main
--- thread as plain data: the outline (the main thread finds it, with the
--- file's settings and their setup files), the file's TODO keywords and
--- the options the section parse reads (`log_into_drawer`,
--- `property_separators` without regexps).

local M = {}

-- Keys of the encoded headline records, sent as indices (string.buffer's
-- `dict`): part of the format, so of the index's signature.
M.DICT = {
  "_l",
  "_r",
  "active",
  "clocks",
  "commented",
  "date",
  "day",
  "drawers",
  "end",
  "end_col",
  "end_hour",
  "end_min",
  "first_inactive",
  "hour",
  "in_title",
  "line",
  "logbook",
  "min",
  "minutes",
  "month",
  "name",
  "planning",
  "planning_line",
  "priority",
  "properties",
  "properties_extend",
  "properties_range",
  "property_base",
  "range_end",
  "repeater",
  "start",
  "start_col",
  "tags",
  "timestamps",
  "title",
  "todo",
  "type",
  "unit",
  "value",
  "warning",
  "year",
  "closed",
  "deadline",
  "scheduled",
  "max",
}

local codec ---@type string.buffer|nil

--- The string.buffer that encodes headline records (dates keep their
--- metatable). One per Lua state: the worker's dates have the worker's
--- metatable, decoded as the main thread's.
---@return string.buffer
function M.codec()
  if not codec then
    codec = require("string.buffer").new({ metatable = { require("org.date").Date }, dict = M.DICT })
  end
  return codec
end

--- Lines of a file's contents, as from the disk (utils.split_content).
---@param content string
---@return string[]
function M.split_content(content)
  -- a UTF-8 byte order mark is not text (Vim's 'bomb', Emacs's
  -- utf-8-with-signature): a file read from disk must parse like its buffer
  if content:sub(1, 3) == "\239\187\191" then
    content = content:sub(4)
  end
  content = content:gsub("\r\n", "\n")
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Parse all of each headline (what parse left to be parsed on first use)
--- and return their records: the headline's line and text, and its
--- LAZY_FIELDS.
---@param headlines org.Headline[]
---@return table[]
function M.records(headlines)
  local parser = require("org.parser")
  local fields = parser.LAZY_FIELDS
  local recs = {}
  for i, hl in ipairs(headlines) do
    parser.load_all(hl)
    local r = { _l = rawget(hl, "line"), _r = rawget(hl, "raw") }
    for _, k in ipairs(fields) do
      r[k] = rawget(hl, k)
    end
    recs[i] = r
  end
  return recs
end

---@class org.agenda.index.Job
---@field outline integer[] each headline's line, body_end and section end (parser.section_to), in turn
---@field min_inline integer|nil the file's inlinetask_min_level
---@field todo string[] the file's TODO keywords
---@field log_drawer string the file's log drawer, upper-cased
---@field opts table the options the section parse reads

--- What a worker needs to parse `file` (just parsed on the main thread,
--- its outline only), encoded; nil when it can't be parsed in a worker
--- (a property separator given as a regexp: vim.regex is not there).
---@param file org.File
---@param cfg table org.config.opts
---@return string|nil
function M.job(file, cfg)
  local seps = cfg.property_separators or {}
  for _, spec in ipairs(seps) do
    if type(spec) ~= "table" or type(spec[1]) ~= "table" then
      return nil
    end
  end
  local outline = {}
  for _, hl in ipairs(file.headlines) do
    outline[#outline + 1] = rawget(hl, "line")
    outline[#outline + 1] = rawget(hl, "body_end")
    outline[#outline + 1] = require("org.parser").section_to(hl)
  end
  local todo = file.settings and file.settings.todo
  return require("string.buffer").encode({
    outline = outline,
    todo = todo and todo:names() or {},
    log_drawer = file._log_drawer,
    min_inline = file._min_inline,
    opts = { property_separators = seps },
  })
end

--- The TODO keywords of the file, as the headline line parse uses them.
---@param names string[]
local function keywords(names)
  local set = {}
  for _, n in ipairs(names) do
    set[n] = true
  end
  return {
    is_keyword = function(_, name)
      return name ~= nil and set[name] ~= nil
    end,
  }
end

--- The worker's side: parse the headlines of `data` (a file's contents)
--- as `job` (M.job) says, and return their records, encoded.
---@param data string
---@param job string
---@return string
function M.run(data, job)
  local sbuf = require("string.buffer")
  local j = sbuf.decode(job)
  -- org.config can't load here: the options come from the main thread.
  -- org.keywords (file settings, read on the main thread) isn't needed.
  package.loaded["org.config"] = { opts = j.opts }
  package.loaded["org.keywords"] = package.loaded["org.keywords"] or {}
  local parser = require("org.parser")
  local lines = M.split_content(data)
  local file = {
    lines = lines,
    settings = { todo = keywords(j.todo) },
    _log_drawer = j.log_drawer,
    _min_inline = j.min_inline,
  }
  local headlines = {}
  local outline = j.outline
  for i = 1, #outline, 3 do
    local l = outline[i]
    headlines[#headlines + 1] = setmetatable({
      file = file,
      line = l,
      raw = lines[l],
      body_end = outline[i + 1],
      _section_to = outline[i + 2],
      _lazy_head = true,
      _lazy_section = true,
    }, parser.Headline)
  end
  return M.codec():reset():encode(M.records(headlines)):tostring()
end

--- The function a worker runs (vim.uv.new_work dumps it: no upvalues).
--- `lua_dir` is the `lua` directory org.nvim is loaded from; `id` comes
--- back with the result.
---@param lua_dir string
---@param id integer
---@param data string
---@param job string
---@return boolean ok, integer id, string records or error
function M.work(lua_dir, id, data, job)
  local ok, res = pcall(function()
    if _G.__org_index_lua_dir ~= lua_dir then
      package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
      _G.__org_index_lua_dir = lua_dir
    end
    return require("org.agenda.index.thread").run(data, job)
  end)
  return ok, id, tostring(res)
end

return M
