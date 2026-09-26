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

--- `#+STARTUP` options (org-startup-options).
M.startup = {
  "fold", "overview", "nofold", "showall", "showeverything", "content", "indent", "noindent",
  "num", "nonum", "hidestars", "showstars", "odd", "oddeven", "align", "noalign", "shrink",
  "descriptivelinks", "literallinks", "inlineimages", "noinlineimages", "linkpreviews",
  "nolinkpreviews", "latexpreview", "nolatexpreview", "customtime", "logdone", "lognotedone",
  "nologdone", "lognoteclock-out", "nolognoteclock-out", "logrepeat", "lognoterepeat",
  "nologrepeat", "logdrawer", "nologdrawer", "logstatesreversed", "nologstatesreversed",
  "logreschedule", "lognotereschedule", "nologreschedule", "logredeadline", "lognoteredeadline",
  "nologredeadline", "logrefile", "lognoterefile", "nologrefile", "fninline", "nofninline",
  "fnlocal", "fnauto", "fnprompt", "fnconfirm", "fnplain", "fnadjust", "nofnadjust", "fnanon",
  "constcgs", "constSI", "noptag", "beamer", "entitiespretty", "entitiesplain", "hideblocks",
  "nohideblocks", "hidedrawers", "nohidedrawers",
}

--- Source block header arguments (org-babel-common-header-args-w-values)
--- and switches.
M.header_args = {
  ":cache", ":cmdline", ":colnames", ":comments", ":dir", ":epilogue", ":eval", ":exports",
  ":file", ":file-desc", ":file-ext", ":file-mode", ":hlines", ":mkdirp", ":no-expand",
  ":noeval", ":noweb", ":noweb-prefix", ":noweb-ref", ":noweb-sep", ":output-dir", ":padline",
  ":post", ":prologue", ":results", ":rownames", ":sep", ":session", ":shebang", ":tangle",
  ":tangle-mode", ":var", ":wrap", "-n", "-r", "-l",
}

--- Clock table parameters (pcomplete/org-mode/block-option/clocktable).
M.clocktable_params = {
  ":maxlevel", ":scope", ":lang", ":tstart", ":tend", ":block", ":step", ":stepskip0",
  ":fileskip0", ":emphasize", ":link", ":narrow", ":indent", ":hidefiles", ":tcolumns",
  ":level", ":compact", ":timestamp", ":formula", ":formatter", ":wstart", ":mstart",
  ":match", ":tags", ":properties", ":inherit-props", ":filetitle", ":sort", ":header",
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

--- Completion runs while the current property name is incomplete, when
--- the strict document parser correctly does not expose drawer metadata.
--- Recognize that editing context locally without publishing partial IDs
--- or other properties to the rest of the document model.
local function property_keys_at(file, lnum)
  local hl = file:headline_at(lnum)
  local first = hl and ((hl.planning_line or hl.line) + 1) or 1
  local last = hl and hl.body_end or file.preamble_end
  if not hl then
    while
      first <= last
      and (
        file.lines[first]:match("^%s*$")
        or file.lines[first]:match("^%s*#%s")
        or file.lines[first]:match("^%s*#$")
      )
    do
      first = first + 1
    end
  end
  if lnum <= first or not (file.lines[first] or ""):match("^%s*:PROPERTIES:%s*$") then
    return nil
  end
  local keys = {}
  for i = first + 1, last do
    if file.lines[i]:match("^%s*:END:%s*$") then
      return lnum < i and keys or nil
    elseif i ~= lnum then
      local name = require("org.parser").parse_property_line(file.lines[i])
      if not name then
        return nil
      end
      keys[(name:gsub("%+$", "")):upper()] = true
    end
  end
  -- Also complete a property drawer that is still being written at EOF.
  return keys
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
  -- #+begin_src <lang> <header args>
  local lang_lead = before:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S*)$")
  if lang_lead then
    return { start = col - #lang_lead, items = items(block_languages(), "language") }
  end
  local arg_lead = before:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+%S+.-%s([-:]%S*)$")
    or before:match("^%s*#%+[Hh][Ee][Aa][Dd][Ee][Rr]:.-([:]%S*)$")
  if arg_lead then
    return { start = col - #arg_lead, items = items(M.header_args, "header arg") }
  end
  -- #+BEGIN: clocktable parameters
  local ct_lead = before:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+clocktable%s.-(:%S*)$")
  if ct_lead then
    return { start = col - #ct_lead, items = items(M.clocktable_params, "parameter") }
  end
  -- \entity (org-entities)
  local tex_lead = before:match("\\(%a*)$")
  if tex_lead and not before:match("^%s*#%+") then
    local set = {}
    for _, e in ipairs(require("org.entities").list) do
      if e[1]:match("^%a+%d*$") then
        set[e[1]] = true
      end
    end
    for k in pairs(require("org.export.ast").ENTITIES or {}) do
      set[k] = true
    end
    local names = vim.tbl_keys(set)
    table.sort(names)
    return { start = col - #tex_lead - 1, items = items(names, "entity", "\\") }
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
      -- tags already on the headline are not offered again
      local set = {}
      for t in line:gmatch(":([^:%s]+)") do
        set[t] = true
      end
      local list = vim.tbl_filter(function(t)
        return not set[t] or t == last
      end, all_tags(file))
      return { start = col - #last, items = items(vim.tbl_map(function(t)
        return t .. ":"
      end, list), "tag") }
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
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local property_keys = property_keys_at(file, lnum)
    local list = {}
    if property_keys then
      -- property names not yet set in this entry (pcomplete/org-mode/prop)
      for _, p in ipairs(property_names(file)) do
        if not property_keys[p:upper()] then
          list[#list + 1] = p .. ": "
        end
      end
      list[#list + 1] = "END:"
      return { start = col - #prop_lead, items = items(list, "property") }
    end
    -- drawer names used in the buffer (pcomplete/org-mode/drawer)
    local seen = { PROPERTIES = true, END = true, LOGBOOK = true }
    list = { "PROPERTIES:", "END:", "LOGBOOK:" }
    for _, h in ipairs(file.headlines) do
      for _, d in ipairs(h.drawers or {}) do
        if not seen[d.name:upper()] then
          seen[d.name:upper()] = true
          list[#list + 1] = d.name .. ":"
        end
      end
    end
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
