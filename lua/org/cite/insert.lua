---@mod org.cite.insert Inserting citations
---
--- Supported styles (org-cite-supported-styles) and the insert capability
--- (org-cite-make-insert-processor, org-cite-insert, org-cite--allowed-p).
--- Part of org.cite, which loads it.

local utils = require("org.utils")
local shared = require("org.cite.shared")

local M = require("org.cite")
local basic = M.basic
local opt = shared.opt
local user_error = M.user_error
local new_edit = shared.new_edit
local processor_for = shared.processor_for

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
    -- user_error aborts; the return is for the type checker
    return user_error("No bibliography set")
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
  elseif el and t == "block" then
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
