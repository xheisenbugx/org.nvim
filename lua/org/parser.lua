---@mod org.parser Org document model
---
--- A fast, line-based parser producing an outline of headlines with their
--- planning, properties, drawers, clocks and timestamps. Element-level
--- parsing for export lives in `org.export.ast`.
---
--- Line numbers are 1-based everywhere.

local date = require("org.date")
local todo_keywords = require("org.todo_keywords")
local keywords = require("org.keywords")

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
---@field properties table<string,string> keys upper-cased (`KEY+:` values appended)
---@field properties_extend table<string,boolean>|nil keys only given as `KEY+:`
---@field properties_range integer[]|nil {start, end}
---@field drawers { name: string, start: integer, ["end"]: integer }[]
---@field logbook { start: integer, ["end"]: integer }|nil
---@field clocks { start: table, ["end"]: table|nil, minutes: integer|nil, line: integer }[]
---@field timestamps { date: table, line: integer, start_col: integer, end_col: integer }[]
---@field parent org.Headline|nil
---@field children org.Headline[]
---@field index integer position in file.headlines
local Headline = {}
M.Headline = Headline

-- A parse only finds the outline. The rest of a headline line (TODO
-- keyword, priority, title, tags) and its section (planning, drawers,
-- clocks, timestamps) are parsed the first time one of their fields is
-- read or written, so commands that only need the structure of a large
-- file don't pay for the whole of it.
local HEAD_FIELDS = { todo = true, priority = true, commented = true, title = true, tags = true }
local SECTION_FIELDS = {
  planning = true,
  planning_line = true,
  properties = true,
  property_base = true,
  properties_extend = true,
  properties_range = true,
  drawers = true,
  logbook = true,
  clocks = true,
  timestamps = true,
  first_inactive = true,
}

local parse_section

local function load_head(hl)
  rawset(hl, "_lazy_head", nil)
  local parts = M.parse_headline_line(rawget(hl, "raw"), rawget(hl, "file").settings.todo)
  rawset(hl, "todo", parts.todo)
  rawset(hl, "priority", parts.priority)
  rawset(hl, "commented", parts.commented)
  rawset(hl, "title", parts.title)
  rawset(hl, "tags", parts.tags)
end

local function load_section(hl)
  rawset(hl, "_lazy_section", nil)
  local file = rawget(hl, "file")
  parse_section(hl, file.lines, rawget(hl, "line") + 1, rawget(hl, "body_end"), file._log_drawer)
end

function Headline.__index(hl, key)
  local method = Headline[key]
  if method ~= nil then
    return method
  end
  if HEAD_FIELDS[key] then
    if rawget(hl, "_lazy_head") then
      load_head(hl)
      return rawget(hl, key)
    end
  elseif SECTION_FIELDS[key] and rawget(hl, "_lazy_section") then
    load_section(hl)
    return rawget(hl, key)
  end
end

function Headline.__newindex(hl, key, value)
  if HEAD_FIELDS[key] then
    if rawget(hl, "_lazy_head") then
      load_head(hl)
    end
  elseif SECTION_FIELDS[key] and rawget(hl, "_lazy_section") then
    load_section(hl)
  end
  rawset(hl, key, value)
end

---@class org.File
---@field filename string|nil
---@field lines string[]
---@field headlines org.Headline[]
---@field children org.Headline[]
---@field settings table
---@field setup_dependencies table<string,string> signatures of local setup files
local File = {}
File.__index = File
M.File = File

---------------------------------------------------------------------------
-- Headline line parsing
---------------------------------------------------------------------------

--- Is `line` a headline? Returns the level.
---@return integer|nil
function M.headline_level(line)
  -- "^(%*+) ", byte by byte so that LuaJIT compiles loops over many lines
  local n = 0
  while line:byte(n + 1) == 42 do
    n = n + 1
  end
  if n > 0 and line:byte(n + 1) == 32 then
    return n
  end
  return nil
end

