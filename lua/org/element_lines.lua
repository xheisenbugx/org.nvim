---@mod org.element_lines Shared Org element line classifiers and affiliated keyword tables
---
--- Single source of truth for the line-level Org 9.8 syntax predicates and
--- affiliated keyword tables shared by `org.element`, `org.export.element`
--- and `org.lint`.

local M = {}

---------------------------------------------------------------------------
-- Affiliated keywords (org-element-affiliated-keywords)
---------------------------------------------------------------------------

--- Maps each affiliated keyword (including legacy aliases) to its canonical
--- official name (`org-element-keyword-translation-alist`).
---@type table<string, string>
M.AFFILIATED_MAP = {
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

--- Set of all recognized affiliated keyword names (official + aliases).
---@type table<string, boolean>
M.AFFILIATED = {}

--- Maps legacy affiliated keyword aliases to their canonical names.
---@type table<string, string>
M.TRANSLATION = {}

for k, v in pairs(M.AFFILIATED_MAP) do
  M.AFFILIATED[k] = true
  if k ~= v then
    M.TRANSLATION[k] = v
  end
end

--- Affiliated keywords that accept an optional dual `[...]` value.
---@type table<string, boolean>
M.DUAL = { CAPTION = true, RESULTS = true }

--- Affiliated keywords that may appear multiple times on one element.
---@type table<string, boolean>
M.MULTIPLE = { CAPTION = true, HEADER = true }

--- Affiliated keywords whose values are parsed as Org objects.
---@type table<string, boolean>
M.PARSED = { CAPTION = true }

---------------------------------------------------------------------------
-- Line classification predicates
---------------------------------------------------------------------------

---@param l string
---@return integer|nil
function M.headline_stars(l)
  local stars = l:match("^(%*+) ")
  return stars and #stars or nil
end

---@param l string
---@return boolean
function M.is_comment_line(l)
  return l:match("^[ \t]*#$") ~= nil or l:match("^[ \t]*# ") ~= nil
end

---@param l string
---@return string|nil
function M.drawer_name(l)
  return l:match("^[ \t]*:([%w_%-]+):[ \t]*$")
end

---@param l string
---@return boolean
function M.is_end_line(l)
  return l:match("^[ \t]*:[Ee][Nn][Dd]:[ \t]*$") ~= nil
end

--- A node property line (`org-property-re`): the key's closing colon is
--- followed by a blank or the end of the line. Returns key and value.
---@param l string
---@return string|nil key, string|nil value
function M.property_line(l)
  local key, value = l:match("^[ \t]*:(%S+):[ \t]+(.-)[ \t]*$")
  if not key then
    key = l:match("^[ \t]*:(%S+):$")
    value = key and ""
  end
  return key, value
end

--- When `L[i]` opens a property drawer (`org-property-drawer-re`: only
--- property lines up to an `:END:` line, at most line `e`), returns that
--- closing line number.
---@param L string[]
---@param i integer
---@param e integer
---@return integer|nil
function M.property_drawer_end(L, i, e)
  if not (L[i] and L[i]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$")) then
    return nil
  end
  for j = i + 1, e do
    if M.is_end_line(L[j]) then
      return j
    elseif not M.property_line(L[j]) then
      return nil
    end
  end
  return nil
end

---@param l string
---@return boolean
function M.is_fixed_width(l)
  return l:match("^[ \t]*:$") ~= nil or l:match("^[ \t]*: ") ~= nil
end

---@param l string
---@return boolean
function M.is_footnote_def(l)
  return l:match("^%[fn:[%w%-_]+%]") ~= nil
end

---@param l string
---@return boolean
function M.is_hr(l)
  return l:match("^[ \t]*%-%-%-%-%-+[ \t]*$") ~= nil
end

---@param l string
---@return string|nil
function M.latex_env_begin(l)
  return l:match("^[ \t]*\\begin{([A-Za-z0-9*]+)}")
end

---@param l string
---@return string|nil
function M.block_type(l)
  return l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
end

---@param l string
---@return boolean
function M.is_dynamic_block(l)
  return l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:[ \t]*%S") ~= nil
end

---@param l string
---@return boolean
function M.is_table_line(l)
  return l:match("^[ \t]*|") ~= nil
end

return M
