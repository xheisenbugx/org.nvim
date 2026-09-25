---@mod org.lint Linting (org-lint)
---
--- Checks an Org buffer for syntax mistakes, like Emacs `org-lint`. The
--- buffer is parsed into elements and objects following Org's element
--- parser (org-element), then every checker reports problems as
--- `{ lnum, col, checker, message, trust }`. Checker names, messages and
--- the reported lines follow Emacs Org 9.8.
---
--- ```lua
--- require("org.lint").lint(0)            -- list of reports
--- require("org.lint").show()             -- location list
--- require("org.lint").show({ "invalid-fuzzy-link" })
--- ```

local M = {}

---@class org.LintReport
---@field lnum integer 1-based line
---@field col integer 1-based byte column
---@field checker string checker name
---@field message string
---@field trust "high"|"low"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

local function is_blank(l)
  return l == nil or l:match("^[ \t]*$") ~= nil
end

--- Lisp `prin1` of a string (`%S` in `format`).
local function lisp_str(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

local function nw(s)
  return s and s:match("%S") and s or nil
end

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

--- Index of the character closing the bracket opened at `p` (balanced on
--- `open`/`close` only, like Emacs' pair syntax tables), or nil.
local function balanced(s, p, open, close, last)
  last = last or #s
  local depth = 0
  for i = p, last do
    local c = s:sub(i, i)
    if c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
  end
  return nil
end

local function word_char(c)
  return c ~= "" and (c:match("[%w_]") ~= nil or c:byte() >= 128)
end

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return m <= 2 and y + 1 or y, m, d
end

--- `format-time-string` of `org-timestamp-formats` (without brackets) for a
--- date that may be out of range (normalized like `encode-time`).
local function format_date(y, mo, d, h, mi)
  local total = (h or 0) * 60 + (mi or 0)
  y = y + math.floor((mo - 1) / 12)
  mo = (mo - 1) % 12 + 1
  local days = days_from_civil(y, mo, 1) + d - 1 + math.floor(total / 1440)
  total = total % 1440
  local yy, mm, dd = civil_from_days(days)
  local s = string.format("%04d-%02d-%02d %s", yy, mm, dd, DAYS[(days + 4) % 7 + 1])
  if h and mi then
    s = s .. string.format(" %02d:%02d", math.floor(total / 60), total % 60)
  end
  return s
end

---------------------------------------------------------------------------
-- Emacs data
---------------------------------------------------------------------------

local AFFILIATED = {
  CAPTION = true,
  DATA = true,
  HEADER = true,
  HEADERS = true,
  LABEL = true,
  NAME = true,
  PLOT = true,
  RESNAME = true,
  RESULT = true,
  RESULTS = true,
  SOURCE = true,
  SRCNAME = true,
  TBLNAME = true,
}
local TRANSLATION = {
  DATA = "NAME",
  LABEL = "NAME",
  RESNAME = "NAME",
  SOURCE = "NAME",
  SRCNAME = "NAME",
  TBLNAME = "NAME",
  RESULT = "RESULTS",
  HEADERS = "HEADER",
}

-- `org-babel-header-arg-names`
local HEADER_ARG_NAMES = {
  "cache", "cmdline", "colnames", "comments", "dir", "eval", "exports", "epilogue", "file", "file-desc", "file-ext",
  "file-mode", "hlines", "mkdirp", "no-expand", "noeval", "noweb", "noweb-ref", "noweb-sep", "noweb-prefix",
  "output-dir", "padline", "post", "prologue", "results", "rownames", "sep", "session", "shebang", "tangle",
  "tangle-mode", "var", "wrap",
}

-- `org-babel-common-header-args-w-values`: name -> "any" | nil | list of groups.
local ANY = "any"
local COMMON_HEADER_VALUES = {
  { "cache", { { "no", "yes" } } },
  { "cmdline", ANY },
  { "colnames", { { "nil", "no", "yes" } } },
  { "comments", { { "no", "link", "yes", "org", "both", "noweb" } } },
  { "dir", ANY },
  { "eval", { { "yes", "no", "no-export", "strip-export", "never-export", "eval", "never", "query" } } },
  { "exports", { { "code", "results", "both", "none" } } },
  { "epilogue", ANY },
  { "file", ANY },
  { "file-desc", ANY },
  { "file-ext", ANY },
  { "file-mode", { { 493, 365, 292, ANY } } },
  { "hlines", { { "no", "yes" } } },
  { "mkdirp", { { "yes", "no" } } },
  { "no-expand", false },
  { "noeval", false },
  { "noweb", { { "yes", "no", "tangle", "strip-tangle", "no-export", "strip-export" } } },
  { "noweb-ref", ANY },
  { "noweb-sep", ANY },
  { "noweb-prefix", { { "no", "yes" } } },
  { "output-dir", ANY },
  { "padline", { { "yes", "no" } } },
  { "post", ANY },
  { "prologue", ANY },
  {
    "results",
    {
      { "file", "list", "vector", "table", "scalar", "verbatim" },
      { "raw", "html", "latex", "org", "code", "pp", "drawer", "link", "graphics" },
      { "replace", "silent", "none", "discard", "append", "prepend" },
      { "output", "value" },
    },
  },
  { "rownames", { { "no", "yes" } } },
  { "sep", ANY },
  { "session", ANY },
  { "shebang", ANY },
  { "tangle", { { "tangle", "yes", "no", ANY } } },
  { "tangle-mode", { { 493, 365, 292, ANY } } },
  { "var", ANY },
  { "wrap", ANY },
}

-- `org-babel-header-args:LANG` of the languages shipped with Org.
local LANG_HEADER_ARGS = {
  ["emacs-lisp"] = { { "lexical", ANY } },
  python = { { "return", ANY }, { "python", ANY }, { "async", { { "yes", "no" } } } },
  shell = { { "async", { { "yes", "no" } } } },
  sh = { { "async", { { "yes", "no" } } } },
  bash = { { "async", { { "yes", "no" } } } },
  zsh = { { "async", { { "yes", "no" } } } },
  C = {
    { "includes", ANY },
    { "defines", ANY },
    { "main", ANY },
    { "flags", ANY },
    { "cmdline", ANY },
    { "libs", ANY },
  },
  ["C++"] = {
    { "namespaces", ANY },
    { "includes", ANY },
    { "defines", ANY },
    { "main", ANY },
    { "flags", ANY },
    { "cmdline", ANY },
    { "libs", ANY },
  },
  sqlite = {
    { "db", ANY },
    { "header", ANY },
    { "echo", ANY },
    { "bail", ANY },
    { "csv", ANY },
    { "column", ANY },
    { "html", ANY },
    { "line", ANY },
    { "list", ANY },
    { "separator", ANY },
    { "nullvalue", ANY },
    { "readonly", { { "yes", "no" } } },
  },
  java = {
    { "dir", ANY },
    { "classname", ANY },
    { "imports", ANY },
    { "cmpflag", ANY },
    { "cmdline", ANY },
    { "cmdarg", ANY },
  },
  haskell = { { "compile", ANY } },
  clojure = {
    { "ns", ANY },
    { "package", ANY },
    { "backend", { { "inf-clojure", "cider", "slime", "babashka", "nbb" } } },
  },
  lisp = { { "package", ANY } },
  scheme = { { "host", ANY }, { "port", ANY } },
}
-- Languages whose header arguments are accepted in #+CALL lines
-- (`org-babel-load-languages`).
local LOADED_LANGUAGES = { "emacs-lisp" }

-- Items of `org-export-options-alist` and the registered backends.
local OPTIONS_ITEMS = {
  "H", "\\n", "num", "timestamp", "arch", "author", "expand-links", "broken-links", "c", "creator", "date", "d",
  "email", "*", "e", ":", "f", "inline", "tex", "p", "pri", "prop", "'", "-", "stat", "^", "toc", "|", "tags",
  "tasks", "<", "title", "todo", "latex-use-sans", "html5-fancy", "html-link-use-abs-url", "html-postamble",
  "html-preamble", "html-style", "html-scripts", "html-self-link-headlines",
}

-- Export keywords of `org-export-options-alist`.
local COMMON_OPTION_KEYWORDS = {
  "CITE_EXPORT", "CREATOR", "EXCLUDE_TAGS", "SELECT_TAGS", "LANGUAGE", "EMAIL", "AUTHOR", "DATE", "TITLE",
}
-- Export keywords of the registered backends: keyword -> backends.
local BACKEND_OPTION_KEYWORDS = {
  { "LATEX_CLASS", { "latex", "beamer" } },
  { "COLUMNS", { "beamer" } },
  { "BEAMER_THEME", { "beamer" } },
  { "BEAMER_COLOR_THEME", { "beamer" } },
  { "BEAMER_FONT_THEME", { "beamer" } },
  { "BEAMER_INNER_THEME", { "beamer" } },
  { "BEAMER_OUTER_THEME", { "beamer" } },
  { "BEAMER_HEADER", { "beamer" } },
  { "ODT_STYLES_FILE", { "odt" } },
  { "DESCRIPTION", { "html", "latex", "odt" } },
  { "KEYWORDS", { "html", "latex", "odt" } },
  { "SUBTITLE", { "ascii", "html", "latex", "odt" } },
  { "LATEX_HEADER", { "html", "latex", "odt" } },
  { "LATEX_CLASS_OPTIONS", { "latex" } },
  { "LATEX_HEADER_EXTRA", { "latex" } },
  { "LATEX_CLASS_PRE", { "latex" } },
  { "LATEX_FOOTNOTE_COMMAND", { "latex" } },
  { "LATEX_ENGRAVED_THEME", { "latex" } },
  { "LATEX_COMPILER", { "latex" } },
  { "DATE", { "latex" } },
  { "ICALENDAR_EXCLUDE_TAGS", { "icalendar" } },
  { "ICAL-TTL", { "icalendar" } },
  { "HTML_DOCTYPE", { "html" } },
  { "HTML_CONTAINER", { "html" } },
  { "HTML_CONTENT_CLASS", { "html" } },
  { "HTML_LINK_HOME", { "html" } },
  { "HTML_LINK_UP", { "html" } },
  { "HTML_MATHJAX", { "html" } },
  { "HTML_EQUATION_REFERENCE_FORMAT", { "html" } },
  { "HTML_HEAD", { "html" } },
  { "HTML_HEAD_EXTRA", { "html" } },
  { "INFOJS_OPT", { "html" } },
  { "CREATOR", { "html" } },
}

-- `org-default-properties`
local DEFAULT_PROPERTIES = {
  "ARCHIVE", "CATEGORY", "SUMMARY", "DESCRIPTION", "CUSTOM_ID", "LOCATION", "LOGGING", "COLUMNS", "VISIBILITY",
  "TABLE_EXPORT_FORMAT", "TABLE_EXPORT_FILE", "EXPORT_OPTIONS", "EXPORT_TEXT", "EXPORT_FILE_NAME", "EXPORT_TITLE",
  "EXPORT_AUTHOR", "EXPORT_DATE", "UNNUMBERED", "ORDERED", "NOBLOCKING", "COOKIE_DATA", "LOG_INTO_DRAWER",
  "REPEAT_TO_STATE", "CLOCK_MODELINE_TOTAL", "STYLE", "HTML_CONTAINER_CLASS", "ORG-IMAGE-ACTUAL-WIDTH",
}

-- `org-special-properties`
local SPECIAL_PROPERTIES = {
  "ALLTAGS", "BLOCKED", "CLOCKSUM", "CLOCKSUM_T", "CLOSED", "DEADLINE", "FILE", "ITEM", "PRIORITY", "SCHEDULED",
  "TAGS", "TIMESTAMP", "TIMESTAMP_IA", "TODO",
}

-- Link types known to Org (`org-link-types`).
local LINK_TYPES = {
  "eww", "rmail", "mhe", "irc", "info", "gnus", "docview", "bibtex", "bbdb", "w3m", "doi", "attachment", "id",
  "file+sys", "file+emacs", "shell", "news", "mailto", "https", "http", "ftp", "shortdoc", "help", "file", "elisp",
}

-- Citation processors (`org-cite-try-load-processor` finds them).
local CITE_PROCESSORS = { basic = true, biblatex = true, bibtex = true, csl = true, natbib = true }

local BEAMER_FRAME_ENVIRONMENT = "orgframe"

---------------------------------------------------------------------------
-- Document model: elements
---------------------------------------------------------------------------

---@class org.lint.Element
---@field type string org-element type
---@field begin integer first line (affiliated keywords included)
---@field post integer post-affiliated line
---@field col integer column of the first character (items/footnotes)
---@field last integer last line of the element (without trailing blank lines)
---@field stop integer first line after the element and its blank lines
---@field cbegin integer|nil first contents line
---@field ccol integer|nil column of the contents start on `cbegin`
---@field cend integer|nil last contents line
---@field aff table[] affiliated keywords { key, raw, value, dual, line, col }
---@field children org.lint.Element[]
---@field parent org.lint.Element|nil

local Doc = {}
Doc.__index = Doc

local function new_el(t, fields)
  fields.type = t
  fields.children = fields.children or {}
  fields.aff = fields.aff or {}
  fields.col = fields.col or 1
  return fields
end

function Doc:skip_blank(k, e)
  while k <= e and is_blank(self.lines[k]) do
    k = k + 1
  end
  return k
end

--- Last non-blank line before `k` (not before `floor`).
function Doc:last_nonblank(k, floor)
  k = k - 1
  while k > floor and is_blank(self.lines[k]) do
    k = k - 1
  end
  return k
end

local function headline_stars(l)
  local stars = l:match("^(%*+) ")
  return stars and #stars or nil
end

local function match_drawer(l)
  return l:match("^[ \t]*:([%w_%-]+):[ \t]*$")
end

local function is_drawer_end(l)
  return l:match("^[ \t]*:[Ee][Nn][Dd]:[ \t]*$") ~= nil
end

local function match_block_begin(l)
  return l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
end

local function is_comment(l)
  return l:match("^[ \t]*#$") ~= nil or l:match("^[ \t]*# ") ~= nil
end

local function is_fixed(l)
  return l:match("^[ \t]*:$") ~= nil or l:match("^[ \t]*: ") ~= nil
end

local function is_hr(l)
  return l:match("^[ \t]*%-%-%-%-%-+[ \t]*$") ~= nil
end

local function is_item(l)
  return l:match("^[ \t]*[%-+][ \t]") ~= nil
    or l:match("^[ \t]*[%-+]$") ~= nil
    or l:match("^[ \t]*%d+[%.%)][ \t]") ~= nil
    or l:match("^[ \t]*%d+[%.%)]$") ~= nil
    or l:match("^[ \t]+%*[ \t]") ~= nil
    or l:match("^[ \t]+%*$") ~= nil
end

local function latex_begin(l)
  return l:match("^[ \t]*\\begin{([A-Za-z0-9*]+)}")
end

local function tableel_rule(l)
  local body = l:match("^[ \t]*%+([%-+]+)[ \t]*$")
  return body ~= nil and body:sub(-1) == "+" and not body:find("++", 1, true)
end

--- Is `s` (from the first char) an inactive timestamp `[YYYY-MM-DD ...]`?
--- Returns candidate end indexes.
local function inactive_ts_ends(s, p)
  if not s:sub(p):match("^%[%d%d%d%d%-%d%d%-%d%d") then
    return {}
  end
  local q = p + 11
  local c = s:sub(q, q)
  if c == "]" then
    return { q }
  elseif c ~= " " then
    return {}
  end
  local out = {}
  local i = q + 1
  while true do
    local j = s:find("]", i, true)
    if not j then
      break
    end
    out[#out + 1] = j
    i = j + 1
  end
  return out
end

--- `org-element-clock-line-re`
local function is_clock_line(l)
  local rest = l:match("^[ \t]*[Cc][Ll][Oo][Cc][Kk]:(.*)$")
  if not rest then
    return false
  end
  if rest:match("^[ \t]+=>[ \t]+%d+:%d%d[ \t]*$") then
    return true
  end
  local p = rest:find("[^ \t]")
  if not p or p == 1 then
    return false
  end
  for _, e1 in ipairs(inactive_ts_ends(rest, p)) do
    local after = rest:sub(e1 + 1)
    if after:match("^[ \t]*$") then
      return true
    end
    if after:sub(1, 2) == "--" then
      for _, e2 in ipairs(inactive_ts_ends(after, 3)) do
        if after:sub(e2 + 1):match("^[ \t]+=>[ \t]+%d+:%d%d[ \t]*$") then
          return true
        end
      end
    end
  end
  return false
end

--- Match an affiliated keyword line. Returns { key, raw, value, dual, vcol }.
local function match_affiliated(l)
  local pre, key, rest = l:match("^([ \t]*#%+)([%w_%-]+)(.*)$")
  if not pre then
    return nil
  end
  local up = key:upper()
  local dual, after
  if up == "CAPTION" or up == "RESULTS" then
    local d, a = rest:match("^%[(.*)%]:(.*)$")
    if d then
      dual, after = d, a
    elseif rest:sub(1, 1) == ":" then
      after = rest:sub(2)
    end
  elseif AFFILIATED[up] or up:match("^ATTR_[%-_A-Za-z0-9]+$") then
    if rest:sub(1, 1) == ":" then
      after = rest:sub(2)
    end
  end
  if not after then
    return nil
  end
  local ws = after:match("^[ \t]*")
  local vcol = #l - #after + #ws + 1
  return { key = TRANSLATION[up] or up, raw = up, value = trim(after), dual = dual, vcol = vcol }
end

--- Double checks of `org-element-paragraph-separate`.
function Doc:para_sep(k, e)
  local l = self.lines[k]
  if l:match("^%*+ ") or l:match("^%[fn:[%w_%-]+%]") or l:match("^%%%%%(") or is_blank(l) then
    return true
  end
  if l:match("^[ \t]*|") or tableel_rule(l) then
    return true
  end
  local ll = l:lower()
  if ll:match("^[ \t]*#") then
    if is_comment(l) then
      return true
    end
    local bt = match_block_begin(l)
    if bt then
      return self:find_block_end(k, e, bt) ~= nil
    end
    local key, br = l:match("^[ \t]*#%+(%S-)(%[.*%]):")
    if l:match("^[ \t]*#%+%S+:") or br then
      if br then
        return key:upper() == "CAPTION" or key:upper() == "RESULTS"
      end
      return true
    end
    return false
  end
  if ll:match("^[ \t]*:") then
    if is_fixed(l) then
      return true
    end
    if match_drawer(l) then
      for j = k + 1, e do
        if is_drawer_end(self.lines[j]) then
          return true
        end
      end
      return false
    end
    return false
  end
  if is_hr(l) then
    return true
  end
  local env = latex_begin(l)
  if env then
    return self:find_latex_end(k, e, env) ~= nil
  end
  if is_clock_line(l) then
    return true
  end
  if l:match("^[ \t]*[%-+*][ \t]") or l:match("^[ \t]*[%-+*]$") or l:match("^[ \t]*%d+[%.%)][ \t]")
    or l:match("^[ \t]*%d+[%.%)]$") then
    return true
  end
  return false
end

function Doc:find_block_end(k, e, btype)
  local want = "#+end_" .. btype:lower()
  for j = k + 1, e do
    local l = self.lines[j]:lower()
    local t = l:match("^[ \t]*(#%+%S+)[ \t]*$")
    if t == want then
      return j
    end
  end
  return nil
end

function Doc:find_latex_end(k, e, env)
  local pat = "\\end{" .. env .. "}"
  for j = k, e do
    local l = self.lines[j]
    local s = l:find(pat, 1, true)
    while s do
      if l:sub(s + #pat):match("^[ \t]*$") then
        return j
      end
      s = l:find(pat, s + 1, true)
    end
  end
  return nil
end

--- Paragraph starting at line `k` (column `col`), bounded by `e`.
function Doc:paragraph(i, k, e, aff, col)
  local j = k + 1
  while j <= e and not self:para_sep(j, e) do
    j = j + 1
  end
  local last = self:last_nonblank(j, k)
  return new_el("paragraph", {
    begin = i,
    post = k,
    col = col,
    last = last,
    stop = self:skip_blank(j, e),
    cbegin = k,
    ccol = col or 1,
    cend = last,
    aff = aff,
  })
end

--- List structure (`org-element--list-struct`) starting at line `k`.
function Doc:list_struct(k, e)
  local L = self.lines
  local items, struct = {}, {}
  local function indent(l)
    local ws = l:match("^[ \t]*")
    local w = 0
    for c in ws:gmatch(".") do
      w = c == "\t" and (math.floor(w / 8) + 1) * 8 or w + 1
    end
    return w
  end
  local function finish()
    table.sort(struct, function(a, b)
      return a.line < b.line
    end)
    return struct
  end
  local j = k
  while true do
    if j > e then
      local stop = self:last_nonblank(e + 1, k - 1) + 1
      for _, it in ipairs(items) do
        it.stop = stop
        struct[#struct + 1] = it
      end
      return finish()
    elseif is_blank(L[j]) and j + 1 <= #L and is_blank(L[j + 1]) then
      for _, it in ipairs(items) do
        it.stop = j
        struct[#struct + 1] = it
      end
      return finish()
    elseif is_item(L[j]) then
      local ind = indent(L[j])
      while #items > 0 and ind <= items[#items].ind do
        local it = table.remove(items)
        it.stop = j
        struct[#struct + 1] = it
      end
      local l = L[j]
      local bullet = l:match("^[ \t]*([%-+*][ \t]*)") or l:match("^[ \t]*(%d+[%.%)][ \t]*)")
      local p = #l:match("^[ \t]*") + #bullet + 1
      local rest = l:sub(p)
      local counter, cafter = rest:match("^%[@start:([%dA-Za-z]+)%][ \t]*()")
      if not counter then
        counter, cafter = rest:match("^%[@([%dA-Za-z]+)%][ \t]*()")
      end
      if counter and not (counter:match("^%d+$") or counter:match("^%a$")) then
        counter = nil
      end
      if counter then
        p = p + cafter - 1
        rest = l:sub(p)
      end
      local box = rest:match("^(%[[ X%-]%])[ \t]") or rest:match("^(%[[ X%-]%])$")
      if box then
        p = p + #(rest:match("^%[[ X%-]%][ \t]*"))
        rest = l:sub(p)
      end
      local tag
      if bullet:match("^[%-+*]") then
        local t, tafter = rest:match("^(.*)[ \t]+::[ \t]+()")
        if not t then
          t = rest:match("^(.*)[ \t]+::$")
          tafter = t and #rest + 1
        end
        if t then
          tag = t
          p = p + tafter - 1
        end
      end
      items[#items + 1] = {
        line = j,
        ind = ind,
        bullet = bullet,
        counter = counter,
        checkbox = box,
        tag = tag,
        ccol = p,
      }
      j = j + 1
    elseif is_blank(L[j]) then
      j = j + 1
    else
      local ind = indent(L[j])
      local stop = self:last_nonblank(j, k - 1) + 1
      while #items > 0 and ind <= items[#items].ind do
        local it = table.remove(items)
        it.stop = stop
        struct[#struct + 1] = it
        if #items == 0 then
          return finish()
        end
      end
      local l = L[j]
      local bt = l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn](:)") or l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn](_%S+)")
      if bt then
        local want = ("#+end" .. bt):lower()
        for x = j + 1, e do
          local t = L[x]:lower():match("^[ \t]*(#%+%S+)[ \t]*$")
          if t == want then
            j = x
            break
          end
        end
      elseif match_drawer(l) then
        for x = j + 1, e do
          if is_drawer_end(L[x]) then
            j = x
            break
          end
        end
      end
      j = j + 1
    end
  end
end

--- Parse the element starting at line `i` (column `col`), bounded by `e`.
function Doc:current_element(i, e, mode, col, ctx)
  local L = self.lines
  local l = L[i]
  if mode == "item" and ctx.items and ctx.items[i] then
    local it = ctx.items[i]
    local stop = it.stop
    local last = self:last_nonblank(stop, i)
    local el = new_el("item", {
      begin = i,
      post = i,
      last = last,
      stop = stop,
      item = it,
    })
    -- contents: after bullet/counter/checkbox/tag, skipping blanks
    local rest = l:sub(it.ccol)
    if rest:match("%S") then
      el.cbegin, el.ccol = i, it.ccol + #rest:match("^[ \t]*")
      el.cend = last
    else
      local k = self:skip_blank(i + 1, stop - 1)
      if k <= stop - 1 then
        el.cbegin, el.ccol, el.cend = k, 1, last
      end
    end
    return el
  elseif mode == "table-row" then
    return new_el("table-row", { begin = i, post = i, last = i, stop = i + 1 })
  elseif mode == "node-property" then
    return self:node_property(i)
  end
  local bol = col == nil or col == 1
  if bol and headline_stars(l) then
    return self:headline(i)
  end
  if mode == "section" or mode == "first-section" then
    local j = i
    while j <= e and not headline_stars(L[j]) do
      j = j + 1
    end
    local last = self:last_nonblank(j, i)
    return new_el("section", { begin = i, post = i, last = last, stop = j, cbegin = i, ccol = 1, cend = last })
  end
  if bol and is_comment(l) then
    local j = i
    while j + 1 <= e and is_comment(L[j + 1]) do
      j = j + 1
    end
    return new_el("comment", { begin = i, post = i, last = j, stop = self:skip_blank(j + 1, e) })
  end
  if mode == "planning" and bol and i > 1 and L[i - 1]:sub(1, 1) == "*" then
    local ll = l:lower()
    if ll:match("^[ \t]*closed:") or ll:match("^[ \t]*deadline:") or ll:match("^[ \t]*scheduled:") then
      return self:planning(i, e)
    end
  end
  if bol then
    local ok = (mode == "planning" and i > 1 and L[i - 1]:sub(1, 1) == "*")
      or mode == "property-drawer"
      or mode == "top-comment"
    if ok and l:lower():match("^[ \t]*:properties:[ \t]*$") then
      local j = i + 1
      local stop_at
      while j <= #L do
        if is_drawer_end(L[j]) then
          stop_at = j
          break
        end
        if not (L[j]:match("^[ \t]*:%S+:$") or L[j]:match("^[ \t]*:%S+:[ \t]")) then
          break
        end
        j = j + 1
      end
      if stop_at then
        local el = new_el("property-drawer", {
          begin = i,
          post = i,
          last = stop_at,
          stop = self:skip_blank(stop_at + 1, e),
        })
        if stop_at > i + 1 then
          el.cbegin, el.ccol, el.cend = i + 1, 1, stop_at - 1
        end
        return el
      end
    end
  end
  if not bol then
    return self:paragraph(i, i, e, {}, col)
  end
  if is_clock_line(l) then
    return new_el("clock", { begin = i, post = i, last = i, stop = self:skip_blank(i + 1, e) })
  end
  -- affiliated keywords
  local aff = {}
  local j = i
  while j <= e do
    local a = match_affiliated(L[j])
    if not a then
      break
    end
    a.line = j
    aff[#aff + 1] = a
    j = j + 1
  end
  if #aff > 0 then
    local nl = L[j]
    if nl == nil or is_blank(nl) or is_comment(nl) or nl:match("^[ \t]*[Cc][Ll][Oo][Cc][Kk]:") or nl:match("^%*+ ") then
      aff, j = {}, i
    elseif j > e then
      return self:keyword(i, i, e, {})
    end
  end
  local k = j
  l = L[k]
  local env = latex_begin(l)
  if env then
    local stop_at = self:find_latex_end(k, e, env)
    if not stop_at then
      return self:paragraph(i, k, e, aff)
    end
    return new_el("latex-environment", {
      begin = i,
      post = k,
      last = stop_at,
      stop = self:skip_blank(stop_at + 1, e),
      aff = aff,
    })
  end
  local dname = match_drawer(l)
  if dname then
    local stop_at
    for x = k + 1, e do
      if is_drawer_end(L[x]) then
        stop_at = x
        break
      end
    end
    if not stop_at then
      return self:paragraph(i, k, e, aff)
    end
    local el = new_el("drawer", {
      begin = i,
      post = k,
      last = stop_at,
      stop = self:skip_blank(stop_at + 1, e),
      aff = aff,
      name = dname,
      end_line = stop_at,
    })
    local cb = self:skip_blank(k + 1, stop_at - 1)
    if cb < stop_at then
      el.cbegin, el.ccol, el.cend = cb, 1, stop_at - 1
    end
    return el
  end
  if is_fixed(l) then
    local x = k
    while x + 1 <= e and is_fixed(L[x + 1]) do
      x = x + 1
    end
    return new_el("fixed-width", { begin = i, post = k, last = x, stop = self:skip_blank(x + 1, e), aff = aff })
  end
  if l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:[ \t]*%S") then
    local stop_at
    for x = k + 1, e do
      local t = L[x]:lower()
      if t:match("^[ \t]*#%+end:?[ \t]*$") then
        stop_at = x
        break
      end
    end
    if not stop_at then
      return self:paragraph(i, k, e, aff)
    end
    local el = new_el("dynamic-block", {
      begin = i,
      post = k,
      last = stop_at,
      stop = self:skip_blank(stop_at + 1, e),
      aff = aff,
    })
    if stop_at > k + 1 then
      el.cbegin, el.ccol, el.cend = k + 1, 1, stop_at - 1
    end
    return el
  end
  if l:match("^[ \t]*#%+") then
    local btype = match_block_begin(l)
    if btype then
      return self:block(i, k, e, aff, btype)
    end
    if l:match("^[ \t]*#%+[Cc][Aa][Ll][Ll]:") then
      return self:babel_call(i, k, e, aff)
    end
    if l:match("^[ \t]*#%+%S+:") then
      return self:keyword(i, k, e, aff)
    end
  end
  local label = l:match("^%[fn:([%w_%-]+)%]")
  if label then
    return self:footnote_definition(i, k, e, aff, label)
  end
  if is_hr(l) then
    return new_el("horizontal-rule", { begin = i, post = k, last = k, stop = self:skip_blank(k + 1, e), aff = aff })
  end
  if l:match("^%%%%%(") then
    return new_el("diary-sexp", { begin = i, post = k, last = k, stop = self:skip_blank(k + 1, e), aff = aff })
  end
  if l:match("^[ \t]*|") then
    local x = k
    while x + 1 <= e and L[x + 1]:match("^[ \t]*|") do
      x = x + 1
    end
    local rows_end = x
    while x + 1 <= e and L[x + 1]:lower():match("^[ \t]*#%+tblfm:") do
      x = x + 1
    end
    local el = new_el("table", {
      begin = i,
      post = k,
      last = x,
      stop = self:skip_blank(x + 1, e),
      aff = aff,
      cbegin = k,
      ccol = 1,
      cend = rows_end,
    })
    return el
  end
  if tableel_rule(l) and k < e then
    local x = k
    while x + 1 <= e and L[x + 1]:match("^[ \t]*[+|]") do
      x = x + 1
    end
    if x > k and tableel_rule(L[x]) then
      return new_el("table", {
        begin = i,
        post = k,
        last = x,
        stop = self:skip_blank(x + 1, e),
        aff = aff,
        tableel = true,
      })
    end
  end
  if is_item(l) then
    local struct = self:list_struct(k, e)
    local byline = {}
    for _, it in ipairs(struct) do
      byline[it.line] = it
    end
    local first = byline[k]
    local pos, ind = first.stop, first.ind
    while byline[pos] and byline[pos].ind == ind do
      pos = byline[pos].stop
    end
    local cend = self:last_nonblank(pos, k)
    local ordered = l:match("^[ \t]*[%w]") ~= nil
    return new_el("plain-list", {
      begin = i,
      post = k,
      last = cend,
      stop = self:skip_blank(cend + 1, e),
      aff = aff,
      cbegin = k,
      ccol = 1,
      cend = cend,
      items = byline,
      list_type = ordered and "ordered" or (first.tag and "descriptive" or "unordered"),
    })
  end
  return self:paragraph(i, k, e, aff)
end

function Doc:headline(i)
  local L = self.lines
  local level = headline_stars(L[i])
  local j = i + 1
  while j <= #L do
    local s = headline_stars(L[j])
    if s and s <= level then
      break
    end
    j = j + 1
  end
  local el = new_el("headline", { begin = i, post = i, last = j - 1, stop = j, level = level })
  local cb = self:skip_blank(i + 1, j - 1)
  if cb <= j - 1 then
    el.cbegin, el.ccol, el.cend = cb, 1, j - 1
  end
  self:parse_title(el)
  return el
end

--- Headline title properties (`org-element--headline-parse-title`).
function Doc:parse_title(el)
  local line = self.lines[el.begin]
  local p = #line:match("^%*+[ \t]*") + 1
  local todo_cfg = self.todo or (self.file and self.file.settings.todo)
  local word = line:match("^(%S+)", p)
  if word and todo_cfg and todo_cfg:is_keyword(word) then
    local nxt = line:sub(p + #word, p + #word)
    if nxt == "" or nxt == " " then
      el.todo = word
      p = p + #word
      p = p + #line:match("^[ \t]*", p)
    end
  end
  -- org-priority-regexp: ".*?\\(\\[#\\([A-Z]\\|[0-9]\\|[1-5][0-9]\\|6[0-4]\\)\\] ?\\)" (case-folded)
  local search = p
  while true do
    local s = line:find("[#", search, true)
    if not s then
      break
    end
    local v = line:sub(s + 2):match("^(%a)%]") or line:sub(s + 2):match("^(%d)%]")
    if not v then
      v = line:sub(s + 2):match("^([1-5]%d)%]") or line:sub(s + 2):match("^(6[0-4])%]")
    end
    if v then
      if v:match("%d") then
        el.priority = tonumber(v)
      else
        el.priority = v:byte()
      end
      p = s + 3 + #v
      if line:sub(p, p) == " " then
        p = p + 1
      end
      break
    end
    search = s + 1
  end
  local c = line:match("^COMMENT()", p)
  if c and (line:sub(c, c) == "" or line:sub(c, c) == " ") then
    el.commented = true
    p = c
    p = p + #line:match("^[ \t]*", p)
  end
  local title_start = p
  local title_end = #line + 1
  -- org-tag-group-re: "[ \t]+\\(:\\([[:alnum:]_@#%:]+\\):\\)[ \t]*$"
  local back = title_start
  while back > 1 and line:sub(back - 1, back - 1):match("[ \t]") do
    back = back - 1
  end
  local ts, tagstr = line:match("()[ \t]+(:[%w_@#%%:]+:)[ \t]*$", back)
  if ts and #tagstr > 2 then
    title_end = ts
    el.tags = {}
    local inner = tagstr:sub(2, -2)
    for t in (inner .. ":"):gmatch("([^:]*):") do
      el.tags[#el.tags + 1] = t
    end
  end
  el.tags = el.tags or {}
  el.raw_value = trim(line:sub(title_start, title_end - 1))
  -- title objects: from title start (blanks skipped) to title end (blanks trimmed)
  local ostart = title_start + #line:match("^[ \t]*", title_start)
  local oend = title_end - 1
  while oend >= ostart and line:sub(oend, oend):match("[ \t]") do
    oend = oend - 1
  end
  el.title_range = { ostart, oend }
end

function Doc:planning(i, e)
  local l = self.lines[i]
  local el = new_el("planning", { begin = i, post = i, last = i, stop = self:skip_blank(i + 1, e) })
  for _, kw in ipairs({ "CLOSED:", "DEADLINE:", "SCHEDULED:" }) do
    local s = l:find(kw, 1, true)
    if s then
      local p = s + #kw
      p = p + #l:match("^[ \t]*", p)
      local ts = M._timestamp(l, p, #l)
      el[kw:sub(1, -2):lower()] = ts
    end
  end
  return el
end

function Doc:node_property(i)
  local l = self.lines[i]
  local el = new_el("node-property", { begin = i, post = i, last = i, stop = i + 1 })
  local body = l:match("^[ \t]*:(.*)$")
  if body then
    -- key: shortest "\S-+?" such that ":" is followed by blanks or eol
    local p = 1
    while true do
      local c = body:find(":", p + 1, true)
      if not c then
        break
      end
      local key = body:sub(1, c - 1)
      if key:match("%s") then
        break
      end
      local after = body:sub(c + 1)
      if after == "" or after:match("^[ \t]") then
        if key:sub(-1) == "+" then
          key = key:sub(1, -2)
        end
        el.key = key
        local v = after:match("^[ \t]+(.-)[ \t]*$")
        el.value = v
        break
      end
      p = c
    end
  end
  return el
end

function Doc:keyword(i, k, e, aff)
  local l = self.lines[k]
  local key, after = l:match("^[ \t]*#%+(%S*):(.*)$")
  return new_el("keyword", {
    begin = i,
    post = k,
    last = k,
    stop = self:skip_blank(k + 1, e),
    aff = aff,
    key = (key or ""):upper(),
    value = trim(after or ""),
    post_blank = self:skip_blank(k + 1, e) - (k + 1),
  })
end

function Doc:babel_call(i, k, e, aff)
  local l = self.lines[k]
  local p = l:find(":", 1, true) + 1
  p = p + #l:match("^[ \t]*", p)
  local q = p
  while q <= #l and not l:sub(q, q):match("[%[%]%(%)]") do
    q = q + 1
  end
  local el = new_el("babel-call", { begin = i, post = k, last = k, stop = self:skip_blank(k + 1, e), aff = aff })
  el.call = nw(l:sub(p, q - 1))
  if l:sub(q, q) == "[" then
    local c = balanced(l, q, "[", "]")
    if c then
      el.inside_header = l:sub(q + 1, c - 1)
      q = c + 1
    end
  end
  if l:sub(q, q) == "(" then
    local c = balanced(l, q, "(", ")")
    if c then
      el.arguments = nw(l:sub(q + 1, c - 1))
      q = c + 1
    end
  end
  el.end_header = nw(trim(l:sub(q)))
  return el
end

local function unescape_code(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:gsub("^([ \t]*),([*,])", "%1%2"):gsub("^([ \t]*),(#%+)", "%1%2")
  end
  return out
end

function Doc:block(i, k, e, aff, btype)
  local L = self.lines
  local up = btype:upper()
  local stop_at = self:find_block_end(k, e, btype)
  if not stop_at then
    return self:paragraph(i, k, e, aff)
  end
  local types = {
    CENTER = "center-block",
    COMMENT = "comment-block",
    EXAMPLE = "example-block",
    EXPORT = "export-block",
    QUOTE = "quote-block",
    SRC = "src-block",
    VERSE = "verse-block",
  }
  local el = new_el(types[up] or "special-block", {
    begin = i,
    post = k,
    last = stop_at,
    stop = self:skip_blank(stop_at + 1, e),
    aff = aff,
    end_line = stop_at,
  })
  local l = L[k]
  local rest = l:match("^[ \t]*#%+%S+(.*)$")
  if up == "SRC" then
    local r = rest
    local lang = r:match("^ +(%S+)")
    if lang then
      el.language = lang
      r = r:sub(#r:match("^ +%S+") + 1)
    end
    local switches = {}
    while true do
      local m = r:match('^( +%-l ".+")') or r:match("^( +%-[ikr])") or r:match("^( +[%-+]n *%d+)")
        or r:match("^( +[%-+]n)")
      if not m then
        break
      end
      switches[#switches + 1] = m
      r = r:sub(#m + 1)
    end
    el.switches = #switches > 0 and table.concat(switches) or nil
    el.parameters = nw(trim(r))
    el.label_fmt = el.switches and el.switches:match('%-l +"([^"\n]+)"')
    el.value = table.concat(unescape_code(vim.list_slice(L, k + 1, stop_at - 1)), "\n")
  elseif up == "EXAMPLE" then
    local sw = rest:match("^ +(.*)$")
    el.switches = sw
    el.label_fmt = sw and sw:match('%-l +"([^"\n]+)"')
    el.value = table.concat(unescape_code(vim.list_slice(L, k + 1, stop_at - 1)), "\n")
  elseif up == "EXPORT" then
    el.backend = rest:match("^[ \t]+(%S+)")
  elseif not types[up] then
    el.block_type = btype
  end
  if up == "CENTER" or up == "QUOTE" or not types[up] then
    local cb = k + 1
    if cb < stop_at then
      el.cbegin, el.ccol, el.cend = cb, 1, stop_at - 1
    end
  elseif up == "VERSE" then
    if k + 1 < stop_at then
      el.vbegin, el.vend = k + 1, stop_at - 1
    end
  end
  return el
end

function Doc:footnote_definition(i, k, e, aff, label)
  local L = self.lines
  local stop
  local x = k + 1
  local blanks = 0
  while x <= e do
    local l = L[x]
    if l:match("^%*+ ") then
      stop = x
      break
    elseif l:match("^%[fn:[%w_%-]+%]") then
      local y = x - 1
      while y > k and match_affiliated(L[y]) do
        y = y - 1
      end
      stop = y + 1
      break
    elseif is_blank(l) then
      blanks = blanks + 1
      if blanks >= 2 then
        stop = self:skip_blank(x, e)
        break
      end
    else
      blanks = 0
    end
    x = x + 1
  end
  stop = stop or e + 1
  local last = self:last_nonblank(stop, k)
  local el = new_el("footnote-definition", { begin = i, post = k, last = last, stop = stop, aff = aff, label = label })
  local p = #L[k]:match("^%[fn:[%w_%-]+%]") + 1
  local rest = L[k]:sub(p)
  if rest:match("%S") then
    el.cbegin, el.ccol, el.cend = k, p + #rest:match("^[ \t]*"), last
  else
    local cb = self:skip_blank(k + 1, stop - 1)
    if cb <= stop - 1 then
      el.cbegin, el.ccol, el.cend = cb, 1, last
    end
  end
  return el
end

local GREATER = {
  ["center-block"] = true,
  drawer = true,
  ["dynamic-block"] = true,
  ["footnote-definition"] = true,
  headline = true,
  item = true,
  ["plain-list"] = true,
  ["property-drawer"] = true,
  ["quote-block"] = true,
  section = true,
  ["special-block"] = true,
  table = true,
}

local function next_mode(mode, t, parent)
  if parent then
    if t == "headline" then
      return "section"
    elseif t == "section" and mode == "first-section" then
      return "top-comment"
    elseif t == "plain-list" then
      return "item"
    elseif t == "property-drawer" then
      return "node-property"
    elseif t == "section" then
      return "planning"
    elseif t == "table" then
      return "table-row"
    end
    return nil
  end
  if mode == "item" then
    return "item"
  elseif mode == "node-property" then
    return "node-property"
  elseif mode == "planning" and t == "planning" then
    return "property-drawer"
  elseif mode == "table-row" then
    return "table-row"
  elseif mode == "top-comment" and t == "comment" then
    return "property-drawer"
  end
  return nil
end

--- Parse elements between lines `s` (column `col`) and `e` into `parent`.
function Doc:parse_region(s, e, mode, parent, col)
  local i = s
  local ctx = { items = parent.items }
  while i <= e do
    if col == nil and is_blank(self.lines[i]) then
      i = i + 1
    else
      local el = self:current_element(i, e, mode, col, ctx)
      el.parent = parent
      parent.children[#parent.children + 1] = el
      self.elements[#self.elements + 1] = el
      if el.cbegin and GREATER[el.type] and not el.tableel then
        local ccol = el.ccol ~= 1 and el.ccol or nil
        self:parse_region(el.cbegin, el.cend, next_mode(mode, el.type, true), el, ccol)
      end
      i = math.max(el.stop, i + 1)
      col = nil
      mode = next_mode(mode, el.type, false)
    end
  end
end

---------------------------------------------------------------------------
-- Document model: objects
---------------------------------------------------------------------------

---@class org.lint.Object
---@field type string
---@field b integer start offset in the container string
---@field e integer end offset (exclusive, trailing blanks included)
---@field cb integer|nil contents start offset
---@field ce integer|nil contents end offset (exclusive)
---@field parent org.lint.Object|nil enclosing object
---@field element org.lint.Element container element
---@field lnum integer
---@field col integer
---@field pos fun(offset: integer): integer, integer line and column of an offset

--- Timestamp object at `p` in `s` (`org-element-timestamp-parser`).
---@return table|nil
function M._timestamp(s, p, last)
  last = last or #s
  local c = s:sub(p, p)
  if c ~= "<" and c ~= "[" then
    return nil
  end
  local raw_end, date_start, date_end
  if s:sub(p, p + 2) == "<%%" and s:sub(p + 3, p + 3) == "(" then
    -- "<%%(...)...>"
    local close = s:find(")", p + 4, true)
    local gt = s:find(">", p + 3, true)
    local nl = s:find("\n", p, true)
    if not close or not gt or (nl and nl < gt) or close > gt then
      return nil
    end
    -- "(?:([^>\n]+))" greedy: last ")" before ">"
    local lastclose = close
    local x = close
    while true do
      local y = s:find(")", x + 1, true)
      if not y or y > gt then
        break
      end
      lastclose = y
      x = y
    end
    raw_end = gt
    date_start = s:sub(lastclose + 1, gt - 1)
    local ts = { kind = "diary", b = p, sexp = s:sub(p + 3, lastclose) }
    local h, mi, h2, m2 = date_start:match("([012]?%d):([0-5]%d)%-([012]?%d):([0-5]%d)")
    if not h then
      h, mi = date_start:match("([012]?%d):([0-5]%d)")
    end
    ts.hour_start, ts.minute_start = tonumber(h), tonumber(mi)
    ts.hour_end, ts.minute_end = tonumber(h2), tonumber(m2)
    ts.range_type = h2 and "timerange" or nil
    ts.raw_end = raw_end
    local post = s:match("^[ \t]*", raw_end + 1)
    ts.e = raw_end + 1 + #post
    ts.post_blank = #post
    return ts
  end
  if not s:sub(p + 1, p + 10):match("^%d%d%d%d%-%d%d%-%d%d$") then
    return nil
  end
  local q = p + 11
  local qc = s:sub(q, q)
  local close
  if qc == "]" or qc == ">" then
    close = q
  elseif qc == " " then
    local x = q + 1
    while x <= last do
      local ch = s:sub(x, x)
      if ch == "\n" then
        break
      end
      if ch == "]" or ch == ">" then
        close = x
        break
      end
      x = x + 1
    end
  end
  if not close then
    return nil
  end
  date_start = s:sub(p + 1, close - 1)
  raw_end = close
  if s:sub(close + 1, close + 2) == "--" then
    local r = close + 3
    local rc = s:sub(r, r)
    if (rc == "<" or rc == "[") and s:sub(r + 1, r + 10):match("^%d%d%d%d%-%d%d%-%d%d$") then
      local q2 = r + 11
      local c2 = s:sub(q2, q2)
      local close2
      if c2 == "]" or c2 == ">" then
        close2 = q2
      elseif c2 == " " then
        local x = q2 + 1
        while x <= last do
          local ch = s:sub(x, x)
          if ch == "\n" then
            break
          end
          if ch == "]" or ch == ">" then
            close2 = x
            break
          end
          x = x + 1
        end
      end
      if close2 then
        date_end = s:sub(r + 1, close2 - 1)
        raw_end = close2
      end
    end
  end
  local raw = s:sub(p, raw_end)
  local active = c == "<"
  local ts = { b = p, raw = raw, raw_end = raw_end }
  local function parse_time(str)
    local y, mo, d, rest = str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
    local h, mi
    local r2 = rest:match("^ +[^%]+0-9>\r\n %-]+(.*)$") or rest
    h, mi = r2:match("^ +(%d%d?):(%d%d)")
    return tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  end
  ts.year_start, ts.month_start, ts.day_start, ts.hour_start, ts.minute_start = parse_time(date_start)
  local th, tm = date_start:match("[012]?%d:[0-5]%d%-([012]?%d):([0-5]%d)")
  local time_range = th and { tonumber(th), tonumber(tm) } or nil
  if date_end then
    local y, mo, d, h, mi = parse_time(date_end)
    ts.year_end, ts.month_end, ts.day_end = y, mo, d
    ts.hour_end = h or (time_range and time_range[1]) or ts.hour_start
    ts.minute_end = mi or (time_range and time_range[2]) or ts.minute_start
  else
    ts.year_end, ts.month_end, ts.day_end = ts.year_start, ts.month_start, ts.day_start
    ts.hour_end = (time_range and time_range[1]) or ts.hour_start
    ts.minute_end = (time_range and time_range[2]) or ts.minute_start
  end
  if active then
    ts.kind = (date_end or time_range) and "active-range" or "active"
  else
    ts.kind = (date_end or time_range) and "inactive-range" or "inactive"
  end
  ts.range_type = date_end and "daterange" or (time_range and "timerange" or nil)
  -- repeater: first "+", "++" or ".+" followed by N unit
  local x = 1
  while x <= #raw do
    local sub = raw:sub(x)
    local rt, rv, ru, dv, du
    for _, pat in ipairs({ "^(%+)(%d+)([hdwmy])", "^(%+%+)(%d+)([hdwmy])", "^(%.%+)(%d+)([hdwmy])" }) do
      rt, rv, ru = sub:match(pat)
      if rt then
        break
      end
    end
    if rt then
      ts.repeater_type = rt == "++" and "catch-up" or (rt == ".+" and "restart" or "cumulate")
      ts.repeater_value = tonumber(rv)
      ts.repeater_unit = ru
      dv, du = sub:match("^/(%d+)([hdwmy])", #rt + #rv + #ru + 1)
      ts.repeater_deadline_value, ts.repeater_deadline_unit = tonumber(dv), du
      break
    end
    x = x + 1
  end
  local wfirst, wv, wu = raw:match("(%-?)%-(%d+)([hdwmy])")
  if wv then
    ts.warning_type = wfirst == "-" and "first" or "all"
    ts.warning_value = tonumber(wv)
    ts.warning_unit = wu
  end
  local post = s:match("^[ \t]*", raw_end + 1)
  ts.e = raw_end + 1 + #post
  ts.post_blank = #post
  return ts
end

--- `org-element-timestamp-interpreter`
local function interpret_timestamp(ts)
  if not ts then
    return nil
  end
  local t = ts.kind
  if t ~= "diary" and not (ts.day_start and ts.month_start and ts.year_start) then
    return nil
  end
  local rep = ""
  if ts.repeater_type then
    rep = (ts.repeater_type == "cumulate" and "+" or (ts.repeater_type == "catch-up" and "++" or ".+"))
      .. ts.repeater_value
      .. ts.repeater_unit
    if ts.repeater_deadline_value and ts.repeater_deadline_unit then
      rep = rep .. "/" .. ts.repeater_deadline_value .. ts.repeater_deadline_unit
    end
  end
  local warn = ""
  if ts.warning_type then
    warn = (ts.warning_type == "first" and "--" or "-") .. ts.warning_value .. ts.warning_unit
  end
  local open, close = "<", ">"
  if t == "inactive" or t == "inactive-range" then
    open, close = "[", "]"
  end
  local tail = (rep ~= "" and (" " .. rep) or "") .. (warn ~= "" and (" " .. warn) or "") .. close
  local out = { open }
  if t == "diary" then
    out[#out + 1] = "%%" .. ts.sexp
    if ts.minute_start and ts.hour_start then
      out[#out + 1] = string.format(" %02d:%02d", ts.hour_start, ts.minute_start)
    end
  else
    out[#out + 1] = format_date(ts.year_start, ts.month_start, ts.day_start, ts.hour_start, ts.minute_start)
  end
  local he, me = ts.hour_end, ts.minute_end
  if t == "active" or t == "inactive" then
    if ts.hour_start and he and ts.minute_start and me and (ts.hour_start ~= he or ts.minute_start ~= me) then
      out[#out + 1] = string.format("-%02d:%02d", he, me)
    end
  elseif t == "active-range" or t == "inactive-range" or (t == "diary" and ts.range_type == "timerange") then
    if ts.range_type == "timerange" then
      out[#out + 1] = string.format("-%02d:%02d", he or ts.hour_start, me or ts.minute_start)
    else
      out[#out + 1] = tail .. "--" .. open
      out[#out + 1] = format_date(
        ts.year_end or ts.year_start,
        ts.month_end or ts.month_start,
        ts.day_end or ts.day_start,
        (me and he) and he or nil,
        (me and he) and me or nil
      )
    end
  end
  out[#out + 1] = tail
  return table.concat(out)
end
M._interpret_timestamp = interpret_timestamp

local ENTITIES
local function is_entity(name)
  if not ENTITIES then
    local ok, ast = pcall(require, "org.export.ast")
    ENTITIES = ok and ast.ENTITIES or {}
  end
  return ENTITIES[name] ~= nil or name == "dollar"
end

--- Object parser over a container string.
local Lexer = {}
Lexer.__index = Lexer

--- Longest link type (`org-link-types`) followed by ":" at `p`.
local function link_type_at(types, s, p)
  local best
  for _, t in ipairs(types) do
    if s:sub(p, p + #t) == t .. ":" and (not best or #t > #best) then
      best = t
    end
  end
  return best
end

-- Emphasis markers
local EMPH = {
  ["*"] = "bold",
  ["/"] = "italic",
  ["_"] = "underline",
  ["+"] = "strike-through",
  ["="] = "verbatim",
  ["~"] = "code",
}

local function is_space(c)
  return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\f" or c == "\v"
end

-- Unicode characters with whitespace syntax in Emacs (U+2000..U+200B, U+3000).
local function uspace_ending_at(s, q)
  local t = s:sub(q - 2, q)
  return t:match("^\226\128[\128-\139]$") ~= nil or t == "\227\128\128"
end

local function uspace_starting_at(s, q)
  local t = s:sub(q, q + 2)
  return t:match("^\226\128[\128-\139]$") ~= nil or t == "\227\128\128"
end

function Lexer:emphasis(p, a, b)
  local s = self.s
  local mark = s:sub(p, p)
  if p > a then
    local prev = s:sub(p - 1, p - 1)
    if not (is_space(prev) or prev:match("[%-%(%'\"{]") or uspace_ending_at(s, p - 1)) then
      return nil
    end
  end
  local nxt = s:sub(p + 1, p + 1)
  if nxt == "" or p + 1 > b or is_space(nxt) or uspace_starting_at(s, p + 1) then
    return nil
  end
  local q = p + 2
  while q <= b do
    if s:sub(q, q) == mark and not is_space(s:sub(q - 1, q - 1)) and not uspace_ending_at(s, q - 1) then
      local after = s:sub(q + 1, q + 1)
      if
        q == b
        or after == ""
        or is_space(after)
        or after:match("[%-%.,;:!%?'\"%)}\\%[]")
        or uspace_starting_at(s, q + 1)
      then
        local post = s:match("^[ \t]*", q + 1)
        local o = { type = EMPH[mark], b = p, e = q + 1 + #post }
        if mark ~= "=" and mark ~= "~" then
          o.cb, o.ce = p + 1, q
        else
          o.value = s:sub(p + 1, q - 1)
        end
        return o
      end
    end
    q = q + 1
  end
  return nil
end

function Lexer:link(p, a, b)
  local s = self.s
  if s:sub(p, p + 1) == "[[" then
    -- org-link-bracket-re
    local i = p + 2
    local path_end
    while i <= b do
      local ch = s:sub(i, i)
      if ch == "\\" then
        local j = i
        while s:sub(j, j) == "\\" do
          j = j + 1
        end
        i = j + 1
        if s:sub(j, j) == "" then
          break
        end
      elseif ch == "[" then
        break
      elseif ch == "]" then
        path_end = i - 1
        break
      else
        i = i + 1
      end
    end
    if not path_end or path_end < p + 2 then
      return nil
    end
    local raw = s:sub(p + 2, path_end)
    local link_end, cb, ce
    if s:sub(path_end + 1, path_end + 2) == "]]" then
      link_end = path_end + 2
    elseif s:sub(path_end + 1, path_end + 2) == "][" then
      local d = s:find("]]", path_end + 4, true)
      if not d or d > b then
        return nil
      end
      cb, ce = path_end + 3, d
      link_end = d + 1
    else
      return nil
    end
    raw = raw:gsub("[ \t]*\n[ \t]*", " ")
    raw = raw:gsub("(\\+)([%[%]])", function(bs, br)
      return string.rep("\\", math.floor(#bs / 2)) .. br
    end):gsub("(\\+)$", function(bs)
      return string.rep("\\", math.floor(#bs / 2))
    end)
    raw = self.expand_abbrev(raw)
    local o = { type = "link", b = p, format = "bracket", raw_link = raw, cb = cb, ce = ce, link_end = link_end }
    local lt = link_type_at(self.doc.link_types, raw, 1)
    if raw:match("^[/~]") or raw:match("^%.%.?/") then
      o.link_type, o.path = "file", raw
    elseif lt then
      o.link_type, o.path = lt, raw:sub(#lt + 2)
    elseif raw:sub(1, 1) == "(" and raw:sub(-1) == ")" then
      o.link_type, o.path = "coderef", raw:sub(2, -2)
    elseif raw:sub(1, 1) == "#" then
      o.link_type, o.path = "custom-id", raw:sub(2)
    else
      o.link_type, o.path = "fuzzy", raw
    end
    return self:finish_link(o)
  end
  if s:sub(p, p) == "<" then
    local t = link_type_at(self.doc.link_types, s, p + 1)
    if not t then
      return nil
    end
    local q = p + #t + 2
    local gt = s:find(">", q, true)
    if not gt or gt > b then
      return nil
    end
    local inner = s:sub(q, gt - 1)
    -- continuation lines must start with a non-blank, non-> character
    for cont in inner:gmatch("\n([^\n]*)") do
      if not cont:match("^[ \t]*[^> \t]") then
        return nil
      end
    end
    local o = {
      type = "link",
      b = p,
      format = "angle",
      link_type = t,
      path = inner:gsub("[ \t]*\n[ \t]*", ""),
      link_end = gt,
    }
    o.raw_link = t .. ":" .. inner
    return self:finish_link(o)
  end
  -- plain link: word-start, type ":" path
  if p > a and word_char(s:sub(p - 1, p - 1)) then
    return nil
  end
  local t = link_type_at(self.doc.link_types, s, p)
  if not t then
    return nil
  end
  local q = p + #t + 1
  -- (1+ (or non-space-bracket parenthesis)) then a final char
  local i = q
  local good_end
  while i <= b do
    local ch = s:sub(i, i)
    if ch:match("[%(%[<]") then
      -- one level of parentheses: (any "<([") non-space-brackets (any "])>")
      local j = i + 1
      local ok = false
      while j <= b do
        local cj = s:sub(j, j)
        if cj == ")" or cj == "]" or cj == ">" then
          ok = true
          break
        end
        if cj:match("[ \t\n%(%)<>%[%]]") then
          break
        end
        j = j + 1
      end
      if not ok then
        break
      end
      if i > q then
        good_end = j
      end
      i = j + 1
    elseif ch:match("[%[%] \t\n%(%)<>]") then
      break
    else
      if i > q and (ch:match("[%w]") or ch:byte() >= 128 or ch == "-" or ch == "/") then
        good_end = i
      end
      i = i + 1
    end
  end
  if not good_end then
    return nil
  end
  local o = {
    type = "link",
    b = p,
    format = "plain",
    link_type = t,
    path = s:sub(q, good_end),
    raw_link = s:sub(p, good_end),
    link_end = good_end,
  }
  return self:finish_link(o)
end

function Lexer:finish_link(o)
  local s = self.s
  local post = s:match("^[ \t]*", o.link_end + 1)
  o.e = o.link_end + 1 + #post
  local app = o.link_type:match("^file%+(.+)$")
  if o.link_type == "file" or app then
    o.application = app
    o.link_type = "file"
    local path, opt = o.path:match("^(.-)::(.*)$")
    if path then
      o.search_option = opt
      o.path = path
    end
    o.path = o.path:gsub("^///*(%a:)/", "%1/"):gsub("^///*/", "/")
  end
  return o
end

function Lexer:footnote_ref(p, b)
  local s = self.s
  local label, rest = s:match("^%[fn:([%w_%-]*)()", p)
  if not label then
    return nil
  end
  local nxt = s:sub(rest, rest)
  local inline
  if nxt == ":" then
    inline = true
  elseif nxt == "]" and label ~= "" then
    inline = false
  else
    return nil
  end
  local close = balanced(s, p, "[", "]", b)
  if not close then
    return nil
  end
  local post = s:match("^[ \t]*", close + 1)
  local o = {
    type = "footnote-reference",
    b = p,
    e = close + 1 + #post,
    label = label ~= "" and label or nil,
    ref_type = inline and "inline" or "standard",
  }
  if inline then
    o.cb, o.ce = rest + 1, close
  end
  return o
end

function Lexer:citation(p, b)
  local s = self.s
  local style, start = s:match("^%[cite/([%w/_%-]+):()", p)
  if not style then
    start = s:match("^%[cite:()", p)
  end
  if not start then
    return nil
  end
  local close = balanced(s, p, "[", "]", b)
  if not close then
    return nil
  end
  local inner = s:sub(start, close - 1)
  if not inner:find("@[%w%-%.:%?!`'/%*@%+|%(%){}<>&_%^%$#%%~]") then
    return nil
  end
  local post = s:match("^[ \t]*", close + 1)
  return { type = "citation", b = p, e = close + 1 + #post }
end

function Lexer:macro(p, b)
  local s = self.s
  local name, after = s:match("^{{{([a-zA-Z][%-a-zA-Z0-9_]*)()", p)
  if not name then
    return nil
  end
  local args, stop
  if s:sub(after, after + 2) == "}}}" then
    stop = after + 2
  elseif s:sub(after, after) == "(" then
    local c = s:find(")}}}", after, true)
    if not c or c + 3 > b then
      return nil
    end
    args = s:sub(after + 1, c - 1)
    stop = c + 3
  else
    return nil
  end
  local post = s:match("^[ \t]*", stop + 1)
  local o = { type = "macro", b = p, e = stop + 1 + #post, key = name:lower() }
  if args then
    local a = trim(args):gsub("[ \t\r\n]+", " ")
    a = a:gsub("(\\*),", function(bs)
      return string.rep("\\", math.floor(#bs / 2)) .. (#bs % 2 == 0 and "\0" or ",")
    end)
    o.args = vim.split(a, "\0", { plain = true })
  end
  return o
end

function Lexer:latex(p, a, b)
  local s = self.s
  local c = s:sub(p, p)
  local after
  if c ~= "$" then
    local n = s:sub(p + 1, p + 1)
    if n == "(" then
      local e2 = s:find("\\)", p + 2, true)
      after = e2 and e2 + 2
    elseif n == "[" then
      local e2 = s:find("\\]", p + 2, true)
      after = e2 and e2 + 2
    else
      local m = s:match("^\\[a-zA-Z]+%*?", p)
      if not m then
        return nil
      end
      local q = p + #m
      while true do
        local arg = s:match("^%[[^%]%[\n{}]*%]", q) or s:match("^{[^{}\n]*}", q)
        if not arg then
          break
        end
        q = q + #arg
      end
      after = q
    end
  elseif s:sub(p + 1, p + 1) == "$" then
    local e2 = s:find("$$", p + 2, true)
    after = e2 and e2 + 2
  else
    if p > a and s:sub(p - 1, p - 1) == "$" then
      return nil
    end
    local n = s:sub(p + 1, p + 1)
    if n == "" or n:match("[ \t\n,%.;]") then
      return nil
    end
    local e2 = s:find("$", p + 1, true)
    if not e2 then
      return nil
    end
    local before = s:sub(e2 - 1, e2 - 1)
    if before:match("[ \t\n,%.]") then
      return nil
    end
    local nx = s:sub(e2 + 1, e2 + 1)
    if not (nx == "" or nx == "\n" or nx:match("[%p%s]")) then
      return nil
    end
    after = e2 + 1
  end
  if not after or after - 1 > b then
    return nil
  end
  local post = s:match("^[ \t]*", after)
  return { type = "latex-fragment", b = p, e = after + #post, value = s:sub(p, after - 1) }
end

function Lexer:entity(p)
  local s = self.s
  local name, after = s:match("^\\([a-zA-Z]+)()", p)
  if not name then
    return nil
  end
  local n = s:sub(after, after)
  if not (n == "" or n == "\n" or s:sub(after, after + 1) == "{}" or not n:match("%a")) then
    return nil
  end
  if not is_entity(name) then
    return nil
  end
  local stop = s:sub(after, after + 1) == "{}" and after + 2 or after
  local post = s:match("^[ \t]*", stop)
  return { type = "entity", b = p, e = stop + #post }
end

function Lexer:target(p)
  local s = self.s
  local radio = s:match("^<<<([^<>\n\r \t][^<>\n\r]-[^<>\n\r \t])>>>", p) or s:match("^<<<([^<>\n\r \t])>>>", p)
  if radio then
    local stop = p + #radio + 6
    local post = s:match("^[ \t]*", stop)
    return { type = "radio-target", b = p, e = stop + #post, value = radio, cb = p + 3, ce = p + 3 + #radio }
  end
  local v = s:match("^<<([^<>\n\r \t][^<>\n\r]-[^<>\n\r \t])>>", p) or s:match("^<<([^<>\n\r \t])>>", p)
  if not v then
    return nil
  end
  local stop = p + #v + 4
  local post = s:match("^[ \t]*", stop)
  return { type = "target", b = p, e = stop + #post, value = v }
end

function Lexer:inline_src(p, a, b)
  local s = self.s
  if p > a and word_char(s:sub(p - 1, p - 1)) then
    return nil
  end
  local lang, q = s:match("^[sS][rR][cC]_([^ \t\n%[{]+)()", p)
  if not lang then
    return nil
  end
  local o = { type = "inline-src-block", b = p, language = lang }
  if s:sub(q, q) == "[" then
    local c = balanced(s, q, "[", "]", b)
    if not c then
      return nil
    end
    o.parameters = nw(s:sub(q + 1, c - 1))
    q = c + 1
  end
  if s:sub(q, q) ~= "{" then
    return nil
  end
  local c = balanced(s, q, "{", "}", b)
  if not c then
    return nil
  end
  local post = s:match("^[ \t]*", c + 1)
  o.e = c + 1 + #post
  return o
end

function Lexer:inline_call(p, a, b)
  local s = self.s
  if p > a and word_char(s:sub(p - 1, p - 1)) then
    return nil
  end
  local name, q = s:match("^[cC][aA][lL][lL]_([^ \t\n%[%(]+)()", p)
  if not name then
    return nil
  end
  local o = { type = "inline-babel-call", b = p, call = name }
  if s:sub(q, q) == "[" then
    local c = balanced(s, q, "[", "]", b)
    if not c then
      return nil
    end
    o.inside_header = s:sub(q + 1, c - 1)
    q = c + 1
  end
  if s:sub(q, q) ~= "(" then
    return nil
  end
  local c = balanced(s, q, "(", ")", b)
  if not c then
    return nil
  end
  q = c + 1
  if s:sub(q, q) == "[" then
    local c2 = balanced(s, q, "[", "]", b)
    if c2 then
      o.end_header = nw(s:sub(q + 1, c2 - 1))
      q = c2 + 1
    end
  end
  local post = s:match("^[ \t]*", q)
  o.e = q + #post
  return o
end

function Lexer:snippet(p, b)
  local s = self.s
  local be, q = s:match("^@@([%w%-]+):()", p)
  if not be then
    return nil
  end
  local c = s:find("@@", q, true)
  if not c or c + 1 > b then
    return nil
  end
  local post = s:match("^[ \t]*", c + 2)
  return { type = "export-snippet", b = p, e = c + 2 + #post }
end

--- Next object at or after `p` in [p, b] (`org-element--object-lex`).
--- `restrict` flags disable object types (see `org-element-object-restrictions`).
function Lexer:next_object(p, a, b, restrict)
  local s = self.s
  local R = restrict
  while p <= b do
    local c = s:sub(p, p)
    local n = s:sub(p + 1, p + 1)
    local o
    local low = s:sub(p, p + 4):lower()
    if low == "call_" or low:sub(1, 4) == "src_" then
      if R.minimal then
        o = nil
      elseif low:sub(1, 4) == "src_" then
        o = not R.no_babel and self:inline_src(p, a, b) or nil
      else
        o = not R.no_babel and self:inline_call(p, a, b) or nil
      end
    elseif EMPH[c] and n ~= "" and not is_space(n) then
      o = self:emphasis(p, a, b)
    elseif c == "@" and n == "@" then
      o = not R.minimal and self:snippet(p, b) or nil
    elseif c == "{" and s:sub(p, p + 2) == "{{{" then
      o = not R.minimal and self:macro(p, b) or nil
    elseif c == "$" then
      o = self:latex(p, a, b)
    elseif c == "<" then
      if n == "<" then
        o = not R.no_targets and self:target(p) or nil
      elseif n == "%" or n:match("%d") then
        o = not R.no_timestamps and M._timestamp(s, p, b) or nil
        if o then
          o.type = "timestamp"
        end
      elseif not R.no_links then
        o = self:link(p, a, b)
      end
    elseif c == "\\" then
      if n:match("[%a%[%(]") then
        o = self:entity(p) or self:latex(p, a, b)
      end
    elseif c == "[" then
      if n == "[" then
        o = not R.no_links and self:link(p, a, b) or nil
      elseif s:sub(p, p + 3) == "[fn:" then
        o = not R.no_footnotes and self:footnote_ref(p, b) or nil
      elseif s:sub(p, p + 5) == "[cite:" or s:sub(p, p + 5) == "[cite/" then
        o = not R.no_citations and self:citation(p, b) or nil
      elseif n:match("%d") then
        o = not R.no_timestamps and M._timestamp(s, p, b) or nil
        if o then
          o.type = "timestamp"
        end
      end
    elseif c:match("%a") and not R.no_links then
      if p == a or not word_char(s:sub(p - 1, p - 1)) then
        o = self:link(p, a, b)
      end
    end
    if o then
      return o
    end
    p = p + 1
  end
  return nil
end

-- Restrictions of link descriptions and radio targets (minimal set plus
-- snippets, inline Babel and macros for links).
local LINK_RESTRICT = {
  no_links = true,
  no_timestamps = true,
  no_footnotes = true,
  no_targets = true,
  no_citations = true,
}
local MINIMAL_RESTRICT = {
  minimal = true,
  no_links = true,
  no_timestamps = true,
  no_footnotes = true,
  no_targets = true,
  no_citations = true,
}
local CELL_RESTRICT = { no_babel = true }

--- Parse objects in [a, b] of the container string, appending to the
--- document with `parent` as enclosing object.
function Lexer:parse(a, b, parent, restrict)
  local p = a
  local text_start = a
  while p <= b do
    local o = self:next_object(p, a, b, restrict)
    if not o then
      break
    end
    if o.b > text_start then
      self:add_text(text_start, o.b - 1, parent)
    end
    o.parent = parent
    self:add(o)
    if o.cb then
      local r = {}
      if o.type == "link" then
        r = LINK_RESTRICT
      elseif o.type == "radio-target" then
        r = MINIMAL_RESTRICT
      end
      self:parse(o.cb, o.ce - 1, o, r)
    end
    p = math.max(o.e, p + 1)
    text_start = p
  end
  if text_start <= b then
    self:add_text(text_start, b, parent)
  end
end

function Lexer:add(o)
  o.element = self.element
  o.pos = self.pos
  o.lnum, o.col = self.pos(o.b)
  o.s = self.s
  if o.type == "timestamp" then
    o.text = self.s:sub(o.b, o.e - 1)
  end
  local list = self.doc.objects
  list[#list + 1] = o
end

function Lexer:add_text(a, b, parent)
  local o = { type = "plain-text", b = a, e = b + 1, parent = parent, value = self.s:sub(a, b) }
  self:add(o)
end

--- Parse objects of a container made of `segments` ({line, col, text}).
function Doc:parse_objects(segments, element, restrict)
  local parts, starts = {}, {}
  local off = 1
  for i, seg in ipairs(segments) do
    starts[i] = off
    parts[#parts + 1] = seg.text
    off = off + #seg.text + 1
  end
  local s = table.concat(parts, "\n")
  if #s == 0 then
    return
  end
  local function pos(o)
    for i = #segments, 1, -1 do
      if o >= starts[i] then
        return segments[i].line, segments[i].col + (o - starts[i])
      end
    end
    return segments[1].line, segments[1].col
  end
  local lx = setmetatable({
    s = s,
    doc = self,
    element = element,
    pos = pos,
    expand_abbrev = self.expand_abbrev,
  }, Lexer)
  lx:parse(1, #s, nil, restrict or {})
end

function Doc:collect_objects()
  local L = self.lines
  -- Parsed affiliated keywords (CAPTION) are not traversed: the checkers
  -- call `org-element-map' without WITH-AFFILIATED.
  for _, el in ipairs(self.elements) do
    if el.type == "paragraph" then
      local segs = {}
      for k = el.cbegin, el.cend do
        local c = k == el.cbegin and el.ccol or 1
        segs[#segs + 1] = { line = k, col = c, text = L[k]:sub(c) }
      end
      self:parse_objects(segs, el)
    elseif el.type == "item" and el.item.tag then
      local l = L[el.begin]
      local tstart = l:find(el.item.tag, 1, true)
      if tstart then
        self:parse_objects({ { line = el.begin, col = tstart, text = el.item.tag } }, el)
      end
    elseif el.type == "headline" then
      local r = el.title_range
      if r[2] >= r[1] then
        self:parse_objects({ { line = el.begin, col = r[1], text = L[el.begin]:sub(r[1], r[2]) } }, el)
      end
    elseif el.type == "verse-block" and el.vbegin then
      local segs = {}
      for k = el.vbegin, el.vend do
        segs[#segs + 1] = { line = k, col = 1, text = L[k] }
      end
      self:parse_objects(segs, el)
    elseif el.type == "table-row" then
      local l = L[el.begin]
      if not l:match("^[ \t]*|%-") then
        local p = l:find("|", 1, true) + 1
        while p <= #l do
          local bar = l:find("|", p, true)
          local cell_end = (bar or #l + 1) - 1
          local cs, ce = p, cell_end
          while cs <= ce and l:sub(cs, cs):match("[ \t]") do
            cs = cs + 1
          end
          while ce >= cs and l:sub(ce, ce):match("[ \t]") do
            ce = ce - 1
          end
          if ce >= cs then
            self:parse_objects({ { line = el.begin, col = cs, text = l:sub(cs, ce) } }, el, CELL_RESTRICT)
          end
          if not bar then
            break
          end
          p = bar + 1
        end
      end
    end
  end
end

--- Innermost element containing (lnum, col), like `org-element-at-point`.
function Doc:element_at(lnum, col)
  col = col or 1
  local function covers(el)
    if lnum < el.begin or lnum >= el.stop then
      return false
    end
    if lnum == el.begin and el.col > 1 and col < el.col then
      return false
    end
    return true
  end
  local node = self.root
  local found = nil
  while true do
    local next_node
    for _, ch in ipairs(node.children) do
      if covers(ch) then
        next_node = ch
      end
    end
    if not next_node then
      return found
    end
    found = next_node
    -- descend only inside the contents
    if not next_node.cbegin or #next_node.children == 0 then
      return found
    end
    if lnum < next_node.cbegin or (lnum == next_node.cbegin and next_node.ccol > 1 and col < next_node.ccol) then
      return found
    end
    node = next_node
  end
end

--- TODO keywords when #+SETUPFILE files define some (the buffer's own
--- settings do not follow setup files). nil otherwise.
function M._setup_todo(lines, dir)
  local seqs, from_setup = {}, false
  local seen = {}
  local function scan(ls, d, depth)
    for _, l in ipairs(ls) do
      local key, value = l:match("^#%+(%S-):[ \t]*(.-)[ \t]*$")
      key = key and key:upper()
      if key == "TODO" or key == "SEQ_TODO" or key == "TYP_TODO" then
        seqs[#seqs + 1] = value
        from_setup = from_setup or depth > 0
      elseif key == "SETUPFILE" and depth < 5 then
        local f = value:match('^"(.*)"$') or value
        if not f:match("^%a[%w+%.%-]*://") then
          if f:sub(1, 2) == "~/" then
            f = (vim.uv.os_homedir() or "~") .. f:sub(2)
          elseif not f:match("^/") then
            f = d .. "/" .. f
          end
          f = vim.fs.normalize(f)
          if not seen[f] and vim.uv.fs_stat(f) then
            seen[f] = true
            local ok, fl = pcall(vim.fn.readfile, f)
            if ok then
              scan(fl, vim.fn.fnamemodify(f, ":h"), depth + 1)
            end
          end
        end
      end
    end
  end
  scan(lines, dir, 0)
  if not from_setup then
    return nil
  end
  return require("org.todo_keywords").new(seqs)
end

--- Parse buffer lines into a document.
---@param lines string[]
---@param opts? { file?: table, dir?: string, bufnr?: integer, filename?: string }
function M.parse(lines, opts)
  opts = opts or {}
  local doc = setmetatable({
    lines = lines,
    elements = {},
    objects = {},
    file = opts.file,
    dir = opts.dir,
    bufnr = opts.bufnr,
    filename = opts.filename,
  }, Doc)
  local abbrevs = opts.file and opts.file.settings.link_abbrevs or {}
  doc.expand_abbrev = function(raw)
    local name = raw:match("^([%w_%-]+):") or raw
    if abbrevs[name] or (require("org.config").opts.links.abbreviations or {})[name] then
      local ok, links = pcall(require, "org.links")
      if ok then
        return links.expand_abbrev(raw, opts.file)
      end
    end
    return raw
  end
  local types = vim.deepcopy(LINK_TYPES)
  for t in pairs(require("org.config").opts.links.types or {}) do
    types[#types + 1] = t
  end
  doc.link_types = types
  doc.todo = M._setup_todo(lines, opts.dir or vim.fn.getcwd())
  doc.root = new_el("org-data", { begin = 1, post = 1, last = #lines, stop = #lines + 1 })
  local s = doc:skip_blank(1, #lines)
  doc:parse_region(s, #lines, "first-section", doc.root)
  doc:collect_objects()
  return doc
end

---------------------------------------------------------------------------
-- Checker helpers
---------------------------------------------------------------------------

local function map_type(doc, t)
  local out = {}
  local set = type(t) == "table" and t or { [t] = true }
  for _, el in ipairs(doc.elements) do
    if set[el.type] then
      out[#out + 1] = el
    end
  end
  return out
end

local function map_objects(doc, t)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == t then
      out[#out + 1] = o
    end
  end
  return out
end

local function aff_value(el, key)
  local v
  for _, a in ipairs(el.aff) do
    if a.key == key then
      v = a
    end
  end
  return v
end

local function aff_values(el, key)
  local out = {}
  for _, a in ipairs(el.aff) do
    if a.key == key then
      out[#out + 1] = a.value
    end
  end
  return out
end

--- Report at the start of an element.
local function at_begin(el, msg)
  return { el.begin, el.begin == el.post and el.col or 1, msg }
end

local function at_post(el, msg)
  return { el.post, el.post == el.begin and el.col or 1, msg }
end

local function at_obj(o, msg)
  return { o.lnum, o.col, msg }
end

--- `org-lint--collect-duplicates`
local function collect_duplicates(items, key_of, pos_of, msg_of)
  local keys, originals, reports = {}, {}, {}
  local seen_orig = {}
  for _, it in ipairs(items) do
    local key = key_of(it)
    if key ~= nil then
      local id = type(key) == "table" and table.concat(key, "\0") or key
      if keys[id] then
        if not seen_orig[id] then
          seen_orig[id] = true
          originals[#originals + 1] = { id = id, key = key }
        end
        table.insert(reports, 1, { pos = pos_of(it, key), key = key })
      else
        keys[id] = pos_of(it, key)
      end
    end
  end
  for _, o in ipairs(originals) do
    table.insert(reports, 1, { pos = keys[o.id], key = o.key })
  end
  local out = {}
  for _, r in ipairs(reports) do
    out[#out + 1] = { r.pos[1], r.pos[2], msg_of(r.key) }
  end
  return out
end

--- `org-babel-balanced-split` on "[ \t]:".
local function balanced_split(str)
  local result, partial = {}, {}
  local i, n = 1, #str
  local function flush()
    if #partial > 0 then
      result[#result + 1] = table.concat(partial)
      partial = {}
    end
  end
  while i <= n do
    local ch = str:sub(i, i)
    local prev = i > 1 and str:sub(i - 1, i - 1) or nil
    if (prev == " " or prev == "\t") and ch == ":" then
      table.remove(partial)
      flush()
      i = i + 1
    elseif ch == "(" or ch == "[" then
      local openings = { ch }
      local j = i + 1
      while #openings > 0 and j <= n do
        local cj = str:sub(j, j)
        if cj == "[" or cj == "(" then
          openings[#openings + 1] = cj
        elseif cj == "]" then
          if openings[#openings] == "[" then
            table.remove(openings)
          end
        elseif cj == ")" then
          if openings[#openings] == "(" then
            table.remove(openings)
          end
        end
        j = j + 1
      end
      if #openings == 0 then
        partial[#partial + 1] = str:sub(i, j - 1)
        i = j
      else
        partial[#partial + 1] = ch
        i = i + 1
      end
    elseif ch == '"' and prev ~= "\\" then
      local j = i + 1
      local close
      while j <= n do
        if str:sub(j, j) == '"' and str:sub(j - 1, j - 1) ~= "\\" then
          close = j
          break
        end
        j = j + 1
      end
      if close then
        partial[#partial + 1] = str:sub(i, close)
        i = close + 1
      else
        partial[#partial + 1] = ch
        i = i + 1
      end
    else
      partial[#partial + 1] = ch
      i = i + 1
    end
  end
  flush()
  return result
end

--- `org-babel-read` with Lisp evaluation inhibited.
local function babel_read(cell)
  if not nw(cell) then
    return cell
  end
  local t = trim(cell)
  if not t:match("%s") and cell:match("^[0-9e%.%+ %-]+$") then
    local n = tonumber(t)
    if n then
      return n
    end
  end
  local q = cell:match('^%s*"(.*)"%s*$')
  if q and not q:find('[^\\]"') and not q:match('^"') then
    return (q:gsub('\\(.)', "%1"))
  end
  return cell
end

--- `org-babel-parse-header-arguments` (no-eval): list of { name, value }
--- where `name` keeps its leading colon.
local function parse_header_args(str)
  if not nw(str) then
    return {}
  end
  local raw = balanced_split(str)
  local out = {}
  for idx, arg in ipairs(raw) do
    if idx > 1 then
      arg = ":" .. arg
    end
    local name, value = arg:match("^([^ \f\t\n\r\v]+)[ \f\t\n\r\v]+([^ \f\t\n\r\v]+.*)$")
    if name then
      out[#out + 1] = { name = name, value = babel_read((value:gsub("[ \f\t\n\r\v]+$", ""))) }
    else
      out[#out + 1] = { name = (arg:gsub("[ \f\t\n\r\v]+$", "")), value = nil }
    end
  end
  -- org-babel-parse-multiple-vars: split ":var a=1 b=2" in several :var
  local expanded = {}
  for _, h in ipairs(out) do
    if h.name == ":var" and type(h.value) == "string" then
      local ok, parts = pcall(function()
        local res = {}
        for _, v in ipairs(balanced_split(" :" .. h.value:gsub("([%s])([%w_%-]+=)", "%1:%2"))) do
          res[#res + 1] = trim(v)
        end
        return res
      end)
      if ok and #parts > 1 then
        for _, v in ipairs(parts) do
          expanded[#expanded + 1] = { name = ":var", value = v }
        end
      else
        expanded[#expanded + 1] = h
      end
    else
      expanded[#expanded + 1] = h
    end
  end
  return expanded
end
M._parse_header_args = parse_header_args

local function header_values_for(lang)
  local out = {}
  for _, e in ipairs(lang and LANG_HEADER_ARGS[lang] or {}) do
    out[#out + 1] = e
  end
  for _, e in ipairs(COMMON_HEADER_VALUES) do
    out[#out + 1] = e
  end
  return out
end

local function assoc_values(list, name)
  for _, e in ipairs(list) do
    if e[1] == name then
      return e[2]
    end
  end
  return nil
end

local function expand_home(path)
  if path:sub(1, 1) == "~" then
    local user, rest = path:match("^~([^/]*)(.*)$")
    if user == "" then
      return (vim.uv.os_homedir() or "~") .. rest
    end
  end
  return path
end

local function file_exists(doc, path)
  if path == nil or path == "" then
    return false
  end
  local p = expand_home(path)
  if not p:match("^/") and not p:match("^%a:[/\\]") then
    p = (doc.dir or vim.fn.getcwd()) .. "/" .. p
  end
  return vim.uv.fs_stat(p) ~= nil
end

local function is_remote(path)
  return path:match("^/[%w%-_%.]+:") ~= nil or path:match("^/%a+:[^/]*:") ~= nil
end

local function is_url(path)
  return path:match("^%a[%w+%.%-]*://") ~= nil
end

local function strip_quotes(s)
  local q = s:match('^"(.*)"$')
  return q or s
end

local function prev_sibling(el)
  local p = el.parent
  if not p then
    return nil
  end
  local prev
  for _, c in ipairs(p.children) do
    if c == el then
      return prev
    end
    prev = c
  end
end

local function ancestor(el, t)
  local p = el.parent
  while p do
    if p.type == t then
      return p
    end
    p = p.parent
  end
end

local function headline_of(el)
  return el.type == "headline" and el or ancestor(el, "headline")
end

local function headline_properties(doc, h)
  local props = {}
  if not h or not h.cbegin then
    return props
  end
  for _, sec in ipairs(h.children) do
    if sec.type == "section" then
      for _, c in ipairs(sec.children) do
        if c.type == "property-drawer" then
          for _, np in ipairs(c.children) do
            if np.key then
              props[np.key:upper()] = np.value
            end
          end
        end
      end
    end
  end
  return props
end

--- Resolve a fuzzy search like `org-export-resolve-fuzzy-link`.
local function search_cells_index(doc)
  if doc._cells then
    return doc._cells
  end
  local idx = {}
  local function add(kind, words)
    idx[kind .. "\0" .. table.concat(words, "\0")] = true
  end
  local function split(s)
    local w = {}
    for x in s:gmatch("%S+") do
      w[#w + 1] = x
    end
    return w
  end
  for _, el in ipairs(doc.elements) do
    if el.type == "headline" then
      local t = el.raw_value:gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " ")
      local words = split(t:upper())
      add("headline", words)
      add("other", words)
    else
      local name = aff_value(el, "NAME")
      local res = aff_value(el, "RESULTS")
      local n = (name and name.value) or (res and res.value)
      if n and n ~= "" then
        add("other", split(n))
      end
    end
  end
  for _, o in ipairs(doc.objects) do
    if o.type == "target" then
      add("target", split(o.value:upper()))
    end
  end
  doc._cells = idx
  return idx
end

local function resolve_fuzzy(doc, path)
  local idx = search_cells_index(doc)
  local function split(s)
    local w = {}
    for x in s:gmatch("%S+") do
      w[#w + 1] = x
    end
    return w
  end
  if path:sub(1, 1) == "*" then
    return idx["headline\0" .. table.concat(split(path:sub(2):upper()), "\0")] or false
  end
  local w = split(path)
  local up = split(path:upper())
  return idx["target\0" .. table.concat(w, "\0")]
    or idx["other\0" .. table.concat(w, "\0")]
    or idx["target\0" .. table.concat(up, "\0")]
    or idx["other\0" .. table.concat(up, "\0")]
    or false
end

local function local_ids(doc)
  if doc._ids then
    return doc._ids
  end
  local ids = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    local props = headline_properties(doc, h)
    if props.ID then
      ids[props.ID] = h
    end
    if props.CUSTOM_ID then
      ids[props.CUSTOM_ID] = h
    end
  end
  doc._ids = ids
  return ids
end

-- Languages whose Emacs editing mode has no same-named Vim filetype
-- (true: known without a filetype).
local LANG_MODES = {
  ["emacs-lisp"] = true,
  elisp = true,
  org = true,
  calc = true,
  authinfo = true,
  cfengine = true,
  cfengine3 = true,
  makefile = "make",
  screen = "sh",
  shell = "sh",
  sqlite = "sql",
  asymptote = "asy",
  C = "c",
  ["C++"] = "cpp",
  ["c++"] = "cpp",
  D = "d",
  R = "r",
}

--- Language known to Babel or with an editing mode (a Vim filetype),
--- like `org-babel-execute:LANG' or `org-src-get-lang-mode-if-bound'.
local known_cache = {}
local function known_language_uncached(lang)
  local mode = LANG_MODES[lang]
  if mode == true then
    return true
  end
  local ok, langs = pcall(require, "org.babel.langs")
  if ok and lang == lang:lower() and langs.family(lang) ~= "generic" then
    return true
  end
  local sok, syntax = pcall(require, "org.syntax")
  if sok and syntax.lang_aliases[lang] then
    return true
  end
  local ft = mode or lang
  return #vim.api.nvim_get_runtime_file("syntax/" .. ft .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("syntax/" .. ft .. ".lua", false) > 0
    or #vim.api.nvim_get_runtime_file("ftplugin/" .. ft .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("ftplugin/" .. ft .. ".lua", false) > 0
end

local function known_language(lang)
  local cfg = require("org.config").opts
  if (cfg.babel and cfg.babel.languages or {})[lang] then
    return true
  end
  if known_cache[lang] == nil then
    known_cache[lang] = known_language_uncached(lang) and true or false
  end
  return known_cache[lang]
end

local function src_headers(el)
  local out = {}
  for _, h in ipairs(parse_header_args(el.parameters)) do
    out[#out + 1] = h
  end
  for _, v in ipairs(aff_values(el, "HEADER")) do
    for _, h in ipairs(parse_header_args(v)) do
      out[#out + 1] = h
    end
  end
  return out
end

local function call_headers(o)
  local out = {}
  for _, h in ipairs(parse_header_args(o.inside_header)) do
    out[#out + 1] = h
  end
  for _, h in ipairs(parse_header_args(o.end_header)) do
    out[#out + 1] = h
  end
  return out
end

--- Babel-header carriers: { datum, lnum, col, language, headers }.
local function babel_data(doc, with_keywords)
  local out = {}
  for _, el in ipairs(doc.elements) do
    if el.type == "src-block" then
      out[#out + 1] = {
        el = el,
        lnum = el.post,
        col = 1,
        lang = el.language,
        headers = src_headers(el),
        kind = "src-block",
      }
    elseif el.type == "babel-call" then
      out[#out + 1] = { el = el, lnum = el.post, col = 1, headers = call_headers(el), kind = "babel-call" }
    elseif with_keywords and el.type == "keyword" and el.key == "PROPERTY" then
      local lang, rest = el.value:match("^header%-args:(%S+)%+ *(.*)$")
      if not lang then
        rest = el.value:match("^header%-args%+ *(.*)$")
      end
      if not rest then
        lang, rest = el.value:match("^header%-args:(%S+) *(.*)$")
      end
      if not rest then
        rest = el.value:match("^header%-args *(.*)$")
      end
      if rest then
        out[#out + 1] = {
          el = el,
          lnum = el.post,
          col = 1,
          lang = lang,
          headers = parse_header_args(rest),
          kind = "keyword",
        }
      end
    elseif with_keywords and el.type == "node-property" and el.key then
      local k = el.key:upper()
      local lang = k:match("^HEADER%-ARGS:(%S+)")
      if lang or k:match("^HEADER%-ARGS") then
        if lang then
          lang = el.key:match("^[^:]+:(%S+)")
        end
        out[#out + 1] = {
          el = el,
          lnum = el.post,
          col = 1,
          lang = lang,
          headers = parse_header_args(el.value),
          kind = "node-property",
        }
      end
    end
  end
  for _, o in ipairs(doc.objects) do
    if o.type == "inline-src-block" then
      out[#out + 1] = {
        el = o,
        lnum = o.lnum,
        col = o.col,
        lang = o.language,
        headers = parse_header_args(o.parameters),
        kind = "inline-src-block",
      }
    elseif o.type == "inline-babel-call" then
      out[#out + 1] = { el = o, lnum = o.lnum, col = o.col, headers = call_headers(o), kind = "inline-babel-call" }
    end
  end
  table.sort(out, function(x, y)
    if x.lnum ~= y.lnum then
      return x.lnum < y.lnum
    end
    return x.col < y.col
  end)
  return out
end

local function priority_bounds(doc)
  local p = doc.file and doc.file:priorities()
    or { highest = require("org.config").opts.priority_highest, lowest = require("org.config").opts.priority_lowest }
  local function val(x)
    x = tostring(x)
    return tonumber(x) or x:byte()
  end
  return val(p.highest), val(p.lowest)
end

local function footnote_section_name()
  local s = require("org.config").opts.footnote_section
  if s == nil then
    return "Footnotes"
  end
  return s or nil
end

---------------------------------------------------------------------------
-- Checkers
---------------------------------------------------------------------------

local C = {}

C["misplaced-heading"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local init = 1
    while true do
      local s, e = l:find("[^%*\r ,]%*%*+ ", init)
      if not s then
        break
      end
      local el = doc:element_at(lnum, e + 1)
      if el and (el.type == "paragraph" or el.type == "headline") then
        table.insert(out, 1, { lnum, s, "Possibly misplaced heading line" })
      end
      init = e + 1
    end
  end
  return out
end

C["duplicate-custom-id"] = function(doc)
  return collect_duplicates(map_type(doc, "node-property"), function(p)
    return p.key and p.key:upper() == "CUSTOM_ID" and p.value or nil
  end, function(p)
    return { p.begin, 1 }
  end, function(k)
    return string.format('Duplicate CUSTOM_ID property "%s"', k)
  end)
end

C["duplicate-name"] = function(doc)
  local L = doc.lines
  return collect_duplicates(doc.elements, function(el)
    local a = aff_value(el, "NAME")
    return a and a.value or nil
  end, function(el, name)
    for k = el.begin, #L do
      local v = L[k]:match("^[ \t]*#%+[A-Za-z]+:[ \t]*(.-)[ \t]*$")
      if v == name then
        return { k, 1 }
      end
    end
    return { el.begin, 1 }
  end, function(k)
    return string.format('Duplicate NAME "%s"', k)
  end)
end

C["duplicate-target"] = function(doc)
  return collect_duplicates(map_objects(doc, "target"), function(o)
    local w = {}
    for x in o.value:gmatch("%S+") do
      w[#w + 1] = x
    end
    return w
  end, function(o)
    return { o.lnum, o.col }
  end, function(k)
    return string.format("Duplicate target <<%s>>", table.concat(k, " "))
  end)
end

C["duplicate-footnote-definition"] = function(doc)
  return collect_duplicates(map_type(doc, "footnote-definition"), function(el)
    return el.label
  end, function(el)
    return { el.post, 1 }
  end, function(k)
    return string.format('Duplicate footnote definition "%s"', k)
  end)
end

C["orphaned-affiliated-keywords"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if (k.key:match("^ATTR_[%-_A-Za-z0-9]+$") or (AFFILIATED[k.key] and k.key ~= "RESULT" and k.key ~= "RESULTS")) then
      out[#out + 1] = at_post(k, string.format('Orphaned affiliated keyword: "%s"', k.key))
    end
  end
  return out
end

C["combining-keywords-with-affiliated"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.post_blank == 0 and k.last + 1 <= #doc.lines then
      local nxt = doc:element_at(k.last + 1, 1)
      if nxt and nxt ~= k and nxt.begin ~= k.begin and nxt.begin < nxt.post then
        out[#out + 1] = at_begin(
          k,
          string.format("Independent keyword %s may be confused with affiliated keywords below", k.key)
        )
      end
    end
  end
  return out
end

C["obsolete-affiliated-keywords"] = function(doc)
  local out = {}
  local repl = { HEADERS = "HEADER", RESULT = "RESULTS" }
  for lnum, l in ipairs(doc.lines) do
    local key, e = l:match("^[ \t]*#%+([%a]+):()")
    local up = key and key:upper()
    if up and (TRANSLATION[up]) then
      local el = doc:element_at(lnum, e)
      if el and el.post > lnum then
        table.insert(out, 1, {
          lnum,
          1,
          string.format('Obsolete affiliated keyword: "%s".  Use "%s" instead', up, repl[up] or "NAME"),
        })
      end
    end
  end
  return out
end

C["deprecated-export-blocks"] = function(doc)
  local dep = { "ASCII", "BEAMER", "HTML", "LATEX", "MAN", "MARKDOWN", "MD", "ODT", "ORG", "TEXINFO" }
  local out = {}
  for _, b in ipairs(map_type(doc, "special-block")) do
    if contains(dep, b.block_type:upper()) then
      out[#out + 1] = at_post(
        b,
        string.format('Deprecated syntax for export block.  Use "BEGIN_EXPORT %s" instead', b.block_type)
      )
    end
  end
  return out
end

C["deprecated-header-syntax"] = function(doc)
  local props = {}
  for _, e in ipairs(COMMON_HEADER_VALUES) do
    if e[1] ~= "dir" then
      props[#props + 1] = e[1]
    end
  end
  local out = {}
  for _, el in ipairs(doc.elements) do
    if el.type == "keyword" and el.key == "PROPERTY" then
      -- regexp-opt: longest alternative wins
      local best
      local low = el.value:lower()
      for _, p in ipairs(props) do
        if low:sub(1, #p) == p and low:sub(#p + 1, #p + 1):match("^[ \t]$") and (not best or #p > #best) then
          best = p
        end
      end
      if best then
        out[#out + 1] = at_begin(
          el,
          string.format('Deprecated syntax for "%s".  Use header-args instead', el.value:sub(1, #best))
        )
      end
    elseif el.type == "node-property" and el.key then
      for _, p in ipairs(props) do
        if el.key:lower() == p then
          out[#out + 1] = at_begin(el, string.format('Deprecated syntax for "%s".  Use :header-args: instead', el.key))
          break
        end
      end
    end
  end
  return out
end

C["missing-language-in-src-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "src-block")) do
    if not b.language then
      out[#out + 1] = at_post(b, "Missing language in source block")
    end
  end
  return out
end

C["suspicious-language-in-src-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "src-block")) do
    if b.language and not known_language(b.language) then
      out[#out + 1] = at_post(b, string.format("Unknown source block language: '%s'", b.language))
    end
  end
  return out
end

C["missing-backend-in-export-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "export-block")) do
    if not b.backend then
      out[#out + 1] = at_post(b, "Missing backend in export block")
    end
  end
  return out
end

C["invalid-babel-call-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "babel-call")) do
    if not b.call then
      out[#out + 1] = at_post(b, "Invalid syntax in babel call block")
    elseif b.end_header and b.end_header:match("^%[.*%]$") then
      out[#out + 1] = at_post(b, "Babel call's end header must not be wrapped within brackets")
    end
  end
  return out
end

C["wrong-header-argument"] = function(doc)
  local out = {}
  for _, d in ipairs(babel_data(doc, true)) do
    local allowed = {}
    for _, n in ipairs(HEADER_ARG_NAMES) do
      allowed[n] = true
    end
    for _, lang in ipairs(d.lang and { d.lang } or LOADED_LANGUAGES) do
      for _, e in ipairs(LANG_HEADER_ARGS[lang] or {}) do
        allowed[e[1]] = true
      end
    end
    for _, h in ipairs(d.headers) do
      if h.name:sub(1, 1) ~= ":" then
        table.insert(out, 1, { d.lnum, d.col, string.format('Missing colon in header argument "%s"', h.name) })
      elseif not allowed[h.name:sub(2)] then
        table.insert(out, 1, { d.lnum, d.col, string.format('Unknown header argument "%s"', h.name) })
      end
    end
  end
  return out
end

C["wrong-header-value"] = function(doc)
  local out = {}
  for _, d in ipairs(babel_data(doc, false)) do
    local allowed_list = header_values_for(d.lang)
    local joined
    if d.kind == "src-block" then
      local parts = { d.el.parameters or "" }
      for _, v in ipairs(aff_values(d.el, "HEADER")) do
        parts[#parts + 1] = v
      end
      joined = table.concat(parts, " ")
    elseif d.kind == "inline-src-block" then
      joined = d.el.parameters or ""
    else
      joined = (d.el.inside_header or "") .. " " .. (d.el.end_header or "")
    end
    for _, h in ipairs(parse_header_args(trim(joined))) do
      local allowed = assoc_values(allowed_list, h.name:sub(2))
      if type(allowed) == "table" then
        local vals
        if type(h.value) == "string" then
          vals = vim.split(trim(h.value), "%s+", { trimempty = true })
        else
          vals = { h.value == nil and vim.NIL or h.value }
        end
        local groups = {}
        for _, v in ipairs(vals) do
          local valid = false
          local forbidden = false
          for gi, group in ipairs(allowed) do
            local member = false
            if type(v) == "string" then
              for _, g in ipairs(group) do
                if g ~= ANY and tostring(g) == v then
                  member = true
                end
              end
            end
            if not member then
              if contains(group, ANY) then
                valid = true
                groups[gi] = v
              end
            elseif groups[gi] ~= nil then
              table.insert(out, 1, {
                d.lnum,
                d.col,
                string.format(
                  'Forbidden combination in header "%s": %s, %s',
                  h.name,
                  groups[gi] == vim.NIL and "nil" or tostring(groups[gi]),
                  v == vim.NIL and "nil" or tostring(v)
                ),
              })
              forbidden = true
              break
            else
              groups[gi] = v
              valid = true
            end
          end
          if not forbidden and not valid then
            table.insert(out, 1, {
              d.lnum,
              d.col,
              string.format('Unknown value "%s" for header "%s"', v == vim.NIL and "nil" or tostring(v), h.name),
            })
          end
        end
      end
    end
  end
  return out
end

--- Header arguments in effect for a src block (defaults, #+PROPERTY,
--- inherited HEADER-ARGS properties, #+HEADER lines, block parameters).
local function src_block_args(doc, el)
  local args = { exports = "code" }
  local lang = el.language
  local function apply(str)
    for _, h in ipairs(parse_header_args(str)) do
      if h.name:sub(1, 1) == ":" then
        args[h.name:sub(2)] = type(h.value) == "string" and h.value or tostring(h.value)
      end
    end
  end
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "PROPERTY" then
      local rest = k.value:match("^header%-args +(.*)$") or k.value:match("^header%-args%+ +(.*)$")
      if rest then
        apply(rest)
      end
      if lang then
        local l2, r2 = k.value:match("^header%-args:(%S-)%+? +(.*)$")
        if l2 == lang then
          apply(r2)
        end
      end
    end
  end
  local chain = {}
  local h = headline_of(el)
  while h do
    table.insert(chain, 1, h)
    h = ancestor(h, "headline")
  end
  for _, hl in ipairs(chain) do
    local props = headline_properties(doc, hl)
    if props["HEADER-ARGS"] then
      apply(props["HEADER-ARGS"])
    end
    if lang and props["HEADER-ARGS:" .. lang:upper()] then
      apply(props["HEADER-ARGS:" .. lang:upper()])
    end
  end
  for _, v in ipairs(aff_values(el, "HEADER")) do
    apply(v)
  end
  apply(el.parameters)
  return args
end

C["named-result"] = function(doc)
  local out = {}
  for _, el in ipairs(doc.elements) do
    local res = aff_value(el, "RESULTS")
    local name = aff_value(el, "NAME")
    if res and name then
      local origin
      if nw(res.value) then
        local v = res.value
        if v:sub(1, 1) == "#" then
          origin = local_ids(doc)[v:sub(2)]
        elseif v:match("^id:") then
          origin = local_ids(doc)[v:sub(4)]
        else
          -- resolve to the element (target, named element or headline)
          local up = v:upper()
          for _, cand in ipairs(doc.elements) do
            local n = aff_value(cand, "NAME")
            if cand ~= el and n and (n.value == v or n.value:upper() == up) then
              origin = cand
              break
            end
          end
        end
      else
        origin = prev_sibling(el)
      end
      if origin and origin.type == "src-block" then
        local exports = src_block_args(doc, origin).exports
        if exports ~= "results" and exports ~= "both" then
          out[#out + 1] = at_begin(
            el,
            string.format(
              'Links to "%s" will not be valid during export unless the parent source block has '
                .. ":exports results or both",
              name.value
            )
          )
        end
      end
    end
  end
  return out
end

C["empty-header-argument"] = function(doc)
  local out = {}
  for _, d in ipairs(babel_data(doc, false)) do
    for _, h in ipairs(d.headers) do
      if h.value == nil then
        table.insert(out, 1, { d.lnum, d.col, string.format('Empty value in header argument "%s"', h.name) })
      end
    end
  end
  return out
end

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

local function coderef_resolves(doc, ref)
  for _, el in ipairs(map_type(doc, { ["src-block"] = true, ["example-block"] = true })) do
    local fmt = el.label_fmt or "(ref:%s)"
    local label = fmt:gsub("%%s", function()
      return ref
    end)
    for l in (trim(el.value or "") .. "\n"):gmatch("([^\n]*)\n") do
      local s = l:find(label, 1, true)
      while s do
        if l:sub(s + #label):match("^[ \t]*$") then
          return true
        end
        s = l:find(label, s + 1, true)
      end
    end
  end
  return false
end

local function links(doc, t)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == "link" and (not t or o.link_type == t) then
      out[#out + 1] = o
    end
  end
  return out
end

C["invalid-coderef-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "coderef")) do
    if not coderef_resolves(doc, o.path) then
      out[#out + 1] = at_obj(o, string.format('Unknown coderef "%s"', o.path))
    end
  end
  return out
end

C["invalid-custom-id-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "custom-id")) do
    if not local_ids(doc)[o.path] then
      out[#out + 1] = at_obj(o, string.format('Unknown custom ID "%s"', o.path))
    end
  end
  return out
end

C["invalid-fuzzy-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "fuzzy")) do
    if not resolve_fuzzy(doc, o.path) then
      local p = o.path:sub(1, 1) == "*" and o.path:sub(2) or o.path
      out[#out + 1] = at_obj(o, string.format('Unknown fuzzy location "%s"', p))
    end
  end
  return out
end

C["invalid-id-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "id")) do
    local found = false
    for _, h in ipairs(map_type(doc, "headline")) do
      if headline_properties(doc, h).ID == o.path then
        found = true
        break
      end
    end
    if not found then
      local ok, id = pcall(require, "org.id")
      if ok then
        local okf, loc = pcall(id.find, o.path)
        found = okf and loc ~= nil
      end
    end
    if not found then
      out[#out + 1] = at_obj(o, string.format('Unknown ID "%s"', o.path))
    end
  end
  return out
end

C["trailing-bracket-after-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.s:sub(o.e, o.e) == "]" then
      out[#out + 1] = at_obj(o, "Trailing ']' after link end")
    end
  end
  return out
end

C["unclosed-brackets-in-link-description"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.cb then
      local desc = o.s:sub(o.cb, o.ce - 1)
      local count = 0
      for ch in desc:gmatch("[%[%]]") do
        count = count + (ch == "[" and 1 or -1)
      end
      if count > 0 then
        out[#out + 1] = at_obj(o, "No closing ']' matches '[' in link description: " .. desc)
      end
    end
  end
  return out
end

local function in_link(o)
  local p = o.parent
  while p do
    if p.type == "link" then
      return true
    end
    p = p.parent
  end
  return false
end

--- `substitute-env-in-file-name`
local function substitute_env(s)
  s = s:gsub("%$%$", "\0")
  s = s:gsub("%${([%w_]+)}", function(v)
    return os.getenv(v) or ("${" .. v .. "}")
  end)
  s = s:gsub("%$([%w_]+)", function(v)
    return os.getenv(v) or ("$" .. v)
  end)
  return (s:gsub("%z", "$"))
end

C["link-to-local-file"] = function(doc)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == "link" and (o.link_type == "file" or o.link_type == "attachment") then
      local path = o.path
      local file = path
      if o.link_type == "attachment" then
        path = path:match("^(.-)::.*$") or path
        local dir
        local ok, attach = pcall(require, "org.attach")
        if ok and doc.bufnr then
          local okd, d = pcall(attach.dir_for, { bufnr = doc.bufnr, lnum = o.lnum })
          dir = okd and d or nil
        end
        file = dir and (dir .. "/" .. path) or path
      end
      file = substitute_env(file)
      if not is_remote(file) and not file_exists(doc, file) then
        local fmt = in_link(o) and "Link to non-existent image file %s in description"
          or "Link to non-existent local file %s"
        out[#out + 1] = at_obj(o, string.format(fmt, lisp_str(file)))
      end
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
local function link_search(lines, search)
  local file = M.parse(lines, {})
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
            local lines
            if file then
              local p = expand_home(file)
              if not p:match("^/") then
                p = (doc.dir or vim.fn.getcwd()) .. "/" .. p
              end
              local okr, l = pcall(vim.fn.readfile, p)
              lines = okr and l or {}
            else
              lines = doc.lines
            end
            if not link_search(lines, search) then
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
  local seen_files = {}
  local function collect(lines, dir)
    for _, l in ipairs(lines) do
      local key, value = l:match("^[ \t]*#%+(%S-):[ \t]*(.-)[ \t]*$")
      key = key and key:upper()
      if key == "MACRO" then
        local name, tmpl = value:match("^(%S+)%s*(.*)$")
        if name then
          defined[#defined + 1] = { name, trim(tmpl) }
        end
      elseif key == "SETUPFILE" then
        local f = expand_home(strip_quotes(value))
        if not is_url(f) then
          if not f:match("^/") then
            f = dir .. "/" .. f
          end
          f = vim.fs.normalize(f)
          if not seen_files[f] and vim.uv.fs_stat(f) then
            seen_files[f] = true
            local ok, flines = pcall(vim.fn.readfile, f)
            if ok then
              collect(flines, vim.fn.fnamemodify(f, ":h"))
            end
          end
        end
      end
    end
  end
  collect(doc.lines, doc.dir or vim.fn.getcwd())
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

C["special-property-in-properties-drawer"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    if np.key and contains(SPECIAL_PROPERTIES, np.key:upper()) then
      out[#out + 1] = at_begin(np, string.format('Special property "%s" found in a properties drawer', np.key))
    end
  end
  return out
end

C["obsolete-properties-drawer"] = function(doc)
  local out = {}
  for _, d in ipairs(map_type(doc, "drawer")) do
    if d.name == "PROPERTIES" then
      -- `before' is always nil in Emacs (assq on nodes), hence "contents"
      out[#out + 1] = at_post(d, "Incorrect contents for PROPERTIES drawer")
    end
  end
  return out
end

local function duration_p(s)
  local units = { "min", "h", "d", "w", "m", "y" }
  local function unit_prefix(str, p)
    local n = str:match("^%d+%.?%d*", p)
    if not n then
      return nil
    end
    local q = p + #n
    q = q + #str:match("^[ \t]*", q)
    local best
    for _, u in ipairs(units) do
      if str:sub(q, q + #u - 1) == u and (not best or #u > #best) then
        best = u
      end
    end
    if not best then
      return nil
    end
    return q + #best
  end
  -- full: (?:[ \t]*UNIT)+[ \t]*
  local function units_run(str, p)
    local q = p
    local count = 0
    while true do
      local ws = str:match("^[ \t]*", q)
      local nq = unit_prefix(str, q + #ws)
      if not nq then
        break
      end
      q = nq
      count = count + 1
    end
    return count > 0 and q or nil
  end
  local q = units_run(s, 1)
  if q and s:sub(q):match("^[ \t]*$") then
    return true
  end
  if q then
    local rest = s:sub(q):match("^[ \t]*(.*)$")
    if rest:match("^%d+:%d%d[ \t]*$") or rest:match("^%d+:%d%d:%d%d[ \t]*$") then
      return true
    end
  end
  return s:match("^[ \t]*%d+:%d%d[ \t]*$") ~= nil or s:match("^[ \t]*%d+:%d%d:%d%d[ \t]*$") ~= nil
end
M._duration_p = duration_p

C["invalid-effort-property"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    if np.key == "EFFORT" and nw(np.value) and not duration_p(np.value) then
      out[#out + 1] = at_begin(np, string.format("Invalid effort duration format: %s", lisp_str(np.value)))
    end
  end
  return out
end

C["invalid-id-property"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    if np.key == "ID" and nw(np.value) and np.value:find("::", 1, true) then
      out[#out + 1] = at_begin(np, string.format('IDs should not include "::": %s', lisp_str(np.value)))
    end
  end
  return out
end

C["undefined-footnote-reference"] = function(doc)
  local defs = {}
  for _, el in ipairs(doc.elements) do
    if el.type == "footnote-definition" then
      defs[el.label] = true
    end
  end
  for _, o in ipairs(map_objects(doc, "footnote-reference")) do
    if o.ref_type == "inline" and o.label then
      defs[o.label] = true
    end
  end
  local out = {}
  for _, o in ipairs(map_objects(doc, "footnote-reference")) do
    if o.ref_type == "standard" and not defs[o.label] then
      out[#out + 1] = at_obj(o, string.format("Missing definition for footnote [%s]", o.label))
    end
  end
  return out
end

C["unreferenced-footnote-definition"] = function(doc)
  local refs = {}
  for _, o in ipairs(map_objects(doc, "footnote-reference")) do
    if o.label then
      refs[o.label] = true
    end
  end
  local out = {}
  for _, el in ipairs(map_type(doc, "footnote-definition")) do
    if el.label and not refs[el.label] then
      out[#out + 1] = at_post(el, string.format("No reference for footnote definition [%s]", el.label))
    end
  end
  return out
end

C["extraneous-element-in-footnote-section"] = function(doc)
  local name = footnote_section_name()
  if not name then
    return {}
  end
  local ok_types = {
    comment = true,
    ["comment-block"] = true,
    ["footnote-definition"] = true,
    ["property-drawer"] = true,
    section = true,
  }
  local out = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    if h.raw_value == name then
      local found = false
      local function walk(node)
        for _, c in ipairs(node.children) do
          if found then
            return
          end
          if not ok_types[c.type] and not (c.type == "headline" and c.commented) then
            found = true
            return
          end
          if c.type ~= "footnote-definition" and c.type ~= "property-drawer" then
            walk(c)
          end
        end
      end
      walk(h)
      if found then
        out[#out + 1] = at_begin(h, "Extraneous elements in footnote section are not exported")
      end
    end
  end
  return out
end

C["invalid-keyword-syntax"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local name = l:match("^[ \t]*#%+([^%s:]*) ") or l:match("^[ \t]*#%+([^%s:]*)$")
    if name then
      local up = name:upper()
      local exception = l:match("^[ \t]*#%+[Cc][Aa][Pp][Tt][Ii][Oo][Nn]%[.*%]:")
        or l:match("^[ \t]*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]%[.*%]:")
      if exception then
        local after = l:match("%]:(.*)$")
        exception = after == "" or after:match("^ ") ~= nil
      end
      if up:sub(1, 5) ~= "BEGIN" and up:sub(1, 3) ~= "END" and not exception then
        table.insert(out, 1, { lnum, 1, string.format('Possible missing colon in keyword "%s"', name) })
      end
    end
  end
  return out
end

C["invalid-image-alignment"] = function(doc)
  local out = {}
  for _, p in ipairs(map_type(doc, "paragraph")) do
    local vals = aff_values(p, "ATTR_ORG")
    local ks = vals[1]
    if ks then
      local reports = {}
      local align = ks:match(":align%s+(%S+)")
      if align and not contains({ "left", "center", "right" }, align) then
        table.insert(
          reports,
          1,
          at_begin(p, string.format('"%s" not a supported value for #+ATTR_ORG keyword attribute ":align".', align))
        )
      end
      local center = ks:match(":center%s+(%S+)")
      if center and center ~= "t" then
        table.insert(
          reports,
          1,
          at_begin(p, string.format('"%s" not a supported value for #+ATTR_ORG keyword attribute ":center".', center))
        )
      end
      vim.list_extend(out, reports)
    end
  end
  return out
end

local BLOCK_TYPES = {
  ["center-block"] = true,
  ["comment-block"] = true,
  ["dynamic-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["quote-block"] = true,
  ["special-block"] = true,
  ["src-block"] = true,
  ["verse-block"] = true,
}

C["invalid-block"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local pre, kw = l:match("^([ \t]*#%+)(%a+)")
    local upkw = kw and kw:upper() or ""
    local which = (upkw:sub(1, 5) == "BEGIN" and "BEGIN") or (upkw:sub(1, 3) == "END" and "END") or nil
    if which then
      local p = #pre + #which + 1
      local c = l:sub(p, p)
      if c == ":" then
        p = p + 1
      elseif c == "_" then
        p = p + #l:match("^_[^%s]*", p)
      end
      p = p + #l:match("^[ \t]*", p)
      local name = trim(l)
      if which == "END" and p <= #l then
        table.insert(out, 1, { lnum, 1, string.format('Invalid block closing line "%s"', name) })
      else
        local el = doc:element_at(lnum, p)
        if not (el and BLOCK_TYPES[el.type]) then
          table.insert(out, 1, { lnum, 1, string.format('Possible incomplete block "%s"', name) })
        end
      end
    end
  end
  return out
end

C["mismatched-planning-repeaters"] = function(doc)
  local out = {}
  for _, p in ipairs(map_type(doc, "planning")) do
    local s, d = p.scheduled, p.deadline
    local function cum(ts)
      return ts and (ts.repeater_type == "cumulate" or ts.repeater_type == "catch-up")
    end
    if s and d and cum(s) and cum(d) and s.repeater_value > 0 and d.repeater_value > 0 then
      local same = s.repeater_type == d.repeater_type
        and s.repeater_unit == d.repeater_unit
        and s.repeater_value == d.repeater_value
      if not same then
        out[#out + 1] = at_begin(p, "Different repeaters in SCHEDULED and DEADLINE timestamps.")
      end
    end
  end
  return out
end

local VERBATIM_BLOCKS = {
  ["comment-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["src-block"] = true,
  ["verse-block"] = true,
}

C["misplaced-planning-info"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local ll = l:lower()
    local e = ll:match("^[ \t]*closed:()") or ll:match("^[ \t]*deadline:()") or ll:match("^[ \t]*scheduled:()")
    if e then
      local el = doc:element_at(lnum, e)
      if not (el and (VERBATIM_BLOCKS[el.type] or el.type == "planning")) then
        table.insert(out, 1, { lnum, 1, "Misplaced planning info line" })
      end
    end
  end
  return out
end

C["incomplete-drawer"] = function(doc)
  local out = {}
  local L = doc.lines
  local lnum = 1
  while lnum <= #L do
    local l = L[lnum]
    local nm = match_drawer(l)
    local nextl = lnum + 1
    if nm then
      local name = trim(l)
      local el = doc:element_at(lnum, #l + 1)
      local t = el and el.type
      if t == "drawer" then
        if el.cbegin then
          for x = math.max(lnum + 1, el.cbegin), el.end_line - 1 do
            if match_drawer(L[x]) then
              table.insert(out, 1, { x, 1, string.format("Possible misleading drawer entry %s", lisp_str(trim(L[x]))) })
            end
          end
        end
        nextl = el.stop
      elseif t == "property-drawer" then
        nextl = el.stop
      elseif not VERBATIM_BLOCKS[t] then
        table.insert(out, 1, { lnum, 1, string.format("Possible incomplete drawer %s", lisp_str(name)) })
      end
    end
    lnum = math.max(nextl, lnum + 1)
  end
  return out
end

C["indented-diary-sexp"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local e = l:match("^[ \t]+%%%%%(()")
    if e then
      local el = doc:element_at(lnum, e)
      if not (el and (VERBATIM_BLOCKS[el.type] or el.type == "diary-sexp")) then
        table.insert(out, 1, { lnum, 1, "Possible indented diary-sexp" })
      end
    end
  end
  return out
end

C["quote-section"] = function(doc)
  local out = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    if h.raw_value:sub(1, 6) == "QUOTE " or h.raw_value:sub(1, 14) == "COMMENT QUOTE " then
      out[#out + 1] = at_begin(h, "Deprecated QUOTE section")
    end
  end
  return out
end

C["file-application"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.application then
      out[#out + 1] = at_obj(o, string.format('Deprecated "file+%s" link type', o.application))
    end
  end
  return out
end

C["percent-encoding-link-escape"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.format == "bracket" then
      local uri = o.path
      local obsolete = uri:find("%", 1, true) ~= nil
      local start = 1
      while true do
        local s = uri:find("%", start, true)
        if not s then
          break
        end
        local code = uri:sub(s + 1, s + 2)
        local nl = code:find("\n", 1, true)
        if #code < 2 or nl then
          code = nil
        end
        start = s + 1 + (code and 2 or 0)
        if not (code and contains({ "25", "5B", "5D", "20" }, code)) then
          obsolete = false
          break
        end
      end
      if obsolete then
        out[#out + 1] = at_obj(o, "Link escaped with obsolete percent-encoding syntax")
      end
    end
  end
  return out
end

C["spurious-colons"] = function(doc)
  local out = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    if contains(h.tags, "") then
      out[#out + 1] = at_begin(h, "Tags contain a spurious colon")
    end
  end
  return out
end

C["non-existent-bibliography"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "BIBLIOGRAPHY" then
      local file = strip_quotes(k.value)
      if not is_remote(file) and not file_exists(doc, file) then
        out[#out + 1] = at_begin(k, string.format("Non-existent bibliography %s", lisp_str(file)))
      end
    end
  end
  return out
end

C["missing-print-bibliography"] = function(doc)
  if #map_objects(doc, "citation") == 0 then
    return {}
  end
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "PRINT_BIBLIOGRAPHY" then
      return {}
    end
  end
  local n = #doc.lines
  local lnum = doc.eol == false and math.max(n, 1) or n + 1
  local col = doc.eol == false and #(doc.lines[n] or "") + 1 or 1
  return { { lnum, col, 'Possibly missing "PRINT_BIBLIOGRAPHY" keyword' } }
end

C["invalid-cite-export-declaration"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "CITE_EXPORT" then
      local v = k.value
      if v == "" then
        out[#out + 1] = at_begin(k, "Missing export processor name")
      else
        local tokens = {}
        local p = 1
        local bad = false
        while p <= #v do
          p = p + #v:match("^[ \t]*", p)
          if p > #v then
            break
          end
          if v:sub(p, p) == '"' then
            local c = v:find('"', p + 1, true)
            if not c then
              bad = true
              break
            end
            tokens[#tokens + 1] = { quoted = true, text = v:sub(p + 1, c - 1) }
            p = c + 1
          else
            local t = v:match("^[^ \t]+", p)
            tokens[#tokens + 1] = { text = t }
            p = p + #t
          end
        end
        local name = tokens[1]
        if
          bad
          or #tokens > 3
          or name.quoted
          or tonumber(name.text)
          or name.text:match("[%(%)%[%]\"';`,#]")
        then
          out[#out + 1] = at_begin(k, "Invalid cite export processor declaration")
        elseif not CITE_PROCESSORS[name.text] then
          out[#out + 1] = at_begin(k, string.format("Unknown cite export processor %s", name.text))
        end
      end
    end
  end
  return out
end

C["incomplete-citation"] = function(doc)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == "plain-text" and (o.value:find("%[cite:") or o.value:find("%[cite/[%w/_%-]+:")) then
      local parent = o.parent
      if parent and parent.cb then
        -- contents-begin of the enclosing object
        local lnum, col = parent.pos(parent.cb)
        out[#out + 1] = { lnum, col, "Possibly incomplete citation markup" }
      else
        local el = o.element
        if el.type == "headline" then
          local cb = el.cbegin or el.begin
          out[#out + 1] = { cb, 1, "Possibly incomplete citation markup" }
        elseif el.type == "paragraph" then
          out[#out + 1] = { el.cbegin, el.ccol, "Possibly incomplete citation markup" }
        else
          out[#out + 1] = { o.lnum, o.col, "Possibly incomplete citation markup" }
        end
      end
    end
  end
  return out
end

C["item-number"] = function(doc)
  local out = {}
  for _, it in ipairs(map_type(doc, "item")) do
    local st = it.item
    if not st.counter then
      local bullet = st.bullet
      local bn
      local letter = bullet:match("%a")
      if letter then
        bn = letter:upper():byte() - 64
      elseif bullet:match("%d+") then
        bn = tonumber(bullet:match("%d+"))
      end
      if bn then
        -- relative number among siblings (counters restart the count)
        local siblings = {}
        for _, c in ipairs(it.parent.children) do
          if c.type == "item" then
            siblings[#siblings + 1] = c
          end
        end
        local idx
        for x, c in ipairs(siblings) do
          if c == it then
            idx = x
          end
        end
        local seq, counter = 0, nil
        local x = idx
        while x >= 1 do
          counter = siblings[x].item.counter
          if counter then
            break
          end
          x = x - 1
          if x >= 1 then
            seq = seq + 1
          end
        end
        local true_n
        if not counter then
          true_n = seq + 1
        elseif counter:match("%a") then
          true_n = counter:match("%a"):upper():byte() - 64 + seq
        else
          true_n = tonumber(counter:match("%d+")) + seq
        end
        if bn ~= true_n then
          out[#out + 1] = at_begin(
            it,
            string.format(
              'Bullet counter "%s" is not the same with item position %d.  Consider adding manual [@%d] counter.',
              bullet,
              true_n,
              bn
            )
          )
        end
      end
    end
  end
  return out
end

C["priority"] = function(doc)
  local out = {}
  local hi, lo = priority_bounds(doc)
  local function valid(p, ignore_bounds)
    if not ((p >= 0 and p <= 64) or (p >= 65 and p <= 90)) then
      return false
    end
    return ignore_bounds or (lo >= p and p >= hi)
  end
  for _, h in ipairs(map_type(doc, "headline")) do
    local p = h.priority
    if p then
      if not valid(p) and valid(p, true) then
        local s = p <= 64 and tostring(p) or string.char(p)
        out[#out + 1] = at_begin(h, string.format("Out-of-bounds priority '%s'", s))
      end
    else
      local whole, g1, g2 = h.raw_value:match("^(%[#([^%[%]]*)(%]*))")
      if whole then
        if g2 == "" then
          out[#out + 1] = at_begin(h, string.format("Malformed priority '%s'", whole))
        else
          out[#out + 1] = at_begin(h, string.format("Invalid priority '%s'", g1))
        end
      end
    end
  end
  return out
end

C["LaTeX-$-fragment"] = function(doc)
  local out = {}
  for _, o in ipairs(map_objects(doc, "latex-fragment")) do
    if o.value:match("^%$[^%$]") then
      out[#out + 1] = at_obj(o, "Potentially confusing LaTeX fragment format.  Prefer using more reliable \\(...\\)")
    end
  end
  return out
end

-- Objects whose contents cannot hold a LaTeX fragment.
local NO_LATEX = {
  verbatim = true,
  code = true,
  timestamp = true,
  macro = true,
  ["inline-src-block"] = true,
  ["inline-babel-call"] = true,
  ["export-snippet"] = true,
  entity = true,
  target = true,
}

C["LaTeX-$"] = function(doc)
  local out = {}
  local containers = {
    paragraph = true,
    headline = true,
    keyword = true,
    ["table-row"] = true,
    ["verse-block"] = true,
    item = true,
  }
  for lnum, l in ipairs(doc.lines) do
    local init = 1
    while true do
      local s, e = l:find("%$%.%d", init)
      if not s then
        break
      end
      local point = e + 1
      local el = doc:element_at(lnum, point)
      if el and containers[el.type] then
        local ok = true
        for _, o in ipairs(doc.objects) do
          if o.lnum == lnum and o.element == el and NO_LATEX[o.type] then
            local len = o.e - o.b - (o.post_blank or 0)
            if o.col <= point and point < o.col + len then
              ok = false
            end
          end
        end
        if ok then
          table.insert(out, 1, {
            lnum,
            point,
            "$ symbol potentially matching LaTeX fragment boundary.  Consider using \\dollar entity.",
          })
        end
      end
      init = e + 1
    end
  end
  return out
end

C["beamer-frame"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local init = 1
    while true do
      local s, e = l:find("\\begin{" .. BEAMER_FRAME_ENVIRONMENT .. "}", init, true)
      local s2, e2 = l:find("\\end{" .. BEAMER_FRAME_ENVIRONMENT .. "}", init, true)
      if s2 and (not s or s2 < s) then
        s, e = s2, e2
      end
      if not s then
        break
      end
      table.insert(out, 1, {
        lnum,
        s,
        "Beamer frame name may cause error when exporting.  Consider customizing `org-beamer-frame-environment'.",
      })
      init = e + 1
    end
  end
  return out
end

C["timestamp-syntax"] = function(doc)
  local out = {}
  for _, o in ipairs(map_objects(doc, "timestamp")) do
    local expected = interpret_timestamp(o)
    if expected then
      expected = expected .. string.rep(" ", o.post_blank or 0)
      local actual = o.text
      if expected ~= actual then
        out[#out + 1] = at_obj(o, string.format("Potentially malformed timestamp %s.  Parsed as: %s", actual, expected))
      end
    end
  end
  return out
end

C["clock-syntax"] = function(doc)
  local out = {}
  for _, c in ipairs(map_type(doc, "clock")) do
    local l = doc.lines[c.begin]
    local p = l:find(":", 1, true) + 1
    p = p + #l:match("^[ \t]*", p)
    local ts = M._timestamp(l, p, #l)
    local duration
    local arrow = l:find("=> ", 1, true)
    if arrow then
      local q = arrow + 3
      q = q + #l:match("^[ \t]*", q)
      duration = l:sub(q):match("^(%S+)[ \t]*$")
    end
    local interp = interpret_timestamp(ts)
    local expected = "CLOCK: " .. (interp or "")
    if duration then
      local parts = {}
      for x in duration:gmatch("[^:]+") do
        parts[#parts + 1] = x
      end
      if #parts >= 2 then
        expected = expected .. " => " .. string.format("%2s:%2s", parts[1], parts[2])
      end
    end
    expected = expected:gsub("[ \t\n]+$", "")
    local actual = trim(l)
    if expected ~= actual then
      out[#out + 1] = at_begin(
        c,
        string.format("Potentially malformed CLOCK: line\n           %s\nParsed as: %s", actual, expected)
      )
    end
  end
  return out
end

C["planning-inactive"] = function(doc)
  local out = {}
  for _, p in ipairs(map_type(doc, "planning")) do
    local function inactive(ts)
      return ts and (ts.kind == "inactive" or ts.kind == "inactive-range")
    end
    if inactive(p.scheduled) then
      out[#out + 1] = at_begin(p, "Inactive timestamp in SCHEDULED will not appear in agenda.")
    elseif inactive(p.deadline) then
      out[#out + 1] = at_begin(p, "Inactive timestamp in DEADLINE will not appear in agenda.")
    end
  end
  return out
end

--- Checkers in Emacs registration order: name, trust, summary.
M.checkers = {
  { "misplaced-heading", "low", "Report accidentally misplaced heading lines." },
  { "duplicate-custom-id", "high", "Report duplicate CUSTOM_ID properties" },
  { "duplicate-name", "high", "Report duplicate NAME values" },
  { "duplicate-target", "high", "Report duplicate targets" },
  { "duplicate-footnote-definition", "high", "Report duplicate footnote definitions" },
  { "orphaned-affiliated-keywords", "low", "Report orphaned affiliated keywords" },
  { "combining-keywords-with-affiliated", "low", "Report independent keywords preceding affiliated keywords." },
  { "obsolete-affiliated-keywords", "high", "Report obsolete affiliated keywords" },
  { "deprecated-export-blocks", "low", "Report deprecated export block syntax" },
  { "deprecated-header-syntax", "low", "Report deprecated Babel header syntax" },
  { "missing-language-in-src-block", "high", "Report missing language in source blocks" },
  { "suspicious-language-in-src-block", "low", "Report suspicious language in source blocks" },
  { "missing-backend-in-export-block", "high", "Report missing backend in export blocks" },
  { "invalid-babel-call-block", "high", "Report invalid Babel call blocks" },
  { "wrong-header-argument", "high", "Report wrong babel headers" },
  { "wrong-header-value", "low", "Report invalid value in babel headers" },
  { "named-result", "high", "Report results evaluation with #+name keyword." },
  { "empty-header-argument", "low", "Report empty values in babel headers" },
  { "deprecated-category-setup", "high", "Report misuse of CATEGORY keyword" },
  { "invalid-coderef-link", "high", 'Report "coderef" links with unknown destination' },
  { "invalid-custom-id-link", "high", 'Report "custom-id" links with unknown destination' },
  { "invalid-fuzzy-link", "high", 'Report "fuzzy" links with unknown destination' },
  { "invalid-id-link", "high", 'Report "id" links with unknown destination' },
  { "trailing-bracket-after-link", "low", "Report potentially confused trailing ']' after link." },
  { "unclosed-brackets-in-link-description", "low", "Report unclosed '[' in link description." },
  { "link-to-local-file", "low", "Report links to non-existent local files" },
  { "non-existent-setupfile-parameter", "low", "Report SETUPFILE keywords with non-existent file parameter" },
  { "wrong-include-link-parameter", "low", "Report INCLUDE keywords with misleading link parameter" },
  { "obsolete-include-markup", "low", "Report obsolete markup in INCLUDE keyword" },
  { "unknown-options-item", "low", "Report unknown items in OPTIONS keyword" },
  { "misspelled-export-option", "low", "Report potentially misspelled export options in properties." },
  { "invalid-macro-argument-and-template", "low", "Report spurious macro arguments or invalid macro templates" },
  { "special-property-in-properties-drawer", "high", "Report special properties in properties drawers" },
  { "obsolete-properties-drawer", "high", "Report obsolete syntax for properties drawers" },
  { "invalid-effort-property", "high", "Report invalid duration in EFFORT property" },
  { "invalid-id-property", "high", 'Report search string delimiter "::" in ID property' },
  { "undefined-footnote-reference", "high", "Report missing definition for footnote references" },
  { "unreferenced-footnote-definition", "high", "Report missing reference for footnote definitions" },
  { "extraneous-element-in-footnote-section", "high", "Report non-footnote definitions in footnote section" },
  { "invalid-keyword-syntax", "low", "Report probable invalid keywords" },
  { "invalid-image-alignment", "high", "Report unsupported align attribute for keyword" },
  { "invalid-block", "low", "Report invalid blocks" },
  { "mismatched-planning-repeaters", "low", "Report mismatched repeaters in planning info line" },
  { "misplaced-planning-info", "low", "Report misplaced planning info line" },
  { "incomplete-drawer", "low", "Report probable incomplete drawers" },
  { "indented-diary-sexp", "low", "Report probable indented diary-sexps" },
  { "quote-section", "low", "Report obsolete QUOTE section" },
  { "file-application", "high", 'Report obsolete "file+application" link' },
  { "percent-encoding-link-escape", "low", "Report obsolete escape syntax in links" },
  { "spurious-colons", "high", "Report spurious colons in tags" },
  { "non-existent-bibliography", "high", "Report invalid bibliography file" },
  { "missing-print-bibliography", "high", 'Report missing "print_bibliography" keyword' },
  { "invalid-cite-export-declaration", "high", 'Report invalid value for "cite_export" keyword' },
  { "incomplete-citation", "low", "Report incomplete citation object" },
  { "item-number", "high", "Report inconsistent item numbers in lists" },
  { "priority", "high", "Report out-of-bounds, invalid, and malformed priorities." },
  { "LaTeX-$-fragment", "high", "Report potentially confusing $...$ LaTeX markup.", default = false },
  { "LaTeX-$", "low", "Report $ that might be treated as LaTeX fragment boundary." },
  { "beamer-frame", "low", "Report that frame text contains beamer frame environment." },
  { "timestamp-syntax", "low", "Report malformed timestamps." },
  { "clock-syntax", "low", "Report malformed clocks." },
  { "planning-inactive", "high", "Report inactive timestamps in SCHEDULED/DEADLINE." },
}

--- Names of the checkers run by default.
---@return string[]
function M.checker_names()
  local out = {}
  for _, c in ipairs(M.checkers) do
    if c.default ~= false then
      out[#out + 1] = c[1]
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

--- Lint an org buffer (org-lint).
---@param bufnr? integer default current buffer
---@param checkers? string[] checker names (default: all the default checkers)
---@return org.LintReport[] reports sorted by position
function M.lint(bufnr, checkers)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local file
  local ok, files = pcall(require, "org.files")
  if ok then
    local okf, f = pcall(files.get_buffer, bufnr)
    file = okf and f or nil
  end
  local doc = M.parse(lines, {
    file = file,
    bufnr = bufnr,
    filename = name,
    dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd(),
  })
  doc.eol = vim.bo[bufnr].eol or vim.bo[bufnr].fixeol
  local wanted
  if checkers then
    wanted = {}
    for _, n in ipairs(checkers) do
      wanted[n] = true
    end
  end
  -- Emacs keeps its checkers in reverse registration order; reports on
  -- the same position keep that order (stable sort).
  local reports = {}
  for idx = #M.checkers, 1, -1 do
    local c = M.checkers[idx]
    if (wanted and wanted[c[1]]) or (not wanted and c.default ~= false) then
      local okc, res = pcall(C[c[1]], doc)
      if okc then
        for _, r in ipairs(res) do
          reports[#reports + 1] = { lnum = r[1], col = r[2], checker = c[1], message = r[3], trust = c[2] }
        end
      else
        reports[#reports + 1] = {
          lnum = 1,
          col = 1,
          checker = c[1],
          message = "Checker error: " .. tostring(res),
          trust = c[2],
        }
      end
    end
  end
  for i, r in ipairs(reports) do
    r._i = i
  end
  table.sort(reports, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a._i < b._i
  end)
  for _, r in ipairs(reports) do
    r._i = nil
  end
  return reports
end

--- Lint the current buffer and show the reports in the location list
--- (the Neovim counterpart of Emacs' "*Org Lint*" report buffer).
---@param checkers? string[] restrict to these checker names
---@return org.LintReport[]|nil
function M.show(checkers)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "org" then
    require("org.utils").warn("Not in an Org buffer")
    return nil
  end
  if checkers then
    local known = {}
    for _, c in ipairs(M.checkers) do
      known[c[1]] = true
    end
    for _, n in ipairs(checkers) do
      if not known[n] then
        require("org.utils").warn("Unknown org-lint checker: " .. n)
        return nil
      end
    end
  end
  local reports = M.lint(bufnr, checkers)
  local last = vim.api.nvim_buf_line_count(bufnr)
  local items = {}
  for _, r in ipairs(reports) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = math.min(r.lnum, last),
      col = r.col,
      text = r.checker .. ": " .. r.message:gsub("%s*\n%s*", " "),
      type = r.trust == "low" and "W" or "E",
    }
  end
  vim.fn.setloclist(0, {}, " ", { title = "org-lint", items = items })
  if #items == 0 then
    require("org.utils").notify("org-lint: no problems found")
  else
    vim.cmd("lopen")
  end
  return reports
end

--- `:Org lint [checker ...]`
---@param args? string checker names separated by spaces
function M.command(args)
  local names = vim.split(args or "", "%s+", { trimempty = true })
  return M.show(#names > 0 and names or nil)
end

return M
