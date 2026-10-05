---@mod org.export.element.state Export parser state
---
--- The parser object (org.export.element.new), its link types and
--- the blank-line helpers.
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local blank = shared.blank
local trim = shared.trim
local headline_stars = shared.headline_stars

---------------------------------------------------------------------------
-- Parser state
---------------------------------------------------------------------------

local P = {}
P.__index = P

--- Create a parser.
---@param opts? table { todo = org.TodoConfig, link_types = string[], abbrevs = table, radio = string[],
---  inlinetask_min_level = integer, alpha = boolean, term = string|nil, macro = function|nil, visible = function|nil }
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
  "info",
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

-- Locals the later parts share
shared.P = P
shared.skip_blank = skip_blank
shared.after = after
