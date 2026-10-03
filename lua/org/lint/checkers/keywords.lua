---@mod org.lint.checkers.keywords org-lint checkers: keywords, INCLUDE, SETUPFILE, OPTIONS, macros
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local data = require("org.lint.data")
local object = require("org.lint.object")
local helpers = require("org.lint.helpers")

local trim = util.trim
local lisp_str = util.lisp_str
local nw = util.nw
local contains = util.contains
local OPTIONS_ITEMS = data.OPTIONS_ITEMS
local COMMON_OPTION_KEYWORDS = data.COMMON_OPTION_KEYWORDS
local BACKEND_OPTION_KEYWORDS = data.BACKEND_OPTION_KEYWORDS
local DEFAULT_PROPERTIES = data.DEFAULT_PROPERTIES
local parse = object.parse
local map_type = helpers.map_type
local map_objects = helpers.map_objects
local at_begin = helpers.at_begin
local at_post = helpers.at_post
local at_obj = helpers.at_obj
local expand_home = helpers.expand_home
local file_exists = helpers.file_exists
local is_remote = helpers.is_remote
local is_url = helpers.is_url
local strip_quotes = helpers.strip_quotes
local resolve_fuzzy = helpers.resolve_fuzzy
local local_ids = helpers.local_ids
local coderef_resolves = helpers.coderef_resolves

local C = {}

