---@mod org.completion Completion for org buffers
---
--- Context-aware candidates for TODO keywords, tags, `#+` keywords, block
--- languages, property names, `#+STARTUP` options and links. Exposed as
--- an omnifunc (`<C-x><C-o>`), a blink.cmp source (`org.completion.blink`)
--- and an nvim-cmp source (`org.completion.cmp`).

local M = {}

M.keywords = {
  "TITLE", "AUTHOR", "DATE", "EMAIL", "LANGUAGE", "DESCRIPTION", "KEYWORDS", "SUBTITLE",
  "OPTIONS", "STARTUP", "FILETAGS", "TAGS", "TODO", "SEQ_TODO", "TYP_TODO", "CATEGORY",
  "PROPERTY", "COLUMNS", "ARCHIVE", "LINK", "PRIORITIES", "SETUPFILE", "INCLUDE", "NAME",
  "RESULTS", "CALL", "HEADER", "CAPTION", "ATTR_HTML", "ATTR_LATEX", "TBLFM", "PLOT", "MACRO",
  "HTML_HEAD", "HTML_HEAD_EXTRA", "LATEX_CLASS", "LATEX_CLASS_OPTIONS", "LATEX_HEADER",
  "EXPORT_FILE_NAME", "SELECT_TAGS", "EXCLUDE_TAGS", "BIND", "CONSTANTS",
  "BEGIN_SRC", "END_SRC", "BEGIN_EXAMPLE", "END_EXAMPLE", "BEGIN_QUOTE", "END_QUOTE",
  "BEGIN_VERSE", "END_VERSE", "BEGIN_CENTER", "END_CENTER", "BEGIN_COMMENT", "END_COMMENT",
  "BEGIN_EXPORT", "END_EXPORT", "BEGIN:", "END:",
}

M.startup = {
  "overview", "content", "showall", "showeverything", "nofold", "indent", "noindent",
  "logdone", "lognotedone", "nologdone", "logrepeat", "lognoterepeat", "nologrepeat",
  "logreschedule", "lognotereschedule", "nologreschedule", "logredeadline", "lognoteredeadline",
  "nologredeadline", "lognoteclock-out", "nolognoteclock-out", "logdrawer", "nologdrawer",
  "logstatesreversed", "nologstatesreversed", "hidestars", "showstars", "odd", "oddeven",
  "align", "noalign", "inlineimages", "noinlineimages", "entitiespretty", "entitiesplain",
  "hideblocks", "nohideblocks", "hidedrawers", "nohidedrawers", "fninline", "fnlocal",
}

M.options = {
  "toc:", "num:", "H:", "todo:", "tags:", "pri:", "author:", "date:", "email:", "timestamp:",
  "^:", "\\n:", "f:", "creator:", "d:", "p:", "prop:", "stat:", "tasks:", "tex:", "title:",
  "broken-links:", "e:", "c:", "*:", "|:", "<:", "':", "-:",
}

M.link_types = {
  "file:", "id:", "https://", "http://", "mailto:", "shell:", "help:", "attachment:", "ftp:",
  "doi:", "news:",
}

M.properties = {
  "ID", "CUSTOM_ID", "CATEGORY", "Effort", "STYLE", "ORDERED", "NOBLOCKING", "COOKIE_DATA",
  "LOGGING", "COLUMNS", "ARCHIVE", "DIR", "ATTACH_DIR", "VISIBILITY", "EXPORT_FILE_NAME",
  "EXPORT_TITLE", "EXPORT_OPTIONS", "header-args", "LAST_REPEAT", "REPEAT_TO_STATE",
  "TRIGGER", "BLOCKER", "CREATED",
}

