---@mod org.extensions.transclusion.source Finding and formatting transcluded text
---
--- `resolve(spec, ctx)` finds the source of a `#+transclude:` keyword (a
--- file, a headline by title, CUSTOM_ID or ID, a `#+NAME:` element, a
--- `<<target>>` paragraph or a range of lines) and formats its text the
--- way org-transclusion does: elements excluded, headline levels shifted
--- to `:level`, links expanded, code wrapped in a src block, and nested
--- transclusions expanded up to a depth limit.

local element = require("org.element")
local keyword = require("org.extensions.transclusion.keyword")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@class org.transclusion.Result
---@field path string|nil source file (nil for an unnamed buffer)
---@field bufnr integer|nil the source's loaded buffer
---@field kind "org"|"text"
---@field first integer first source line (in the source without transclusions)
---@field last integer last source line
---@field raw string[] the source lines first..last
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

local disk = {} -- path -> { mtime, lines }
local parsed = {} -- key -> org.File

function M.clear_cache(path)
  if path then
    disk[path] = nil
  else
    disk = {}
  end
  parsed = {}
end

function M.is_org_path(path)
  return path ~= nil and (path:match("%.org$") ~= nil or path:match("%.org_archive$") ~= nil)
end

--- Current text of a source: its loaded buffer, else the file on disk.
---@param path string|nil
---@param bufnr? integer used when `path` is nil or unnamed
---@return string[]|nil lines, integer|nil bufnr, integer[]|nil map, string key
function M.read(path, bufnr)
  local b = bufnr
  if path and path ~= "" then
    b = utils.find_buffer(path)
  end
  if b and vim.api.nvim_buf_is_loaded(b) then
    local lines, map = M.buffer_lines(b)
    return lines, b, map, "b" .. b .. ":" .. vim.api.nvim_buf_get_changedtick(b)
  end
  if not path or path == "" then
    return nil, nil, nil, ""
  end
  local mtime = utils.mtime(path)
  if not mtime then
    return nil, nil, nil, ""
  end
  local c = disk[path]
  if not c or c.mtime ~= mtime then
    c = { mtime = mtime, lines = utils.readfile(path) or {} }
    disk[path] = c
  end
  return c.lines, nil, nil, "m" .. path .. ":" .. mtime
end

--- A cheap signature of a source's current version (buffer tick or mtime).
function M.signature(path)
  local b = utils.find_buffer(path)
  if b then
    return "b" .. b .. ":" .. vim.api.nvim_buf_get_changedtick(b)
  end
  return "m" .. tostring(utils.mtime(path))
end

local function parse(lines, path, key)
  local k = key .. "\0" .. (path or "")
  local f = parsed[k]
  if not f or f.lines ~= lines then
    f = parser.parse(lines, path)
    parsed[k] = f
  end
  return f
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
  for _, el in ipairs(element.parse(lines, s, e)) do
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

--- Apply `:lines a-b` (inclusive, relative to `start`) and `:end`.
local function line_range(lines, start, spec, last)
  last = last or #lines
  local a, b = 0, 0
  if spec.lines then
    local x, y = spec.lines:match("^(%d*)%-(%d*)$")
    a, b = tonumber(x) or 0, tonumber(y) or 0
  end
  local first = a > 0 and start + a - 1 or start
  local stop = last
  if spec.end_search and spec.end_search ~= "" then
    local n = text_search(lines, spec.end_search, first + 1)
    if n then
      stop = n - 1
    end
  elseif b > 0 then
    stop = math.min(#lines, start + b - 1)
  end
  return first, stop
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
  local function section(s, e)
    if s > e then
      return
    end
    walk(element.parse(lines, s, e))
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
      section(s, math.min(hl.body_end, last))
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
  if spec.expand_links and res.path then
    local dir = vim.fn.fnamemodify(res.path, ":h")
    for i, l in ipairs(out) do
      out[i] = expand_links(l, dir)
    end
  end
  out = expand_nested(out, heads, ctx, res)
  return out
end

local function format_text(lines, first, last, spec, ctx)
  local out = {}
  local indent = ctx.indent or ""
  if spec.src then
    out[1] = indent .. "#+begin_src " .. spec.src .. (spec.rest and (" " .. spec.rest) or "")
  end
  for i = first, last do
    out[#out + 1] = (lines[i] == "" and "" or indent) .. lines[i]
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
    return nil, "Cannot read " .. (path and vim.fn.fnamemodify(path, ":~:.") or "the buffer")
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
  if is_org then
    local file = parse(lines, path, key)
    if id or search then
      first, last, err = org_search(file, lines, search, id)
      if not first then
        return nil, err
      end
    else
      first, last, whole = 1, #lines, true
    end
    if spec.lines or spec.end_search then
      first, last = line_range(lines, first, spec, spec.lines and #lines or last)
      whole = false
    end
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
  else
    local start = 1
    local ranged = spec.lines or spec.end_search or spec.src
    if search and ranged then
      start = text_search(lines, search)
      if not start then
        return nil, "No match for " .. search
      end
    end
    first, last = 1, #lines
    if ranged then
      first, last = line_range(lines, start, spec)
    end
    if first > #lines then
      return nil, "Line " .. first .. " is past the end of " .. label
    end
    last = math.min(last, #lines)
    res.first, res.last = first, last
    res.raw = vim.list_slice(lines, first, last)
    res.lines = format_text(lines, first, last, spec, ctx)
    if spec.src then
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
