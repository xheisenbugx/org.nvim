---@mod org.protocol org-protocol: capture, store links and open sources from other apps
---
--- Handles `org-protocol://` URLs like Emacs `org-protocol.el`. A browser
--- bookmarklet or another program calls a URL handler that forwards the URL
--- to a running Neovim (see |org-protocol|):
--- >sh
---     nvim --server "$SOCKET" --remote-expr \
---       "v:lua.require'org.protocol'.handle('org-protocol://capture?url=...')"
--- <
--- Sub-protocols: `capture`, `store-link`, `open-source`, plus the ones in
--- `protocol.handlers`.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

local function cfg()
  return config.opts.protocol or {}
end

--- Percent-decode a URL component (org-link-decode).
function M.decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- "https:/x" -> "https://x": emacsclient and some handlers compress
--- slashes (org-protocol-sanitize-uri).
function M.sanitize_uri(uri)
  if not uri then
    return nil
  end
  local scheme, rest = uri:match("^(%l+):/+(.*)$")
  if scheme then
    return scheme .. "://" .. rest:gsub("/+", "/")
  end
  return uri
end

--- `key=val&key2=val2` to a table, `+` as space, values decoded
--- (org-protocol-convert-query-to-plist).
function M.parse_query(query)
  local out = {}
  for pair in (query or ""):gsub("%+", " "):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then
      out[k] = M.decode(v)
    end
  end
  return out
end

--- Old-style `a/b/c` data split on `/+` and `?` and decoded, assigned to
--- `order` names; extra values are taken as key/value pairs
--- (org-protocol-assign-parameters).
function M.parse_old_style(data, order)
  local parts = vim.split(data, "[/?]+", { trimempty = true })
  parts = vim.tbl_map(M.decode, parts)
  local out = {}
  for _, key in ipairs(order or {}) do
    out[key] = table.remove(parts, 1)
  end
  while #parts > 0 do
    local k = table.remove(parts, 1)
    out[k] = table.remove(parts, 1)
  end
  return out
end

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------

--- org-protocol://store-link?url=URL&title=TITLE: store the link for
--- `insert_link` and put the URL in the unnamed register.
function M.store_link(params)
  local uri = M.sanitize_uri(params.url)
  if not uri then
    utils.warn("org-protocol store-link: no url")
    return nil
  end
  require("org.links").store(uri, params.title)
  vim.fn.setreg('"', uri)
  pcall(vim.fn.setreg, "+", uri)
  utils.notify(string.format("insert_link to insert new Org link, p to insert %q", uri))
  return true
end

--- org-protocol://capture?template=KEY&url=URL&title=TITLE&body=TEXT:
--- capture with the template (default `protocol.default_template_key`);
--- `%a` / `%:link` / `%:description` / `%i` / `%:<key>` come from the URL.
function M.capture(params)
  local url = params.url and M.sanitize_uri(params.url) or nil
  local title = params.title or ""
  local orglink = url and require("org.links").format(url, title ~= "" and title or url) or title
  if url then
    require("org.links").store(url, title)
  end
  local keywords = vim.tbl_extend("force", {}, params, {
    type = url and url:match("^(%l+):") or nil,
    link = url,
    description = title,
    annotation = orglink,
    initial = params.body or "",
  })
  local capture = require("org.capture")
  capture.link_store_props = {
    link = url,
    description = title,
    annotation = orglink,
    initial = params.body or "",
    keywords = keywords,
  }
  local key = params.template or cfg().default_template_key
  local ok, err
  if key and key ~= "" then
    ok, err = pcall(utils.run, capture.capture, key, { initial = params.body })
  else
    ok, err = pcall(utils.run, capture.prompt, { initial = params.body })
  end
  capture.link_store_props = nil
  if not ok then
    utils.error("org-protocol capture: " .. tostring(err))
    return nil
  end
  return true
end

--- Local file for a URL according to `protocol.projects`
--- (org-protocol-project-alist), or nil.
function M.source_file(url)
  url = M.sanitize_uri(url)
  for _, p in ipairs(cfg().projects or {}) do
    local base = p.base_url
    local s = base and url:find(base, 1, true)
    if s then
      local f1 = url:gsub("[?#].*$", "")
      local start = s + #base
      local stop = #f1
      if p.online_suffix then
        local sfx = f1:find(p.online_suffix, start, true)
        if sfx then
          stop = sfx - 1
        end
      end
      local wdir = utils.expand(p.working_directory or "")
      if wdir ~= "" and wdir:sub(-1) ~= "/" then
        wdir = wdir .. "/"
      end
      local file = wdir .. f1:sub(start, stop) .. (p.working_suffix or "")
      if not utils.exists(file) then
        for pat, target in pairs(p.rewrites or {}) do
          -- rewrites: { [vim regex] = path relative to working_directory }
          if vim.fn.match(f1, pat) >= 0 then
            return wdir .. target
          end
        end
      end
      if vim.fn.filereadable(file) == 1 then
        return file
      end
      utils.warn(file .. ": no such file or directory.")
    end
  end
  return nil
end

--- org-protocol://open-source?url=URL: open the local file behind a
--- published URL (org-protocol-open-source).
function M.open_source(params)
  local file = params.url and M.source_file(params.url)
  if not file then
    return nil
  end
  utils.open_file(file)
  return file
end

local DEFAULT_HANDLERS = {
  { name = "org-capture", protocol = "capture", fn = M.capture, order = { "url", "title", "body" }, capture = true },
  { name = "org-store-link", protocol = "store-link", fn = M.store_link, order = { "url", "title" } },
  { name = "org-open-source", protocol = "open-source", fn = M.open_source, order = { "url" } },
}

--- Handle an `org-protocol://SUB?key=val&...` URL (or the old
--- `org-protocol://SUB://a/b` form). Returns the handler's result, or nil
--- when the URL is not an org-protocol URL (org-protocol-check-filename-for-protocol).
---@param url string
function M.handle(url)
  local rest = url:match("org%-protocol:/+(.*)$")
  if not rest then
    utils.warn("Not an org-protocol URL: " .. url)
    return nil
  end
  local handlers = vim.list_extend(vim.deepcopy(cfg().handlers or {}), DEFAULT_HANDLERS)
  for _, h in ipairs(handlers) do
    local proto = h.protocol
    local data, new_style
    local after = rest:sub(1, #proto) == proto and rest:sub(#proto + 1) or nil
    if after then
      if after:match("^:/+") then
        data, new_style = after:gsub("^:/+", ""), false
      elseif after:match("^/*%?") then
        data, new_style = after:gsub("^/*%?", ""), true
      end
    end
    if data then
      local params
      if new_style then
        params = M.parse_query(data)
      else
        -- old style; a one-character first part is the capture template
        local order = h.order
        if h.capture and data:match("^[^/]/") then
          order = { "template", "url", "title", "body" }
        end
        params = M.parse_old_style(data, order)
      end
      return h.fn(params)
    end
  end
  utils.warn("No org-protocol handler for: " .. url)
  return nil
end

return M
