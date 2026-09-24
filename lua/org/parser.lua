---@mod org.parser Org document model
---
--- A fast, line-based parser producing an outline of headlines with their
--- planning, properties, drawers, clocks and timestamps. Element-level
--- parsing for export lives in `org.export.ast`.
---
--- Line numbers are 1-based everywhere.

local date = require("org.date")
local todo_keywords = require("org.todo_keywords")

local M = {}

---@class org.Headline
---@field file org.File
---@field level integer
---@field line integer
---@field end_line integer last line of the subtree
---@field body_end integer last line of the headline's own section (before first child)
---@field raw string
---@field todo string|nil
---@field priority string|nil
---@field commented boolean
---@field title string
---@field tags string[] own tags
---@field planning { scheduled?: table, deadline?: table, closed?: table }
---@field planning_line integer|nil
---@field properties table<string,string> keys upper-cased
---@field properties_range integer[]|nil {start, end}
---@field drawers { name: string, start: integer, ["end"]: integer }[]
---@field logbook { start: integer, ["end"]: integer }|nil
---@field clocks { start: table, ["end"]: table|nil, minutes: integer|nil, line: integer }[]
---@field timestamps { date: table, line: integer, start_col: integer, end_col: integer }[]
---@field parent org.Headline|nil
---@field children org.Headline[]
---@field index integer position in file.headlines
local Headline = {}
Headline.__index = Headline
M.Headline = Headline

---@class org.File
---@field filename string|nil
---@field lines string[]
---@field headlines org.Headline[]
---@field children org.Headline[]
---@field settings table
local File = {}
File.__index = File
M.File = File

---------------------------------------------------------------------------
-- Headline line parsing
---------------------------------------------------------------------------

--- Is `line` a headline? Returns the level.
---@return integer|nil
function M.headline_level(line)
  local stars = line:match("^(%*+)%s") or line:match("^(%*+)$")
  return stars and #stars or nil
end

