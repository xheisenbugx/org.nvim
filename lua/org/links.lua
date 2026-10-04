---@mod org.links Hyperlinks
---
--- Supports bracket links `[[target][description]]`, `[[target]]`, angle
--- links `<https://...>`, plain links (`https://...`, `file:...`) and radio
--- targets `<<<text>>>`. Link types follow Emacs: http(s), ftp, mailto,
--- news, doi, file, id, shell, help, man, info, attachment, `#custom-id`,
--- `*heading`, coderef `(label)`, fuzzy (dedicated `<<target>>`, `#+NAME:`,
--- headline, text), abbreviations (`#+LINK:` / `links.abbreviations`) and
--- custom types (`links.types`).
---
--- This file holds the link types (URL_SCHEMES, custom `links.types`)
--- and the stored links; the rest loads from org/links/: parse (strings,
--- parsing, abbreviations), search (org-link-search), open (following
--- links), shell (shell: and elisp: links), store (org-store-link),
--- insert (org-insert-link) and commands (next/previous link, entry
--- links, display toggle).

local config = require("org.config")

local M = {}
-- The parts in org/links/ add their functions to this table and require
-- it back, so it must be in package.loaded before they load.
package.loaded["org.links"] = M

---@class org.Link
---@field raw string
---@field target string link path as written (unescaped, newlines collapsed)
---@field desc string|nil
---@field start_col integer 1-based inclusive (in the line `lnum`)
---@field end_col integer 1-based inclusive (in the line `end_lnum`)
---@field lnum? integer
---@field end_lnum? integer
---@field type string
---@field path string part after "type:" (or the whole target)

--- Links stored with `store_link`, most recent first: { link, desc }
--- (org-stored-links).
M.stored = {}

M.URL_SCHEMES = {
  http = true,
  https = true,
  ftp = true,
  mailto = true,
  news = true,
  doi = true,
  file = true,
  id = true,
  shell = true,
  elisp = true,
  help = true,
  man = true,
  attachment = true,
  info = true,
  irc = true,
  docview = true,
  bibtex = true,
  ["file+sys"] = true,
  ["file+emacs"] = true,
}

local function lopts()
  return config.opts.links or {}
end

--- Definition of a custom link type as a table (`links.types.<name>` may be
--- a follow function or a table of properties).
---@return table|nil
function M.link_type(name)
  local t = name and (lopts().types or {})[name]
  if type(t) == "function" then
    return { follow = t }
  elseif type(t) == "table" then
    return t
  end
end

local function is_type(scheme)
  return scheme and (M.URL_SCHEMES[scheme:lower()] or (lopts().types or {})[scheme]) and true or false
end

-- Local functions the parts below share
local shared = require("org.links.shared")
shared.is_type = is_type
shared.lopts = lopts

require("org.links.parse")
require("org.links.search")
require("org.links.open")
require("org.links.shell")
require("org.links.store")
require("org.links.insert")
require("org.links.commands")

return M
