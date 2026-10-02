---@mod org.cite Citations in the buffer (Emacs oc.el and oc-basic.el)
---
--- The insert, follow and activate capabilities of citation processors:
--- org-cite-insert (C-c C-x @) inserts or edits a `[cite:@key]` citation
--- with keys completed from the bibliography, org-open-at-point on a
--- citation opens the bibliography entry (org-cite-follow), and citations
--- are highlighted, unknown keys flagged (org-cite-activate). The processor
--- used for each is set by `export.cite.insert_processor`,
--- `follow_processor` and `activate_processor` ("basic" by default).
---
--- Positions follow Emacs points: in a string `s`, point `p` sits before
--- the character `s:sub(p, p)`.

local utils = require("org.utils")

local M = {}

local function ccfg()
  return (require("org.config").opts.export or {}).cite or {}
end

--- Report `msg` and abort the running action (Emacs user-error).
local function user_error(msg)
  utils.error(msg)
  utils.abort()
end
M.user_error = user_error

local function opt(name, default)
  local v = ccfg()[name]
  if v == nil then
    return default
  end
  return v
end

---------------------------------------------------------------------------
-- Syntax (org-element-citation-parser, org-element-citation-reference-parser)
---------------------------------------------------------------------------

--- org-element-citation-key-re: "@" then word characters or any of
--- -.:?!`'/*@+|(){}<>&_^$#%~.
local KEY_CHARS = "[%w\128-\255%-%.:%?!`'/%*@%+|%(%){}<>&_%^%$#%%~]"

