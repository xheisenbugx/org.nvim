---@mod org.export.element Org syntax tree for export (port of org-element.el)
---
--- Parses Org text into the same tree Emacs Org builds with
--- `org-element-parse-buffer`: typed nodes with `contents` (children),
--- `parent`, `post_blank` (blank lines after an element, spaces after an
--- object) and the element-specific properties. Plain text is a node of
--- type "plain-text" with a `value`. Element and object type names and
--- the parsing rules (paragraph separation, lists, affiliated keywords,
--- object restrictions, ...) follow org-element.el of Org 9.8.
---
--- This file holds the node helpers (types, restrictions, node, interpret)
--- and the text helpers; the rest loads from org/export/element/: line
--- (line classification, affiliated keywords), state (the parser object),
--- block (paragraphs, blocks, the element dispatcher), elements (the
--- element parsers), list (plain lists), markup (emphasis, timestamps),
--- link (links, radio targets), object (the other objects, parse_objects)
--- and document (parse, map, lineage, position, siblings).

local M = {}
-- The parts in org/export/element/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.export.element"] = M

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
  link = set(
    vim.list_extend(
      { "export-snippet", "inline-babel-call", "inline-src-block", "macro", "statistics-cookie" },
      MINIMAL
    )
  ),
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
    return "src_"
      .. data.language
      .. (data.parameters and ("[" .. data.parameters .. "]") or "")
      .. "{"
      .. data.value
      .. "}"
      .. pb
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

-- Locals the parts below share
local shared = require("org.export.element.shared")
shared.blank = blank
shared.indentation = indentation
shared.trim = trim

require("org.export.element.line")
require("org.export.element.state")
require("org.export.element.block")
require("org.export.element.elements")
require("org.export.element.list")
require("org.export.element.markup")
require("org.export.element.link")
require("org.export.element.object")
require("org.export.element.document")

return M
