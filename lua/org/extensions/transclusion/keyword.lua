---@mod org.extensions.transclusion.keyword The #+transclude: keyword
---
--- Parses `#+transclude: [[link]] :prop value ...` lines with
--- org-transclusion's property set: `:level [N]`, `:only-contents`,
--- `:exclude-elements "a b"`, `:expand-links`, `:disable-auto`,
--- `:no-first-heading`, `:lines a-b`, `:src lang`, `:rest "args"` and
--- `:end "search"`.

local M = {}

local KEYWORD = "^([ \t]*)#%+[Tt][Rr][Aa][Nn][Ss][Cc][Ll][Uu][Dd][Ee]:[ \t]*(.-)[ \t]*$"

---@class org.transclusion.Spec
---@field value string the keyword value
---@field link string the bracket link, `[[...]]`
---@field type string link type ("file", "id", "heading", "custom-id", "fuzzy")
---@field path string file path or ID
---@field search? string search option (`::*Heading`, `::#id`, ...)
---@field level? integer|"auto"
---@field only_contents? boolean
---@field exclude string[] element types from `:exclude-elements`
---@field expand_links? boolean
---@field disable_auto? boolean
---@field no_first_heading? boolean
---@field lines? string "a-b", inclusive
---@field src? string
---@field rest? string
---@field end_search? string

--- Indentation and value of a `#+transclude:` line, or nil.
---@param line string
---@return string|nil indent, string|nil value
function M.match(line)
  local indent, value = line:match(KEYWORD)
  return indent, value
end

--- Parse a keyword value. Returns nil and an error without a bracket link
--- (the link is mandatory, as in org-transclusion).
---@param value string
---@return org.transclusion.Spec|nil, string|nil
function M.parse(value)
  local link = value:match("%[%[.-%]%]")
  if not link then
    return nil, "a #+transclude: keyword needs a [[link]]"
  end
  local l = require("org.links").parse_links(link, { bracket_only = true })[1]
  if not l then
    return nil, "invalid link " .. link
  end
  -- properties are read from the text after the link, so a link can't set them
  local s, e = value:find(link, 1, true)
  local props = value:sub(1, s - 1) .. " " .. value:sub(e + 1)
  local spec = { value = value, link = link, type = l.type, path = l.path, exclude = {} }
  if l.type == "file" or l.type == "id" then
    local p, search = l.path:match("^(.-)::(.*)$")
    if p then
      spec.path, spec.search = p, search
    end
  elseif l.type == "heading" or l.type == "custom-id" or l.type == "fuzzy" then
    -- a link into the same file
    spec.path, spec.search = "", l.target
  end
  local lvl = props:match(":level *([1-9]?)")
  if lvl then
    spec.level = lvl == "" and "auto" or tonumber(lvl)
  end
  spec.only_contents = props:find(":only%-contents?") ~= nil or nil
  local ex = props:match(':exclude%-elements +"(.-)"')
  if ex then
    spec.exclude = vim.split(vim.trim(ex), "%s+", { trimempty = true })
  end
  spec.expand_links = props:find(":expand%-links") ~= nil or nil
  spec.disable_auto = props:find(":disable%-auto") ~= nil or nil
  spec.no_first_heading = props:find(":no%-first%-heading") ~= nil or nil
  spec.lines = props:match(':lines +"?(%d*%-%d*)"?')
  local src = props:match(':src +"?([%w_+]*%-?[%w_+]*)"?')
  spec.src = src ~= "" and src or nil
  spec.rest = props:match(':rest +"(.-)"')
  spec.end_search = props:match(':end +"(.-)"')
  return spec
end

--- `#+transclude:` lines of `lines` outside blocks: { row (1-based),
--- indent, value }.
---@param lines string[]
---@param skip? fun(row: integer): boolean rows to leave out
---@return { row: integer, indent: string, value: string }[]
function M.scan(lines, skip)
  local out = {}
  local block
  for i, line in ipairs(lines) do
    if block then
      if line:lower():match("^[ \t]*#%+end_" .. vim.pesc(block) .. "[ \t]*$") then
        block = nil
      end
    elseif not (skip and skip(i)) then
      local b = line:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
      if b then
        block = b:lower()
      else
        local indent, value = M.match(line)
        if indent then
          out[#out + 1] = { row = i, indent = indent, value = value }
        end
      end
    end
  end
  return out
end

--- `line` with its `:level` set to `level` (added when missing).
---@param line string
---@param level integer
---@return string
function M.set_level(line, level)
  level = math.max(1, math.min(9, level))
  if line:find(":level *[1-9]?") then
    return (line:gsub(":level *[1-9]?", ":level " .. level, 1))
  end
  return line .. " :level " .. level
end

return M