local function block_languages()
  local langs = vim.tbl_keys(require("org.config").opts.babel.languages or {})
  for alias in pairs(require("org.syntax").lang_aliases) do
    langs[#langs + 1] = alias
  end
  local seen, out = {}, {}
  for _, l in ipairs(langs) do
    if not seen[l] then
      seen[l] = true
      out[#out + 1] = l
    end
  end
  table.sort(out)
  return out
end

local function all_tags(file)
  local ok, tags = pcall(function()
    return require("org.tags").all_tags()
  end)
  local list = ok and tags or {}
  local seen = {}
  for _, t in ipairs(list) do
    seen[t] = true
  end
  for _, def in ipairs(file:tag_definitions()) do
    if def.name and not seen[def.name] then
      seen[def.name] = true
      list[#list + 1] = def.name
    end
  end
  for _, hl in ipairs(file.headlines) do
    for _, t in ipairs(hl.tags) do
      if not seen[t] then
        seen[t] = true
        list[#list + 1] = t
      end
    end
  end
  return list
end

local function headline_titles(file)
  local out = {}
  for _, hl in ipairs(file.headlines) do
    out[#out + 1] = hl:plain_title()
  end
  return out
end

local function property_names(file)
  local seen, out = {}, {}
  for _, p in ipairs(M.properties) do
    seen[p:upper()] = true
    out[#out + 1] = p
  end
  for _, hl in ipairs(file.headlines) do
    for k in pairs(hl.properties) do
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = k
      end
    end
  end
  return out
end

---@class org.CompletionContext
---@field start integer 0-based byte column where the completed word starts
---@field items { word: string, kind: string, menu?: string }[]

--- Candidates for the text before the cursor.
---@param line string full line
---@param col integer 0-based cursor column (bytes)
---@param bufnr? integer
---@return org.CompletionContext|nil
function M.get(line, col, bufnr)
  local before = line:sub(1, col)
  local file = require("org.files").get_buffer(bufnr or 0)
  local function items(list, kind, prefix)
    local out = {}
    for _, w in ipairs(list) do
      out[#out + 1] = { word = (prefix or "") .. w, kind = kind }
    end
    return out
  end

  -- #+STARTUP: options
  local startup_lead = before:match("^%s*#%+[Ss][Tt][Aa][Rr][Tt][Uu][Pp]:.-(%S*)$")
  if startup_lead then
    return { start = col - #startup_lead, items = items(M.startup, "startup") }
  end
  local options_lead = before:match("^%s*#%+[Oo][Pp][Tt][Ii][Oo][Nn][Ss]:.-(%S*)$")
  if options_lead then
    return { start = col - #options_lead, items = items(M.options, "option") }
  end
  -- #+begin_src <lang>
  local lang_lead = before:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S*)$")
  if lang_lead then
    return { start = col - #lang_lead, items = items(block_languages(), "language") }
  end
  -- #+TODO / #+FILETAGS values
  local ft_lead = before:match("^%s*#%+[Ff][Ii][Ll][Ee][Tt][Aa][Gg][Ss]:.-:?([^:%s]*)$")
  if ft_lead then
    return { start = col - #ft_lead, items = items(all_tags(file), "tag") }
  end
  -- #+KEYWORD
  local kw_lead = before:match("^%s*#%+(%S*)$")
  if kw_lead then
    local upper = kw_lead:upper() == kw_lead and kw_lead ~= ""
    local list = {}
    for _, k in ipairs(M.keywords) do
      local w = k:sub(-1) == ":" and k or (k .. ":")
      if k:match("^BEGIN_") or k:match("^END_") then
        w = k
      end
      list[#list + 1] = upper and w or w:lower()
      if not upper and kw_lead == "" then
        list[#list] = w
      end
    end
    return { start = col - #kw_lead, items = items(list, "keyword") }
  end
  -- links
  local link_lead = before:match("%[%[([^%]]*)$")
  if link_lead then
    if link_lead:sub(1, 1) == "*" then
      local out = items(headline_titles(file), "heading", "*")
      return { start = col - #link_lead, items = out }
    end
    if link_lead:sub(1, 1) == "#" then
      local list = {}
      for _, hl in ipairs(file.headlines) do
        if hl.properties.CUSTOM_ID then
          list[#list + 1] = "#" .. hl.properties.CUSTOM_ID
        end
      end
      return { start = col - #link_lead, items = items(list, "custom_id") }
    end
    local list = vim.deepcopy(M.link_types)
    local ok, links = pcall(require, "org.links")
    if ok and type(links.stored) == "table" then
      for _, l in ipairs(links.stored) do
        list[#list + 1] = type(l) == "table" and (l.link or l[1]) or l
      end
    end
    for abbrev in pairs(file.settings.link_abbrevs) do
      list[#list + 1] = abbrev .. ":"
    end
    for abbrev in pairs(require("org.config").opts.links.abbreviations or {}) do
      list[#list + 1] = abbrev .. ":"
    end
    for _, t in ipairs(headline_titles(file)) do
      list[#list + 1] = "*" .. t
    end
    return { start = col - #link_lead, items = items(list, "link") }
  end
  -- headline: tags / todo keywords
  if before:match("^%*+%s") then
    local tag_lead = before:match("%s:([^%s]*)$")
    if tag_lead then
      local last = tag_lead:match("([^:]*)$")
      return { start = col - #last, items = items(all_tags(file), "tag") }
    end
    local word = before:match("^%*+%s+(%S*)$")
    if word then
      local list = file.settings.todo:names()
      list[#list + 1] = "COMMENT"
      return { start = col - #word, items = items(list, "todo") }
    end
    return nil
  end
  -- property drawer key / drawer names
  local prop_lead = before:match("^%s*:([^%s:]*)$")
  if prop_lead then
    local list = { "PROPERTIES:", "END:", "LOGBOOK:" }
    for _, p in ipairs(property_names(file)) do
      list[#list + 1] = p .. ":"
    end
    return { start = col - #prop_lead, items = items(list, "property") }
  end
  return nil
end

--- Vim omnifunc.
function M.omnifunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ctx = M.get(line, col, 0)
  if findstart == 1 then
    if not ctx then
      return -3
    end
    return ctx.start
  end
  if not ctx then
    return {}
  end
  local out = {}
  for _, it in ipairs(ctx.items) do
    if base == "" or it.word:lower():find(base:lower(), 1, true) == 1 then
      out[#out + 1] = { word = it.word, menu = "[org " .. it.kind .. "]" }
    end
  end
  return out
end

return M
