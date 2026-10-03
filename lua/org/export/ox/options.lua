---@mod org.export.ox.options Export options: config, #+OPTIONS and keywords, the environment
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local M = require("org.export.ox")

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function cfg()
  return require("org.config").opts.export or {}
end
M.cfg = cfg

--- Normalise an option value given as a Lua config value:
--- with_drawers = true | false | { "A", "B" } | { not = { "LOGBOOK" } }
function M.normalize_list_option(v)
  if type(v) ~= "table" then
    return v
  end
  if v["not"] then
    local l = vim.deepcopy(v["not"])
    l.negate = true
    return l
  end
  return v
end

local full_name_cache

--- The default author, like Emacs `user-full-name`: the full name of the
--- system user (GECOS), else the login name. `export.author` overrides it.
function M.user_full_name()
  local c = cfg().author
  if c ~= nil then
    return c or nil
  end
  if full_name_cache then
    return full_name_cache
  end
  local ok, pw = pcall(vim.uv.os_get_passwd)
  local login = ok and pw and pw.username or vim.env.USER or ""
  local name
  if vim.fn.has("mac") == 1 and vim.fn.executable("id") == 1 then
    local res = vim.system({ "id", "-F" }, { text = true }):wait(2000)
    if res.code == 0 then
      name = vim.trim(res.stdout or "")
    end
  elseif vim.fn.executable("getent") == 1 then
    local res = vim.system({ "getent", "passwd", login }, { text = true }):wait(2000)
    if res.code == 0 then
      local gecos = (res.stdout or ""):match("^[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):")
      name = gecos and gecos:match("^([^,]*)")
    end
  end
  if not name or name == "" then
    name = login
  end
  full_name_cache = name
  return name
end

--- org-export-options-alist: { property, keyword, option, default, behavior }
function M.global_options()
  local c = cfg()
  local function d(v, default)
    if v == nil then
      return default
    end
    return v
  end
  return {
    { "title", "TITLE", nil, nil, "parse" },
    { "date", "DATE", nil, nil, "parse" },
    { "author", "AUTHOR", nil, M.user_full_name(), "parse" },
    { "email", "EMAIL", nil, c.email or "", "t" },
    { "language", "LANGUAGE", nil, d(c.default_language, "en"), "t" },
    { "select_tags", "SELECT_TAGS", nil, d(c.select_tags, { "export" }), "split" },
    { "exclude_tags", "EXCLUDE_TAGS", nil, d(c.exclude_tags, { "noexport" }), "split" },
    { "creator", "CREATOR", nil, d(c.creator, M.creator_string()) },
    { "headline_levels", nil, "H", d(c.headline_levels, 3) },
    { "preserve_breaks", nil, "\\n", d(c.preserve_breaks, false) },
    { "section_numbers", nil, "num", d(c.with_section_numbers, true) },
    { "time_stamp_file", nil, "timestamp", d(c.timestamp_file, true) },
    { "with_archived_trees", nil, "arch", d(c.with_archived_trees, "headline") },
    { "with_author", nil, "author", d(c.with_author, true) },
    { "expand_links", nil, "expand-links", d(c.expand_links, true) },
    { "with_broken_links", nil, "broken-links", d(c.with_broken_links, false) },
    { "with_clocks", nil, "c", d(c.with_clocks, false) },
    { "with_creator", nil, "creator", d(c.with_creator, false) },
    { "with_date", nil, "date", d(c.with_date, true) },
    { "with_drawers", nil, "d", M.normalize_list_option(d(c.with_drawers, { ["not"] = { "LOGBOOK" } })) },
    { "with_email", nil, "email", d(c.with_email, false) },
    { "with_emphasize", nil, "*", d(c.with_emphasize, true) },
    { "with_entities", nil, "e", d(c.with_entities, true) },
    { "with_fixed_width", nil, ":", d(c.with_fixed_width, true) },
    { "with_footnotes", nil, "f", d(c.with_footnotes, true) },
    { "with_inlinetasks", nil, "inline", d(c.with_inlinetasks, true) },
    { "with_latex", nil, "tex", d(c.with_latex, true) },
    { "with_planning", nil, "p", d(c.with_planning, false) },
    { "with_priority", nil, "pri", d(c.with_priority, false) },
    { "with_properties", nil, "prop", M.normalize_list_option(d(c.with_properties, false)) },
    { "with_smart_quotes", nil, "'", d(c.with_smart_quotes, false) },
    { "with_special_strings", nil, "-", d(c.with_special_strings, true) },
    { "with_special_rows", nil, nil, false },
    { "with_statistics_cookies", nil, "stat", d(c.with_statistics_cookies, true) },
    { "with_sub_superscript", nil, "^", d(c.with_sub_superscripts, true) },
    { "with_toc", nil, "toc", d(c.with_toc, true) },
    { "with_tables", nil, "|", d(c.with_tables, true) },
    { "with_tags", nil, "tags", d(c.with_tags, true) },
    { "with_tasks", nil, "tasks", M.normalize_list_option(d(c.with_tasks, true)) },
    { "with_timestamps", nil, "<", d(c.with_timestamps, true) },
    { "with_title", nil, "title", d(c.with_title, true) },
    { "with_todo_keywords", nil, "todo", d(c.with_todo_keywords, true) },
    { "with_cite_processors", nil, nil, d(c.process_citations, true) },
    { "cite_export", "CITE_EXPORT", nil, c.cite_export },
  }
