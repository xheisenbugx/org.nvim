---@mod org.extensions.transclusion.source Finding and formatting transcluded text
---
--- `resolve(spec, ctx)` finds the source of a `#+transclude:` keyword (a
--- file, a headline by title, CUSTOM_ID or ID, a `#+NAME:` element, a
--- `<<target>>` paragraph, a range of lines, a noweb chunk or a thing at
--- point) and formats its text the way org-transclusion does: elements
--- excluded, headline levels shifted to `:level`, links expanded, code
--- wrapped in a src block, and nested transclusions expanded up to a depth
--- limit.

local keyword = require("org.extensions.transclusion.keyword")
local utils = require("org.utils")

local M = {}

---@class org.transclusion.Result
---@field path string|nil source file (nil for an unnamed buffer)
---@field bufnr integer|nil the source's loaded buffer
---@field kind "org"|"text"
---@field first integer first source line (in the source without transclusions)
---@field last integer last source line
---@field raw string[] the source lines first..last
---@field tail string|nil the rest of line `last` after `raw` (a thing at point ends inside it)
---@field lines string[] the formatted text to show
---@field lang string|nil language of text sources
---@field label string where the text comes from, for display
---@field sources table<string, boolean> files read, nested ones included
---@field errors string[] problems with nested transclusions

--- Lines of a loaded buffer as its file would have them, with a map from
--- those lines to buffer rows. Set by the extension to leave out
--- materialized transclusions.
---@type fun(buf: integer): string[], integer[]|nil
M.buffer_lines = function(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false), nil
end

--- Options of the extension (set by init.lua).
M.opts = {}

local disk = {} -- path -> { mtime, lines } (or { mtime, err })
local bufread = {} -- buf -> { tick, lines, map }
local parsed = {} -- key -> org.File
local resolved = {} -- keyword key -> { res, sig }
local resolved_n = 0
-- path -> real path (or false); symbolic links rarely change, and this
-- is asked for every source of every drawing pass
local reals = {}

-- A drawing pass asks for the same buffers and files many times (200
-- keywords into 50 files): `frame` memoizes buffer lookups and file stats
-- while it runs.
local memo

--- Forget cached text: of `path` (results made from it are checked
--- against their sources anyway), or of everything.
function M.clear_cache(path)
  if path then
    disk[path] = nil
    return
  end
  disk = {}
  bufread = {}
  parsed = {}
  reals = {}
  resolved, resolved_n = {}, 0
end

--- Run `fn(...)` with buffer lookups and file stats memoized.
function M.frame(fn, ...)
  if memo then
    return fn(...)
  end
  memo = { stat = {}, find = {} }
  local ok, a, b, c, d = pcall(fn, ...)
  memo = nil
  if not ok then
    error(a, 0)
  end
  return a, b, c, d
end