--- Split a headline line into components.
---@param line string
---@param todo_cfg? org.TodoConfig
---@return table|nil { level, stars, todo, priority, commented, title, tags }
function M.parse_headline_line(line, todo_cfg)
  -- like org-outline-regexp, stars must be followed by a space
  local stars, rest = line:match("^(%*+) +(.*)$")
  if not stars then
    return nil
  end
  todo_cfg = todo_cfg or todo_keywords.global()
  local parts = { level = #stars, stars = stars, tags = {}, commented = false }

  -- tags
  -- tags use org-tag-re characters: letters, digits, _ @ # % (and any
  -- non-ASCII letter)
  local before, tagstr = rest:match("^(.-)%s+(:[%w_@#%%:\128-\255]+:)%s*$")
  if not before then
    tagstr = rest:match("^(:[%w_@#%%:\128-\255]+:)%s*$")
    if tagstr then
      before = ""
    end
  end
  if tagstr then
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
  -- org-priority-value-regexp: A-Z or 0-64
  local prio, after2 = rest:match("^%[#([A-Z])%](.*)$")
  if not prio then
    prio, after2 = rest:match("^%[#(%d%d?)%](.*)$")
    if prio and tonumber(prio) > 64 then
      prio = nil
    end
  end
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

-- Org applies startup words in order, setting the same variable for each
-- member of a group. Keep only its last word so boolean-map consumers agree.
local STARTUP_GROUP = {}
for _, group in ipairs({
  {
    "fold",
    "overview",
    "nofold",
    "showall",
    "show2levels",
    "show3levels",
    "show4levels",
    "show5levels",
    "showeverything",
    "content",
  },
  { "indent", "noindent" },
  { "num", "nonum" },
  { "hidestars", "showstars" },
  { "odd", "oddeven" },
  { "align", "noalign" },
  { "shrink", "noshrink" },
  { "descriptivelinks", "literallinks" },
  { "inlineimages", "noinlineimages", "linkpreviews", "nolinkpreviews" },
  { "latexpreview", "nolatexpreview" },
  { "logdone", "lognotedone", "nologdone" },
  { "lognoteclock-out", "nolognoteclock-out", "nologclock-out" },
  { "logrepeat", "lognoterepeat", "nologrepeat" },
  { "logreschedule", "lognotereschedule", "nologreschedule" },
  { "logredeadline", "lognoteredeadline", "nologredeadline" },
  { "logrefile", "lognoterefile", "nologrefile" },
  { "logdrawer", "nologdrawer" },
  { "logstatesreversed", "nologstatesreversed" },
  { "fninline", "nofninline" },
  { "fnauto", "fnprompt", "fnconfirm", "fnplain", "fnanon" },
  { "fnadjust", "nofnadjust" },
  { "constcgs", "constsi" },
  { "hideblocks", "nohideblocks" },
  { "hidedrawers", "nohidedrawers" },
  { "entitiespretty", "entitiesplain" },
}) do
  for _, word in ipairs(group) do
    STARTUP_GROUP[word] = group
  end
end

local function parse_settings(lines, filename)
  local s = {
    keywords = {},
    title = nil,
    filetags = {},
    tags = {},
    category = nil,
    startup = {},
    properties = {},
    -- properties with a non-`+` definition (`:Foo:` vs only `:Foo+:`)
    property_base = {},
    link_abbrevs = {},
    archive = nil,
    columns = nil,
    todo_sequences = {},
    priorities = nil,
  }
  local entries, dependencies = keywords.collect(lines, filename)
  s.keyword_entries = entries
  local local_category, first_category
  local todo_lines = {}
  for _, entry in ipairs(entries) do
    local key, value = entry.key, entry.value
    s.keywords[key] = s.keywords[key] or {}
    table.insert(s.keywords[key], value)
    if key == "TITLE" then
      s.title = s.title and (s.title .. " " .. value) or value
    elseif key == "TODO" or key == "SEQ_TODO" or key == "TYP_TODO" then
      todo_lines[key] = todo_lines[key] or {}
      table.insert(todo_lines[key], key == "TYP_TODO" and { type = value } or value)
    elseif key == "FILETAGS" then
      for tag in value:gmatch("[^:%s]+") do
        table.insert(s.filetags, tag)
      end
    elseif key == "TAGS" then
      table.insert(s.tags, value)
    elseif key == "CATEGORY" then
      -- org-element--get-category: the buffer's last CATEGORY keyword, else
      -- org-category, the first one collected (setup files included).
      if entry.filename == filename then
        local_category = value
      end
      first_category = first_category or value
    elseif key == "STARTUP" then
      for w in value:gmatch("%S+") do
        w = w:lower()
        for _, other in ipairs(STARTUP_GROUP[w] or {}) do
          s.startup[other] = nil
        end
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
          s.property_base[pname:upper()] = true
        end
      end
    elseif key == "LINK" then
      local abbrev, url = value:match("^(%S+)%s+(.*)$")
      if abbrev then
        s.link_abbrevs[abbrev] = url
      end
    elseif key == "ARCHIVE" and s.archive == nil then
      s.archive = value
    elseif key == "COLUMNS" and s.columns == nil then
      s.columns = value
    elseif key == "PRIORITIES" and #s.keywords.PRIORITIES == 1 then
      local hi, lo, def = value:match("^(%S+)%s+(%S+)%s+(%S+)")
      if hi then
        s.priorities = { highest = hi, lowest = lo, default = def }
      end
    end
  end
  -- like Emacs: type sequences first, then #+TODO:, then #+SEQ_TODO:
  for _, key in ipairs({ "TYP_TODO", "TODO", "SEQ_TODO" }) do
    vim.list_extend(s.todo_sequences, todo_lines[key] or {})
  end
  s.category = local_category or first_category
  if not s.category and filename then
    s.category = vim.fn.fnamemodify(filename, ":t:r")
  end
  return s, dependencies
