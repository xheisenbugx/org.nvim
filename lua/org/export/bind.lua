---@mod org.export.bind #+BIND: keywords (org-export--list-bound-variables)
---
--- With `export.allow_bind_keywords` (org-export-allow-bind-keywords, off
--- by default like Emacs), `#+BIND: VARIABLE VALUE` sets an Emacs variable
--- for the export of the buffer. Here the export variables map to the
--- `export` options they mirror, which are overridden while the buffer is
--- exported:
---
---   org-export-NAME              export.NAME
---   org-BACKEND-NAME             export.BACKEND.NAME  (html latex md ascii
---                                odt texinfo icalendar beamer org cite)
---   user-full-name               export.author
---   user-mail-address            export.email
---
--- with `-` in NAME as `_`, plus the few options named differently (see
--- `ALIASES`). VALUE is read with the Lisp reader and not evaluated, like
--- Emacs: strings, numbers, t (true), nil (false), symbols (their name),
--- lists (arrays), `(not ...)` for with-drawers; a leading quote is
--- dropped. Other variables are ignored.

local M = {}

local BACKENDS = {
  html = true,
  latex = true,
  md = true,
  ascii = true,
  odt = true,
  texinfo = true,
  icalendar = true,
  beamer = true,
  org = true,
  cite = true,
}

--- Variables whose option is named differently.
M.ALIASES = {
  ["user-full-name"] = { "author" },
  ["user-mail-address"] = { "email" },
  ["org-export-creator-string"] = { "creator" },
  ["org-export-snippet-translation-alist"] = { "snippet_translation" },
  ["org-export-before-processing-functions"] = false,
  ["org-export-before-parsing-functions"] = false,
  ["org-html-container-element"] = { "html", "container" },
  ["org-latex-default-packages-alist"] = { "latex", "default_packages" },
  ["org-latex-packages-alist"] = { "latex", "packages" },
  ["org-inlinetask-min-level"] = { "inlinetask_min_level" },
  ["org-table-number-fraction"] = { "table_number_fraction" },
}

--- Variables whose value is an alist, read as a table of key -> value.
local ALISTS = {
  ["org-export-global-macros"] = true,
  ["org-export-snippet-translation-alist"] = true,
  ["org-html-postamble-format"] = true,
  ["org-html-preamble-format"] = true,
}

--- The option path of an Emacs variable ({ "html", "postamble" }), or nil
--- when it has none.
---@param var string
---@return string[]|nil
function M.option_path(var)
  local alias = M.ALIASES[var]
  if alias ~= nil then
    return alias or nil
  end
  local rest = var:match("^org%-export%-(.+)$")
  if rest then
    return { (rest:lower():gsub("%-", "_")) }
  end
  local backend
  backend, rest = var:match("^org%-(%l+)%-(.+)$")
  if backend and BACKENDS[backend] then
    return { backend, (rest:lower():gsub("%-", "_")) }
  end
end

local el = function()
  return require("org.table.elisp")
end

--- A Lisp value read from a #+BIND: line as an option value.
local function convert(v)
  local lisp = el()
  if v == nil then
    return false
  elseif v == true or type(v) == "string" or type(v) == "number" then
    return v
  elseif lisp.is_float(v) then
    return lisp.tonumber(v)
  elseif type(v) == "table" and v.n == nil and v.name then
    return v.name
  elseif type(v) == "table" and v.n then
    local head = v[1]
    if type(head) == "table" and head.name == "not" and head.n == nil then
      local rest = {}
      for i = 2, v.n do
        rest[#rest + 1] = convert(v[i])
      end
      return { ["not"] = rest }
    end
    local out = {}
    for i = 1, v.n do
      out[i] = convert(v[i])
    end
    if v.dot ~= nil then
      out[#out + 1] = convert(v.dot)
    end
    return out
  end
end

--- An alist ((KEY . VALUE) or (KEY VALUE) entries) as a table.
local function convert_alist(v)
  if v == nil then
    return {}
  elseif type(v) ~= "table" or not v.n then
    return nil
  end
  local out = {}
  for i = 1, v.n do
    local entry = v[i]
    if type(entry) == "table" and entry.n then
      local key = convert(entry[1])
      local value = entry.dot
      if value == nil then
        value = entry[2]
      end
      if type(key) == "string" then
        out[key] = convert(value)
      end
    end
  end
  return out
end

--- The #+BIND: values of `keywords` (org-export--list-bound-variables),
--- in order: { { var = "org-html-postamble", path = {...}, value = ... } }.
--- Lines that don't read or name no export option are skipped.
function M.bindings(keywords)
  local out = {}
  for _, line in ipairs(keywords.BIND or {}) do
    local ok, form = pcall(el().read, "(" .. line .. ")")
    if ok and type(form) == "table" and form.n and type(form[1]) == "table" and form[1].name then
      local var = form[1].name
      local path = M.option_path(var)
      local raw = form[2]
      -- Emacs sets the value unevaluated: a quoted list would stay (quote ...)
      if type(raw) == "table" and raw.n == 2 and type(raw[1]) == "table" and raw[1].name == "quote" then
        raw = raw[2]
      end
      local value
      if ALISTS[var] then
        value = convert_alist(raw)
      else
        value = convert(raw)
      end
      if path and value ~= nil then
        out[#out + 1] = { var = var, path = path, value = value }
      end
    end
  end
  return out
end

--- Install the #+BIND: values of `keywords` as `export` options when
--- `export.allow_bind_keywords` is set. Returns a function restoring the
--- options, or nil when nothing was bound.
---@return function|nil
function M.install(keywords)
  local config = require("org.config")
  local saved = config.opts.export or {}
  if not saved.allow_bind_keywords or not keywords.BIND then
    return nil
  end
  local binds = M.bindings(keywords)
  if #binds == 0 then
    return nil
  end
  local opts = vim.deepcopy(saved)
  for _, b in ipairs(binds) do
    local t = opts
    for i = 1, #b.path - 1 do
      local k = b.path[i]
      if type(t[k]) ~= "table" then
        t[k] = {}
      end
      t = t[k]
    end
    t[b.path[#b.path]] = b.value
  end
  config.opts.export = opts
  return function()
    config.opts.export = saved
  end
end

return M