--- A stamp of the file's version: its mtime to the nanosecond and size
--- (a number of nanoseconds since 1970 doesn't fit a double), or nil.
---@param path string
---@return string|nil
function M.stamp(path)
  local st = vim.uv.fs_stat(path)
  return st and string.format("%d.%09d:%d", st.mtime.sec, st.mtime.nsec, st.size) or nil
end

local function mtime(path)
  if not memo then
    return M.stamp(path)
  end
  local m = memo.stat[path]
  if m == nil then
    m = M.stamp(path) or false
    memo.stat[path] = m
  end
  return m or nil
end

local function real(path)
  local r = reals[path]
  if r == nil then
    r = utils.realpath(path) or false
    reals[path] = r
  end
  return r
end

--- The loaded buffer of `path` (by name, then by real path).
local function find_buffer(path)
  if not memo then
    return utils.find_buffer(path)
  end
  local key = path
  local f = memo.find[key]
  if f ~= nil then
    return f or nil
  end
  if not memo.names then
    memo.names, memo.tails = {}, {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" then
          name = vim.fs.normalize(name)
          memo.names[name] = b
          memo.tails[name:match("[^/]*$")] = true
        end
      end
    end
  end
  path = vim.fs.normalize(path)
  f = memo.names[path]
  -- through links: only when a loaded buffer has the same file name
  if not f and memo.tails[path:match("[^/]*$")] then
    local rp = real(path)
    if rp then
      if not memo.reals then
        memo.reals = {}
        for name, b in pairs(memo.names) do
          local r = real(name)
          if r then
            memo.reals[r] = b
          end
        end
      end
      f = memo.reals[rp]
    end
  end
  memo.find[key] = f or false
  return f
end

M.find_buffer = find_buffer

--- The key of `sources` (a set of paths) naming the same file as `path`,
--- through symbolic links too (/var and /private/var on macOS).
---@param sources table<string, boolean>
---@param path string
---@return string|nil
function M.source_key(sources, path)
  if sources[path] then
    return path
  end
  local r = real(path)
  if r then
    for p in pairs(sources) do
      if real(p) == r then
        return p
      end
    end
  end
end

function M.is_org_path(path)
  return path ~= nil and (path:match("%.org$") ~= nil or path:match("%.org_archive$") ~= nil)
end

--- Lines of a file, or nil and an error (binary files are refused).
local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil, "Cannot read " .. vim.fn.fnamemodify(path, ":~:.")
  end
  local content = fd:read("*a") or ""
  fd:close()
  if content:sub(1, 8000):find("\0", 1, true) then
    return nil, vim.fn.fnamemodify(path, ":~:.") .. " is a binary file"
  end
  content = content:gsub("\r\n", "\n")
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Current text of a source: its loaded buffer, else the file on disk.
---@param path string|nil
---@param bufnr? integer used when `path` is nil or unnamed
---@return string[]|nil lines, integer|nil bufnr, integer[]|nil map, string key or error
function M.read(path, bufnr)
  local b = bufnr
  if path and path ~= "" then
    b = find_buffer(path)
  end
  if b and vim.api.nvim_buf_is_loaded(b) then
    local tick = vim.api.nvim_buf_get_changedtick(b)
    local c = bufread[b]
    if not c or c.tick ~= tick then
      local lines, map = M.buffer_lines(b)
      c = { tick = tick, lines = lines, map = map }
      bufread[b] = c
    end
    return c.lines, b, c.map, "b" .. b .. ":" .. tick
  end
  if not path or path == "" then
    return nil, nil, nil, "Cannot read the buffer"
  end
  local mt = mtime(path)
  if not mt then
    return nil, nil, nil, "Cannot read " .. vim.fn.fnamemodify(path, ":~:.")
  end
  local c = disk[path]
  if not c or c.mtime ~= mt then
    local lines, err = read_file(path)
    c = { mtime = mt, lines = lines, err = err }
    disk[path] = c
  end
  if not c.lines then
    return nil, nil, nil, c.err
  end
  return c.lines, nil, nil, "m" .. path .. ":" .. mt
end

--- A cheap signature of a source's current version (buffer tick or mtime).
function M.signature(path)
  local b = find_buffer(path)
  if b then
    return "b" .. b .. ":" .. vim.api.nvim_buf_get_changedtick(b)
  end
  return "m" .. tostring(mtime(path))
end

-- the parsed source, one per file or buffer (its latest version)
local function parse(lines, path, key)
  local k = path or key:match("^b%d+") or key
  local c = parsed[k]
  if not c or c.key ~= key or c.lines ~= lines then
    c = { key = key, lines = lines, file = require("org.parser").parse(lines, path) }
    parsed[k] = c
  end
  return c.file
end

---------------------------------------------------------------------------
-- Locating the source region
---------------------------------------------------------------------------

local function trim_blank_end(lines, first, last)
  while last > first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  return last
end

--- The top-level element of its section that contains line `lnum`.
local function element_around(file, lines, lnum)
  local hl = file:headline_at(lnum)
  if hl and hl.line == lnum then
    return hl.line, hl.end_line
  end
  local s = hl and hl.line + 1 or 1
  local e = hl and hl.body_end or file.preamble_end
  for _, el in ipairs(require("org.element").parse(lines, s, e)) do
    if el.first <= lnum and lnum <= el.last then
      return el.first, el.clast
    end
  end
  return lnum, lnum
end

local function words_find(lines, search, from)
  local words = vim.split(vim.trim(search), "%s+", { trimempty = true })
  if #words == 0 then
    return nil
  end
  local pat = table.concat(
    vim.tbl_map(function(w)
      return vim.pesc(w:lower())
    end, words),
    "%s+"
  )
  for i = from or 1, #lines do
    if lines[i]:lower():find(pat) then
      return i
    end
  end
end

local function regexp_find(lines, re, from)
  local ok, rx = pcall(vim.regex, require("org.links").emacs_regexp_to_vim(re))
  if not ok then
    return nil
  end
  for i = from or 1, #lines do
    if rx:match_str(lines[i]) then
      return i
    end
  end
end

--- Line where `search` points in a text file (`::N`, `::/regexp/` or
--- words), or nil.
local function text_search(lines, search, from)
  if search:match("^%d+$") then
    local n = tonumber(search)
    return n >= 1 and n <= #lines and n or nil
  end
  local re = search:match("^/(.*)/$")
  if re then
    return regexp_find(lines, re, from)
  end
  return words_find(lines, search, from)
end

--- Region of an org search option: a subtree, or an element.
---@return integer|nil first, integer|nil last, string|nil err
local function org_search(file, lines, search, id)
  if id then
    local hl = file:find_by_id(id)
    if hl then
      return hl.line, hl.end_line
    end
    if file.properties and file.properties.ID == id then
      return 1, #lines
    end
    return nil, nil, "Cannot find entry with ID: " .. id
  end
  local s = vim.trim(search)
  if s:sub(1, 1) == "*" then
    local hl = file:find_by_title(vim.trim(s:sub(2)))
    if hl then
      return hl.line, hl.end_line
    end
    return nil, nil, "No match for heading: " .. s:sub(2)
  elseif s:sub(1, 1) == "#" then
    local hl = file:find_by_custom_id(s:sub(2))
    if hl then
      return hl.line, hl.end_line
    end
    return nil, nil, "No match for custom ID: " .. s:sub(2)
  elseif s:match("^%d+$") or s:match("^/.*/$") then
    local n = text_search(lines, s)
    if n then
      return element_around(file, lines, n)
    end
    return nil, nil, "No match for " .. s
  end
  -- fuzzy: <<target>>, #+NAME:, then a headline with that title
  local lower = s:lower()
  for i, l in ipairs(lines) do
    if l:lower():find("<<" .. lower .. ">>", 1, true) then
      return element_around(file, lines, i)
    end
  end
  for i, l in ipairs(lines) do
    local name = l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]*(.-)[ \t]*$")
    if name and name:lower() == lower then
      return element_around(file, lines, i)
    end
  end
  local hl = file:find_by_title(s)
  if hl then
    return hl.line, hl.end_line
  end
  return nil, nil, "No match for fuzzy expression: " .. s
end

--- Apply `:lines a-b` (inclusive, relative to `start`) and `:end`. `:end`
--- wins over the end of `:lines`, which applies when `:end` finds nothing
--- (org-transclusion-content-range-of-lines). `last` caps the range (a
--- noweb chunk's end).
local function line_range(lines, start, spec, last)
  last = last or #lines
  local a, b = 0, 0
  if spec.lines then
    local x, y = spec.lines:match("^(%d*)%-(%d*)$")
    a, b = tonumber(x) or 0, tonumber(y) or 0
  end
  local first = a > 0 and start + a - 1 or start
  local stop = last
  local n = not spec.thing
    and spec.end_search
    and spec.end_search ~= ""
    and text_search(lines, spec.end_search, first + 1)
  if n then
    stop = n - 1
  elseif b > 0 then
    stop = math.min(last, start + b - 1)
  end
  return first, stop
end

---------------------------------------------------------------------------
-- :thing-at-point and noweb chunks (org-transclusion-src-lines)
---------------------------------------------------------------------------

local CLOSE = { ["("] = ")", ["["] = "]", ["{"] = "}" }

-- end (line, col) of the bracketed group opening at lines[l]:sub(c, c);
-- double-quoted strings are skipped
local function balanced(lines, l, c)
  local stack, instr = {}, false
  for i = l, #lines do
    local s = lines[i]
    local j = i == l and c or 1
    while j <= #s do
      local ch = s:sub(j, j)
      if instr then
        if ch == "\\" then
          j = j + 1
        elseif ch == '"' then
          instr = false
        end
      elseif ch == '"' then
        instr = true
      elseif CLOSE[ch] then
        stack[#stack + 1] = CLOSE[ch]
      elseif ch == stack[#stack] then
        stack[#stack] = nil
        if #stack == 0 then
          return i, j
        end
      end
      j = j + 1
    end
  end
end

-- the next non-blank position at or after (l, c)
local function skip_blank(lines, l, c)
  while l <= #lines do
    local j = lines[l]:find("%S", c)
    if j then
      return l, j
    end
    l, c = l + 1, 1
  end
end

local function paragraph_end(lines, l)
  local e = l
  while e + 1 <= #lines and not lines[e + 1]:match("^%s*$") do
    e = e + 1
  end
  return e, #lines[e]
end

local THINGS = {
  sexp = function(lines, l, c)
    local ch = lines[l]:sub(c, c)
    if CLOSE[ch] then
      return balanced(lines, l, c)
    elseif ch == '"' then
      local j = c + 1
      local s = lines[l]
      while j <= #s do
        local x = s:sub(j, j)
        if x == "\\" then
          j = j + 1
        elseif x == '"' then
          return l, j
        end
        j = j + 1
      end
      return nil
    end
    local e = lines[l]:find('[%s%(%)%[%]{}"]', c)
    return l, (e or #lines[l] + 1) - 1
  end,
  list = function(lines, l, c)
    local j = lines[l]:find("[%(%[{]", c)
    if j then
      return balanced(lines, l, j)
    end
  end,
  defun = function(lines, l, c)
    local s = lines[l]
    if CLOSE[s:sub(c, c)] then
      return balanced(lines, l, c)
    end
    if s:match(":%s*$") or s:match(":%s*#.*$") then
      -- an indented block (Python and the like)
      local ind = #s:match("^%s*")
      local e = l
      for i = l + 1, #lines do
        if not lines[i]:match("^%s*$") then
          if #lines[i]:match("^%s*") <= ind then
            break
          end
          e = i
        end
      end
      return e, #lines[e]
    end
    -- the braces of a C-like function, up to a blank line
    for i = l, #lines do
      if i > l and lines[i]:match("^%s*$") then
        break
      end
      local j = lines[i]:find("{", i == l and c or 1, true)
      if j then
        return balanced(lines, i, j)
      end
    end
    return paragraph_end(lines, l)
  end,
  paragraph = function(lines, l)
    return paragraph_end(lines, l)
  end,
  line = function(lines, l)
    return l, #lines[l]
  end,
  word = function(lines, l, c)
    local _, e = lines[l]:find("^[%w_]+", c)
    return l, e or c
  end,
  symbol = function(lines, l, c)
    local _, e = lines[l]:find("^[^%s%(%)%[%]{}\"',;`]+", c)
    return l, e or c
  end,
  sentence = function(lines, l, c)
    for i = l, #lines do
      if i > l and lines[i]:match("^%s*$") then
        return i - 1, #lines[i - 1]
      end
      local j = lines[i]:find("[%.%?!]%f[%s%z]", i == l and c or 1)
      if j then
        return i, j
      end
    end
    return #lines, #lines[#lines]
  end,
}

--- End (line, col) of `count` things from the indentation of line `l`
--- (org-transclusion--bounds-of-n-things-at-point).
local function thing_end(lines, l, thing, count)
  local fn = THINGS[thing]
  if not fn then
    return nil, nil, "Unsupported :thing-at-point " .. thing
  end
  local c = lines[l] and lines[l]:find("%S")
  if not c then
    return nil, nil, "No " .. thing .. " at line " .. l
  end
  local el, ec
  for _ = 1, math.max(1, count or 1) do
    local nl, nc = fn(lines, l, c)
    if not nl then
      break
    end
    el, ec = nl, nc
    l, c = skip_blank(lines, el, ec + 1)
    if not l then
      break
    end
  end
  if not el then
    return nil, nil, "No " .. thing .. " at line " .. (l or #lines)
  end
  return el, ec
end

--- First line of the noweb chunk `name` (the line after `<<name>>=`) and
--- its last line: before the next `@` or `<<...>>=` line, blank lines
--- left out (org-transclusion--goto-noweb-chunk-beginning and -end).
local function noweb_chunk(lines, name)
  local head = "<<" .. name .. ">>="
  for i, l in ipairs(lines) do
    if l:find(head, 1, true) then
      local e = #lines
      for j = i + 1, #lines do
        if lines[j]:match("^@") or lines[j]:match("^<<.->>=") then
          e = j - 1
          break
        end
      end
      while e > i and lines[e]:match("^%s*$") do
        e = e - 1
      end
      return i + 1, e
    end
  end
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local PLANNING = { "^%s*SCHEDULED:", "^%s*DEADLINE:", "^%s*CLOSED:" }

local function is_planning(line)
  for _, p in ipairs(PLANNING) do
    if line and line:match(p) then
      return true
    end
  end
  return false
end

--- Mark the lines of excluded element types in first..last.
local function mark_excluded(file, lines, first, last, types, drop)
  local function walk(els)
    for _, el in ipairs(els) do
      if types[el.type] then
        for i = el.first, math.min(el.last, last) do
          drop[i] = true
        end
      elseif el.children and #el.children > 0 then
        walk(el.children)
      end
    end
  end
  -- only property drawers (the default): they can only open a section,
  -- no need to parse every element of a long subtree
  local simple = true
  for t in pairs(types) do
    if t ~= "property-drawer" and t ~= "planning" then
      simple = false
    end
  end
  local function section(s, e, head)
    if s > e then
      return
    end
    if not simple then
      walk(require("org.element").parse(lines, s, e))
      return
    end
    if not types["property-drawer"] then
      return
    end
    local i = s
    if not head then
      -- the file's drawer comes after blank and comment lines only
      while i <= e and (lines[i]:match("^%s*$") or lines[i]:match("^%s*#%s") or lines[i]:match("^%s*#$")) do
        i = i + 1
      end
    end
    if i <= e and lines[i]:match("^%s*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:%s*$") then
      for j = i + 1, e do
        if lines[j]:match("^%s*:[Ee][Nn][Dd]:%s*$") then
          for k = i, j do
            drop[k] = true
          end
          return
        end
      end
    end
  end
  local cur = first
  for _, hl in ipairs(file.headlines) do
    if hl.line >= first and hl.line <= last then
      section(cur, hl.line - 1)
      local s = hl.line + 1
      if is_planning(lines[s]) and s <= last then
        if types.planning then
          drop[s] = true
        end
        s = s + 1
      end
      cur = s
      section(s, math.min(hl.body_end, last), true)
      cur = math.min(hl.body_end, last) + 1
    end
  end
  section(cur, last)
end

local function expand_links(line, dir)
  local function abs(p)
    if p:match("^/") or p:match("^~") or p:match("^%a:[/\\]") then
      return nil
    end
    return vim.fs.normalize(dir .. "/" .. p)
  end
  line = line:gsub("%[%[file:([^%]]-)%]", function(p)
    local path, rest = p:match("^(.-)(::.*)$")
    path, rest = path or p, rest or ""
    local a = abs(path)
    return a and ("[[file:" .. a .. rest .. "]") or nil
  end)
  line = line:gsub("%[%[(%.%.?/[^%]]-)%]", function(p)
    local a = abs(p)
    return a and ("[[" .. a .. "]") or nil
  end)
  return line
end

--- Shift the headlines of `out` (flagged in `heads`) so that the first is
--- at `level`.
local function shift_levels(out, heads, level)
  local base
  for i = 1, #out do
    if heads[i] then
      base = #out[i]:match("^(%*+)")
      break
    end
  end
  if not base or level == base then
    return
  end
  local diff = level - base
  for i = 1, #out do
    if heads[i] then
      local stars, rest = out[i]:match("^(%*+)(.*)$")
      out[i] = string.rep("*", math.max(1, #stars + diff)) .. rest
    end
  end
end

local resolve

--- Replace nested `#+transclude:` lines of org text by their content.
local function expand_nested(out, heads, ctx, res)
  local maxd = M.opts.max_depth or 5
  if M.opts.nested == false then
    return out
  end
  local result = {}
  local level = ctx.level or 0
  local block
  for i, line in ipairs(out) do
    local handled = false
    if heads[i] then
      level = #line:match("^(%*+)")
    end
    if block then
      if line:lower():match("^[ \t]*#%+end_" .. vim.pesc(block) .. "[ \t]*$") then
        block = nil
      end
    else
      local b = line:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
      if b then
        block = b:lower()
      else
        local indent, value = keyword.match(line)
        if indent then
          local spec, err = keyword.parse(value)
          if spec and (ctx.depth or 0) + 1 >= maxd then
            err = "transclusions nested deeper than max_depth (" .. maxd .. ")"
            spec = nil
          end
          if spec then
            local sub, serr = resolve(spec, {
              dir = ctx.src_dir,
              filename = ctx.src_path,
              bufnr = ctx.src_buf,
              level = level,
              indent = indent,
              chain = ctx.chain,
              depth = (ctx.depth or 0) + 1,
            })
            if sub then
              vim.list_extend(result, sub.lines)
              for p in pairs(sub.sources) do
                res.sources[p] = true
              end
              vim.list_extend(res.errors, sub.errors)
              handled = true
            else
              err = serr
            end
          end
          if not handled and err then
            res.errors[#res.errors + 1] = err
          end
        end
      end
    end
    if not handled then
      result[#result + 1] = line
    end
  end
  return result
end

--- `:no-first-heading` and `:level` (org-transclusion-content-format-org-headlines).
local function format_levels(out, heads, spec, ctx)
  if spec.no_first_heading and heads[1] then
    table.remove(out, 1)
    local h = {}
    for i in pairs(heads) do
      if i > 1 then
        h[i - 1] = true
      end
    end
    heads = h
  end
  local level = spec.level
  if level == "auto" then
    level = (ctx.level or 0) + 1
  end
  if level then
    shift_levels(out, heads, level)
  end
  return out, heads
end

local function format_org(file, lines, first, last, spec, ctx, whole, res)
  local drop = {}
  local types = {}
  for _, t in ipairs(M.opts.exclude_elements or {}) do
    types[t] = true
  end
  for _, t in ipairs(spec.exclude or {}) do
    types[t] = true
  end
  if next(types) then
    mark_excluded(file, lines, first, last, types, drop)
  end
  local is_head = {}
  for _, hl in ipairs(file.headlines) do
    if hl.line >= first and hl.line <= last then
      is_head[hl.line] = true
    end
  end
  if whole and M.opts.include_first_section == false then
    for i = first, math.min(last, file.preamble_end) do
      drop[i] = true
    end
  end
  if spec.only_contents then
    for i in pairs(is_head) do
      drop[i] = true
    end
  end
  local out, heads = {}, {}
  for i = first, last do
    if not drop[i] then
      out[#out + 1] = lines[i]
      heads[#out] = is_head[i] or nil
    end
  end
  out, heads = format_levels(out, heads, spec, ctx)
  if spec.expand_links and res.path then
    local dir = vim.fn.fnamemodify(res.path, ":h")
    for i, l in ipairs(out) do
      out[i] = expand_links(l, dir)
    end
  end
  out = expand_nested(out, heads, ctx, res)
  return out
end

local function format_text(raw, spec, ctx)
  local out = {}
  local indent = ctx.indent or ""
  if spec.src then
    out[1] = indent .. "#+begin_src " .. spec.src .. (spec.rest and (" " .. spec.rest) or "")
  end
  for _, l in ipairs(raw) do
    out[#out + 1] = (l == "" and "" or indent) .. l
  end
  if spec.src then
    out[#out + 1] = indent .. "#+end_src"
  end
  return out
end

---------------------------------------------------------------------------
-- Resolving
---------------------------------------------------------------------------

---@class org.transclusion.Context
---@field dir? string directory relative links resolve against
---@field filename? string the file holding the keyword
---@field bufnr? integer the buffer holding the keyword
---@field level? integer level of the headline around the keyword (0 = none)
---@field indent? string indentation of the keyword
---@field chain? table<string, boolean> sources being expanded (cycles)
---@field depth? integer nesting depth

--- Find and format the text a keyword transcludes.
---@param spec org.transclusion.Spec
---@param ctx org.transclusion.Context
---@return org.transclusion.Result|nil, string|nil err
resolve = function(spec, ctx)
  ctx = ctx or {}
  -- a link type that says what to transclude (the code extension's code:
  -- gives the file, the lines of the definition and its language)
  local lt = (require("org.config").opts.links.types or {})[spec.type]
  if type(lt) == "table" and type(lt.transclude) == "function" then
    local ok, conv, err = pcall(lt.transclude, spec.path, ctx)
    if not ok or type(conv) ~= "table" or not conv.path then
      return nil, tostring(ok and (err or ("cannot transclude " .. spec.link)) or conv)
    end
    spec = vim.tbl_extend("force", spec, {
      type = "file",
      path = conv.path,
      search = nil,
      lines = spec.lines or conv.lines,
      src = spec.src or conv.src,
    })
  end
  local dir = ctx.dir or (ctx.filename and vim.fn.fnamemodify(ctx.filename, ":h")) or vim.fn.getcwd()
  local path, id
  local search = spec.search
  if spec.type == "file" then
    path = spec.path == "" and ctx.filename or utils.expand(spec.path, dir)
  elseif spec.type == "id" then
    id = spec.path
    local loc = require("org.id").find(id)
    if not loc then
      return nil, "Cannot find entry with ID: " .. id
    end
    path = loc.filename and vim.fs.normalize(loc.filename)
    search = nil
  elseif spec.type == "heading" or spec.type == "custom-id" or spec.type == "fuzzy" then
    path = ctx.filename
  else
    return nil, "cannot transclude a " .. tostring(spec.type) .. ": link"
  end
  if path == "" then
    path = nil
  end
  local lines, bufnr, map, key = M.read(path, not path and ctx.bufnr or nil)
  if not lines then
    return nil, key
  end
  local ckey = (path or ("buffer " .. tostring(bufnr))) .. "::" .. (id and ("id:" .. id) or search or "")
  local chain = vim.deepcopy(ctx.chain or {})
  if chain[ckey] then
    return nil, "recursive transclusion of " .. ckey
  end
  chain[ckey] = true
  local is_org = (path == nil or M.is_org_path(path)) and not spec.src
  local res = {
    path = path,
    bufnr = bufnr,
    map = map,
    key = key,
    kind = is_org and "org" or "text",
    sources = {},
    errors = {},
  }
  if path then
    res.sources[path] = true
  end
  local label = path and vim.fn.fnamemodify(path, ":t") or "this buffer"
  if id then
    label = "id:" .. id
  elseif search then
    label = label .. "::" .. search
  end
  local first, last, err
  local whole = false
  -- `:lines`, `:end` and `:thing-at-point` on an Org file take its lines
  -- as they are (org-transclusion-src-lines runs before the Org
  -- functions); an ID link keeps its headline levels ("org-lines")
  local org_lines = is_org and path ~= nil and (spec.lines or spec.end_search or spec.thing) and true or false
  if is_org and not (org_lines and not id) then
    local file = parse(lines, path, key)
    if id or search then
      first, last, err = org_search(file, lines, search, id)
      if not first then
        return nil, err
      end
    else
      first, last, whole = 1, #lines, true
    end
    if org_lines then
      first, last = line_range(lines, first, spec, #lines)
      last = math.min(last, #lines)
      res.first, res.last = first, last
      res.raw = vim.list_slice(lines, first, last)
      local out, heads = {}, {}
      for i = first, last do
        out[#out + 1] = lines[i]
        heads[#out] = lines[i]:match("^%*+ ") and require("org.parser").outline_level(lines[i]) and true or nil
      end
      res.lines = format_levels(out, heads, spec, ctx)
    else
      last = trim_blank_end(lines, first, math.min(last, #lines))
      res.first, res.last = first, last
      res.raw = vim.list_slice(lines, first, last)
      local sub_ctx = vim.tbl_extend("force", ctx, {
        chain = chain,
        src_dir = path and vim.fn.fnamemodify(path, ":h") or dir,
        src_path = path,
        src_buf = bufnr,
      })
      res.lines = format_org(file, lines, first, last, spec, sub_ctx, whole, res)
    end
  else
    -- text, or the lines of an Org file: from the search target (or the
    -- noweb chunk) to the end of the file, `:lines`, `:end` or the thing
    local start, stop = 1, #lines
    if spec.noweb_chunk and search then
      start, stop = noweb_chunk(lines, search)
      if not start then
        return nil, "No noweb chunk " .. search
      end
    elseif search and is_org then
      local serr
      start, _, serr = org_search(parse(lines, path, key), lines, search)
      if not start then
        return nil, serr
      end
    elseif search then
      start = text_search(lines, search)
      if not start then
        return nil, "No match for " .. search
      end
    end
    first, last = line_range(lines, start, spec, stop)
    if first > #lines or first < 1 then
      return nil, "Line " .. first .. " is past the end of " .. label
    end
    local cut
    if spec.thing then
      local el, ec, terr = thing_end(lines, start, spec.thing, tonumber(spec.end_search or "") or 1)
      if not el then
        return nil, terr
      end
      last = el
      if ec < #lines[el] then
        cut = ec
      end
    end
    last = math.min(last, #lines)
    res.first, res.last = first, last
    res.raw = vim.list_slice(lines, first, last)
    if cut and #res.raw > 0 then
      -- the rest of the line isn't transcluded, but stays in the source
      res.tail = res.raw[#res.raw]:sub(cut + 1)
      res.raw[#res.raw] = res.raw[#res.raw]:sub(1, cut)
    end
    res.lines = format_text(res.raw, spec, ctx)
    if is_org then
      res.kind = "org"
    elseif spec.src then
      res.lang = spec.src
    elseif path then
      res.lang = vim.filetype.match({ filename = path })
    end
    if spec.lines then
      label = label .. ":" .. first .. "-" .. last
    end
  end
  while #res.lines > 0 and res.lines[#res.lines]:match("^%s*$") do
    table.remove(res.lines)
  end
  res.label = label
  return res
end

M.resolve = resolve

-- signature of every file a result was made from
local function deps(res)
  local keys = vim.tbl_keys(res.sources)
  table.sort(keys)
  local parts = {}
  for _, p in ipairs(keys) do
    parts[#parts + 1] = M.signature(p)
  end
  if not res.path and res.bufnr and vim.api.nvim_buf_is_valid(res.bufnr) then
    parts[#parts + 1] = "b" .. res.bufnr .. ":" .. vim.api.nvim_buf_get_changedtick(res.bufnr)
  end
  return table.concat(parts, "|")
end

--- `resolve`, reusing the last result for the same keyword while none of
--- its sources changed. Results are shared: don't modify them.
---@param spec org.transclusion.Spec
---@param ctx org.transclusion.Context
---@return org.transclusion.Result|nil, string|nil err
function M.resolve_cached(spec, ctx)
  local key = table.concat({
    spec.value,
    tostring(ctx.level or 0),
    ctx.indent or "",
    ctx.filename or "",
    tostring(ctx.bufnr or ""),
    tostring(ctx.depth or 0),
  }, "\1")
  local c = resolved[key]
  if c and c.sig == deps(c.res) then
    return c.res
  end
  local res, err = resolve(spec, ctx)
  if res then
    if not c then
      resolved_n = resolved_n + 1
      if resolved_n > 2000 then
        resolved, resolved_n = {}, 1
      end
    end
    resolved[key] = { res = res, sig = deps(res) }
  elseif c then
    resolved[key] = nil
  end
  return res, err
end

--- Expand every `#+transclude:` keyword of `lines` (for export).
---@param lines string[]
---@param ctx org.transclusion.Context
---@param skip? fun(kw: table, lines: string[]): integer|nil number of lines after the keyword to drop
---@return string[] lines, string[] errors
function M.expand(lines, ctx, skip)
  local out, errors = {}, {}
  local kws = {}
  for _, kw in ipairs(keyword.scan(lines)) do
    kws[kw.row] = kw
  end
  local level = 0
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local stars = line:match("^(%*+) ")
    if stars then
      level = #stars
    end
    local kw = kws[i]
    if kw then
      local n = skip and skip(kw, lines) or 0
      local spec, err = keyword.parse(kw.value)
      if spec and spec.disable_auto then
        spec, err = nil, nil
      end
      if spec then
        local res, rerr = resolve(spec, {
          dir = ctx.dir,
          filename = ctx.filename,
          bufnr = ctx.bufnr,
          level = level,
          indent = kw.indent,
          depth = 0,
        })
        if res then
          vim.list_extend(out, res.lines)
          vim.list_extend(errors, res.errors)
        else
          errors[#errors + 1] = rerr
        end
      elseif err then
        errors[#errors + 1] = err
      end
      i = i + 1 + n
    else
      out[#out + 1] = line
      i = i + 1
    end
  end
  return out, errors
end

return M