end

---------------------------------------------------------------------------
-- Section parsing
---------------------------------------------------------------------------

local PLANNING_KEYS = { SCHEDULED = "scheduled", DEADLINE = "deadline", CLOSED = "closed" }

local function parse_planning(line)
  -- org-planning-line-re starts with a planning keyword. A body line
  -- such as "NOTE: SCHEDULED: ..." must never become editable metadata.
  local first = line:match("^%s*([A-Z]+):")
  if not PLANNING_KEYS[first] then
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

--- Parse a property line, retaining colons in names such as header-args:sh.
--- Like org-property-re, the delimiter is a colon followed by whitespace
--- or the end of the line, and a property may have an empty value.
---@return string|nil name, string|nil value
function M.parse_property_line(line)
  local key, value = line:match("^%s*:(%S+):%s+(.-)%s*$")
  if not key then
    key = line:match("^%s*:(%S+):%s*$")
    value = key and "" or nil
  end
  return key, value
end

local function parse_property_drawer(lines, from, to)
  if from > to or not lines[from]:match("^%s*:PROPERTIES:%s*$") then
    return nil
  end
  local bases, extra, order = {}, {}, {}
  local j = from + 1
  while j <= to and not lines[j]:match("^%s*:END:%s*$") do
    local key, value = M.parse_property_line(lines[j])
    if not key then
      return nil
    end
    local base = key:match("^(.-)%+$")
    local k = (base or key):upper()
    if not bases[k] and not extra[k] then
      order[#order + 1] = k
    end
    if base then
      extra[k] = extra[k] or {}
      table.insert(extra[k], value)
    else
      bases[k] = value
    end
    j = j + 1
  end
  -- org-property-drawer-re requires only property lines and a closing
  -- END. An incomplete drawer is ordinary text, not a source of IDs.
  if j > to then
    return nil
  end
  local drawer = { properties = {}, property_base = {}, properties_range = { from, j } }
  for _, k in ipairs(order) do
    local parts = { bases[k] }
    vim.list_extend(parts, extra[k] or {})
    drawer.properties[k] = table.concat(parts, M.property_separator(k))
    if bases[k] ~= nil then
      drawer.property_base[k] = true
    else
      -- only `KEY+:` here: inherited values are extended (org-entry-get)
      drawer.properties_extend = drawer.properties_extend or {}
      drawer.properties_extend[k] = true
    end
  end
  return drawer
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
      return { start = ds, ["end"] = de, minutes = date.elapsed_minutes(ds, de) }
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

M.parse_planning = parse_planning
M.parse_property_drawer = parse_property_drawer

-- Blocks whose contents are not parsed into objects (org-element).
local VERBATIM_BLOCKS = { src = true, example = true, export = true, comment = true }

--- When `lines[i]` opens a src, example, export or comment block closed by
--- line `to`, the line of its #+end_ and the block's lower-cased name.
---@return integer|nil, string|nil
function M.verbatim_block_end(lines, i, to)
  local name = lines[i]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
  name = name and name:lower()
  if not (name and VERBATIM_BLOCKS[name]) then
    return nil
  end
  local close = "^%s*#%+end_" .. vim.pesc(name) .. "%s*$"
  for k = i + 1, to do
    if lines[k]:lower():match(close) then
      return k, name
    end
  end
end

--- Whether `line` is a comment, a fixed-width line or a keyword (other
--- than CAPTION): Emacs finds no timestamp objects there.
local function no_objects(line)
  if line:match("^%s*[#:]%s") or line:match("^%s*[#:]$") then
    return true
  end
  local key = line:match("^%s*#%+(%S-):")
  return key ~= nil and not key:upper():match("^CAPTION")
end

function parse_section(hl, lines, from, to, log_drawer)
  hl.planning = {}
  hl.properties = {}
  hl.property_base = {}
  hl.drawers = {}
  hl.clocks = {}
  hl.timestamps = {}

  -- timestamps in the title
  for _, item in ipairs(date.parse_all(hl.title)) do
    if not item.date.active and not hl.first_inactive then
      hl.first_inactive = item.date
    end
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
  local drawer = parse_property_drawer(lines, i, to)
  if drawer then
    for key, value in pairs(drawer) do
      hl[key] = value
    end
    i = drawer.properties_range[2] + 1
  end

  -- rest of section: drawers, clocks, timestamps
  local in_drawer = nil
  local verbatim_end = 0
  while i <= to do
    local line = lines[i]
    if i <= verbatim_end then
      -- inside a src/example/export/comment block: no timestamps
    elseif in_drawer then
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
      local block_end = line:find("^%s*#%+") and M.verbatim_block_end(lines, i, to)
      if block_end then
        verbatim_end = block_end
      elseif dname and dname:upper() ~= "END" then
        in_drawer = { name = dname, start = i }
      elseif not (line:find("^%s*[#:]") and no_objects(line)) then
        local is_clock = line:find("CLOCK:", 1, true) and line:match("^%s*CLOCK:")
        for _, item in ipairs(date.parse_all(line)) do
          if not item.date.active and not hl.first_inactive and not is_clock then
            hl.first_inactive = item.date
          end
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
---@param base? org.File use this file's in-buffer settings instead of the
--- ones in `lines` (text shown apart from its file, e.g. presentation slides)
---@return org.File
function M.parse(lines, filename, base)
  local settings, dependencies
  if base then
    settings, dependencies = base.settings, base.setup_dependencies
  else
    settings, dependencies = parse_settings(lines, filename)
    local todo_cfg
    if #settings.todo_sequences > 0 then
      todo_cfg = todo_keywords.new(settings.todo_sequences)
    else
      todo_cfg = todo_keywords.global()
    end
    settings.todo = todo_cfg
  end

  local file = setmetatable({
    filename = filename,
    lines = lines,
    headlines = {},
    children = {},
    settings = settings,
    setup_dependencies = dependencies,
  }, File)

  local cfg = require("org.config").opts
  file._log_drawer = (type(cfg.log_into_drawer) == "string" and cfg.log_into_drawer or "LOGBOOK"):upper()

  local stack = {}
  local headlines = file.headlines
  local min_inline = M.inlinetask_min_level()
  local skip_to = 0
  for i, line in ipairs(lines) do
    if line:byte(1) == 42 and i > skip_to then -- '*'
      local level = M.headline_level(line)
      local parts = level and { level = level }
      if parts and min_inline and parts.level >= min_inline then
        -- an inline task (org-inlinetask): part of the entry's text, up to
        -- its END line when it has one
        local stop = i
        for j = i + 1, #lines do
          local l = lines[j]
          local lv = l:byte(1) == 42 and M.headline_level(l)
          if lv then
            if lv >= min_inline and l:match("^%*+%s+END%s*$") then
              stop = j
            end
            break
          end
        end
        local hl = {
          file = file,
          level = parts.level,
          line = i,
          raw = line,
          _lazy_head = true,
          children = {},
          index = #headlines + 1,
          inlinetask = true,
          end_line = stop,
          parent = stack[#stack],
        }
        headlines[#headlines + 1] = hl
        skip_to = stop
        parts = nil
      end
      if parts then
        local hl = {
          file = file,
          level = parts.level,
          line = i,
          raw = line,
          _lazy_head = true,
          children = {},
          index = #headlines + 1,
        }
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
    if hl.inlinetask then
      hl.body_end = hl.end_line > hl.line and hl.end_line - 1 or hl.line
    else
      local nxt = headlines[idx + 1]
      while nxt and nxt.inlinetask do
        nxt = headlines[nxt.index + 1]
      end
      hl.body_end = nxt and nxt.line - 1 or #lines
    end
    hl._lazy_section = true
    setmetatable(hl, Headline)
  end
  local first = headlines[1]
  while first and first.inlinetask do
    first = headlines[first.index + 1]
  end
  file.preamble_end = first and first.line - 1 or #lines
  M.parse_file_drawer(file)
  return file
end

--- Level from which headlines are inline tasks (org-inlinetask-min-level),
--- nil when inline tasks are off.
function M.inlinetask_min_level()
  local v = require("org.config").opts.inlinetask_min_level
  return type(v) == "number" and v or nil
end

--- Level of `line` as an outline headline: nil for text and, when inline
--- tasks are on, for inline tasks (org-with-limited-levels).
function M.outline_level(line)
  local lvl = M.headline_level(line)
  local min = lvl and M.inlinetask_min_level()
  if min and lvl >= min then
    return nil
  end
  return lvl
end

--- The file-level property drawer: a `:PROPERTIES:` drawer at the top of
--- the file, preceded only by comments and blank lines (like Emacs). Sets
--- `file.properties_range`, `file.properties` and `file.property_base`.
---@param file org.File
function M.parse_file_drawer(file)
  local lines = file.lines
  file.properties = {}
  file.property_base = {}
  file.properties_range = nil
  local i = 1
  while i <= file.preamble_end and (lines[i]:match("^%s*$") or lines[i]:match("^%s*#%s") or lines[i]:match("^%s*#$")) do
    i = i + 1
  end
  local drawer = parse_property_drawer(lines, i, file.preamble_end)
  if drawer then
    for key, value in pairs(drawer) do
      file[key] = value
    end
  end
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
  -- after an inline task, the line belongs to the enclosing entry
  while found and found.inlinetask and lnum > found.end_line do
    found = hls[found.index - 1]
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
    highest = tostring(p and p.highest or cfg.priority_highest),
    lowest = tostring(p and p.lowest or cfg.priority_lowest),
    default = tostring(p and p.default or cfg.priority_default),
  }
end

--- Tag definitions for completion: list of { name, key? } including groups.
function File:tag_definitions()
  local out = {}
  local function add(spec)
    for tok in spec:gmatch("%S+") do
      if tok == "{" or tok == "}" or tok == "\\n" or tok == "[" or tok == "]" or tok == ":" then
        -- `:` separates a group tag from its members
        out[#out + 1] = { group = tok }
      else
        local name, key = tok:match("^([^%(]+)%((.)%)$")
        out[#out + 1] = { name = name or tok, key = key }
      end
    end
  end
  local opts = require("org.config").opts
  local specs = #self.settings.tags > 0 and self.settings.tags or opts.tags or {}
  for i, spec in ipairs(specs) do
    if i > 1 and #self.settings.tags > 0 then
      -- #+TAGS lines are joined with newlines, like Emacs
      out[#out + 1] = { group = "\\n" }
    end
    add(spec)
  end
  -- `tags_persistent` (org-tag-persistent-alist) comes first, unless
  -- `#+STARTUP: noptag`; its tags already defined outside a group are
  -- dropped (org--tag-add-to-alist)
  local persistent = opts.tags_persistent or {}
  if #persistent > 0 and not self.settings.startup.noptag then
    local defined = {}
    for _, d in ipairs(out) do
      if d.name then
        defined[d.name] = true
      end
    end
    local rest = out
    out = {}
    for _, spec in ipairs(persistent) do
      add(spec)
    end
    local in_group = false
    local merged = {}
    for _, d in ipairs(out) do
      if d.group == "{" or d.group == "[" then
        in_group = true
      elseif d.group == "}" or d.group == "]" then
        in_group = false
      end
      if not d.name or in_group or not defined[d.name] then
        merged[#merged + 1] = d
      end
    end
    out = vim.list_extend(merged, rest)
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
  -- use_tag_inheritance: true, false, a list of tags or a regexp
  -- (org-use-tag-inheritance)
  local inh = cfg.use_tag_inheritance
  local inh_re = type(inh) == "string" and vim.regex(inh) or nil
  local function add(tag, inherited)
    if seen[tag] then
      return
    end
    if inherited and vim.tbl_contains(cfg.tags_exclude_from_inheritance or {}, tag) then
      return
    end
    if inherited and type(inh) == "table" and not vim.tbl_contains(inh, tag) then
      return
    end
    if inherited and inh_re and not inh_re:match_str(tag) then
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
  elseif type(inh) == "string" then
    -- a regexp matched against the name, ignoring case like Emacs
    local ok, re = pcall(vim.regex, "\\c" .. inh)
    return ok and re:match_str(name) ~= nil
  elseif type(inh) == "table" then
    for _, p in ipairs(inh) do
      if p:upper() == name then
        return true
      end
    end
  end
  return false
end

--- Separator joining the values of `PROP` and `PROP+` (org-property-separators,
--- org--property-get-separator): the first `property_separators` entry
--- whose names (a list, compared ignoring case) or regexp (ignoring case)
--- match `key`, else a space.
---@param key string
---@return string
function M.property_separator(key)
  for _, spec in ipairs(require("org.config").opts.property_separators or {}) do
    local match, sep = spec[1], spec[2]
    if type(match) == "table" then
      for _, n in ipairs(match) do
        if n:upper() == key:upper() then
          return sep
        end
      end
    elseif type(match) == "string" then
      local ok, re = pcall(vim.regex, "\\c" .. match)
      if ok and re:match_str(key) then
        return sep
      end
    end
  end
  return " "
end

local function inherited_property(file, key, h)
  -- org-entry-get-with-inheritance: `PROP+` values accumulate onto the
  -- inherited value until a plain `PROP` definition is found
  local parts = {}
  local function take(props, base)
    local v = props[key]
    if v ~= nil then
      table.insert(parts, 1, v)
      return base[key] == true
    end
    return false
  end
  while h do
    if take(h.properties, h.property_base) then
      return table.concat(parts, M.property_separator(key))
    end
    h = h.parent
  end
  if take(file.properties or {}, file.property_base or {}) then
    return table.concat(parts, M.property_separator(key))
  end
  if take(file.settings.properties, file.settings.property_base or {}) then
    return table.concat(parts, M.property_separator(key))
  end
  local global = require("org.config").opts.global_properties or {}
  for k, v in pairs(global) do
    if k:upper() == key then
      table.insert(parts, 1, v)
      break
    end
  end
  return #parts > 0 and table.concat(parts, M.property_separator(key)) or nil
end

--- File drawer property, optionally inheriting keyword/global properties.
---@param name string
---@param inherit? boolean nil = use config `use_property_inheritance`
function File:get_property(name, inherit)
  local key = name:upper()
  if inherit == nil then
    inherit = should_inherit(key)
  end
  if not inherit then
    return self.properties[key]
  end
  return inherited_property(self, key)
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
  elseif key == "TIMESTAMP_IA" then
    return self.first_inactive and self.first_inactive:to_string() or nil
  elseif key == "BLOCKED" then
    -- org-entry-blocked-p: an open TODO that cannot be marked done
    local blocked = self:is_todo() and require("org.todo").blocked_reason(self) ~= nil
    return blocked and "t" or ""
  end
  if inherit == nil then
    inherit = should_inherit(key)
  end
  if not inherit then
    return self.properties[key]
  end
  return inherited_property(self.file, key, self)
end

local function allowed_values(value)
  if not value or not value:match("%S") then
    return nil
  end
  -- org-property-get-allowed-values reads Lisp data: quoted strings may
  -- contain spaces/escapes, and numbers and symbols become their names.
  -- Reading (never evaluating) also keeps nested forms inert.
  local elisp = require("org.table.elisp")
  local valid, values = pcall(elisp.read, "(" .. value .. ")")
  if not valid or not values then
    return nil
  end
  local out = {}
  for i = 1, values.n do
    local v = values[i]
    if v == nil then
      out[#out + 1] = "nil"
    elseif type(v) == "string" or type(v) == "number" or v == true or elisp.is_float(v) then
      out[#out + 1] = elisp.to_string(v)
    elseif type(v) == "table" and v.name then
      out[#out + 1] = v.name
    else
      out[#out + 1] = "???"
    end
  end
  return out
end

--- Allowed values for a property (`PROP_ALL`), searched upward then globally.
---@return string[]|nil
function Headline:get_allowed_values(name)
  return allowed_values(self:get_property(name:upper() .. "_ALL", true))
end

---@return string[]|nil
function File:get_allowed_values(name)
  return allowed_values(self:get_property(name:upper() .. "_ALL", true))
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
