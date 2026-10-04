---@mod org.export.element.block Export parser: paragraphs, blocks, dispatch
---
--- Affiliated keywords, paragraphs, greater blocks and the element
--- dispatcher (element_at, parse_elements).
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local blank = shared.blank
local headline_stars = shared.headline_stars
local is_comment_line = shared.is_comment_line
local is_clock_line = shared.is_clock_line
local is_planning_line = shared.is_planning_line
local drawer_name = shared.drawer_name
local is_end_line = shared.is_end_line
local is_fixed_width = shared.is_fixed_width
local is_footnote_def = shared.is_footnote_def
local is_hr = shared.is_hr
local latex_env_begin = shared.latex_env_begin
local block_type = shared.block_type
local is_dynamic_block = shared.is_dynamic_block
local is_table_line = shared.is_table_line
local is_tableel_rule = shared.is_tableel_rule
local item_match = shared.item_match
local DUAL = shared.DUAL
local MULTIPLE = shared.MULTIPLE
local PARSED = shared.PARSED
local affiliated_match = shared.affiliated_match
local P = shared.P
local after = shared.after

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
    elseif item_match(l, self.opts.alpha, self.opts.term) then
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
  -- text without a final newline (a region ending inside a line)
  node.no_final_newline = self.opts.no_final_newline and last == #L or nil
  -- the first line of a paragraph starting an item or a footnote
  -- definition does not count for the common indentation
  self:fill_paragraph(node, not_bol)
  return node, nxt
end

--- Fill a paragraph (or verse) node with objects.
function P:fill_paragraph(node, ignore_first)
  local lines = M.remove_indentation(node.raw_lines, ignore_first)
  local text = table.concat(lines, "\n") .. (node.no_final_newline and "" or "\n")
  node.contents =
    self:parse_objects(text, M.RESTRICTIONS[node.type == "verse-block" and "verse-block" or "paragraph"], node)
  -- Emacs only removes the common indentation from plain text
  -- (org-element-normalize-contents): multi-line verbatim values keep it
  local removed = #lines > 1 and #node.raw_lines[#lines] - #lines[#lines] or 0
  if removed > 0 and node.raw_lines[#lines]:sub(1, removed):match("^ +$") then
    local pad = "\n" .. string.rep(" ", removed)
    local types = { verbatim = true, code = true, ["inline-src-block"] = true, ["latex-fragment"] = true }
    M.map(node.contents, types, function(o)
      if o.value and o.value:find("\n", 1, true) then
        -- lint: allow gsub: a newline and spaces
        o.value = o.value:gsub("\n", pad)
      end
    end)
  end
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
  return require("org.babel.blocks").unescape(lines)
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
    M.adopt(node, self:block_contents(L, i + 1, j - 1, node))
  end
  return node, nxt
end

--- Contents of a center, quote, special or dynamic block. They begin on
--- the line after #+BEGIN, unlike drawers or items, so a blank line there
--- is read as a paragraph (org-element-paragraph-parser), which Emacs
--- exports as an empty one.
function P:block_contents(L, s, e, parent)
  local out = {}
  if blank(L[s]) then
    local pb, nxt = after(L, s, e)
    -- its post-blank counts its own line too
    local p = M.node("paragraph", { post_blank = pb + 1, raw_lines = { L[s] } })
    self:fill_paragraph(p)
    out[1] = p
    s = nxt
  end
  vim.list_extend(out, self:parse_elements(L, s, e, nil, parent))
  return out
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
  if item_match(l, self.opts.alpha, self.opts.term) then
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

-- Locals the later parts share
shared.find_line = find_line
shared.attach = attach
shared.block_end = block_end
shared.switches_props = switches_props
shared.unescape = unescape