C["deprecated-category-setup"] = function(doc)
  local out = {}
  local seen = false
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "CATEGORY" then
      if seen then
        out[#out + 1] = at_post(k, "Spurious CATEGORY keyword.  Set :CATEGORY: property instead")
      end
      seen = true
    end
  end
  return out
end

C["non-existent-setupfile-parameter"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "SETUPFILE" then
      local file = k.value:match('^"(.*)"$') or k.value
      if not is_url(file) and not is_remote(file) and not file_exists(doc, file) then
        out[#out + 1] = at_begin(k, string.format("Non-existent setup file %s", lisp_str(file)))
      end
    end
  end
  return out
end

--- Does `search` (an org-link-search string) match in `lines`?
local function link_search(lines, search, filename)
  -- the target's own SETUPFILE settings (TODO keywords) apply to its headlines
  local file = parse(lines, filename and { filename = filename, dir = vim.fn.fnamemodify(filename, ":h") } or {})
  if search:sub(1, 1) == "*" then
    local want = trim(search:sub(2))
    for _, h in ipairs(map_type(file, "headline")) do
      local t = h.raw_value:gsub("%s*%[%d*%%%]", ""):gsub("%s*%[%d*/%d*%]", "")
      if trim(t) == want then
        return true
      end
    end
    return false
  elseif search:sub(1, 1) == "#" then
    return local_ids(file)[search:sub(2)] ~= nil
  elseif search:match("^%(.*%)$") then
    return coderef_resolves(file, search:sub(2, -2))
  elseif search:match("^/.*/$") then
    local ok, re = pcall(vim.regex, search:sub(2, -2))
    if not ok then
      return false
    end
    for _, l in ipairs(lines) do
      if re:match_str(l) then
        return true
      end
    end
    return false
  elseif search:match("^%d+$") then
    return tonumber(search) <= #lines
  end
  if resolve_fuzzy(file, search) then
    return true
  end
  for _, h in ipairs(map_type(file, "headline")) do
    if trim(h.raw_value) == trim(search) then
      return true
    end
  end
  return false
end

C["wrong-include-link-parameter"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "INCLUDE" then
      local value = k.value
      local path = value:match('^(".-")') or value:match("^(%S+)")
      if not path then
        out[#out + 1] = at_post(k, "Missing location argument in INCLUDE keyword")
      else
        path = strip_quotes(path)
        local before, search = path:match("^(.-)::(.*)$")
        local file = nw(before or path)
        search = before and nw(search) or nil
        if not (file and is_url(file)) then
          if file and not is_remote(file) and not file_exists(doc, file) then
            out[#out + 1] = at_post(k, "Non-existent file argument in INCLUDE keyword")
          elseif search then
            local lines, target
            if file then
              target = expand_home(file)
              if not require("org.utils").is_absolute(target) then
                target = (doc.dir or vim.fn.getcwd()) .. "/" .. target
              end
              local okr, l = pcall(vim.fn.readfile, target)
              lines = okr and l or {}
            else
              lines, target = doc.lines, doc.filename ~= "" and doc.filename or nil
            end
            if not link_search(lines, search, target) then
              out[#out + 1] = at_post(k, string.format('Invalid search part "%s" in INCLUDE keyword', search))
            end
          end
        end
      end
    end
  end
  return out
end

C["obsolete-include-markup"] = function(doc)
  local markups = { "ASCII", "BEAMER", "HTML", "LATEX", "MAN", "MARKDOWN", "MD", "ODT", "ORG", "TEXINFO" }
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "INCLUDE" then
      local first = k.value:match('^(".+")[ \t]') or k.value:match("^(%S+)")
      if first then
        local rest = k.value:sub(#first + 1)
        local ws = rest:match("^[ \t]+")
        if ws then
          local after = rest:sub(#ws + 1):upper()
          local best
          for _, m in ipairs(markups) do
            if after:sub(1, #m) == m and (not best or #m > #best) then
              best = m
            end
          end
          if best then
            local markup = rest:sub(#ws + 1, #ws + #best)
            out[#out + 1] = at_post(
              k,
              string.format('Obsolete markup "%s" in INCLUDE keyword.  Use "export %s" instead', markup, markup)
            )
          end
        end
      end
    end
  end
  return out
end

C["unknown-options-item"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "OPTIONS" then
      local v = k.value
      local start = 1
      while start <= #v do
        -- "\\(.+?\\):\\((.*?)\\|\\S-+\\)?[ \t]*"
        local colon = v:find(":", start + 1, true)
        if not colon then
          break
        end
        local item = v:sub(start, colon - 1)
        local p = colon + 1
        local has_value = false
        if v:sub(p, p) == "(" then
          local c = v:find(")", p + 1, true)
          if c then
            p, has_value = c + 1, true
          end
        end
        if not has_value then
          local m = v:match("^%S+", p)
          if m then
            p, has_value = p + #m, true
          end
        end
        p = p + #v:match("^[ \t]*", p)
        if not contains(OPTIONS_ITEMS, item) then
          table.insert(out, 1, at_post(k, string.format('Unknown OPTIONS item "%s"', item)))
        end
        if not has_value then
          table.insert(out, 1, at_post(k, string.format("Missing value for option item %s", lisp_str(item))))
        end
        start = p
      end
    end
  end
  return out
end

C["misspelled-export-option"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    local prop = np.key
    if prop then
      local backends
      for _, e in ipairs(BACKEND_OPTION_KEYWORDS) do
        if e[1] == prop then
          backends = e[2]
        end
      end
      local common = contains(COMMON_OPTION_KEYWORDS, prop)
      if (backends or common) and not contains(DEFAULT_PROPERTIES, prop) then
        local suffix = ""
        if not common and backends then
          suffix = string.format(
            " in %s export %s",
            #backends == 1 and backends[1] or ("(" .. table.concat(backends, " ") .. ")"),
            #backends > 1 and "backends" or "backend"
          )
        end
        table.insert(
          out,
          1,
          at_post(
            np,
            string.format(
              'Potentially misspelled %sexport option "%s"%s.  Consider "EXPORT_%s".',
              common and "global " or "nil",
              prop,
              suffix,
              prop
            )
          )
        )
      end
    end
  end
  return out
end

local function placeholders(template)
  local seen, args = {}, {}
  for n in template:gmatch("%$([1-9]%d*)") do
    n = tonumber(n)
    if not seen[n] then
      seen[n] = true
      args[#args + 1] = n
    end
  end
  table.sort(args)
  return args
end

C["invalid-macro-argument-and-template"] = function(doc)
  local out = {}
  local function push(r)
    table.insert(out, 1, r)
  end
  local templates = {
    { "author", "$1" },
    { "date", "$1" },
    { "email", "$1" },
    { "title", "$1" },
    { "results", "$1" },
  }
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "MACRO" then
      local name = k.value:match("^%S+")
      local template = name and trim(k.value:sub(#name + 1))
      if not name then
        push(at_post(k, "Missing name in MACRO keyword"))
      elseif not nw(template) then
        push(at_post(k, 'Missing template in macro "%s"'))
      else
        local args = placeholders(template)
        local ok = #args == 0 or args[#args] == #args
        if not ok then
          push(at_post(k, string.format('Unused placeholders in macro "%s"', name)))
        end
      end
    end
  end
  -- org-macro-initialize-templates: buffer (and SETUPFILE) definitions
  -- and built-ins
  local defined = {}
  local entries = doc.file and doc.file.settings.keyword_entries
    or require("org.keywords").collect(doc.lines, doc.filename ~= "" and doc.filename or nil)
  for _, entry in ipairs(entries) do
    if entry.key == "MACRO" then
      local name, tmpl = entry.value:match("^(%S+)%s*(.*)$")
      if name then
        defined[#defined + 1] = { name, trim(tmpl) }
      end
    end
  end
  for _, n in ipairs({ "date", "title", "email", "author" }) do
    defined[#defined + 1] = { n, "" }
  end
  for _, n in ipairs({ "keyword", "n", "property", "time" }) do
    defined[#defined + 1] = { n, false }
  end
  if doc.filename and doc.filename ~= "" then
    defined[#defined + 1] = { "input-file", "" }
    defined[#defined + 1] = { "modification-time", false }
  end
  for _, d in ipairs(defined) do
    templates[#templates + 1] = d
  end
  local function lookup(name)
    for _, t in ipairs(templates) do
      if t[1]:lower() == name:lower() then
        return t[2], true
      end
    end
    return nil, false
  end
  local function check_arity(lo, hi, m)
    local name = m.key
    local args = m.args or {}
    local l = #args
    if l < lo - 1 then
      push(at_obj(m, string.format("Missing arguments in macro %s", lisp_str(name))))
    elseif l < lo then
      push(at_obj(m, string.format("Missing argument in macro %s", lisp_str(name))))
    elseif l > hi + 1 then
      local sp = {}
      for x = hi + 1, l do
        sp[#sp + 1] = trim(args[x])
      end
      push(at_obj(m, string.format("Spurious arguments in macro %s: %s", lisp_str(name), table.concat(sp, ", "))))
    elseif l > hi then
      push(at_obj(m, string.format("Spurious argument in macro %s: %s", lisp_str(name), args[l])))
    end
  end
  for _, m in ipairs(map_objects(doc, "macro")) do
    local tmpl, found = lookup(m.key)
    if not found then
      push(at_obj(m, string.format("Undefined macro %s", lisp_str(m.key))))
    elseif m.key == "keyword" then
      check_arity(1, 1, m)
    elseif m.key == "modification-time" then
      check_arity(1, 2, m)
    elseif m.key == "n" then
      check_arity(0, 2, m)
    elseif m.key == "property" then
      check_arity(1, 2, m)
    elseif m.key == "time" then
      check_arity(1, 1, m)
    elseif tmpl ~= false and not tmpl:match("^%(eval ") then
      -- (eval ...) templates are functions: not checked
      local nums = placeholders(tmpl)
      local mx = nums[#nums] or 0
      check_arity(mx, mx, m)
    end
  end
  return out
end

return C