end

function M.creator_string()
  local v = vim.version()
  return string.format("Neovim %d.%d.%d (org.nvim, Org mode 9.8 compatible)", v.major, v.minor, v.patch)
end

--- Read one Emacs Lisp value from `s` at `pos` (for #+OPTIONS values).
--- Returns value, next position. t/nil -> true/false, symbols and
--- strings -> strings, lists -> tables (`(not ...)` sets `negate`).
function M.read_sexp(s, pos)
  pos = pos or 1
  local ws = s:match("^%s*", pos)
  pos = pos + #ws
  local c = s:sub(pos, pos)
  if c == "" then
    return nil, pos
  elseif c == '"' then
    local out = {}
    local k = pos + 1
    while k <= #s do
      local ch = s:sub(k, k)
      if ch == "\\" then
        out[#out + 1] = s:sub(k + 1, k + 1)
        k = k + 2
      elseif ch == '"' then
        return table.concat(out), k + 1
      else
        out[#out + 1] = ch
        k = k + 1
      end
    end
    return table.concat(out), k
  elseif c == "(" then
    local list = {}
    local k = pos + 1
    local first = true
    while true do
      local w = s:match("^%s*", k)
      k = k + #w
      if s:sub(k, k) == ")" or k > #s then
        return list, k + 1
      end
      local v, nk = M.read_sexp(s, k)
      if first and v == "not" then
        list.negate = true
      elseif v ~= nil then
        list[#list + 1] = v
      end
      first = false
      k = nk
    end
  elseif c == "'" and s:sub(pos + 1, pos + 1) ~= "" and not s:sub(pos + 1, pos + 1):match("%s") then
    return M.read_sexp(s, pos + 1)
  else
    local tok = s:match('^[^%s%(%)"]+', pos) or c
    local e = pos + #tok
    if tok == "t" then
      return true, e
    elseif tok == "nil" then
      return false, e
    elseif tonumber(tok) then
      return tonumber(tok), e
    end
    return tok, e
  end
end

--- Parse an #+OPTIONS line into { [option_key] = value }.
function M.parse_option_line(line)
  local out = {}
  local order = {}
  local pos = 1
  while pos <= #line do
    local ws = line:match("^%s*", pos)
    pos = pos + #ws
    if pos > #line then
      break
    end
    local colon = line:find(":", pos + 1, true)
    if not colon then
      break
    end
    local key = line:sub(pos, colon - 1)
    local nxt = line:sub(colon + 1, colon + 1)
    if nxt == "" or nxt:match("%s") then
      -- "key:" followed by blank: skip (looking-at-p "\\S-" fails)
      pos = colon + 1
    else
      local v, e = M.read_sexp(line, colon + 1)
      out[key] = v
      order[#order + 1] = key
      pos = e
    end
  end
  return out, order
end

--- Collect in-buffer keywords: { KEY = { values... } } in buffer order,
--- including local SETUPFILE dependencies. The unused depth argument and
--- accumulator remain accepted for callers of the former recursive scanner.
function M.collect_keywords(lines, dir, _depth, acc, filename)
  acc = acc or {}
  local source = filename or ((dir or vim.fn.getcwd()) .. "/.org-export-keyword-context")
  local entries = require("org.keywords").collect(lines, source)
  for _, entry in ipairs(entries) do
    if entry.key ~= "SETUPFILE" then
      acc[entry.key] = acc[entry.key] or {}
      table.insert(acc[entry.key], entry.value)
    end
  end
  return acc
end

--- Expand $VAR and ${VAR} (substitute-env-in-file-name).
function M.expand_env(s)
  return (
    s:gsub("%${([%w_]+)}", function(v)
      return vim.env[v] or ""
    end):gsub("%$([%a_][%w_]*)", function(v)
      return vim.env[v] or ("$" .. v)
    end)
  )
end

--- Compute export options (org-export-get-environment).
---@param ctx table { keywords, backend, subtree_props, ext, parser }
function M.environment(ctx)
  local backend = ctx.backend
  local options = vim.list_extend(vim.deepcopy(M.all_options(backend)), M.global_options())
  local info = {}
  local seen = {}
  -- global defaults
  for _, o in ipairs(options) do
    if not seen[o[1]] then
      seen[o[1]] = true
      local v = o[4]
      if type(v) == "function" then
        v = v()
      end
      if o[5] == "parse" and type(v) == "string" then
        v = ctx.parse_secondary(v)
      end
      info[o[1]] = vim.deepcopy(v)
    end
  end
  -- external overrides
  for k, v in pairs(ctx.ext or {}) do
    info[k] = v
  end
  -- in-buffer settings
  local kw = ctx.keywords
  local by_option = {}
  local by_keyword = {}
  local seen2 = {}
  for _, o in ipairs(options) do
    if not seen2[o[1]] then
      seen2[o[1]] = true
      if o[3] then
        -- every property read from the same OPTIONS item is set
        -- (org-export--parse-option-keyword), e.g. koma-letter's
        -- :with-email and :inbuffer-with-email
        by_option[o[3]] = by_option[o[3]] or {}
        table.insert(by_option[o[3]], o)
      end
      if o[2] then
        by_keyword[o[2]] = by_keyword[o[2]] or {}
        table.insert(by_keyword[o[2]], o)
      end
    end
  end
  local function apply_options(line)
    local parsed = M.parse_option_line(line)
    for key, v in pairs(parsed) do
      local list = by_option[key]
      if not list then
        -- case-insensitive match (assoc-string ... t)
        for k2, o2 in pairs(by_option) do
          if k2:lower() == key:lower() then
            list = o2
          end
        end
      end
      for _, o in ipairs(list or {}) do
        info[o[1]] = v
      end
    end
  end
  for _, v in ipairs(kw.OPTIONS or {}) do
    apply_options(v)
  end
  if kw.FILETAGS then
    local tags, seen3 = {}, {}
    for _, v in ipairs(kw.FILETAGS) do
      for t in v:gmatch("[^:%s]+") do
        if not seen3[t] then
          seen3[t] = true
          tags[#tags + 1] = t
        end
      end
    end
    info.filetags = tags
  end
  for key, list in pairs(by_keyword) do
    local values = kw[key]
    if values then
      for _, o in ipairs(list) do
        local b = o[5]
        local v
        if b == "parse" then
          v = ctx.parse_secondary(table.concat(values, " "))
        elseif b == "space" then
          v = table.concat(values, " ")
        elseif b == "newline" then
          v = table.concat(values, "\n")
        elseif b == "split" then
          v = {}
          for _, x in ipairs(values) do
            vim.list_extend(v, vim.split(x, "%s+", { trimempty = true }))
          end
        elseif b == "t" then
          v = values[#values]
        else
          v = values[1]
        end
        info[o[1]] = v
      end
    end
  end
  -- subtree EXPORT_* properties
  local props = ctx.subtree_props
  if props then
    if props.EXPORT_OPTIONS then
      apply_options(props.EXPORT_OPTIONS)
    end
    local seen4 = {}
    for _, o in ipairs(options) do
      local k = o[2]
      if k and not seen4[o[1]] then
        seen4[o[1]] = true
        local v = props["EXPORT_" .. k]
        if k == "TITLE" and not v then
          v = ctx.subtree_title
        end
        if v then
          if o[5] == "parse" then
            v = ctx.parse_secondary(v)
          elseif o[5] == "split" then
            v = vim.split(v, "%s+", { trimempty = true })
          end
          info[o[1]] = v
        end
      end
    end
  end
  info.with_drawers = M.normalize_list_option(info.with_drawers)
  info.with_properties = M.normalize_list_option(info.with_properties)
  return info
end