--- Split a headline line into components.
---@param line string
---@param todo_cfg? org.TodoConfig
---@return table|nil { level, stars, todo, priority, commented, title, tags }
function M.parse_headline_line(line, todo_cfg)
  local stars, rest = line:match("^(%*+)%s+(.*)$")
  if not stars then
    stars = line:match("^(%*+)$")
    if not stars then
      return nil
    end
    rest = ""
  end
  todo_cfg = todo_cfg or todo_keywords.global()
  local parts = { level = #stars, stars = stars, tags = {}, commented = false }

  -- tags
  local before, tagstr = rest:match("^(.-)%s+(:[^%s]+:)%s*$")
  if not before then
    tagstr = rest:match("^(:[^%s]+:)%s*$")
    if tagstr then
      before = ""
    end
  end
  if tagstr and not tagstr:find("::", 1, true) then
    for tag in tagstr:gmatch("[^:]+") do
      parts.tags[#parts.tags + 1] = tag
    end
    rest = before
  end
  rest = rest:gsub("%s+$", "")

  -- todo keyword
  local word, after = rest:match("^(%S+)(.*)$")
  if word and todo_cfg:is_keyword(word) and (after == "" or after:match("^%s")) then
    parts.todo = word
    rest = after:gsub("^%s+", "")
  end
  -- priority
  local prio, after2 = rest:match("^%[#(%w)%](.*)$")
  if prio and (after2 == "" or after2:match("^%s")) then
    parts.priority = prio
    rest = after2:gsub("^%s+", "")
  end
  -- COMMENT
  local c_after = rest:match("^COMMENT(.*)$")
  if c_after and (c_after == "" or c_after:match("^%s")) then
    parts.commented = true
    rest = c_after:gsub("^%s+", "")
  end
  parts.title = rest
  return parts
end

---------------------------------------------------------------------------
-- File settings (#+KEYWORD: value)
---------------------------------------------------------------------------

local function parse_settings(lines, filename)
  local s = {
    keywords = {},
    title = nil,
    filetags = {},
    tags = {},
    category = nil,
    startup = {},
    properties = {},
    link_abbrevs = {},
    archive = nil,
    columns = nil,
    todo_sequences = {},
    priorities = nil,
  }
  for _, line in ipairs(lines) do
    if line:byte(1) == 35 then -- '#'
      local key, value = line:match("^#%+([%w_%-]+):%s*(.-)%s*$")
      if key then
        key = key:upper()
        s.keywords[key] = s.keywords[key] or {}
        table.insert(s.keywords[key], value)
        if key == "TITLE" then
          s.title = s.title and (s.title .. " " .. value) or value
        elseif key == "TODO" or key == "SEQ_TODO" or key == "TYP_TODO" then
          table.insert(s.todo_sequences, value)
        elseif key == "FILETAGS" then
          for tag in value:gmatch("[^:%s]+") do
            table.insert(s.filetags, tag)
          end
        elseif key == "TAGS" then
          table.insert(s.tags, value)
        elseif key == "CATEGORY" then
          s.category = value
        elseif key == "STARTUP" then
          for w in value:gmatch("%S+") do
            s.startup[w] = true
          end
        elseif key == "PROPERTY" then
          local pname, pval = value:match("^(%S+)%s*(.*)$")
          if pname then
            local plus = pname:match("^(.-)%+$")
            if plus then
              local k = plus:upper()
              s.properties[k] = s.properties[k] and (s.properties[k] .. " " .. pval) or pval
            else
              s.properties[pname:upper()] = pval
            end
          end
        elseif key == "LINK" then
          local abbrev, url = value:match("^(%S+)%s+(.*)$")
          if abbrev then
            s.link_abbrevs[abbrev] = url
          end
        elseif key == "ARCHIVE" then
          s.archive = value
        elseif key == "COLUMNS" then
          s.columns = value
        elseif key == "PRIORITIES" then
          local hi, lo, def = value:match("^(%w)%s+(%w)%s+(%w)")
          if hi then
            s.priorities = { highest = hi, lowest = lo, default = def }
          end
        end
      end
    end
  end
  if not s.category and filename then
    s.category = vim.fn.fnamemodify(filename, ":t:r")
  end
  return s
end

---------------------------------------------------------------------------
-- Section parsing
---------------------------------------------------------------------------

local PLANNING_KEYS = { SCHEDULED = "scheduled", DEADLINE = "deadline", CLOSED = "closed" }

local function parse_planning(line)
  if not (line:find("SCHEDULED:", 1, true) or line:find("DEADLINE:", 1, true) or line:find("CLOSED:", 1, true)) then
    return nil
  end
  if not line:match("^%s*[A-Z]+:") then
    return nil
  end
  local planning = {}
  for key, field in pairs(PLANNING_KEYS) do
    local s = line:find(key .. ":", 1, true)
    if s then
      local rest = line:sub(s + #key + 1)
      local items = date.parse_all(rest)
      if items[1] and rest:sub(1, items[1].start_col - 1):match("^%s*$") then
        planning[field] = items[1].date
      end
    end
  end
  return planning
end

M.CLOCK_CLOSED_PATTERN = "^%s*CLOCK:%s*(%[[^%]]+%])%-%-(%[[^%]]+%])%s*=>%s*(%-?%d+):(%d+)"
M.CLOCK_OPEN_PATTERN = "^%s*CLOCK:%s*(%[[^%]]+%])%s*$"

--- Parse a CLOCK line.
---@return table|nil { start, end?, minutes? }
function M.parse_clock_line(line)
  if not line:find("CLOCK:", 1, true) then
    return nil
  end
  local s, e, h, m = line:match(M.CLOCK_CLOSED_PATTERN)
  if s then
    local ds, de = date.parse(s), date.parse(e)
    if not ds or not de then
      return nil
    end
    local mins = tonumber(h) * 60 + tonumber(m)
    if h:sub(1, 1) == "-" then
      mins = tonumber(h) * 60 - tonumber(m)
    end
    return { start = ds, ["end"] = de, minutes = mins }
  end
  -- closed clock without "=>" duration
  s, e = line:match("^%s*CLOCK:%s*(%[[^%]]+%])%-%-(%[[^%]]+%])%s*$")
  if s then
    local ds, de = date.parse(s), date.parse(e)
    if ds and de then
      return { start = ds, ["end"] = de, minutes = de:minutes() - ds:minutes() }
    end
  end
  s = line:match(M.CLOCK_OPEN_PATTERN)
  if s then
    local ds = date.parse(s)
    if ds then
      return { start = ds }
    end
  end
  return nil
end

local function parse_section(hl, lines, from, to, log_drawer)
  hl.planning = {}
  hl.properties = {}
  hl.drawers = {}
  hl.clocks = {}
  hl.timestamps = {}

  -- timestamps in the title
  for _, item in ipairs(date.parse_all(hl.title)) do
    if item.date.active then
      local col_offset = hl.raw:find(hl.title, 1, true)
      hl.timestamps[#hl.timestamps + 1] = {
        date = item.date,
        line = hl.line,
        start_col = (col_offset or 1) + item.start_col - 1,
        end_col = (col_offset or 1) + item.end_col - 1,
        in_title = true,
      }
    end
  end

  local i = from
  -- planning line
  if i <= to then
    local planning = parse_planning(lines[i])
    if planning then
      hl.planning = planning
      hl.planning_line = i
      i = i + 1
    end
  end
  -- properties drawer
  if i <= to and lines[i]:match("^%s*:PROPERTIES:%s*$") then
    local start = i
    local j = i + 1
    while j <= to and not lines[j]:match("^%s*:END:%s*$") do
      local key, value = lines[j]:match("^%s*:([^%s:]+):%s*(.-)%s*$")
      if key then
        local base = key:match("^(.-)%+$")
        if base then
          local k = base:upper()
          hl.properties[k] = hl.properties[k] and (hl.properties[k] .. " " .. value) or value
        else
          hl.properties[key:upper()] = value
        end
      end
      j = j + 1
    end
    if j <= to then
      hl.properties_range = { start, j }
      i = j + 1
    end
  end

  -- rest of section: drawers, clocks, timestamps
  local in_drawer = nil
  while i <= to do
    local line = lines[i]
    if in_drawer then
      if line:match("^%s*:END:%s*$") then
        in_drawer["end"] = i
        hl.drawers[#hl.drawers + 1] = in_drawer
        if in_drawer.name:upper() == log_drawer and not hl.logbook then
          hl.logbook = { start = in_drawer.start, ["end"] = i }
        end
        in_drawer = nil
      end
    else
      local dname = line:match("^%s*:([%w_%-]+):%s*$")
      if dname and dname:upper() ~= "END" then
        in_drawer = { name = dname, start = i }
      else
        for _, item in ipairs(date.parse_all(line)) do
          if item.date.active then
            hl.timestamps[#hl.timestamps + 1] = {
              date = item.date,
              line = i,
              start_col = item.start_col,
              end_col = item.end_col,
            }
          end
        end
      end
    end
    local clock = line:find("CLOCK:", 1, true) and M.parse_clock_line(line)
    if clock then
      clock.line = i
      hl.clocks[#hl.clocks + 1] = clock
    end
    i = i + 1
  end
end

---------------------------------------------------------------------------
-- File parsing
---------------------------------------------------------------------------

---@param lines string[]
---@param filename? string absolute path
---@return org.File
function M.parse(lines, filename)
  local settings = parse_settings(lines, filename)
  local todo_cfg
  if #settings.todo_sequences > 0 then
    todo_cfg = todo_keywords.new(settings.todo_sequences)
  else
    todo_cfg = todo_keywords.global()
  end
  settings.todo = todo_cfg

  local file = setmetatable({
    filename = filename,
    lines = lines,
    headlines = {},
    children = {},
    settings = settings,
  }, File)

  local cfg = require("org.config").opts
  local log_drawer = (type(cfg.log_into_drawer) == "string" and cfg.log_into_drawer or "LOGBOOK"):upper()

  local stack = {}
  local headlines = file.headlines
  for i, line in ipairs(lines) do
    if line:byte(1) == 42 then -- '*'
      local parts = M.parse_headline_line(line, todo_cfg)
      if parts then
        local hl = setmetatable({
          file = file,
          level = parts.level,
          line = i,
          raw = line,
          todo = parts.todo,
          priority = parts.priority,
          commented = parts.commented,
          title = parts.title,
          tags = parts.tags,
          children = {},
          index = #headlines + 1,
        }, Headline)
        while #stack > 0 and stack[#stack].level >= hl.level do
          local closed = table.remove(stack)
          closed.end_line = i - 1
        end
        hl.parent = stack[#stack]
        if hl.parent then
          table.insert(hl.parent.children, hl)
        else
          table.insert(file.children, hl)
        end
        stack[#stack + 1] = hl
        headlines[#headlines + 1] = hl
      end
    end
  end
  for _, hl in ipairs(stack) do
    hl.end_line = #lines
  end
  for idx, hl in ipairs(headlines) do
    local nxt = headlines[idx + 1]
    hl.body_end = nxt and nxt.line - 1 or #lines
    parse_section(hl, lines, hl.line + 1, hl.body_end, log_drawer)
  end
  file.preamble_end = headlines[1] and headlines[1].line - 1 or #lines
  return file
end

---------------------------------------------------------------------------
-- File methods
---------------------------------------------------------------------------

--- Innermost headline whose section contains `lnum` (nil in the preamble).
---@return org.Headline|nil
function File:headline_at(lnum)
  local hls = self.headlines
  local lo, hi, found = 1, #hls, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if hls[mid].line <= lnum then
      found = hls[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

--- Headline starting exactly at `lnum`.
function File:headline_on(lnum)
  local hl = self:headline_at(lnum)
  if hl and hl.line == lnum then
    return hl
  end
end

function File:find_headline(pred)
  for _, hl in ipairs(self.headlines) do
    if pred(hl) then
      return hl
    end
  end
end

function File:find_by_id(id)
  return self:find_headline(function(hl)
    return hl.properties.ID == id
  end)
end

function File:find_by_custom_id(id)
  return self:find_headline(function(hl)
    return hl.properties.CUSTOM_ID == id
  end)
end

--- Find a headline by title (link-stripped, case-sensitive), or by an outline path.
---@param title string|string[]
function File:find_by_title(title)
  if type(title) == "table" then
    local nodes = self.children
    local found
    for _, part in ipairs(title) do
      found = nil
      for _, hl in ipairs(nodes) do
        if hl:plain_title() == part or hl.title == part then
          found = hl
          break
        end
      end
      if not found then
        return nil
      end
      nodes = found.children
    end
    return found
  end
  return self:find_headline(function(hl)
    return hl:plain_title() == title or hl.title == title
  end)
end

function File:get_todo_config()
  return self.settings.todo
end

function File:category()
  return self.settings.category or "???"
end

function File:title()
  return self.settings.title or (self.filename and vim.fn.fnamemodify(self.filename, ":t:r")) or "untitled"
end

function File:priorities()
  local cfg = require("org.config").opts
  local p = self.settings.priorities
  return {
    highest = p and p.highest or cfg.priority_highest,
    lowest = p and p.lowest or cfg.priority_lowest,
    default = p and p.default or cfg.priority_default,
  }
end

--- Tag definitions for completion: list of { name, key? } including groups.
function File:tag_definitions()
  local out = {}
  local function add(spec)
    for tok in spec:gmatch("%S+") do
      if tok == "{" or tok == "}" or tok == "\\n" then
        out[#out + 1] = { group = tok }
      else
        local name, key = tok:match("^([^%(]+)%((.)%)$")
        out[#out + 1] = { name = name or tok, key = key }
      end
    end
  end
  if #self.settings.tags > 0 then
    for _, spec in ipairs(self.settings.tags) do
      add(spec)
    end
  else
    for _, spec in ipairs(require("org.config").opts.tags or {}) do
      add(spec)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Headline methods
---------------------------------------------------------------------------

--- Title with links replaced by their descriptions and emphasis kept.
function Headline:plain_title()
  local t = self.title:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  t = t:gsub("%[%[([^%]]-)%]%]", "%1")
  -- strip statistics cookies
  t = t:gsub("%s*%[%d*%%%]", ""):gsub("%s*%[%d*/%d*%]", "")
  return vim.trim(t)
end

function Headline:is_done()
  return self.todo ~= nil and self.file.settings.todo:is_done(self.todo)
end

function Headline:is_todo()
  return self.todo ~= nil and self.file.settings.todo:is_todo(self.todo)
end

function Headline:is_archived()
  return vim.tbl_contains(self.tags, "ARCHIVE")
end

--- Is this headline or any ancestor archived / commented?
function Headline:is_hidden_by_ancestor()
  local h = self
  while h do
    if h.commented or vim.tbl_contains(h.tags, "ARCHIVE") then
      return true
    end
    h = h.parent
  end
  return false
end

function Headline:id()
  return self.properties.ID
end

function Headline:outline_path()
  local path = {}
  local p = self.parent
  while p do
    table.insert(path, 1, p:plain_title())
    p = p.parent
  end
  return path
end

--- Category: CATEGORY property (inherited) > #+CATEGORY > file name.
function Headline:get_category()
  local h = self
  while h do
    if h.properties.CATEGORY then
      return h.properties.CATEGORY
    end
    h = h.parent
  end
  return self.file:category()
end

--- All tags: filetags + inherited + own (deduplicated, own last).
---@param opts? { inherited?: boolean } inherited=false -> own tags only
function Headline:get_tags(opts)
  opts = opts or {}
  if opts.inherited == false then
    return vim.deepcopy(self.tags)
  end
  local cfg = require("org.config").opts
  local seen, out = {}, {}
  local function add(tag, inherited)
    if seen[tag] then
      return
    end
    if inherited and vim.tbl_contains(cfg.tags_exclude_from_inheritance or {}, tag) then
      return
    end
    seen[tag] = true
    out[#out + 1] = tag
  end
  if cfg.use_tag_inheritance ~= false then
    for _, t in ipairs(self.file.settings.filetags) do
      add(t, true)
    end
    local chain = {}
    local p = self.parent
    while p do
      table.insert(chain, 1, p)
      p = p.parent
    end
    for _, p2 in ipairs(chain) do
      for _, t in ipairs(p2.tags) do
        add(t, true)
      end
    end
  end
  for _, t in ipairs(self.tags) do
    add(t, false)
  end
  return out
end

--- Inherited tags only (not own).
function Headline:get_inherited_tags()
  local own = {}
  for _, t in ipairs(self.tags) do
    own[t] = true
  end
  local out = {}
  for _, t in ipairs(self:get_tags()) do
    if not own[t] then
      out[#out + 1] = t
    end
  end
  return out
end

local function should_inherit(name)
  local inh = require("org.config").opts.use_property_inheritance
  if inh == true then
    return true
  elseif type(inh) == "table" then
    for _, p in ipairs(inh) do
      if p:upper() == name then
        return true
      end
    end
  end
  return false
end

--- Property value (special properties included).
---@param name string
---@param inherit? boolean nil = use config `use_property_inheritance`
function Headline:get_property(name, inherit)
  local key = name:upper()
  if key == "ITEM" then
    return self.title
  elseif key == "TODO" then
    return self.todo
  elseif key == "PRIORITY" then
    return self.priority or self.file:priorities().default
  elseif key == "TAGS" then
    return #self.tags > 0 and (":" .. table.concat(self.tags, ":") .. ":") or nil
  elseif key == "ALLTAGS" then
    local t = self:get_tags()
    return #t > 0 and (":" .. table.concat(t, ":") .. ":") or nil
  elseif key == "CATEGORY" then
    return self:get_category()
  elseif key == "LEVEL" then
    return tostring(self.level)
  elseif key == "FILE" then
    return self.file.filename
  elseif key == "SCHEDULED" or key == "DEADLINE" or key == "CLOSED" then
    local d = self.planning[key:lower()]
    return d and d:to_string() or nil
  elseif key == "TIMESTAMP" then
    return self.timestamps[1] and self.timestamps[1].date:to_string() or nil
  elseif key == "BLOCKED" then
    return nil
  end
  if self.properties[key] ~= nil then
    return self.properties[key]
  end
  if inherit == nil then
    inherit = should_inherit(key)
  end
  if inherit then
    local p = self.parent
    while p do
      if p.properties[key] ~= nil then
        return p.properties[key]
      end
      p = p.parent
    end
    if self.file.settings.properties[key] ~= nil then
      return self.file.settings.properties[key]
    end
    local global = require("org.config").opts.global_properties or {}
    for k, v in pairs(global) do
      if k:upper() == key then
        return v
      end
    end
  end
  return nil
end

--- Allowed values for a property (`PROP_ALL`), searched upward then globally.
---@return string[]|nil
function Headline:get_allowed_values(name)
  local key = name:upper() .. "_ALL"
  local h = self
  while h do
    if h.properties[key] then
      return vim.split(h.properties[key], "%s+", { trimempty = true })
    end
    h = h.parent
  end
  local v = self.file.settings.properties[key]
  if not v then
    for k, gv in pairs(require("org.config").opts.global_properties or {}) do
      if k:upper() == key then
        v = gv
      end
    end
  end
  return v and vim.split(v, "%s+", { trimempty = true }) or nil
end

function Headline:scheduled()
  return self.planning.scheduled
end

function Headline:deadline()
  return self.planning.deadline
end

function Headline:closed()
  return self.planning.closed
end

--- Lines of the whole subtree.
function Headline:subtree_lines()
  return vim.list_slice(self.file.lines, self.line, self.end_line)
end

--- Section body lines (excluding headline, planning and property drawer).
function Headline:body_lines()
  local start = self.line + 1
  if self.planning_line then
    start = self.planning_line + 1
  end
  if self.properties_range then
    start = self.properties_range[2] + 1
  end
  return vim.list_slice(self.file.lines, start, self.body_end), start
end

--- Total clocked minutes in this headline's own section (closed clocks),
--- optionally restricted to clocks starting within [from_min, to_min).
function Headline:clocked_minutes(from_min, to_min, include_children)
  local total = 0
  local function sum(h)
    for _, c in ipairs(h.clocks) do
      if c.minutes then
        local s = c.start:minutes()
        if (not from_min or s >= from_min) and (not to_min or s < to_min) then
          total = total + c.minutes
        end
      end
    end
    if include_children then
      for _, child in ipairs(h.children) do
        sum(child)
      end
    end
  end
  sum(self)
  return total
end

--- Is this headline's subtree still containing unfinished TODO children?
function Headline:has_undone_children()
  for _, c in ipairs(self.children) do
    if c:is_todo() or c:has_undone_children() then
      return true
    end
  end
  return false
end

--- Checks if a tags list contains `tag`.
function Headline:has_tag(tag, inherited)
  local list = inherited == false and self.tags or self:get_tags()
  return vim.tbl_contains(list, tag)
end

return M