--- First key in [from, limit): key start ("@"), key, key end.
local function find_key(s, from, limit)
  local i = from
  while true do
    local a = s:find("@", i, true)
    if not a or a >= limit then
      return nil
    end
    local run = s:match("^" .. KEY_CHARS .. "+", a + 1)
    if run then
      local e = math.min(a + 1 + #run, limit)
      if e > a + 1 then
        return a, s:sub(a + 1, e - 1), e
      end
    end
    i = a + 1
  end
end
M.find_key = find_key

--- Last `c` at an index in [from, to].
local function rfind(s, c, from, to)
  for i = to, from, -1 do
    if s:sub(i, i) == c then
      return i
    end
  end
end

--- Index of the "]" closing the "[" at p (square brackets only, like
--- org-element--pair-square-table).
local function closing_bracket(s, p)
  local depth = 0
  for k = p, #s do
    local c = s:byte(k)
    if c == 91 then
      depth = depth + 1
    elseif c == 93 then
      depth = depth - 1
      if depth == 0 then
        return k
      end
    end
  end
end

---@class org.cite.Reference
---@field begin integer
---@field stop integer end (after the ";" separator, if any)
---@field key string
---@field key_begin integer the "@"
---@field key_end integer
---@field prefix boolean
---@field suffix boolean

---@class org.cite.Citation
---@field begin integer the "["
---@field stop integer after "]" (org-cite-boundaries)
---@field end_ integer after the blanks following "]"
---@field style? string
---@field style_end integer the ":" after the style
---@field contents_begin integer
---@field contents_end integer
---@field prefix boolean global prefix
---@field suffix boolean global suffix
---@field references org.cite.Reference[]

--- Parse the citation starting at `p` in `s`, or nil.
---@return org.cite.Citation|nil
function M.parse(s, p)
  local style, after = s:match("^%[cite/([/_%w%-]+):()", p)
  if not style then
    after = s:match("^%[cite:()", p)
    if not after then
      return nil
    end
  end
  local start = s:match("^[\t\n ]*()", after)
  local close = closing_bracket(s, p)
  if not close then
    return nil
  end
  local _, _, first_key_end = find_key(s, start, close)
  if not first_key_end then
    return nil
  end
  local cite = {
    begin = p,
    stop = close + 1,
    end_ = s:match("^[ \t]*()", close + 1),
    style = style,
    style_end = after - 1,
    prefix = false,
    suffix = false,
  }
  -- :contents-begin depends on a non-empty common prefix
  local semi = rfind(s, ";", start, first_key_end - 1)
  if not semi then
    cite.contents_begin = start
  else
    cite.prefix = start < semi
    cite.contents_begin = semi + 1
  end
  -- :contents-end depends on a non-empty common suffix
  local e = close
  while e > first_key_end and s:sub(e - 1, e - 1):match("[ \r\t\n]") do
    e = e - 1
  end
  semi = rfind(s, ";", first_key_end, e - 1)
  if not semi or find_key(s, semi, e) then
    cite.contents_end = e
  else
    cite.suffix = semi + 1 < e
    cite.contents_end = semi + 1
  end
  -- references
  local refs = {}
  local pos = cite.contents_begin
  while pos < cite.contents_end do
    local kb, key, ke = find_key(s, pos, cite.contents_end)
    if not kb then
      break
    end
    local sep = s:find(";", ke, true)
    if sep and sep >= cite.contents_end then
      sep = nil
    end
    local stop = sep and sep + 1 or cite.contents_end
    local suffix_end = sep or cite.contents_end
    refs[#refs + 1] = {
      begin = pos,
      stop = stop,
      key = key,
      key_begin = kb,
      key_end = ke,
      prefix = pos < kb,
      suffix = ke < suffix_end,
    }
    pos = stop
  end
  cite.references = refs
  return cite
end

--- Citations in `s`, in order.
---@return org.cite.Citation[]
function M.citations(s)
  local out = {}
  local i = 1
  while true do
    local a = s:find("[cite", i, true)
    if not a then
      break
    end
    local c = M.parse(s, a)
    if c then
      out[#out + 1] = c
      i = c.stop
    else
      i = a + 1
    end
  end
  return out
end

local function blank_before(s, pos)
  local c = s:sub(pos - 1, pos - 1)
  return c == " " or c == "\t"
end

--- The citation or citation reference at point `pos` in `s`, following
--- org-element-context. Returns type, citation, reference.
---@return "citation"|"citation-reference"|nil, org.cite.Citation|nil, org.cite.Reference|nil
function M.context_in(s, pos)
  local last
  for _, c in ipairs(M.citations(s)) do
    if c.begin > pos then
      break
    end
    if c.end_ <= pos and c.end_ ~= #s + 1 then
      if c.end_ == pos and not blank_before(s, pos) then
        last = c
      end
    else
      local cb, ce = c.contents_begin, c.contents_end
      if pos >= cb and (pos < ce or (pos == ce and (pos == #s + 1 or not blank_before(s, pos)))) then
        local last_ref
        for _, r in ipairs(c.references) do
          if r.begin > pos then
            break
          end
          if r.stop <= pos and r.stop ~= ce then
            if r.stop == pos and not blank_before(s, pos) then
              last_ref = r
            end
          else
            return "citation-reference", c, r
          end
        end
        if last_ref then
          return "citation-reference", c, last_ref
        end
      end
      return "citation", c
    end
  end
  if last then
    return "citation", last
  end
  return nil
end

---------------------------------------------------------------------------
-- Buffer text around the cursor
---------------------------------------------------------------------------

local MAX_SPAN = 40

local function paragraph_bounds(lines_of, row, count)
  local function stop_line(l)
    return l == nil or l:match("^%s*$") or l:match("^%*+ ") or l:match("^%s*#%+")
  end
  local here = lines_of(row)
  if here:match("^%*+ ") then
    return row, row
  end
  local first, last = row, row
  while first > 1 and row - first < MAX_SPAN and not stop_line(lines_of(first - 1)) do
    first = first - 1
  end
  while last < count and last - row < MAX_SPAN and not stop_line(lines_of(last + 1)) do
    last = last + 1
  end
  return first, last
end

---@class org.cite.Region
---@field bufnr integer
---@field first integer first line (1-based)
---@field last integer
---@field text string lines joined with "\n"
---@field starts integer[] offset of each line in `text` (0-based)

--- The paragraph around line `row` of the buffer, as one string.
---@return org.cite.Region
function M.region(bufnr, row)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local cache = {}
  local function lines_of(r)
    if r < 1 or r > count then
      return nil
    end
    if not cache[r] then
      cache[r] = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1]
    end
    return cache[r]
  end
  local first, last = paragraph_bounds(lines_of, row, count)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local starts, off = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = off
    off = off + #l + 1
  end
  return { bufnr = bufnr, first = first, last = last, text = table.concat(lines, "\n"), starts = starts }
end

--- Point in the region's text for (row, col0).
function M.point(region, row, col)
  return region.starts[row - region.first + 1] + col + 1
end

--- Buffer (row, col0) of point `pos` in the region's text.
function M.position(region, pos)
  local off = pos - 1
  for i = #region.starts, 1, -1 do
    if off >= region.starts[i] then
      return region.first + i - 1, off - region.starts[i]
    end
  end
  return region.first, 0
end

--- The citation context at the cursor: { type, citation, reference, region, point }.
function M.at_cursor(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not row then
    row, col = unpack(vim.api.nvim_win_get_cursor(0))
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local region = M.region(bufnr, row)
  local pos = M.point(region, row, math.min(col, #line))
  local t, c, r = M.context_in(region.text, pos)
  return { type = t, citation = c, reference = r, region = region, point = pos }
end

--- Is the cursor on a citation or citation reference?
function M.at_point(bufnr, row, col)
  local ctx = M.at_cursor(bufnr, row, col)
  return ctx.type ~= nil and ctx or nil
end

---------------------------------------------------------------------------
-- Editing the region with Emacs marker semantics for the cursor
---------------------------------------------------------------------------

local Edit = {}
Edit.__index = Edit

local function new_edit(region, point)
  return setmetatable({ region = region, text = region.text, point = point }, Edit)
end

--- insert (before_markers: insert-before-markers, which moves a point
--- sitting at `pos`).
function Edit:insert(pos, str, before_markers)
  self.text = self.text:sub(1, pos - 1) .. str .. self.text:sub(pos)
  if self.point > pos or (self.point == pos and before_markers) then
    self.point = self.point + #str
  end
end

function Edit:delete(a, b)
  if b <= a then
    return
  end
  self.text = self.text:sub(1, a - 1) .. self.text:sub(b)
  if self.point >= b then
    self.point = self.point - (b - a)
  elseif self.point > a then
    self.point = a
  end
end

--- Write the text back and move the cursor to the tracked point.
function Edit:apply()
  local region = self.region
  local lines = vim.split(self.text, "\n", { plain = true })
  if self.drop_all then
    lines = {}
  end
  vim.api.nvim_buf_set_lines(region.bufnr, region.first - 1, region.last, false, lines)
  if #lines == 0 then
    lines = { "" }
  end
  local starts, off = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = off
    off = off + #l + 1
  end
  local new_region = { bufnr = region.bufnr, first = region.first, last = region.first + #lines - 1, starts = starts }
  local row, col = M.position(new_region, self.point)
  if vim.api.nvim_get_current_buf() == region.bufnr then
    pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
  end
end

---------------------------------------------------------------------------
-- Processors
---------------------------------------------------------------------------

--- Citation processors for the buffer capabilities, by name. A processor
--- is a table with any of `activate(citation_marks_ctx)`,
--- `follow(ctx, arg)` and `insert(ctx, arg)` (org-cite-register-processor).
M.processors = {}

--- org-cite-register-processor (buffer capabilities).
---@param name string
---@param spec { activate?: function, follow?: function, insert?: function }
function M.register_processor(name, spec)
  M.processors[name] = spec
end

local function processor_for(capability, option, what)
  local name = opt(option, "basic")
  if not name or name == "" then
    user_error(string.format("No processor set to %s citations", what))
  end
  local p = M.processors[name]
  if not p then
    user_error(string.format("Unknown processor %s", name))
  end
  if not p[capability] then
    user_error(string.format("Processor %s cannot %s citations", name, what))
  end
  return p
end

---------------------------------------------------------------------------
-- Bibliography of a buffer (org-cite-list-bibliography-files)
---------------------------------------------------------------------------

local function strip_quotes(s)
  return (s:gsub('^%s*"(.*)"%s*$', "%1"))
end

local function absolute(f, dir)
  f = vim.fn.expand(f)
  if f:match("^/") or f:match("^%a:[/\\]") then
    return vim.fs.normalize(f)
  end
  return vim.fs.normalize(dir .. "/" .. f)
end

--- Absolute names of the bibliography files of the buffer: its
--- #+BIBLIOGRAPHY keywords (setup files included) and
--- `export.cite.global_bibliography`.
function M.bibliography_files(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
  local out, seen = {}, {}
  local function add(f)
    if f and not seen[f] then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  if ok and file then
    for _, e in ipairs(file.settings.keyword_entries or {}) do
      if e.key == "BIBLIOGRAPHY" and e.value ~= "" then
        local base = dir
        if e.filename and e.filename ~= "" and e.filename ~= name then
          base = vim.fn.fnamemodify(e.filename, ":p:h")
        end
        add(absolute(strip_quotes(e.value), base))
      end
    end
  end
  for _, f in ipairs(opt("global_bibliography", {})) do
    add(absolute(f, dir))
  end
  return out
end

--- org-cite-basic--parse-bibliography outside export: a list of
--- { file, entries }, last file first (like Emacs); unreadable or
--- malformed files are skipped.
function M.parse_bibliography(bufnr)
  local cite = require("org.export.cite")
  local results = {}
  for _, f in ipairs(M.bibliography_files(bufnr)) do
    local real = utils.realpath(f) or f
    local ok, entries = pcall(cite.read_bibliography_file, real)
    if ok and entries then
      table.insert(results, 1, { real, entries })
    end
  end
  return results
end

local basic = {}
M.basic = basic

--- org-cite-basic--all-keys
function basic.all_keys(bib)
  local keys, seen = {}, {}
  for _, f in ipairs(bib) do
    local ks = vim.tbl_keys(f[2])
    table.sort(ks)
    for _, k in ipairs(ks) do
      if not seen[k] then
        seen[k] = true
        keys[#keys + 1] = k
      end
    end
  end
  return keys
end

--- org-cite-basic--get-entry
function basic.get_entry(bib, key)
  for _, f in ipairs(bib) do
    if f[2][key] then
      return f[2][key], f[1]
    end
  end
end

local function field(entry, name)
  for _, kv in ipairs(entry or {}) do
    if kv[1] == name then
      if kv[2] ~= nil and type(kv[2]) ~= "string" then
        error(string.format("Non-string bibliography field value: %s", vim.inspect(kv[2])), 0)
      end
      return kv[2]
    end
  end
end
basic.field = field

--- Year of an entry without disambiguation suffix (org-cite-basic--get-year).
function basic.year(entry)
  local year = field(entry, "year")
  if not year then
    local date = field(entry, "date")
    if type(date) == "string" then
      year = date:match("^(%d%d%d%d)%f[%D]") or date:match("^(%d%d%d%d)$")
    end
  end
  return year
end

--- truncate-string-to-width STR WIDTH nil ?\s
local function fit(s, width)
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. string.rep(" ", width - w)
end

--- org-cite-basic--key-completion-table: { { display, key }... } sorted
--- by display string, or nil when the bibliography has no entry.
function basic.completion_table(bib)
  local width = opt("basic_author_column_end", 25)
  local sep = opt("basic_column_separator", "  ")
  local map, displays = {}, {}
  for _, f in ipairs(bib) do
    for key, entry in pairs(f[2]) do
      local author = field(entry, "author") or field(entry, "editor")
      local d = (author and fit((author:gsub(" and ", "; ")), width) or string.rep(" ", width))
        .. sep
        .. string.format("%4s", basic.year(entry) or "")
        .. sep
        .. (field(entry, "title") or "")
      if map[d] == nil then
        displays[#displays + 1] = d
      end
      map[d] = key
    end
  end
  if #displays == 0 then
    return nil
  end
  table.sort(displays)
  local out = {}
  for i, d in ipairs(displays) do
    out[i] = { d, map[d] }
  end
  return out
end

--- Levenshtein distance (org-string-distance).
function M.string_distance(a, b)
  local la, lb = vim.fn.strchars(a), vim.fn.strchars(b)
  if la == 0 then
    return lb
  elseif lb == 0 then
    return la
  end
  local ca, cb = vim.fn.split(a, "\\zs"), vim.fn.split(b, "\\zs")
  local prev = {}
  for j = 0, lb do
    prev[j] = j
  end
  for i = 1, la do
    local cur = { [0] = i }
    for j = 1, lb do
      local cost = ca[i] == cb[j] and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[lb]
end

--- org-cite-basic--close-keys
function basic.close_keys(key, keys)
  local max = opt("basic_max_key_distance", 2)
  local out = {}
  for _, k in ipairs(keys) do
    if M.string_distance(k, key) <= max then
      out[#out + 1] = k
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Styles (org-cite-supported-styles)
---------------------------------------------------------------------------

--- Style names supported by the export processors of
--- `export.cite.export_processors` (or `processors`), merged in order.
---@param processors? string[]
---@return string[]
function M.supported_styles(processors)
  local cite = require("org.export.cite")
  if not processors then
    processors = {}
    local value = opt("export_processors", { t = { "basic" } })
    local function name_of(p)
      if type(p) == "string" then
        return (p:match("^%S+"))
      elseif type(p) == "table" then
        return p[1]
      end
    end
    if type(value) == "string" or (type(value) == "table" and type(value[1]) == "string") then
      processors[1] = name_of(value)
    elseif type(value) == "table" then
      local backends = vim.tbl_keys(value)
      table.sort(backends, function(a, b)
        a, b = tostring(a), tostring(b)
        if (a == "t" or a == "true") ~= (b == "t" or b == "true") then
          return b == "t" or b == "true"
        end
        return a < b
      end)
      for _, be in ipairs(backends) do
        processors[#processors + 1] = name_of(value[be])
      end
    end
  end
  local names, seen = {}, {}
  for _, name in ipairs(processors) do
    local p = cite.processors[name]
    local styles = p and p.cite_styles
    if type(styles) == "function" then
      styles = styles()
    end
    for _, entry in ipairs(styles or {}) do
      local style = entry[1][1]
      if not seen[style] then
        seen[style] = true
        names[#names + 1] = style
      end
    end
  end
  return names
end

---------------------------------------------------------------------------
-- Insert capability (org-cite-make-insert-processor, org-cite-insert)
---------------------------------------------------------------------------

--- org-cite-basic--complete-style
function basic.complete_style()
  local styles = M.supported_styles()
  if #styles == 1 then
    return styles[1]
  end
  local items = { "" }
  vim.list_extend(items, styles)
  return utils.select(items, {
    prompt = 'Style ("" for default): ',
    format_item = function(s)
      return s == "" and '""' or s
    end,
  })
end

--- The separator of a completing-read-multiple prompt:
--- `export.cite.basic_complete_key_crm_separator` is a Vim regexp, or
--- "dynamic" for ";" repeated so no candidate contains it.
local function crm_separator(value, candidates)
  if value == "dynamic" then
    local sep = ";"
    for _, c in ipairs(candidates) do
      for run in c:gmatch(";+") do
        while #sep <= #run do
          sep = sep .. ";"
        end
      end
    end
    return "[ \\t]*" .. sep .. "[ \\t]*", sep
  end
  return value, (value:gsub("%[ \\t%]%*", ""))
end

M._crm = nil

--- Completion for the multiple-keys prompt: candidates after the last separator.
function M._crm_complete(arglead)
  local crm = M._crm
  if not crm then
    return {}
  end
  local re = vim.regex(crm.regexp)
  local head, rest = "", arglead
  while true do
    local s, e = re:match_str(rest)
    if not s or e == 0 then
      break
    end
    head = head .. rest:sub(1, e)
    rest = rest:sub(e + 1)
  end
  local out = {}
  for _, c in ipairs(crm.candidates) do
    if c:lower():find(rest:lower(), 1, true) == 1 then
      out[#out + 1] = head .. c
    end
  end
  return out
end

--- org-cite-basic--complete-key: a key (multiple = false) or a list of keys.
function basic.complete_key(bufnr, multiple)
  local bib = M.parse_bibliography(bufnr)
  local tbl = #bib > 0 and basic.completion_table(bib) or nil
  if not tbl then
    user_error("No bibliography set")
  end
  local function fmt_item(item)
    return item[1]
  end
  local function nw(k)
    return k and k:match("%S") and k or nil
  end
  if not multiple then
    local choice = utils.select(tbl, { prompt = "Key: ", format_item = fmt_item })
    return choice and nw(choice[2])
  end
  local sep_opt = opt("basic_complete_key_crm_separator", nil)
  if sep_opt then
    -- completing-read-multiple: one prompt, the "author year title"
    -- strings of the references separated by the separator (a "dynamic"
    -- one avoids the "; " between authors); a bare key is accepted too
    local by_display, keys, displays = {}, {}, {}
    for _, item in ipairs(tbl) do
      by_display[item[1]] = item[2]
      keys[#keys + 1] = item[2]
      displays[#displays + 1] = item[1]
    end
    local regexp, shown = crm_separator(sep_opt, displays)
    M._crm = { regexp = regexp, candidates = displays }
    local ok, value = pcall(vim.fn.input, {
      prompt = string.format("[list separated by %s] Keys: ", shown),
      completion = "customlist,v:lua.require'org.cite'._crm_complete",
      cancelreturn = vim.NIL,
    })
    M._crm = nil
    if not ok or value == vim.NIL or value == nil then
      return nil
    end
    local re = vim.regex(regexp)
    local out, rest = {}, value
    local valid = {}
    for _, k in ipairs(keys) do
      valid[k] = true
    end
    while true do
      local s, e = re:match_str(rest)
      local part = s and rest:sub(1, s) or rest
      part = vim.trim(part)
      local key = valid[part] and part or by_display[part]
      if nw(key) then
        out[#out + 1] = key
      end
      if not s or e == 0 then
        break
      end
      rest = rest:sub(e + 1)
    end
    return #out > 0 and out or nil
  end
  -- multiple completing-read prompts until an empty input (cancel)
  local keys = {}
  while true do
    local shown = {}
    for i = #keys, 1, -1 do
      shown[#shown + 1] = keys[i]
    end
    local prompt = #keys > 0 and string.format("Key (empty input exits) %s: ", table.concat(shown, ";"))
      or "Key (empty input exits): "
    local choice = utils.select(tbl, { prompt = prompt, format_item = fmt_item })
    if not choice or not nw(choice[2]) then
      break
    end
    table.insert(keys, 1, choice[2])
  end
  return #keys > 0 and keys or nil
end

--- org-cite-delete-citation, on the region being edited.
local function delete_citation(ed, c)
  local s = ed.text
  local begin, stop = c.begin, c.stop
  local before = begin
  while before > 1 and s:sub(before - 1, before - 1):match("[ \t]") do
    before = before - 1
  end
  local after = c.end_
  local bol = before == 1 or s:sub(before - 1, before - 1) == "\n"
  local eol = after > #s or s:sub(after, after) == "\n"
  if bol and eol then
    -- the citation is alone on its line: remove the line
    local lb = before
    local le = after <= #s and after + 1 or after
    if after > #s and lb > 1 then
      lb = lb - 1
    end
    ed:delete(lb, le)
    if lb == 1 and le > #s then
      ed.drop_all = true
    end
  elseif bol then
    ed:delete(begin, after)
  elseif eol then
    ed:delete(before, after)
  else
    ed:delete(before, stop)
    if after == stop then
      ed:insert(before, " ")
    end
  end
end

--- org-cite-delete-citation for a reference.
local function delete_reference(ed, c, r)
  local refs = c.references
  if #refs == 1 then
    return delete_citation(ed, c)
  end
  if r.begin == c.contents_begin and not c.prefix then
    local b = r.begin
    while b > 1 and ed.text:sub(b - 1, b - 1):match("[ \t]") do
      b = b - 1
    end
    ed:delete(b, r.stop)
  elseif r.stop == c.contents_end and not c.suffix then
    ed:delete(r.begin - 1, c.stop - 1)
  else
    ed:delete(r.begin, r.stop)
  end
end

--- org-cite--insert-string-before
local function insert_before(ed, str, r)
  ed:insert(r.begin, str .. ";")
end

--- org-cite--insert-string-after
local function insert_after(ed, str, r)
  if ed.text:sub(r.stop - 1, r.stop - 1) == ";" then
    ed:insert(r.stop, str .. ";", true)
  else
    ed:insert(r.stop, ";" .. str, true)
  end
end

--- org-cite-make-insert-processor: an insert function built from
--- `select_key(bufnr, multiple)` and `select_style(citation)`.
function M.make_insert_processor(select_key, select_style)
  return function(ctx, arg)
    local bufnr = ctx.region.bufnr
    local ed = new_edit(ctx.region, ctx.point)
    local c, pos = ctx.citation, ctx.point
    if ctx.type == "citation" and pos < c.stop and pos > c.begin then
      if arg then
        delete_citation(ed, c)
      elseif c.style_end >= pos then
        -- on the style part: edit the style
        local style = select_style(c)
        if not style then
          user_error("Aborted")
        end
        ed:delete(c.begin + 5, c.style_end)
        if style:match("%S") then
          ed:insert(c.begin + 5, "/" .. style)
        end
      else
        -- on an affix: a new reference before or after
        local key = select_key(bufnr, false)
        key = "@" .. (key or "")
        if pos < c.contents_begin then
          insert_before(ed, key, c.references[1])
        else
          insert_after(ed, key, c.references[#c.references])
        end
      end
    elseif ctx.type == "citation-reference" and arg then
      delete_reference(ed, c, ctx.reference)
    elseif ctx.type == "citation-reference" then
      local r = ctx.reference
      local key = select_key(bufnr, false)
      if not key then
        user_error("Aborted")
      end
      key = "@" .. key
      if r.key_begin >= pos then
        insert_before(ed, key, r)
      elseif r.key_end <= pos then
        insert_after(ed, key, r)
      else
        ed:delete(r.key_begin, r.key_end)
        ed:insert(r.key_begin, key)
      end
    else
      local keys = select_key(bufnr, true)
      if not keys then
        user_error("Aborted")
      end
      local style = ""
      if arg then
        local refs = {}
        for i, k in ipairs(keys) do
          refs[i] = { key = k }
        end
        local s = select_style({ references = refs })
        if s and s:match("%S") then
          style = "/" .. s
        end
      end
      local at = {}
      for i, k in ipairs(keys) do
        at[i] = "@" .. k
      end
      ed:insert(pos, string.format("[cite%s:%s]", style, table.concat(at, "; ")), true)
    end
    ed:apply()
  end
end

basic.insert = M.make_insert_processor(basic.complete_key, basic.complete_style)

--- org-cite--allowed-p: can a citation be inserted at (row, col0)?
function M.allowed_p(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local parser = require("org.parser")
  -- headline: on the title, before the tags
  if parser.headline_level(line) then
    if line:match("^%*+%s+END%s*$") and require("org.parser").inlinetask_min_level() then
      return false
    end
    local file = require("org.files").get_buffer(bufnr)
    local parts = parser.parse_headline_line(line, file.settings.todo)
    local title_start = #(line:match("^%*+%s+") or "")
    if parts and parts.todo then
      title_start = title_start + #parts.todo
      title_start = title_start + #(line:sub(title_start + 1):match("^%s*"))
    end
    if parts and parts.priority then
      local p = line:sub(title_start + 1):match("^%[#[^%]]+%]%s*")
      title_start = title_start + #(p or "")
    end
    local tags_start = line:match("()%s+:[%w_@#%%:\128-\255]+:%s*$")
    if tags_start then
      tags_start = tags_start + #(line:sub(tags_start):match("^%s+"))
    end
    return col >= title_start and (not tags_start or col < tags_start - 1)
  end
  if line:match("^%s*$") then
    return true
  end
  local el = require("org.element").at(bufnr, row)
  local t = el and el.type
  -- an affiliated #+CAPTION keyword takes citations
  if el and row < el.post then
    return line:upper():match("^%s*#%+CAPTION[^:]*:") ~= nil
  end
  -- property drawers take no objects
  local p = el and el.parent
  while p do
    if p.type == "drawer" then
      local head = vim.api.nvim_buf_get_lines(bufnr, p.first - 1, p.first, false)[1] or ""
      if head:upper():match("^%s*:PROPERTIES:%s*$") then
        return false
      end
    end
    p = p.parent
  end
  local ok = false
  if t == nil or t == "paragraph" then
    ok = true
  elseif t == "block" then
    local head = vim.api.nvim_buf_get_lines(bufnr, el.first - 1, el.first, false)[1] or ""
    ok = head:lower():match("^%s*#%+begin_verse") ~= nil and row > el.first and row <= (el.cend or el.clast)
  elseif t == "footnote-definition" then
    local label = line:match("^%[fn:[^%]]+%]")
    ok = not label or col > #label or (col == #label and line:sub(col + 1, col + 1):match("%s") ~= nil)
  elseif t == "item" then
    local indent = #(line:match("^%s*"))
    local item = require("org.lists").parse_item_line(line)
    local checkbox = item and item.checkbox
    ok = col > indent + (checkbox and 5 or 1)
  elseif t == "table" then
    local first_bar = line:find("|", 1, true)
    ok = first_bar ~= nil and not line:match("^%s*|[-+]") and col >= first_bar
  end
  if not ok then
    return false
  end
  -- no citation inside a link, verbatim or code, or a timestamp
  local links = require("org.links")
  for _, l in ipairs(links.parse_links(line)) do
    if col > l.start_col and col <= l.end_col then
      return false
    end
  end
  for s, e in line:gmatch("()[=~][^%s=~][^\n]-[=~]()") do
    if col > s - 1 and col < e - 1 then
      return false
    end
  end
  return true
end

--- org-cite-insert (C-c C-x @): insert a citation at the cursor, or edit
--- the citation at the cursor. With a count (C-u), delete the reference
--- or citation at the cursor, or also choose a style for a new citation.
function M.insert(arg)
  if arg == nil then
    arg = vim.v.count > 0
  end
  arg = arg or nil
  local bufnr = vim.api.nvim_get_current_buf()
  local p = processor_for("insert", "insert_processor", "insert")
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local ctx = M.at_cursor(bufnr, row, col)
  if not ctx.type and not M.allowed_p(bufnr, row, col) then
    user_error("Cannot insert a citation here")
  end
  p.insert(ctx, arg)
end

---------------------------------------------------------------------------
-- Follow capability (org-cite-follow, org-cite-basic-goto)
---------------------------------------------------------------------------

--- Open the bibliography entry of `key` (org-cite-basic-goto).
function basic.goto_key(bufnr, key)
  local _, file = basic.get_entry(M.parse_bibliography(bufnr), key)
  if not file then
    user_error(string.format('Cannot find citation key: "%s"', key))
  end
  utils.open_file(file)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local target, col = nil, 0
  if file:match("%.json$") then
    local esc = vim.pesc(key)
    local text = table.concat(lines, "\n")
    local s = text:find('"id":[ \t]*"' .. esc .. '"')
    if s then
      local brace = text:sub(1, s):match(".*(){")
      if brace then
        local before = text:sub(1, brace - 1)
        local _, nl = before:gsub("\n", "")
        target = nl + 1
        col = #(before:match("[^\n]*$"))
      end
    end
  else
    local lkey = key:lower()
    for i, l in ipairs(lines) do
      local k = l:match("^%s*@[%w_%-]+%s*[{(]%s*([^,%s]+)")
      if k and k:lower() == lkey then
        target = i
        col = #(l:match("^%s*"))
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, col })
    pcall(vim.cmd, "normal! zv")
  end
end

--- The basic follow function: a reference opens its key; on the rest of a
--- citation with several keys, choose one.
function basic.follow(ctx)
  local bufnr = ctx.region.bufnr
  local key
  if ctx.type == "citation-reference" then
    key = ctx.reference.key
  else
    local keys = {}
    for i, r in ipairs(ctx.citation.references) do
      keys[i] = r.key
    end
    if #keys == 1 then
      key = keys[1]
    else
      key = utils.select(keys, { prompt = "Select citation key: " })
      if not key then
        user_error("Aborted")
      end
    end
  end
  basic.goto_key(bufnr, key)
end

--- org-cite-follow: follow the citation at the cursor. Returns false when
--- the cursor is not on a citation.
function M.follow(arg)
  local ctx = M.at_point()
  if not ctx then
    return false
  end
  processor_for("follow", "follow_processor", "follow").follow(ctx, arg)
  return true
end

---------------------------------------------------------------------------
-- Activate capability (org-cite-activate, org-cite-basic-activate)
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("org.cite")
local attached = {}
local current

--- Highlights of the citations in `s`: list of { begin, stop, group, priority }.
--- `known` is nil for the default fontification (org-cite-fontify-default).
local function default_marks(s)
  local out = {}
  for _, c in ipairs(M.citations(s)) do
    out[#out + 1] = { c.begin, c.stop, "OrgCite", 100 }
    for _, r in ipairs(c.references) do
      out[#out + 1] = { r.key_begin, r.key_end, "OrgCiteKey", 101 }
    end
  end
  return out
end

--- org-cite-basic-activate: keys not in the bibliography get the
--- OrgCiteKeyUnknown group (Emacs `error` face).
function basic.activate(s, bufnr)
  local keys = {}
  for _, k in ipairs(basic.all_keys(M.parse_bibliography(bufnr))) do
    keys[k] = true
  end
  local out = {}
  for _, c in ipairs(M.citations(s)) do
    out[#out + 1] = { c.begin, c.stop, "OrgCite", 100 }
    for _, r in ipairs(c.references) do
      out[#out + 1] = { r.key_begin, r.key_end, keys[r.key] and "OrgCiteKey" or "OrgCiteKeyUnknown", 101 }
    end
  end
  return out
end

--- Citation highlights for rows [top, bot] (0-based): { [row] = { {col, end_col, group, prio}... } }.
function M.marks(bufnr, top, bot)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local first = math.max(0, top - MAX_SPAN)
  local last = math.min(count - 1, bot + MAX_SPAN)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  local text = table.concat(lines, "\n")
  if not text:find("[cite", 1, true) then
    return {}
  end
  local starts, off = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = off
    off = off + #l + 1
  end
  local function pos_of(p)
    local o = p - 1
    for i = #starts, 1, -1 do
      if o >= starts[i] then
        return first + i - 1, o - starts[i]
      end
    end
    return first, 0
  end
  local name = opt("activate_processor", "basic")
  local p = name and M.processors[name]
  local list
  if p and p.activate then
    local ok, res = pcall(p.activate, text, bufnr)
    list = ok and res or default_marks(text)
  else
    list = default_marks(text)
  end
  local rows = {}
  for _, m in ipairs(list) do
    local r1, c1 = pos_of(m[1])
    local r2, c2 = pos_of(m[2])
    for r = r1, r2 do
      if r >= top and r <= bot then
        local cs = r == r1 and c1 or 0
        local ce = r == r2 and c2 or #lines[r - first + 1]
        if ce > cs then
          rows[r] = rows[r] or {}
          table.insert(rows[r], { cs, ce, m[3], m[4] })
        end
      end
    end
  end
  return rows
end

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, bufnr, toprow, botrow)
    if not attached[bufnr] then
      return false
    end
    local ok, rows = pcall(M.marks, bufnr, toprow, botrow)
    current = ok and rows or nil
    return current ~= nil and next(current) ~= nil
  end,
  on_line = function(_, _, bufnr, row)
    local marks = current and current[row]
    if not marks then
      return
    end
    for _, m in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, m[1], {
        end_col = m[2],
        hl_group = m[3],
        priority = m[4],
        ephemeral = true,
      })
    end
  end,
})

--- Activate citations in an org buffer (called for every org buffer).
function M.attach(bufnr)
  attached[bufnr] = true
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      attached[bufnr] = nil
    end,
  })
end

---------------------------------------------------------------------------
-- The key's mouse-1 binding (org-cite-basic--set-keymap)
---------------------------------------------------------------------------

--- A mouse click on a citation key, like Emacs' mouse-1 on an activated
--- key: a known key opens its entry, an unknown key is replaced with one
--- of the close keys (`export.cite.basic_max_key_distance`), or a key is
--- inserted when there is none. Returns false elsewhere.
function M.mouse_click()
  local mp = vim.fn.getmousepos()
  if mp.winid == 0 or mp.line == 0 then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(mp.winid)
  if vim.bo[bufnr].filetype ~= "org" then
    return false
  end
  local row, col = mp.line, mp.column - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  if col >= #line then
    return false
  end
  local ctx = M.at_cursor(bufnr, row, col)
  local r = ctx.reference
  if ctx.type ~= "citation-reference" or ctx.point < r.key_begin or ctx.point >= r.key_end then
    return false
  end
  local bib = M.parse_bibliography(bufnr)
  local keys = basic.all_keys(bib)
  local known = false
  for _, k in ipairs(keys) do
    if k == r.key then
      known = true
      break
    end
  end
  if known then
    M.follow()
    return true
  end
  local close = basic.close_keys(r.key, keys)
  if #close == 0 then
    M.insert()
    return true
  end
  local choice = #close == 1 and close[1] or utils.select(close, { prompt = "Did you mean: " })
  if choice then
    local ed = new_edit(ctx.region, ctx.point)
    ed:delete(r.key_begin, r.key_end)
    ed:insert(r.key_begin, "@" .. choice)
    ed.point = r.key_begin
    ed:apply()
  end
  return true
end

--- The help text Emacs shows over a key (help-echo): the entry of a known
--- key, the suggestions for an unknown one.
function M.key_help(bufnr, key)
  local bib = M.parse_bibliography(bufnr)
  local entry = basic.get_entry(bib, key)
  if entry then
    local author = field(entry, "author") or field(entry, "editor")
    local names = {}
    for _, n in ipairs(vim.split(author or "", " and ", { plain = true })) do
      if n ~= "" then
        names[#names + 1] = vim.split(n, ", ", { plain = true })[1]
      end
    end
    local from = field(entry, "publisher")
      or field(entry, "journal")
      or field(entry, "institution")
      or field(entry, "school")
    return (
      table.concat(names, ", ")
      .. ". "
      .. (field(entry, "title") or "")
      .. (from and (", " .. from) or "")
      .. ", "
      .. (basic.year(entry) or "")
      .. "."
    ):gsub("[{}]", "")
  end
  local close = basic.close_keys(key, basic.all_keys(bib))
  if #close > 0 then
    return "Suggestions (mouse-1 to substitute): " .. table.concat(close, " ")
  end
end

M.register_processor("basic", {
  activate = basic.activate,
  follow = basic.follow,
  insert = basic.insert,
})

return M
