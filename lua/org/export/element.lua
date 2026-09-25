---@mod org.export.element Org syntax tree for export (port of org-element.el)
---
--- Parses Org text into the same tree Emacs Org builds with
--- `org-element-parse-buffer`: typed nodes with `contents` (children),
--- `parent`, `post_blank` (blank lines after an element, spaces after an
--- object) and the element-specific properties. Plain text is a node of
--- type "plain-text" with a `value`. Element and object type names and
--- the parsing rules (paragraph separation, lists, affiliated keywords,
--- object restrictions, ...) follow org-element.el of Org 9.8.

local M = {}

local entities = require("org.export.entities")

---------------------------------------------------------------------------
-- Node helpers
---------------------------------------------------------------------------

M.GREATER = {
  ["center-block"] = true,
  drawer = true,
  ["dynamic-block"] = true,
  ["footnote-definition"] = true,
  headline = true,
  inlinetask = true,
  item = true,
  ["plain-list"] = true,
  ["property-drawer"] = true,
  ["quote-block"] = true,
  section = true,
  ["special-block"] = true,
  table = true,
  ["org-data"] = true,
}

M.ELEMENTS = {
  ["babel-call"] = true,
  ["center-block"] = true,
  clock = true,
  comment = true,
  ["comment-block"] = true,
  ["diary-sexp"] = true,
  drawer = true,
  ["dynamic-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["fixed-width"] = true,
  ["footnote-definition"] = true,
  headline = true,
  ["horizontal-rule"] = true,
  inlinetask = true,
  item = true,
  keyword = true,
  ["latex-environment"] = true,
  ["node-property"] = true,
  paragraph = true,
  ["plain-list"] = true,
  planning = true,
  ["property-drawer"] = true,
  ["quote-block"] = true,
  section = true,
  ["special-block"] = true,
  ["src-block"] = true,
  table = true,
  ["table-row"] = true,
  ["verse-block"] = true,
  ["org-data"] = true,
}

M.RECURSIVE_OBJECTS = {
  bold = true,
  citation = true,
  ["footnote-reference"] = true,
  italic = true,
  link = true,
  subscript = true,
  ["radio-target"] = true,
  ["strike-through"] = true,
  superscript = true,
  ["table-cell"] = true,
  underline = true,
}

--- Secondary strings (object lists stored in properties).
M.SECONDARY = {
  citation = { "prefix", "suffix" },
  headline = { "title" },
  inlinetask = { "title" },
  item = { "tag" },
  ["citation-reference"] = { "prefix", "suffix" },
}

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local MINIMAL = {
  "bold",
  "code",
  "entity",
  "italic",
  "latex-fragment",
  "strike-through",
  "subscript",
  "superscript",
  "underline",
  "verbatim",
}
local ALL_OBJECTS = {
  "bold",
  "citation",
  "code",
  "entity",
  "export-snippet",
  "footnote-reference",
  "inline-babel-call",
  "inline-src-block",
  "italic",
  "line-break",
  "latex-fragment",
  "link",
  "macro",
  "radio-target",
  "statistics-cookie",
  "strike-through",
  "subscript",
  "superscript",
  "target",
  "timestamp",
  "underline",
  "verbatim",
}
local function without(list, ...)
  local drop = set({ ... })
  local out = {}
  for _, v in ipairs(list) do
    if not drop[v] then
      out[#out + 1] = v
    end
  end
  return out
end
local STANDARD = ALL_OBJECTS
local STANDARD_NO_LB = without(STANDARD, "line-break")
local FOR_CITATIONS = without(STANDARD_NO_LB, "citation", "citation-reference", "footnote-reference", "link")

--- org-element-object-restrictions
M.RESTRICTIONS = {
  bold = set(STANDARD),
  citation = set({ "citation-reference" }),
  ["citation-reference"] = set(FOR_CITATIONS),
  ["footnote-reference"] = set(STANDARD),
  headline = set(STANDARD_NO_LB),
  inlinetask = set(STANDARD_NO_LB),
  italic = set(STANDARD),
  item = set(STANDARD_NO_LB),
  keyword = set(without(STANDARD, "footnote-reference")),
  link = set(vim.list_extend({ "export-snippet", "inline-babel-call", "inline-src-block", "macro", "statistics-cookie" }, MINIMAL)),
  paragraph = set(STANDARD),
  ["radio-target"] = set(MINIMAL),
  ["strike-through"] = set(STANDARD),
  subscript = set(STANDARD),
  superscript = set(STANDARD),
  ["table-cell"] = set(vim.list_extend({
    "citation",
    "export-snippet",
    "footnote-reference",
    "link",
    "macro",
    "radio-target",
    "target",
    "timestamp",
  }, MINIMAL)),
  underline = set(STANDARD),
  ["verse-block"] = set(STANDARD),
}

--- Create a node.
function M.node(type, props, contents)
  local n = props or {}
  n.type = type
  n.contents = contents or n.contents or {}
  n.post_blank = n.post_blank or 0
  for _, c in ipairs(n.contents) do
    c.parent = n
  end
  return n
end

function M.text(value, parent)
  return { type = "plain-text", value = value, parent = parent, post_blank = 0, contents = {} }
end

function M.adopt(parent, children)
  for _, c in ipairs(children) do
    c.parent = parent
    parent.contents[#parent.contents + 1] = c
  end
  return parent
end

function M.is_element(n)
  return M.ELEMENTS[n.type] == true
end

--- Plain text of a secondary string / node (like org-element-interpret-data
--- for simple cases, used for raw values).
function M.interpret(data)
  if data == nil then
    return ""
  end
  if data.type == nil then
    local out = {}
    for _, d in ipairs(data) do
      out[#out + 1] = M.interpret(d)
    end
    return table.concat(out)
  end
  local t = data.type
  local pb = string.rep(" ", data.post_blank or 0)
  local inner = function()
    return M.interpret(data.contents)
  end
  if t == "plain-text" then
    return data.value
  elseif t == "bold" then
    return "*" .. inner() .. "*" .. pb
  elseif t == "italic" then
    return "/" .. inner() .. "/" .. pb
  elseif t == "underline" then
    return "_" .. inner() .. "_" .. pb
  elseif t == "strike-through" then
    return "+" .. inner() .. "+" .. pb
  elseif t == "verbatim" then
    return "=" .. data.value .. "=" .. pb
  elseif t == "code" then
    return "~" .. data.value .. "~" .. pb
  elseif t == "entity" then
    return "\\" .. data.name .. (data.use_brackets and "{}" or "") .. pb
  elseif t == "latex-fragment" or t == "timestamp" or t == "statistics-cookie" then
    return (data.raw_value or data.value) .. pb
  elseif t == "subscript" or t == "superscript" then
    local m = t == "subscript" and "_" or "^"
    if data.use_brackets then
      return m .. "{" .. inner() .. "}" .. pb
    end
    return m .. inner() .. pb
  elseif t == "link" then
    if data.link_type == "radio" then
      return inner() .. pb
    end
    local c = #data.contents > 0 and inner() or nil
    local raw = data.raw_link
    if data.format == "plain" and not c then
      return raw .. pb
    elseif data.format == "angle" and not c then
      return "<" .. raw .. ">" .. pb
    end
    return "[[" .. raw .. "]" .. (c and ("[" .. c .. "]") or "") .. "]" .. pb
  elseif t == "footnote-reference" then
    local c = data.fn_type == "inline" and (":" .. inner()) or ""
    return "[fn:" .. (data.label or "") .. c .. "]" .. pb
  elseif t == "target" then
    return "<<" .. data.value .. ">>" .. pb
  elseif t == "radio-target" then
    return "<<<" .. inner() .. ">>>" .. pb
  elseif t == "export-snippet" then
    return "@@" .. data.back_end .. ":" .. data.value .. "@@" .. pb
  elseif t == "line-break" then
    return "\\\\\n"
  elseif t == "macro" then
    return data.value .. pb
  elseif t == "inline-src-block" then
    return "src_" .. data.language .. (data.parameters and ("[" .. data.parameters .. "]") or "") .. "{" .. data.value .. "}" .. pb
  elseif t == "inline-babel-call" then
    return data.value .. pb
  elseif t == "citation" then
    -- org-element-citation-interpreter
    local contents = inner()
    return "[cite"
      .. (data.style and ("/" .. data.style) or "")
      .. ":"
      .. (data.prefix and (M.interpret(data.prefix) .. ";") or "")
      .. (data.suffix and (contents .. M.interpret(data.suffix)) or contents:sub(1, -2))
      .. "]"
      .. pb
  elseif t == "citation-reference" then
    return M.interpret(data.prefix) .. "@" .. data.key .. M.interpret(data.suffix) .. ";"
  elseif t == "table-cell" then
    return " " .. inner() .. " |"
  end
  return inner() .. pb
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------

local function blank(l)
  return l == nil or l:match("^[ \t]*$") ~= nil
end
M.blank = blank

--- Indentation column of a line (tabs count to the next multiple of 8).
local function indentation(l)
  local col = 0
  for i = 1, #l do
    local c = l:sub(i, i)
    if c == " " then
      col = col + 1
    elseif c == "\t" then
      col = col + 8 - (col % 8)
    else
      break
    end
  end
  return col
end
M.indentation = indentation

local function trim(s)
  return (s:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", ""))
end
M.trim = trim

--- Remove common indentation of `lines` (org-remove-indentation).
function M.remove_indentation(lines, ignore_first)
  local min
  for i, l in ipairs(lines) do
    if not blank(l) and not (ignore_first and i == 1) then
      local n = indentation(l)
      min = (not min or n < min) and n or min
    end
  end
  if not min or min == 0 then
    return lines
  end
  local out = {}
  for i, l in ipairs(lines) do
    if ignore_first and i == 1 then
      out[i] = l
    else
      -- drop `min` columns of leading whitespace
      local col, k = 0, 1
      while k <= #l and col < min do
        local c = l:sub(k, k)
        if c == " " then
          col = col + 1
        elseif c == "\t" then
          col = col + 8 - (col % 8)
        else
          break
        end
        k = k + 1
      end
      out[i] = (col > min and string.rep(" ", col - min) or "") .. l:sub(k)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Line classification
---------------------------------------------------------------------------

local function headline_stars(l)
  local stars = l:match("^(%*+) ")
  return stars and #stars or nil
end

local function is_comment_line(l)
  return l:match("^[ \t]*#$") ~= nil or l:match("^[ \t]*# ") ~= nil
end

local function is_clock_line(l)
  return l:match("^[ \t]*CLOCK:") ~= nil
end

local function is_planning_line(l)
  return l:match("^[ \t]*CLOSED:") ~= nil or l:match("^[ \t]*DEADLINE:") ~= nil or l:match("^[ \t]*SCHEDULED:") ~= nil
end

local function drawer_name(l)
  return l:match("^[ \t]*:([%w%-_]+):[ \t]*$")
end

local function is_end_line(l)
  return l:match("^[ \t]*:[Ee][Nn][Dd]:[ \t]*$") ~= nil
end

local function is_fixed_width(l)
  return l:match("^[ \t]*:$") ~= nil or l:match("^[ \t]*: ") ~= nil
end

local function is_footnote_def(l)
  return l:match("^%[fn:[%w%-_]+%]") ~= nil
end

local function is_hr(l)
  return l:match("^[ \t]*%-%-%-%-%-+[ \t]*$") ~= nil
end

local function latex_env_begin(l)
  return l:match("^[ \t]*\\begin{([%w%*]+)}")
end

local function block_type(l)
  return l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
end

local function is_dynamic_block(l)
  return l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:[ \t]*%S") ~= nil
end

local function is_table_line(l)
  return l:match("^[ \t]*|") ~= nil
end

local function is_tableel_rule(l)
  return l:match("^[ \t]*%+%-+[%+%-]*%+[ \t]*$") ~= nil and l:match("^[ \t]*%+[%-%+]*%+[ \t]*$") ~= nil
end

--- Item bullet of a line (org-item-re, alphabetical bullets when allowed).
local function item_match(l, alpha)
  local ind, bullet = l:match("^([ \t]*)([%-%+])[ \t]")
  if not ind then
    ind, bullet = l:match("^([ \t]*)([%-%+])$")
  end
  if not ind then
    ind, bullet = l:match("^([ \t]+)(%*)[ \t]")
    if not ind then
      ind, bullet = l:match("^([ \t]+)(%*)$")
    end
  end
  if not ind then
    ind, bullet = l:match("^([ \t]*)(%d+[%.%)])[ \t]")
    if not ind then
      ind, bullet = l:match("^([ \t]*)(%d+[%.%)])$")
    end
  end
  if not ind and alpha then
    ind, bullet = l:match("^([ \t]*)(%a[%.%)])[ \t]")
    if not ind then
      ind, bullet = l:match("^([ \t]*)(%a[%.%)])$")
    end
  end
  if ind then
    return indentation(ind), bullet
  end
end

local AFFILIATED = {
  CAPTION = "CAPTION",
  DATA = "NAME",
  HEADER = "HEADER",
  HEADERS = "HEADER",
  LABEL = "NAME",
  NAME = "NAME",
  PLOT = "PLOT",
  RESNAME = "NAME",
  RESULT = "RESULTS",
  RESULTS = "RESULTS",
  SOURCE = "NAME",
  SRCNAME = "NAME",
  TBLNAME = "NAME",
}
local DUAL = { CAPTION = true, RESULTS = true }
local MULTIPLE = { CAPTION = true, HEADER = true }
local PARSED = { CAPTION = true }

--- Match an affiliated keyword line. Returns official key, value, dual value.
local function affiliated_match(l)
  local key, rest = l:match("^[ \t]*#%+([%w_%-]+)(.*)$")
  if not key then
    return nil
  end
  local up = key:upper()
  local official = AFFILIATED[up]
  local dual
  if official and DUAL[official] then
    local d, r = rest:match("^%[(.*)%](:.*)$")
    if d then
      dual, rest = d, r
    end
  end
  if not rest:match("^:") then
    return nil
  end
  if not official then
    if up:match("^ATTR_[%w_%-]+$") then
      official = up
    else
      return nil
    end
  end
  local value = rest:sub(2):gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  return official, value, dual
end

---------------------------------------------------------------------------
-- Parser state
---------------------------------------------------------------------------

local P = {}
P.__index = P

--- Create a parser.
---@param opts table { todo = org.TodoConfig, link_types = string[], abbrevs = table, radio = string[],
---  inlinetask_min_level = integer, alpha = boolean, macro = function|nil, visible = function|nil }
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({ opts = opts }, P)
  local types = {}
  for _, t in ipairs(opts.link_types or M.DEFAULT_LINK_TYPES) do
    types[t] = true
  end
  self.link_types = types
  self.inlinetask_min = opts.inlinetask_min_level or 15
  -- radio targets: list of lowercase word lists
  self.radios = {}
  for _, r in ipairs(opts.radio or {}) do
    local words = vim.split(trim(r):lower(), "%s+", { trimempty = true })
    if #words > 0 then
      self.radios[#self.radios + 1] = words
    end
  end
  table.sort(self.radios, function(a, b)
    return #table.concat(a, " ") > #table.concat(b, " ")
  end)
  return self
end

M.DEFAULT_LINK_TYPES = {
  "attachment",
  "id",
  "file+sys",
  "file+emacs",
  "shell",
  "news",
  "mailto",
  "https",
  "http",
  "ftp",
  "shortdoc",
  "help",
  "file",
  "elisp",
  "doi",
}

function P:is_headline(l)
  local n = headline_stars(l)
  return n ~= nil and n < self.inlinetask_min
end

function P:is_any_headline(l)
  return headline_stars(l) ~= nil
end

--- Index of the first line in s..e that is not blank, or e + 1.
local function skip_blank(L, s, e)
  local j = s
  while j <= e and blank(L[j]) do
    j = j + 1
  end
  return j
end

--- post-blank and next index after an element whose last line is `last`.
local function after(L, last, e)
  local j = skip_blank(L, last + 1, e)
  return j - last - 1, j
end

---------------------------------------------------------------------------
-- Elements
---------------------------------------------------------------------------

--- Find the line closing a block: first line in s..e matching `pat` (lowercased).
local function find_line(L, s, e, pred)
  for j = s, e do
    if pred(L[j]) then
      return j
    end
  end
end

--- Collect affiliated keywords starting at line i.
function P:affiliated(L, i, e)
  local out = {}
  local order = {}
  local j = i
  local any = false
  while j <= e do
    local key, value, dual = affiliated_match(L[j])
    if not key then
      break
    end
    any = true
    local v
    if PARSED[key] then
      v = self:parse_objects(value, M.RESTRICTIONS.keyword)
    else
      v = value
    end
    if DUAL[key] then
      local dv = dual
      if dv and PARSED[key] then
        dv = self:parse_objects(dv, M.RESTRICTIONS.keyword)
      end
      v = { v, dv }
    end
    local lk = key:lower()
    if out[lk] == nil then
      order[#order + 1] = lk
    end
    if MULTIPLE[key] or key:match("^ATTR_") then
      out[lk] = out[lk] or {}
      table.insert(out[lk], v)
    else
      out[lk] = v
    end
    j = j + 1
  end
  if not any then
    return nil, i
  end
  local l = L[j]
  if j > e or blank(l) or is_comment_line(l) or is_clock_line(l) or (l and l:match("^%*+ ")) then
    return nil, i
  end
  out._order = order
  return out, j
end

local function attach(node, aff)
  if aff then
    for k, v in pairs(aff) do
      if k ~= "_order" then
        node[k] = v
      end
    end
    node.affiliated_order = aff._order
  end
  return node
end

--- Paragraph ending at the first separator line after i (org-element-paragraph-parser).
function P:paragraph_end(L, i, e)
  local j = i + 1
  while j <= e do
    local l = L[j]
    local sep = false
    if blank(l) or l:match("^%*+ ") or is_footnote_def(l) or l:match("^%%%%%(") then
      sep = true
    elseif is_table_line(l) or l:match("^[ \t]*%+%-+[%+%-]*[ \t]*$") and l:match("^[ \t]*%+[%-]+%+") then
      sep = true
    elseif l:match("^[ \t]*#$") or l:match("^[ \t]*# ") then
      sep = true
    elseif l:match("^[ \t]*#%+") then
      local bt = block_type(l)
      if bt then
        local endp = "^[ \t]*#%+[Ee][Nn][Dd]_" .. vim.pesc(bt:lower()) .. "[ \t]*$"
        sep = find_line(L, j + 1, e, function(x)
          return x:lower():match(endp) ~= nil
        end) ~= nil
      elseif l:match("^[ \t]*#%+%S+%[.*%]:") then
        local k = l:match("^[ \t]*#%+(%S-)%[")
        sep = k ~= nil and DUAL[k:upper()] ~= nil
      elseif l:match("^[ \t]*#%+%S+:") or l:match("^[ \t]*#%+%S+%[.*%]:") then
        sep = true
      end
    elseif is_fixed_width(l) then
      sep = true
    elseif drawer_name(l) then
      sep = find_line(L, j + 1, e, is_end_line) ~= nil
    elseif is_hr(l) then
      sep = true
    elseif latex_env_begin(l) then
      local env = latex_env_begin(l)
      local endp = "\\end{" .. env .. "}"
      sep = find_line(L, j, e, function(x)
        local s = x:find(endp, 1, true)
        return s ~= nil and x:sub(s + #endp):match("^[ \t]*$") ~= nil
      end) ~= nil
    elseif is_clock_line(l) then
      sep = true
    elseif item_match(l, self.opts.alpha) then
      sep = true
    end
    if sep then
      break
    end
    j = j + 1
  end
  return j - 1
end

--- Parse a paragraph from line i. `first` optionally replaces L[i].
function P:paragraph(L, i, e, aff, not_bol)
  local last = self:paragraph_end(L, i, e)
  local lines = vim.list_slice(L, i, last)
  local pb, nxt = after(L, last, e)
  local node = attach(M.node("paragraph", { post_blank = pb, raw_lines = lines }), aff)
  -- the first line of a paragraph starting an item or a footnote
  -- definition does not count for the common indentation
  self:fill_paragraph(node, not_bol)
  return node, nxt
end

--- Fill a paragraph (or verse) node with objects.
function P:fill_paragraph(node, ignore_first)
  local lines = M.remove_indentation(node.raw_lines, ignore_first)
  local text = table.concat(lines, "\n") .. "\n"
  node.contents = self:parse_objects(text, M.RESTRICTIONS[node.type == "verse-block" and "verse-block" or "paragraph"], node)
  node.raw_lines = nil
end

local function block_end(L, i, e, name)
  local endp = "^[ \t]*#%+[Ee][Nn][Dd]_" .. vim.pesc(name:lower()) .. "[ \t]*$"
  return find_line(L, i + 1, e, function(x)
    return x:lower():match(endp) ~= nil
  end)
end

--- Switches analysis shared by src and example blocks.
local function switches_props(switches, node)
  if switches then
    local sign, num = switches:match("([%-%+])n[ \t]*(%d*)")
    if sign then
      local after_n = switches:match("[%-%+]n[ \t]*%d*(.?)")
      if after_n == "" or not after_n:match("[%w_]") then
        node.number_lines = { sign == "-" and "new" or "continued", num ~= "" and (tonumber(num) - 1) or 0 }
      end
    end
    node.preserve_indent = switches:match("%-i%f[^%w]") ~= nil or switches:match("%-i$") ~= nil
    local has_r = switches:match("%-r%f[^%w]") ~= nil or switches:match("%-r$") ~= nil
    local has_k = switches:match("%-k%f[^%w]") ~= nil or switches:match("%-k$") ~= nil
    node.retain_labels = (not has_r) or (node.number_lines ~= nil and has_k)
    node.use_labels = node.retain_labels and not has_k
    node.label_fmt = switches:match('%-l +"([^"\n]+)"')
  else
    node.retain_labels = true
    node.use_labels = true
  end
end

--- Remove the protective commas of a block body (org-unescape-code-in-string).
local function unescape(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:gsub("^([ \t]*),([%*])", "%1%2"):gsub("^([ \t]*),(#%+)", "%1%2")
  end
  return out
end
M.unescape = unescape

function P:greater_block(L, i, e, aff, btype, name)
  local j = block_end(L, i, e, name)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local node = attach(M.node(btype, { post_blank = pb }), aff)
  if btype == "special-block" then
    node.block_type = name
    local params = L[i]:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_%S+[ \t]*(.-)[ \t]*$")
    node.parameters = params ~= "" and params or nil
  end
  if j > i + 1 then
    M.adopt(node, self:parse_elements(L, i + 1, j - 1, nil, node))
  end
  return node, nxt
end

function P:element_at(L, i, e, mode, parent, not_bol)
  local l = L[i]
  -- headline / inlinetask
  local stars = headline_stars(l)
  if stars and not not_bol then
    if stars < self.inlinetask_min then
      return self:headline(L, i, e)
    end
  end
  if mode == "section" or mode == "first-section" then
    return self:section(L, i, e)
  end
  if is_comment_line(l) and not not_bol then
    return self:comment(L, i, e)
  end
  if mode == "planning" and i > 1 and self.prev_is_headline and is_planning_line(l) then
    return self:planning(L, i, e)
  end
  if
    ((mode == "planning" and self.prev_is_headline) or mode == "property-drawer" or mode == "top-comment")
    and l:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$")
  then
    local j = find_line(L, i + 1, e, function(x)
      return is_end_line(x) or not x:match("^[ \t]*:%S+:")
    end)
    if j and is_end_line(L[j]) then
      return self:property_drawer(L, i, j, e)
    end
  end
  if not_bol then
    return self:paragraph(L, i, e, nil, true)
  end
  if is_clock_line(l) then
    return self:clock(L, i, e)
  end
  if stars then
    return self:inlinetask(L, i, e)
  end
  local aff, j = self:affiliated(L, i, e)
  if aff and j > e then
    return self:keyword(L, i, e, nil)
  end
  i = j
  l = L[i]
  if latex_env_begin(l) then
    return self:latex_environment(L, i, e, aff)
  end
  if drawer_name(l) then
    return self:drawer(L, i, e, aff)
  end
  if is_fixed_width(l) then
    return self:fixed_width(L, i, e, aff)
  end
  if l:match("^[ \t]*#%+") then
    local bt = block_type(l)
    if bt then
      local up = bt:upper()
      if up == "CENTER" then
        return self:greater_block(L, i, e, aff, "center-block", bt)
      elseif up == "QUOTE" then
        return self:greater_block(L, i, e, aff, "quote-block", bt)
      elseif up == "COMMENT" then
        return self:raw_block(L, i, e, aff, "comment-block", bt)
      elseif up == "EXAMPLE" then
        return self:raw_block(L, i, e, aff, "example-block", bt)
      elseif up == "EXPORT" then
        return self:raw_block(L, i, e, aff, "export-block", bt)
      elseif up == "SRC" then
        return self:raw_block(L, i, e, aff, "src-block", bt)
      elseif up == "VERSE" then
        return self:verse_block(L, i, e, aff, bt)
      end
      return self:greater_block(L, i, e, aff, "special-block", bt)
    end
    if l:match("^[ \t]*#%+[Cc][Aa][Ll][Ll]:") then
      return self:babel_call(L, i, e, aff)
    end
    if is_dynamic_block(l) then
      return self:dynamic_block(L, i, e, aff)
    end
    if l:match("^[ \t]*#%+%S+:") then
      return self:keyword(L, i, e, aff)
    end
    return self:paragraph(L, i, e, aff)
  end
  if is_footnote_def(l) then
    return self:footnote_definition(L, i, e, aff)
  end
  if is_hr(l) then
    local pb, nxt = after(L, i, e)
    return attach(M.node("horizontal-rule", { post_blank = pb }), aff), nxt
  end
  if l:match("^%%%%%(") then
    local pb, nxt = after(L, i, e)
    return attach(M.node("diary-sexp", { post_blank = pb, value = l:match("^(%%%%%(.*)[ \t]*$") }), aff), nxt
  end
  if is_table_line(l) or self:is_tableel(L, i, e) then
    return self:table(L, i, e, aff)
  end
  if item_match(l, self.opts.alpha) then
    return self:plain_list(L, i, e, aff)
  end
  return self:paragraph(L, i, e, aff)
end

function P:is_tableel(L, i, e)
  local l = L[i]
  if not l:match("^[ \t]*%+%-") or not is_tableel_rule(l) or i + 1 > e then
    return false
  end
  local j = i + 1
  while j <= e and L[j]:match("^[ \t]*[%+|]") do
    j = j + 1
  end
  if j == i + 1 then
    return false
  end
  return is_tableel_rule(L[j - 1])
end

--- Parse elements of lines s..e into a list.
---@param mode string|nil
function P:parse_elements(L, s, e, mode, parent, first_not_bol)
  local out = {}
  local i = s
  local not_bol = first_not_bol
  while i <= e do
    if blank(L[i]) and not not_bol then
      -- only possible at the very start of a container
      i = i + 1
    else
      local node, nxt = self:element_at(L, i, e, mode, parent, not_bol)
      node.parent = parent
      out[#out + 1] = node
      self.prev_is_headline = false
      -- next mode (org-element--next-mode, parent? = nil)
      if mode == "item" then
        mode = "item"
      elseif mode == "planning" and node.type == "planning" then
        mode = "property-drawer"
      elseif mode == "top-comment" and node.type == "comment" then
        mode = "property-drawer"
      else
        mode = nil
      end
      if nxt <= i then
        nxt = i + 1
      end
      i = nxt
      not_bol = false
    end
  end
  return out
end

--- Headline.
function P:headline(L, i, e)
  local level = headline_stars(L[i])
  local j = i + 1
  while j <= e do
    local n = headline_stars(L[j])
    if n and n <= level then
      break
    end
    j = j + 1
  end
  local last = j - 1
  local cb = skip_blank(L, i + 1, last)
  local node = M.node("headline", { level = level, true_level = level })
  local saved = self.current_headline
  node.props = {}
  self:headline_meta(node, L, i, j - 1)
  self.current_headline = node
  self:headline_title(node, L[i])
  if cb <= last then
    node.pre_blank = cb - i - 1
    node.post_blank = 0
    self.prev_is_headline = cb == i + 1
    local first_mode = "section"
    self.current_headline = node
    local children = {}
    local k = cb
    while k <= last do
      if headline_stars(L[k]) and headline_stars(L[k]) < self.inlinetask_min then
        local h, nxt = self:headline(L, k, last)
        h.parent = node
        children[#children + 1] = h
        k = nxt
      else
        -- section until next headline
        local sec, nxt = self:section(L, k, last, first_mode)
        sec.parent = node
        children[#children + 1] = sec
        k = nxt
      end
      first_mode = nil
    end
    M.adopt(node, children)
  else
    node.pre_blank = 0
    node.post_blank = last - i
  end
  self.current_headline = saved
  return node, j
end

--- Parse the title part of a headline line.
function P:headline_title(node, line, inlinetask)
  local rest = line:match("^%*+ +(.*)$") or ""
  rest = rest:gsub("^[ \t]+", "")
  local todo_cfg = self.opts.todo
  local word = rest:match("^(%S+)")
  if word and todo_cfg and todo_cfg:is_keyword(word) and (rest:sub(#word + 1) == "" or rest:sub(#word + 1):match("^ ")) then
    node.todo_keyword = word
    node.todo_type = todo_cfg:is_done(word) and "done" or "todo"
    rest = rest:sub(#word + 1):gsub("^[ \t]+", "")
  end
  local prio = rest:match("^%[#([A-Z0-9]+)%]")
  if prio and (tonumber(prio) == nil or tonumber(prio) <= 64) then
    node.priority = prio
    rest = rest:gsub("^%[#[A-Z0-9]+%] ?", "")
  end
  if rest:match("^COMMENT$") or rest:match("^COMMENT ") then
    node.commentedp = true
    rest = rest:gsub("^COMMENT[ \t]*", "")
  end
  local tags = {}
  local before, tagstr = rest:match("^(.-)[ \t]+(:[%w_@#%%:]+:)[ \t]*$")
  if not before then
    tagstr = rest:match("^(:[%w_@#%%:]+:)[ \t]*$")
    before = tagstr and "" or nil
  end
  if tagstr then
    for t in tagstr:gmatch("[^:]+") do
      tags[#tags + 1] = t
    end
    rest = before
  end
  node.tags = tags
  node.raw_value = trim(rest)
  node.archivedp = vim.tbl_contains(tags, "ARCHIVE")
  node.title = self:parse_objects(trim(rest), M.RESTRICTIONS[inlinetask and "inlinetask" or "headline"], node)
  node.footnote_section_p = self.opts.footnote_section ~= nil and node.raw_value == self.opts.footnote_section
end

--- Planning and property drawer right after the headline line.
function P:headline_meta(node, L, i, last)
  node.props = node.props or {}
  local k = i + 1
  if k <= last and is_planning_line(L[k]) then
    local p = self:planning_values(L[k])
    node.scheduled, node.deadline, node.closed = p.scheduled, p.deadline, p.closed
    k = k + 1
  end
  if k <= last and L[k]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$") then
    local j = k + 1
    while j <= last and not is_end_line(L[j]) do
      local key, value = L[j]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
      if not key then
        break
      end
      local up = key:upper()
      local base = up:match("^(.-)%+$")
      if base and node.props[base] then
        node.props[base] = node.props[base] .. " " .. value
      else
        node.props[base or up] = value
      end
      j = j + 1
    end
  end
end

function P:planning_values(line)
  local out = {}
  for kw, ts in line:gmatch("(%u+):[ \t]*([<%[][^>%]]+[>%]])") do
    local t = self:parse_timestamp(ts, 1)
    if t then
      out[kw:lower()] = t
    end
  end
  return out
end

function P:planning(L, i, e)
  local pb, nxt = after(L, i, e)
  local p = self:planning_values(L[i])
  return M.node("planning", { post_blank = pb, scheduled = p.scheduled, deadline = p.deadline, closed = p.closed }), nxt
end

function P:property_drawer(L, i, j, e)
  local pb, nxt = after(L, j, e)
  local node = M.node("property-drawer", { post_blank = pb })
  local kids = {}
  for k = i + 1, j - 1 do
    local key, value = L[k]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
    if key then
      kids[#kids + 1] = M.node("node-property", { key = key, value = value ~= "" and value or nil })
    end
  end
  M.adopt(node, kids)
  return node, nxt
end

function P:section(L, i, e, mode)
  local j = i
  while j <= e do
    if j > i and self:is_headline(L[j]) then
      break
    end
    j = j + 1
  end
  local node = M.node("section", { post_blank = 0 })
  local child_mode = (mode == "first-section") and "top-comment" or "planning"
  if child_mode == "planning" and not self.prev_is_headline then
    child_mode = "planning"
  end
  M.adopt(node, self:parse_elements(L, i, j - 1, child_mode, node))
  return node, j
end

function P:comment(L, i, e)
  local j = i
  local vals = {}
  while j <= e and is_comment_line(L[j]) do
    vals[#vals + 1] = L[j]:match("^[ \t]*# ?(.*)$") or ""
    j = j + 1
  end
  local pb, nxt = after(L, j - 1, e)
  return M.node("comment", { post_blank = pb, value = table.concat(vals, "\n") }), nxt
end

function P:clock(L, i, e)
  local l = L[i]
  local rest = l:match("CLOCK:[ \t]*(.*)$")
  local ts = self:parse_timestamp(rest, 1)
  local duration = l:match("=>[ \t]*(%S+)[ \t]*$")
  local pb, nxt = after(L, i, e)
  return M.node("clock", { post_blank = pb, value = ts, duration = duration, status = duration and "closed" or "running" }),
    nxt
end

function P:inlinetask(L, i, e)
  local node = M.node("inlinetask", { level = headline_stars(L[i]) })
  self:headline_title(node, L[i], true)
  local task_end
  for j = i + 1, e do
    if L[j]:match("^%*+ ") then
      if L[j]:match("^%*+ [ \t]*END[ \t]*$") then
        task_end = j
      end
      break
    end
  end
  local pb, nxt
  if task_end then
    self:headline_meta(node, L, i, task_end - 1)
    local cb = skip_blank(L, i + 1, task_end - 1)
    if cb <= task_end - 1 then
      node.pre_blank = cb - i - 1
      self.prev_is_headline = cb == i + 1
      M.adopt(node, self:parse_elements(L, cb, task_end - 1, "planning", node))
    end
    pb, nxt = after(L, task_end, e)
  else
    pb, nxt = after(L, i, e)
  end
  node.post_blank = pb
  return node, nxt
end

function P:keyword(L, i, e, aff)
  local key, value = L[i]:match("^[ \t]*#%+(%S-):[ \t]*(.-)[ \t]*$")
  local pb, nxt = after(L, i, e)
  return attach(M.node("keyword", { post_blank = pb, key = (key or ""):upper(), value = value or "" }), aff), nxt
end

function P:babel_call(L, i, e, aff)
  local value = L[i]:match("^[ \t]*#%+[Cc][Aa][Ll][Ll]:[ \t]*(.-)[ \t]*$") or ""
  local call = value:match("^([^%[%]%(%)]+)")
  local pb, nxt = after(L, i, e)
  local node = attach(M.node("babel-call", { post_blank = pb, value = value, call = call and trim(call) }), aff)
  local rest = value:sub(#(call or "") + 1)
  local inside = rest:match("^%b[]")
  if inside then
    node.inside_header = inside:sub(2, -2)
    rest = rest:sub(#inside + 1)
  end
  local args = rest:match("^%b()")
  if args then
    node.arguments = args:sub(2, -2)
    rest = rest:sub(#args + 1)
  end
  node.end_header = trim(rest) ~= "" and trim(rest) or nil
  return node, nxt
end

function P:dynamic_block(L, i, e, aff)
  local j = find_line(L, i + 1, e, function(x)
    return x:match("^[ \t]*#%+[Ee][Nn][Dd]:?[ \t]*$") ~= nil
  end)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local name, args = L[i]:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:[ \t]*(%S+)[ \t]*(.-)[ \t]*$")
  local pb, nxt = after(L, j, e)
  local node = attach(M.node("dynamic-block", { post_blank = pb, block_name = name, arguments = args ~= "" and args or nil }), aff)
  if j > i + 1 then
    M.adopt(node, self:parse_elements(L, i + 1, j - 1, nil, node))
  end
  return node, nxt
end

function P:drawer(L, i, e, aff)
  local j = find_line(L, i + 1, e, is_end_line)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local name = drawer_name(L[i])
  local pb, nxt = after(L, j, e)
  local node = attach(M.node("drawer", { post_blank = pb, drawer_name = name }), aff)
  local cb = skip_blank(L, i + 1, j - 1)
  node.pre_blank = cb - i - 1
  if cb <= j - 1 then
    M.adopt(node, self:parse_elements(L, cb, j - 1, nil, node))
  end
  return node, nxt
end

function P:fixed_width(L, i, e, aff)
  local j = i
  local vals = {}
  while j <= e and is_fixed_width(L[j]) do
    vals[#vals + 1] = L[j]:gsub("^[ \t]*: ?", "")
    j = j + 1
  end
  local pb, nxt = after(L, j - 1, e)
  return attach(M.node("fixed-width", { post_blank = pb, value = table.concat(vals, "\n") }), aff), nxt
end

function P:latex_environment(L, i, e, aff)
  local env = latex_env_begin(L[i])
  local endp = "\\end{" .. env .. "}"
  local j = find_line(L, i, e, function(x)
    local s = x:find(endp, 1, true)
    return s ~= nil and x:sub(s + #endp):match("^[ \t]*$") ~= nil
  end)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local value = table.concat(vim.list_slice(L, i, j), "\n") .. "\n"
  return attach(M.node("latex-environment", { post_blank = pb, value = value }), aff), nxt
end

function P:footnote_definition(L, i, e, aff)
  local label, rest = L[i]:match("^%[fn:([%w%-_]+)%](.*)$")
  -- end: next headline, footnote definition, or two blank lines
  local j = i + 1
  local stop = e + 1
  while j <= e do
    local l = L[j]
    if l:match("^%*+ ") then
      stop = j
      break
    elseif is_footnote_def(l) then
      -- before any affiliated keyword above
      local k = j
      while k - 1 > i and affiliated_match(L[k - 1]) do
        k = k - 1
      end
      stop = k
      break
    elseif blank(l) and blank(L[j + 1]) and j + 1 <= e then
      stop = skip_blank(L, j, e)
      break
    end
    j = j + 1
  end
  local last = stop - 1
  -- contents end before trailing blanks
  local ce = last
  while ce >= i + 1 and blank(L[ce]) do
    ce = ce - 1
  end
  local pb = last - ce
  local node = attach(M.node("footnote-definition", { post_blank = pb, label = label, pre_blank = 0 }), aff)
  local first = rest:gsub("^[ \t]+", "")
  local body
  local not_bol = false
  if first ~= "" then
    body = { first }
    vim.list_extend(body, vim.list_slice(L, i + 1, ce))
    not_bol = true
  else
    local cb = skip_blank(L, i + 1, ce)
    if cb <= ce then
      node.pre_blank = cb - i - 1
      body = vim.list_slice(L, cb, ce)
    end
  end
  if body then
    M.adopt(node, self:parse_elements(body, 1, #body, nil, node, not_bol))
  end
  return node, stop
end

function P:raw_block(L, i, e, aff, btype, name)
  local j = block_end(L, i, e, name)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local body = vim.list_slice(L, i + 1, j - 1)
  local node = attach(M.node(btype, { post_blank = pb }), aff)
  local head = L[i]
  if btype == "src-block" then
    local rest = head:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc](.*)$") or ""
    local lang = rest:match("^ +(%S+)")
    if lang then
      rest = rest:gsub("^ +%S+", "", 1)
    end
    -- switches: -l "fmt", -i, -k, -r, -n N, +n N
    local switches = {}
    while true do
      local sw = rest:match('^( +%-l "[^"]+")') or rest:match("^( +%-[ikr])%f[%s%z]") or rest:match("^( +[%-%+]n *%d*)%f[%s%z]")
      if not sw then
        break
      end
      switches[#switches + 1] = trim(sw)
      rest = rest:sub(#sw + 1)
    end
    node.language = lang
    node.switches = #switches > 0 and table.concat(switches, " ") or nil
    local params = trim(rest)
    node.parameters = params ~= "" and params or nil
    switches_props(node.switches, node)
    node.value = table.concat(unescape(body), "\n") .. (#body > 0 and "\n" or "")
  elseif btype == "example-block" then
    local sw = head:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ee][Xx][Aa][Mm][Pp][Ll][Ee] +(.*)$")
    node.switches = sw and trim(sw) ~= "" and trim(sw) or nil
    switches_props(node.switches, node)
    node.value = table.concat(unescape(body), "\n") .. (#body > 0 and "\n" or "")
  elseif btype == "export-block" then
    local be = head:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ee][Xx][Pp][Oo][Rr][Tt][ \t]+(%S+)")
    node.back_end_type = be and be:upper() or nil
    node.value = table.concat(unescape(body), "\n") .. (#body > 0 and "\n" or "")
  else
    node.value = table.concat(body, "\n") .. (#body > 0 and "\n" or "")
  end
  return node, nxt
end

function P:verse_block(L, i, e, aff, name)
  local j = block_end(L, i, e, name)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local node = attach(M.node("verse-block", { post_blank = pb }), aff)
  local body = M.remove_indentation(vim.list_slice(L, i + 1, j - 1))
  local text = table.concat(body, "\n") .. (#body > 0 and "\n" or "")
  node.contents = self:parse_objects(text, M.RESTRICTIONS["verse-block"], node)
  return node, nxt
end

function P:table(L, i, e, aff)
  local orgtype = is_table_line(L[i])
  local j = i
  if orgtype then
    while j <= e and is_table_line(L[j]) do
      j = j + 1
    end
  else
    while j <= e and L[j]:match("^[ \t]*[%+|]") do
      j = j + 1
    end
  end
  local last = j - 1
  local tblfm = {}
  while j <= e and L[j]:match("^[ \t]*#%+[Tt][Bb][Ll][Ff][Mm]: +") do
    tblfm[#tblfm + 1] = L[j]:match("^[ \t]*#%+[Tt][Bb][Ll][Ff][Mm]: +(.-)[ \t]*$")
    j = j + 1
  end
  local pb, nxt = after(L, j - 1, e)
  local node = attach(M.node("table", { post_blank = pb, tblfm = tblfm, table_type = orgtype and "org" or "table.el" }), aff)
  if not orgtype then
    node.value = table.concat(vim.list_slice(L, i, last), "\n") .. "\n"
    return node, nxt
  end
  local rows = {}
  for k = i, last do
    local l = L[k]
    local row
    if l:match("^[ \t]*|%-") then
      row = M.node("table-row", { row_type = "rule" })
    else
      row = M.node("table-row", { row_type = "standard" })
      local content = l:match("^[ \t]*|(.*)$"):gsub("[ \t]+$", "")
      local cells = {}
      local pos = 1
      while pos <= #content do
        local bar = content:find("|", pos, true)
        local raw = content:sub(pos, (bar or (#content + 1)) - 1)
        local cell = M.node("table-cell", {})
        cell.contents = self:parse_objects(trim(raw), M.RESTRICTIONS["table-cell"], cell)
        cell.parent = row
        cells[#cells + 1] = cell
        if not bar then
          break
        end
        pos = bar + 1
      end
      row.contents = cells
    end
    row.parent = node
    rows[#rows + 1] = row
  end
  node.contents = rows
  return node, nxt
end

---------------------------------------------------------------------------
-- Plain lists (org-element--list-struct / plain-list / item parsers)
---------------------------------------------------------------------------

--- Full item match (org-list-full-item-re).
local function full_item(l)
  local ind, bullet, rest = l:match("^([ \t]*)([%-%+%*][ \t]+)(.*)$")
  if not ind then
    ind, bullet = l:match("^([ \t]*)([%-%+%*])$")
    rest = ""
  end
  if not ind then
    ind, bullet, rest = l:match("^([ \t]*)(%w+[%.%)][ \t]+)(.*)$")
    if not ind then
      ind, bullet = l:match("^([ \t]*)(%w+[%.%)])$")
      rest = ""
    end
  end
  if not ind then
    return nil
  end
  local r = { ind = ind, bullet = bullet }
  local counter, rest2 = rest:match("^%[@([%w]+)%][ \t]*(.*)$")
  if not counter then
    counter, rest2 = rest:match("^%[@start:([%w]+)%][ \t]*(.*)$")
  end
  if counter then
    r.counter = counter
    rest = rest2
  end
  local box, rest3 = rest:match("^(%[[ X%-]%])[ \t]+(.*)$")
  if not box then
    box = rest:match("^(%[[ X%-]%])$")
    rest3 = box and "" or nil
  end
  if box then
    r.checkbox = box
    rest = rest3
  end
  -- tag: greedy up to the last " ::" followed by blank or end
  local tag, after_tag
  local best
  local s = 1
  while true do
    local a, b = rest:find("[ \t]+::", s)
    if not a then
      break
    end
    local nextc = rest:sub(b + 1, b + 1)
    if nextc == "" or nextc:match("[ \t]") then
      best = { a, b }
    end
    s = b + 1
  end
  if best then
    tag = rest:sub(1, best[1] - 1)
    after_tag = rest:sub(best[2] + 1):gsub("^[ \t]+", "")
    r.tag = tag
    r.after_tag = after_tag
  end
  r.rest = rest
  return r
end

function P:list_struct(L, i, e)
  local items, struct = {}, {}
  local alpha = self.opts.alpha
  local j = i
  local function close_all(endline)
    for _, it in ipairs(items) do
      it.last = endline
      struct[#struct + 1] = it
    end
    items = {}
  end
  while true do
    if j > e then
      -- at limit: end before trailing blanks
      local k = e
      while k >= i and blank(L[k]) do
        k = k - 1
      end
      close_all(k)
      break
    end
    local l = L[j]
    if blank(l) and j + 1 <= e and blank(L[j + 1]) then
      close_all(j - 1)
      break
    end
    local ind = item_match(l, alpha)
    if ind then
      while #items > 0 and ind <= items[#items].ind do
        local it = table.remove(items)
        it.last = j - 1
        struct[#struct + 1] = it
      end
      local fi = full_item(l)
      items[#items + 1] = {
        line = j,
        ind = ind,
        bullet = fi.bullet,
        counter = fi.counter,
        checkbox = fi.checkbox,
        tag = fi.bullet:match("^[%-%+%*]") and fi.tag or nil,
        full = fi,
      }
      j = j + 1
    elseif blank(l) then
      j = j + 1
    elseif l:match("^%*+ ") and headline_stars(l) >= self.inlinetask_min then
      -- skip inline tasks
      local origin = j + 1
      local k = origin
      while k <= e and not L[k]:match("^%*+ ") do
        k = k + 1
      end
      if k <= e and L[k]:match("^%*+ [ \t]*END[ \t]*$") then
        j = k + 1
      else
        j = origin
      end
    else
      local ind2 = indentation(l)
      local k = j - 1
      while k >= i and blank(L[k]) do
        k = k - 1
      end
      local done = false
      while #items > 0 and ind2 <= items[#items].ind do
        local it = table.remove(items)
        it.last = k
        struct[#struct + 1] = it
        if #items == 0 then
          done = true
        end
      end
      if done then
        break
      end
      -- skip blocks and drawers
      local bt = l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn](_%S+)") or (l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:") and ":")
      if bt then
        local endp = bt == ":" and "^[ \t]*#%+end:?[ \t]*$" or ("^[ \t]*#%+end" .. vim.pesc(bt:lower()) .. "[ \t]*$")
        local k2 = find_line(L, j + 1, e, function(x)
          return x:lower():match(endp) ~= nil
        end)
        if k2 then
          j = k2
        end
      elseif drawer_name(l) then
        local k2 = find_line(L, j + 1, e, is_end_line)
        if k2 then
          j = k2
        end
      end
      j = j + 1
    end
  end
  table.sort(struct, function(a, b)
    return a.line < b.line
  end)
  local by_line = {}
  for _, it in ipairs(struct) do
    by_line[it.line] = it
  end
  return struct, by_line
end

function P:plain_list(L, i, e, aff, struct_info)
  local struct, by_line
  if struct_info then
    struct, by_line = struct_info[1], struct_info[2]
  else
    struct, by_line = self:list_struct(L, i, e)
  end
  local first = by_line[i]
  if not first then
    return self:paragraph(L, i, e, aff)
  end
  local ltype
  if L[i]:match("^[ \t]*[%w]") then
    ltype = "ordered"
  elseif first.tag then
    ltype = "descriptive"
  else
    ltype = "unordered"
  end
  -- siblings: items with the same indentation, each starting right
  -- where the previous one ends
  local items = {}
  local it = first
  while it do
    items[#items + 1] = it
    local nxt = by_line[it.last + 1]
    if nxt and nxt.ind == first.ind then
      it = nxt
    else
      break
    end
  end
  local last_item = items[#items]
  local ce = last_item.last
  while ce >= i and blank(L[ce]) do
    ce = ce - 1
  end
  local pb, nxt = after(L, ce, e)
  local node = attach(M.node("plain-list", { post_blank = pb, list_type = ltype }), aff)
  local kids = {}
  for _, item in ipairs(items) do
    kids[#kids + 1] = self:item(L, item, item.last, struct, by_line, ltype)
  end
  M.adopt(node, kids)
  return node, nxt
end

function P:item(L, it, iend, struct, by_line, ltype)
  local fi = it.full
  local node = M.node("item", { bullet = it.bullet, pre_blank = 0 })
  if it.checkbox == "[ ]" then
    node.checkbox = "off"
  elseif it.checkbox == "[X]" then
    node.checkbox = "on"
  elseif it.checkbox == "[-]" then
    node.checkbox = "trans"
  end
  if it.counter then
    local c = it.counter
    node.counter = tonumber(c) or (c:upper():byte() - 64)
  end
  -- contents end before trailing blanks
  local ce = iend
  while ce > it.line and blank(L[ce]) do
    ce = ce - 1
  end
  node.post_blank = iend - ce
  -- ordered items cannot have tags: their contents start at the tag
  local first = (fi.tag and it.tag) and fi.after_tag or fi.rest
  if it.tag then
    node.tag = self:parse_objects(it.tag, M.RESTRICTIONS.item, node)
  end
  first = first:gsub("^[ \t]+", "")
  local body
  local not_bol = false
  if first ~= "" then
    body = { first }
    vim.list_extend(body, vim.list_slice(L, it.line + 1, ce))
    not_bol = true
  else
    local cb = skip_blank(L, it.line + 1, ce)
    if cb <= ce then
      node.pre_blank = cb - it.line - 1
      body = vim.list_slice(L, cb, ce)
    end
  end
  if body then
    -- sub-structure lines are offset: rebuild struct for the body
    M.adopt(node, self:parse_elements(body, 1, #body, nil, node, not_bol))
  end
  return node
end

---------------------------------------------------------------------------
-- Objects
---------------------------------------------------------------------------

local function word_char(c)
  return c ~= nil and c ~= "" and c:match("[%w]") ~= nil
end

local PUNCT_CLOSE = "[ \t\n%-%.,;:!%?'\"%)}\\%[]"
local EMPH = { ["*"] = "bold", ["/"] = "italic", ["_"] = "underline", ["+"] = "strike-through", ["="] = "verbatim", ["~"] = "code" }

--- Emphasis at position p (org-element--parse-generic-emphasis).
function P:emphasis(s, p)
  local mark = s:sub(p, p)
  local prev = p > 1 and s:sub(p - 1, p - 1) or "\n"
  if not (prev:match("[ \t\n%-%(%{'\"]") or prev == "\n") then
    return nil
  end
  local nxt = s:sub(p + 1, p + 1)
  if nxt == "" or nxt:match("[ \t\n]") then
    return nil
  end
  -- closing: (not space)(mark)(punct or eol)
  local k = p + 1
  while true do
    local c = s:find(mark, k + 1, true)
    if not c then
      return nil
    end
    local before = s:sub(c - 1, c - 1)
    local after_c = s:sub(c + 1, c + 1)
    if not before:match("[ \t\n]") and (after_c == "" or after_c:match(PUNCT_CLOSE)) then
      local inner = s:sub(p + 1, c - 1)
      local e = c + 1
      local ws = s:match("^[ \t]*", e)
      local t = EMPH[mark]
      local node = M.node(t, { post_blank = #ws })
      if t == "verbatim" or t == "code" then
        node.value = inner
      else
        node.inner = inner
      end
      return node, e + #ws
    end
    k = c
  end
end

--- Parse a timestamp at s:sub(p). Returns node, end index (after post-blank).
function P:parse_timestamp(s, p)
  local c = s:sub(p, p)
  if c ~= "<" and c ~= "[" then
    return nil
  end
  local close = c == "<" and ">" or "]"
  -- diary sexp <%%(...)>
  if s:sub(p, p + 2) == "<%%" then
    local sexp_end = s:find(">", p, true)
    local body = s:match("^<%%%%(%b())([^\n>]*)>", p)
    if not body then
      return nil
    end
    local full = s:match("^(<%%%%%b()[^\n>]*>)", p)
    local e = p + #full
    local ws = s:match("^[ \t]*", e)
    local node = M.node("timestamp", {
      ts_type = "diary",
      raw_value = full,
      diary_sexp = body:sub(2, -2),
      post_blank = #ws,
    })
    local rest = s:match("^<%%%%%b()([^\n>]*)>", p)
    local h1, m1, h2, m2 = (rest or ""):match("(%d?%d):(%d%d)%-(%d?%d):(%d%d)")
    if not h1 then
      h1, m1 = (rest or ""):match("(%d?%d):(%d%d)")
    end
    node.hour_start, node.minute_start = tonumber(h1), tonumber(m1)
    node.hour_end, node.minute_end = tonumber(h2), tonumber(m2)
    if node.hour_end then
      node.range_type = "timerange"
    end
    _ = sexp_end
    return node, e + #ws
  end
  local inner = s:match("^%" .. c .. "(%d%d%d%d%-%d%d%-%d%d[^%" .. close .. "\n]-)%" .. close, p)
  if not inner then
    return nil
  end
  if not (inner:match("^%d%d%d%d%-%d%d%-%d%d$") or inner:match("^%d%d%d%d%-%d%d%-%d%d ")) then
    return nil
  end
  local raw = c .. inner .. close
  local e = p + #raw
  local inner2
  if s:sub(e, e + 1) == "--" then
    local c2 = s:sub(e + 2, e + 2)
    if c2 == "<" or c2 == "[" then
      local close2 = c2 == "<" and ">" or "]"
      inner2 = s:match("^%" .. c2 .. "(%d%d%d%d%-%d%d%-%d%d[^%" .. close2 .. "\n]-)%" .. close2, e + 2)
      if inner2 and (inner2:match("^%d%d%d%d%-%d%d%-%d%d$") or inner2:match("^%d%d%d%d%-%d%d%-%d%d ")) then
        raw = raw .. "--" .. c2 .. inner2 .. close2
        e = p + #raw
      else
        inner2 = nil
      end
    end
  end
  local ws = s:match("^[ \t]*", e)
  local active = c == "<"
  local function parse_date(str)
    local y, mo, d = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    local h, mi = str:match(" (%d?%d):(%d%d)")
    return tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  end
  local y1, mo1, d1, h1, mi1 = parse_date(inner)
  local th, tm = inner:match("%d?%d:%d%d%-(%d?%d):(%d%d)")
  local ttype
  if active and (inner2 or th) then
    ttype = "active-range"
  elseif active then
    ttype = "active"
  elseif inner2 or th then
    ttype = "inactive-range"
  else
    ttype = "inactive"
  end
  local node = M.node("timestamp", {
    ts_type = ttype,
    range_type = inner2 and "daterange" or (th and "timerange" or nil),
    raw_value = raw,
    year_start = y1,
    month_start = mo1,
    day_start = d1,
    hour_start = h1,
    minute_start = mi1,
    post_blank = #ws,
  })
  if inner2 then
    local y2, mo2, d2, h2, mi2 = parse_date(inner2)
    node.year_end, node.month_end, node.day_end, node.hour_end, node.minute_end = y2, mo2, d2, h2, mi2
  else
    node.year_end, node.month_end, node.day_end = y1, mo1, d1
    node.hour_end = tonumber(th) or h1
    node.minute_end = tonumber(tm) or mi1
  end
  local rtype, rval, runit = raw:match("([%.%+]?%+)(%d+)([hdwmy])")
  if rtype then
    node.repeater_type = rtype == "++" and "catch-up" or (rtype == ".+" and "restart" or "cumulate")
    node.repeater_value = tonumber(rval)
    node.repeater_unit = runit
  end
  local wfirst, wval, wunit = raw:match("(%-?)%-(%d+)([hdwmy])")
  if wval and raw:match("%s%-%-?%d+[hdwmy]") then
    node.warning_type = wfirst == "-" and "first" or "all"
    node.warning_value = tonumber(wval)
    node.warning_unit = wunit
  end
  return node, e + #ws
end

--- Balanced square brackets starting at p (s:sub(p,p) == "[").
local function balanced_square(s, p)
  local depth = 0
  for k = p, #s do
    local c = s:sub(k, k)
    if c == "[" then
      depth = depth + 1
    elseif c == "]" then
      depth = depth - 1
      if depth == 0 then
        return k
      end
    end
  end
end

--- Parse paired brackets `open` at p: returns inner, end index or nil.
local function paired(s, p, open)
  local close = ({ ["["] = "]", ["("] = ")", ["{"] = "}" })[open]
  if s:sub(p, p) ~= open then
    return nil
  end
  local depth = 0
  for k = p, #s do
    local c = s:sub(k, k)
    if c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then
        return s:sub(p + 1, k - 1), k + 1
      end
    end
  end
end

function P:link_type_of(raw)
  local t = raw:match("^([%w%+%-]+):")
  if t and (self.link_types[t] or (self.opts.extra_link_types and self.opts.extra_link_types[t])) then
    return t, raw:sub(#t + 2)
  end
end

--- Expand #+LINK / config link abbreviations.
function P:expand_abbrev(link)
  local key, tag = link:match("^([^:]*)::?(.*)$")
  if not key then
    key = link
  end
  local abbrevs = self.opts.abbrevs or {}
  local rpl = abbrevs[key]
  if rpl == nil then
    return link
  end
  if type(rpl) == "function" then
    local ok, v = pcall(rpl, tag or "")
    return ok and v or link
  end
  if rpl:find("%s", 1, true) then
    return (rpl:gsub("%%s", function()
      return tag or ""
    end))
  elseif rpl:find("%h", 1, true) then
    return (rpl:gsub("%%h", function()
      return (tag or ""):gsub("[^%w%-_%.~]", function(ch)
        return string.format("%%%02X", ch:byte())
      end)
    end))
  end
  return rpl .. (tag or "")
end

local function link_unescape(s)
  return (s:gsub("(\\+)([%[%]])", function(bs, ch)
    return string.rep("\\", math.floor(#bs / 2)) .. ch
  end):gsub("(\\+)$", function(bs)
    return string.rep("\\", math.floor(#bs / 2))
  end))
end

function P:make_link(raw, format, desc_text, e, s)
  local ltype, path
  local explicit = false
  if raw:match("^/") or raw:match("^~") or raw:match("^%.%.?/") then
    ltype, path = "file", raw
  else
    local t, p2 = self:link_type_of(raw)
    if t then
      ltype, path, explicit = t, p2, true
    elseif raw:match("^%(.*%)$") then
      ltype, path = "coderef", raw:sub(2, -2)
    elseif raw:sub(1, 1) == "#" then
      ltype, path = "custom-id", raw:sub(2)
    else
      ltype, path = "fuzzy", raw
    end
  end
  local node = M.node("link", {
    link_type = ltype,
    type_explicit = explicit,
    path = path,
    format = format,
    raw_link = raw,
  })
  local app = ltype:match("^file%+(.+)$")
  if ltype == "file" or app then
    node.application = app
    node.link_type = "file"
    local p2, opt = node.path:match("^(.-)::(.*)$")
    if p2 then
      node.path = p2
      node.search_option = opt
    end
    node.path = node.path:gsub("^///*(%a:)/", "%1/")
  end
  if desc_text then
    node.contents = self:parse_objects(desc_text, M.RESTRICTIONS.link, node)
  end
  local ws = s:match("^[ \t]*", e)
  node.post_blank = #ws
  return node, e + #ws
end

--- Plain link path at s:sub(p) after "type:" (org-link-plain-re).
local function plain_path(s, p)
  local k = p
  local n = #s
  local last_ok = nil
  while k <= n do
    local c = s:sub(k, k)
    if c:match("[%s%[%]%(%)<>]") then
      if c == "(" or c == "[" or c == "<" then
        -- balanced group (one level of nesting)
        local close = ({ ["("] = ")", ["["] = "]", ["<"] = ">" })[c]
        local depth, j = 0, k
        local ok = false
        while j <= n do
          local cj = s:sub(j, j)
          if cj:match("%s") then
            break
          end
          if cj == "(" or cj == "[" or cj == "<" then
            depth = depth + 1
          elseif cj == ")" or cj == "]" or cj == ">" then
            depth = depth - 1
            if depth == 0 then
              ok = cj == close
              break
            end
          end
          j = j + 1
        end
        if ok then
          k = j + 1
          last_ok = j
        else
          break
        end
      else
        break
      end
    else
      if not c:match("[%p]") or c == "/" or c == "-" or c:byte() > 127 then
        last_ok = k
      end
      k = k + 1
    end
  end
  if last_ok and last_ok >= p then
    return s:sub(p, last_ok), last_ok + 1
  end
end

function P:link_at(s, p)
  local c = s:sub(p, p)
  if c == "[" and s:sub(p + 1, p + 1) == "[" then
    -- bracket link
    local k = p + 2
    local n = #s
    local path_end
    while k <= n do
      local ch = s:sub(k, k)
      if ch == "\\" then
        k = k + 2
      elseif ch == "[" then
        return nil
      elseif ch == "]" then
        path_end = k
        break
      else
        k = k + 1
      end
    end
    if not path_end or path_end == p + 2 then
      return nil
    end
    local rawpath = s:sub(p + 2, path_end - 1)
    local desc, e
    if s:sub(path_end + 1, path_end + 1) == "]" then
      e = path_end + 2
    elseif s:sub(path_end + 1, path_end + 1) == "[" then
      local close = s:find("]]", path_end + 2, true)
      if not close or close == path_end + 2 then
        return nil
      end
      desc = s:sub(path_end + 2, close - 1)
      e = close + 2
    else
      return nil
    end
    local raw = rawpath:gsub("[ \t]*\n[ \t]*", " ")
    raw = self:expand_abbrev(link_unescape(raw))
    return self:make_link(raw, "bracket", desc, e, s)
  elseif c == "<" then
    local t, rest = s:match("^<([%w%+%-]+):([^>]*)>", p)
    if t and (self.link_types[t] or (self.opts.extra_link_types and self.opts.extra_link_types[t])) then
      local e = p + #t + #rest + 3
      local node, e2 = self:make_link(t .. ":" .. rest:gsub("[ \t]*\n[ \t]*", ""), "angle", nil, e, s)
      node.raw_link = t .. ":" .. rest
      return node, e2
    end
    return nil
  else
    -- plain link
    local prev = p > 1 and s:sub(p - 1, p - 1) or ""
    if word_char(prev) then
      return nil
    end
    local t = s:match("^([%w%+%-]+):", p)
    if not t or not (self.link_types[t] or (self.opts.extra_link_types and self.opts.extra_link_types[t])) then
      return nil
    end
    local path, e = plain_path(s, p + #t + 1)
    if not path then
      return nil
    end
    return self:make_link(t .. ":" .. path, "plain", nil, e, s)
  end
end

--- Radio link at p: returns node, end.
function P:radio_at(s, p, lows)
  if #self.radios == 0 then
    return nil
  end
  local prev = p > 1 and s:sub(p - 1, p - 1) or ""
  if word_char(prev) then
    return nil
  end
  local low = (lows or s:lower()):sub(p)
  for _, words in ipairs(self.radios) do
    local pos = 1
    local ok = true
    for wi, w in ipairs(words) do
      if low:sub(pos, pos + #w - 1) ~= w then
        ok = false
        break
      end
      pos = pos + #w
      if wi < #words then
        local ws = low:match("^[ \t\n]+", pos)
        if not ws then
          ok = false
          break
        end
        pos = pos + #ws
      end
    end
    if ok then
      local nextc = low:sub(pos, pos)
      if not word_char(nextc) then
        local text = s:sub(p, p + pos - 2)
        local node = M.node("link", { link_type = "radio", path = text, format = "plain", raw_link = text })
        node.contents = self:parse_objects(text, M.RESTRICTIONS["radio-target"], node)
        local e = p + pos - 1
        local ws = s:match("^[ \t]*", e)
        node.post_blank = #ws
        return node, e + #ws
      end
    end
  end
end

--- Sub/superscript at p (org-match-substring-regexp).
local function subsup(s, p)
  if p <= 1 then
    return nil
  end
  local prev = s:sub(p - 1, p - 1)
  if prev:match("[ \t\n]") then
    return nil
  end
  local c = s:sub(p + 1, p + 1)
  if c == "{" then
    local inner, e = paired(s, p + 1, "{")
    if inner then
      return inner, e, true
    end
    return nil
  elseif c == "(" then
    local inner, e = paired(s, p + 1, "(")
    if inner then
      return "(" .. inner .. ")", e, false
    end
    return nil
  elseif c == "*" then
    return "*", p + 2, false
  end
  -- [+-]?[[:alnum:].,\\]*[[:alnum:]]
  local k = p + 1
  local sign = s:sub(k, k)
  if sign == "+" or sign == "-" then
    k = k + 1
  end
  local run = s:match("^[%w%.,\\\128-\255]*", k)
  if not run or run == "" then
    return nil
  end
  -- back off to the last alnum
  local last = #run
  while last > 0 and not run:sub(last, last):match("[%w\128-\255]") do
    last = last - 1
  end
  if last == 0 then
    return nil
  end
  local e = k + last
  return s:sub(p + 1, e - 1), e, false
end

--- Entity name at p (after the backslash).
local function entity_at(s, p)
  local sp = s:match("^_( +)", p + 1)
  if sp then
    local name = "_" .. sp
    if entities[name] then
      return name, p + 1 + #name, false
    end
    return nil
  end
  local name = s:match("^(there4)", p + 1) or s:match("^(sup[123])", p + 1) or s:match("^(frac[13][24])", p + 1)
  if not name then
    name = s:match("^(%a+)", p + 1)
  end
  if not name then
    return nil
  end
  local e = p + 1 + #name
  local brackets = false
  if s:sub(e, e + 1) == "{}" then
    brackets = true
  elseif s:sub(e, e):match("%a") then
    return nil
  end
  if not entities[name] and not (M.user_entities and M.user_entities[name]) then
    return nil
  end
  return name, e + (brackets and 2 or 0), brackets
end

function P:latex_fragment(s, p)
  local c = s:sub(p, p)
  local e
  if c ~= "$" then
    local c2 = s:sub(p + 1, p + 1)
    if c2 == "(" then
      local k = s:find("\\)", p + 2, true)
      e = k and k + 2
    elseif c2 == "[" then
      local k = s:find("\\]", p + 2, true)
      e = k and k + 2
    else
      local m = s:match("^\\%a+%*?", p)
      if not m then
        return nil
      end
      local k = p + #m
      while true do
        local g = s:match("^%[[^%]%[\n{}]*%]", k) or s:match("^{[^{}\n]*}", k)
        if not g then
          break
        end
        k = k + #g
      end
      e = k
    end
  elseif s:sub(p + 1, p + 1) == "$" then
    local k = s:find("$$", p + 2, true)
    e = k and k + 2
  else
    local prev = p > 1 and s:sub(p - 1, p - 1) or ""
    local nxt = s:sub(p + 1, p + 1)
    if prev == "$" or nxt:match("^[ \t\n,%.;]") or nxt == "" then
      return nil
    end
    local k = s:find("$", p + 1, true)
    if not k then
      return nil
    end
    local before = s:sub(k - 1, k - 1)
    if before:match("[ \t\n,%.]") then
      return nil
    end
    local after_c = s:sub(k + 1, k + 1)
    if not (after_c == "" or after_c:match("[%p%s]")) then
      return nil
    end
    e = k + 1
  end
  if not e then
    return nil
  end
  local ws = s:match("^[ \t]*", e)
  return M.node("latex-fragment", { value = s:sub(p, e - 1), post_blank = #ws }), e + #ws
end

--- Try to parse an object at position p. Returns node, next position.
function P:object_at(s, p, R)
  local c = s:sub(p, p)
  local rest2 = s:sub(p, p + 4)
  if (rest2:sub(1, 5) == "call_") and R["inline-babel-call"] and not word_char(p > 1 and s:sub(p - 1, p - 1) or "") then
    local name = s:match("^call_([^ \t\n%[%(]+)", p)
    if name then
      local k = p + 5 + #name
      local inside, k2
      if s:sub(k, k) == "[" then
        inside, k2 = paired(s, k, "[")
        if not inside then
          return nil
        end
        k = k2
      end
      local args, k3 = paired(s, k, "(")
      if not args then
        return nil
      end
      k = k3
      local endh
      if s:sub(k, k) == "[" then
        local eh, k4 = paired(s, k, "[")
        if eh then
          endh, k = eh, k4
        end
      end
      local ws = s:match("^[ \t]*", k)
      return M.node("inline-babel-call", {
        call = name,
        inside_header = inside and trim(inside) ~= "" and trim(inside) or nil,
        arguments = args ~= "" and args or nil,
        end_header = endh and trim(endh) ~= "" and trim(endh) or nil,
        value = s:sub(p, k - 1),
        post_blank = #ws,
      }),
        k + #ws
    end
  end
  if rest2:sub(1, 4) == "src_" and R["inline-src-block"] and not word_char(p > 1 and s:sub(p - 1, p - 1) or "") then
    local lang = s:match("^src_([^ \t\n%[{]+)", p)
    if lang then
      local k = p + 4 + #lang
      local params
      if s:sub(k, k) == "[" then
        local pr, k2 = paired(s, k, "[")
        if not pr then
          return nil
        end
        params, k = pr, k2
      end
      local body, k3 = paired(s, k, "{")
      if body then
        local ws = s:match("^[ \t]*", k3)
        return M.node("inline-src-block", {
          language = lang,
          parameters = params and trim(params) ~= "" and trim(params:gsub("\n[ \t]*", " ")) or nil,
          value = body,
          post_blank = #ws,
        }),
          k3 + #ws
      end
    end
  end
  if c == "^" then
    if R.superscript then
      local inner, e, br = subsup(s, p)
      if inner then
        local ws = s:match("^[ \t]*", e)
        return M.node("superscript", { inner = inner, use_brackets = br, post_blank = #ws }), e + #ws
      end
    end
  elseif c == "_" then
    if R.underline then
      local n, e = self:emphasis(s, p)
      if n then
        return n, e
      end
    end
    if R.subscript then
      local inner, e, br = subsup(s, p)
      if inner then
        local ws = s:match("^[ \t]*", e)
        return M.node("subscript", { inner = inner, use_brackets = br, post_blank = #ws }), e + #ws
      end
    end
  elseif EMPH[c] then
    if R[EMPH[c]] then
      return self:emphasis(s, p)
    end
  elseif c == "@" then
    if R["export-snippet"] then
      local be = s:match("^@@([%-%w]+):", p)
      if be then
        local start = p + 3 + #be
        local close = s:find("@@", start, true)
        if close then
          local e = close + 2
          local ws = s:match("^[ \t]*", e)
          return M.node("export-snippet", { back_end = be, value = s:sub(start, close - 1), post_blank = #ws }), e + #ws
        end
      end
    end
  elseif c == "{" then
    if R.macro and s:sub(p, p + 2) == "{{{" then
      local name = s:match("^{{{(%a[%-%w_]*)", p)
      if name then
        local k = p + 3 + #name
        local args
        local e
        if s:sub(k, k + 2) == "}}}" then
          e = k + 3
        elseif s:sub(k, k) == "(" then
          local close = s:find(")}}}", k, true)
          if close then
            args = s:sub(k + 1, close - 1)
            e = close + 4
          end
        end
        if e then
          local ws = s:match("^[ \t]*", e)
          return M.node("macro", {
            key = name:lower(),
            value = s:sub(p, e - 1),
            args = args and M.macro_args(trim((args:gsub("[ \t\r\n]+", " ")))) or nil,
            post_blank = #ws,
          }),
            e + #ws
        end
      end
    end
  elseif c == "$" then
    if R["latex-fragment"] then
      return self:latex_fragment(s, p)
    end
  elseif c == "<" then
    if s:sub(p + 1, p + 1) == "<" then
      if R["radio-target"] and s:sub(p + 2, p + 2) == "<" then
        local v = s:match("^<<<([^<>\n \t][^<>\n]-)>>>", p) or s:match("^<<<([^<>\n \t])>>>", p)
        if v and not v:match("[ \t]$") then
          local e = p + #v + 6
          local ws = s:match("^[ \t]*", e)
          local node = M.node("radio-target", { value = v, post_blank = #ws })
          node.contents = self:parse_objects(v, M.RESTRICTIONS["radio-target"], node)
          return node, e + #ws
        end
      end
      if R.target then
        local v = s:match("^<<([^<>\n \t][^<>\n]-)>>", p) or s:match("^<<([^<>\n \t])>>", p)
        if v and not v:match("[ \t]$") then
          local e = p + #v + 4
          local ws = s:match("^[ \t]*", e)
          return M.node("target", { value = v, post_blank = #ws }), e + #ws
        end
      end
    else
      if R.timestamp then
        local n, e = self:parse_timestamp(s, p)
        if n then
          return n, e
        end
      end
      if R.link then
        return self:link_at(s, p)
      end
    end
  elseif c == "\\" then
    if s:sub(p + 1, p + 1) == "\\" then
      if R["line-break"] and s:match("^\\\\[ \t]*\n", p) or (R["line-break"] and s:match("^\\\\[ \t]*$", p)) then
        local prev = p > 1 and s:sub(p - 1, p - 1) or ""
        if prev ~= "\\" then
          local ws = s:match("^\\\\([ \t]*)", p)
          local e = p + 2 + #ws
          if s:sub(e, e) == "\n" then
            e = e + 1
          end
          return M.node("line-break", { post_blank = 0 }), e
        end
      end
    else
      if R.entity then
        local name, e, br = entity_at(s, p)
        if name then
          local ws = s:match("^[ \t]*", e)
          return M.node("entity", { name = name, use_brackets = br, post_blank = #ws }), e + #ws
        end
      end
      if R["latex-fragment"] then
        return self:latex_fragment(s, p)
      end
    end
  elseif c == "[" then
    local c2 = s:sub(p + 1, p + 1)
    if c2 == "[" then
      if R.link then
        return self:link_at(s, p)
      end
    elseif c2 == "f" and s:sub(p, p + 3) == "[fn:" then
      if R["footnote-reference"] then
        local label = s:match("^%[fn:([%w%-_]*)", p)
        local k = p + 4 + #label
        local ftype
        if s:sub(k, k) == ":" then
          ftype = "inline"
        elseif s:sub(k, k) == "]" and label ~= "" then
          ftype = "standard"
        else
          return nil
        end
        local close = balanced_square(s, p)
        if not close then
          return nil
        end
        local ws = s:match("^[ \t]*", close + 1)
        local node = M.node("footnote-reference", {
          label = label ~= "" and label or nil,
          fn_type = ftype,
          post_blank = #ws,
        })
        if ftype == "inline" then
          node.contents = self:parse_objects(s:sub(k + 1, close - 1), M.RESTRICTIONS["footnote-reference"], node)
        end
        return node, close + 1 + #ws
      end
    elseif c2 == "c" and (s:sub(p, p + 5) == "[cite:" or s:sub(p, p + 5) == "[cite/") then
      if R.citation then
        return self:citation(s, p)
      end
    elseif c2 == "%" or c2 == "/" then
      if R["statistics-cookie"] then
        local v = s:match("^(%[%d*%%%])", p) or s:match("^(%[%d*/%d*%])", p)
        if v then
          local ws = s:match("^[ \t]*", p + #v)
          return M.node("statistics-cookie", { value = v, post_blank = #ws }), p + #v + #ws
        end
      end
    else
      if R.timestamp then
        local n, e = self:parse_timestamp(s, p)
        if n then
          return n, e
        end
      end
      if R["statistics-cookie"] then
        local v = s:match("^(%[%d*%%%])", p) or s:match("^(%[%d*/%d*%])", p)
        if v then
          local ws = s:match("^[ \t]*", p + #v)
          return M.node("statistics-cookie", { value = v, post_blank = #ws }), p + #v + #ws
        end
      end
    end
  elseif c:match("%a") then
    if R.link then
      return self:link_at(s, p)
    end
  end
  return nil
end

--- Citation key (org-element-citation-key-re): "@" then word characters
--- or any of -.:?!`'/*@+|(){}<>&_^$#%~.
local CITE_KEY = "()@([%w\128-\255%-%.:%?!`'/%*@%+|%(%){}<>&_%^%$#%%~]+)()"

--- Citation at p: [cite/style:prefix;@key suffix;...]
--- (org-element-citation-parser).
function P:citation(s, p)
  local style, colon = s:match("^%[cite/([/_%w%-]+)()", p)
  local start
  if style then
    if s:sub(colon, colon) ~= ":" then
      return nil
    end
    start = colon + 1
  elseif s:sub(p, p + 5) == "[cite:" then
    start = p + 6
  else
    return nil
  end
  -- Ignore blanks between cite type and prefix or key.
  start = s:match("^[ \t\n]*()", start)
  local close = balanced_square(s, p)
  if not close then
    return nil
  end
  local inner = s:sub(1, close - 1)
  local _, _, first_key_end = inner:match(CITE_KEY, start)
  if not first_key_end then
    return nil
  end
  local ws = s:match("^[ \t]*", close + 1)
  local node = M.node("citation", { style = style, post_blank = #ws, raw = s:sub(p, close) })
  local types = M.RESTRICTIONS["citation-reference"]
  -- Common prefix: text before the last ";" preceding the first key.
  local cbeg = start
  local semi
  for i = first_key_end - 1, start, -1 do
    if s:sub(i, i) == ";" then
      semi = i
      break
    end
  end
  if semi then
    if start < semi then
      node.prefix = self:parse_objects(s:sub(start, semi - 1), types, node)
    end
    cbeg = semi + 1
  end
  -- Common suffix: text after the last ";" when no key follows it.
  local cend = close - 1
  while cend >= first_key_end and s:sub(cend, cend):match("[ \r\t\n]") do
    cend = cend - 1
  end
  cend = cend + 1 -- exclusive end
  semi = nil
  for i = cend - 1, first_key_end, -1 do
    if s:sub(i, i) == ";" then
      semi = i
      break
    end
  end
  if semi and not s:sub(semi + 1, cend - 1):find(CITE_KEY) then
    if semi + 1 < cend then
      node.suffix = self:parse_objects(s:sub(semi + 1, cend - 1), types, node)
    end
    cend = semi
  end
  -- References, separated by ";" (org-element-citation-reference-parser).
  local refs = {}
  for part in (s:sub(cbeg, cend - 1) .. ";"):gmatch("([^;]*);") do
    local kpos, key, kend = part:match(CITE_KEY)
    if kpos then
      local ref = M.node("citation-reference", { key = key, post_blank = 0 })
      if kpos > 1 then
        ref.prefix = self:parse_objects(part:sub(1, kpos - 1), types, ref)
      end
      if kend <= #part then
        ref.suffix = self:parse_objects(part:sub(kend), types, ref)
      end
      ref.parent = node
      refs[#refs + 1] = ref
    end
  end
  if #refs == 0 then
    return nil
  end
  node.contents = refs
  return node, close + 1 + #ws
end

--- Split macro arguments (org-macro-extract-arguments).
function M.macro_args(s)
  local out = {}
  local cur = {}
  local i = 1
  while i <= #s do
    local bs = s:match("^\\*", i)
    if #bs > 0 and s:sub(i + #bs, i + #bs) == "," then
      cur[#cur + 1] = string.rep("\\", math.floor(#bs / 2))
      if #bs % 2 == 0 then
        out[#out + 1] = table.concat(cur)
        cur = {}
      else
        cur[#cur + 1] = ","
      end
      i = i + #bs + 1
    elseif s:sub(i, i) == "," then
      out[#out + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      local k = #bs > 0 and #bs or 1
      cur[#cur + 1] = s:sub(i, i + k - 1)
      i = i + k
    end
  end
  out[#out + 1] = table.concat(cur)
  return out
end

--- Parse objects of string `s` allowed by restriction set R.
---@return table[] nodes
function P:parse_objects(s, R, parent, depth)
  depth = depth or 0
  local out = {}
  local buf_start = 1
  local p = 1
  local n = #s
  local expansions = 0
  local function flush(upto)
    if upto >= buf_start then
      local t = M.text(s:sub(buf_start, upto), parent)
      out[#out + 1] = t
    end
  end
  local lows = #self.radios > 0 and s:lower() or nil
  while p <= n do
    local node, e = self:object_at(s, p, R)
    if not node and R.link and lows then
      node, e = self:radio_at(s, p, lows)
    end
    local replaced = false
    if node then
      if node.type == "macro" and self.opts.macro and expansions < 10000 then
        local value = self.opts.macro(node, self)
        if value ~= nil then
          -- textual replacement, then continue lexing from here
          local ws = string.rep(" ", node.post_blank)
          s = s:sub(1, p - 1) .. value .. ws .. s:sub(e)
          n = #s
          lows = lows and s:lower()
          expansions = expansions + 1
          node = nil
          replaced = true
        end
      end
    end
    if node then
      flush(p - 1)
      node.parent = parent
      if node.inner then
        node.contents = self:parse_objects(node.inner, M.RESTRICTIONS[node.type] or M.RESTRICTIONS.paragraph, node, depth)
        node.inner = nil
      end
      out[#out + 1] = node
      p = e
      buf_start = e
    elseif not replaced then
      p = p + 1
    end
  end
  flush(n)
  return out
end

--- Parse objects of a secondary string (org-element-parse-secondary-string).
function P:secondary(s, restriction, parent)
  if s == nil or s == "" then
    return nil
  end
  return self:parse_objects(s, M.RESTRICTIONS[restriction] or M.RESTRICTIONS.keyword, parent)
end

---------------------------------------------------------------------------
-- Document
---------------------------------------------------------------------------

--- Fill paragraphs with objects (after the element tree is complete, so
--- that "first paragraph of an item" normalisation is known).
function P:fill(node)
  if node.type == "paragraph" and node.raw_lines then
    self:fill_paragraph(node, node.ignore_first_indent)
    return
  end
  for _, c in ipairs(node.contents or {}) do
    if c.type ~= "plain-text" and M.ELEMENTS[c.type] then
      self:fill(c)
    end
  end
end

--- Parse a whole document.
---@param lines string[]
---@return table org-data node
function P:parse(lines)
  local data = M.node("org-data", { post_blank = 0 })
  local L = lines
  local s = skip_blank(L, 1, #L)
  data.pre_blank = s - 1
  local kids = {}
  local i = s
  local mode = "first-section"
  -- top-level property drawer
  data.props = {}
  do
    local k = s
    while k <= #L and is_comment_line(L[k]) do
      k = k + 1
    end
    if L[k] and L[k]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$") then
      local j = k + 1
      while j <= #L and not is_end_line(L[j]) do
        local key, value = L[j]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
        if key then
          data.props[key:upper()] = value
        end
        j = j + 1
      end
    end
  end
  while i <= #L do
    if self:is_headline(L[i]) then
      local h, nxt = self:headline(L, i, #L)
      h.parent = data
      kids[#kids + 1] = h
      i = nxt
    elseif mode == "first-section" then
      local sec, nxt = self:section(L, i, #L, "first-section")
      sec.parent = data
      kids[#kids + 1] = sec
      i = nxt
    else
      i = i + 1
    end
    mode = nil
  end
  data.contents = kids
  return data
end

--- Convenience: parse lines with options.
function M.parse(lines, opts)
  return M.new(opts):parse(lines)
end

--- Parse objects of a string (secondary string).
function M.parse_secondary(s, restriction, opts, parent)
  return M.new(opts):secondary(s, restriction, parent)
end

--- Map `fn` over nodes of `types` (set or "*") in `data` (org-element-map).
---@param data table node or list of nodes
---@param types table|string
---@param fn fun(node: table): any
---@param opts? { first_match?: boolean, no_recursion?: table, ignore?: table, with_affiliated?: boolean }
function M.map(data, types, fn, opts)
  opts = opts or {}
  local want = types == "*" and true or (type(types) == "string" and { [types] = true } or types)
  local results = {}
  local done = false
  local ignore = opts.ignore or {}
  local function walk(d)
    if done or d == nil then
      return
    end
    if d.type == nil then
      for _, x in ipairs(d) do
        walk(x)
        if done then
          return
        end
      end
      return
    end
    if ignore[d] then
      return
    end
    if want == true or want[d.type] then
      local r = fn(d)
      if r ~= nil and r ~= false then
        if opts.first_match then
          results = r
          done = true
          return
        end
        results[#results + 1] = r
      end
    end
    if opts.no_recursion and opts.no_recursion[d.type] then
      return
    end
    if opts.with_affiliated and d.caption then
      for _, cap in ipairs(d.caption) do
        walk(cap[1])
        walk(cap[2])
      end
    end
    local sec = M.SECONDARY[d.type]
    if sec then
      for _, key in ipairs(sec) do
        if d[key] and d.type ~= "headline" and d.type ~= "inlinetask" and d.type ~= "item" then
          walk(d[key])
        end
      end
    end
    if d.type == "headline" or d.type == "inlinetask" then
      walk(d.title)
    elseif d.type == "item" and d.tag then
      walk(d.tag)
    elseif d.type == "citation-reference" then
      walk(d.prefix)
      walk(d.suffix)
    end
    for _, c in ipairs(d.contents or {}) do
      walk(c)
      if done then
        return
      end
    end
  end
  walk(data)
  if opts.first_match then
    return done and results or nil
  end
  return results
end

--- Ancestors of a node matching `types` (org-element-lineage).
function M.lineage(node, types, with_self)
  local want = type(types) == "string" and { [types] = true } or types
  local n = with_self and node or node.parent
  while n do
    if not want or want[n.type] then
      return n
    end
    n = n.parent
  end
end

--- Nearest enclosing element (org-element-parent-element).
function M.parent_element(node)
  local n = node.parent
  while n and not M.ELEMENTS[n.type] do
    n = n.parent
  end
  return n
end

--- Remove `node` from its parent's contents (org-element-extract).
function M.extract(node)
  local p = node.parent
  if not p then
    return node
  end
  for _, key in ipairs({ "contents", "title", "tag", "prefix", "suffix" }) do
    local list = p[key]
    if type(list) == "table" then
      for i, c in ipairs(list) do
        if c == node then
          table.remove(list, i)
          return node
        end
      end
    end
  end
  return node
end

--- Siblings list containing node.
function M.siblings(node)
  local p = node.parent
  if not p then
    return nil
  end
  for _, key in ipairs({ "contents", "title", "tag", "prefix", "suffix" }) do
    local list = p[key]
    if type(list) == "table" then
      for _, c in ipairs(list) do
        if c == node then
          return list
        end
      end
    end
  end
end

return M
