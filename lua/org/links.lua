---@mod org.links Hyperlinks
---
--- Supports bracket links `[[target][description]]`, `[[target]]`, angle
--- links `<https://...>`, plain links (`https://...`, `file:...`) and radio
--- targets `<<<text>>>`. Link types follow Emacs: http(s), ftp, mailto,
--- news, doi, file, id, shell, help, man, info, attachment, `#custom-id`,
--- `*heading`, coderef `(label)`, fuzzy (dedicated `<<target>>`, `#+NAME:`,
--- headline, text), abbreviations (`#+LINK:` / `links.abbreviations`) and
--- custom types (`links.types`).

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

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
  ["file+sys"] = true,
  ["file+emacs"] = true,
}

-- Files Neovim cannot display usefully open with the system application.
-- Emacs (org-file-apps) opens .pdf, .html and .mm files with the system
-- application and everything else in Emacs, which can display images and
-- office documents; Neovim cannot, so those go to the system app too.
local EXTERNAL_EXT = {
  pdf = true, png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true,
  mp3 = true, mp4 = true, mkv = true, mov = true, avi = true, wav = true, flac = true, ogg = true,
  doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true, odt = true, ods = true,
  zip = true, epub = true, dmg = true, html = true, htm = true, xhtml = true, mm = true,
}

local ZWSP = "\226\128\139" -- U+200B ZERO WIDTH SPACE

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

---------------------------------------------------------------------------
-- Strings
---------------------------------------------------------------------------

--- Remove backslash escapes (org-link-unescape): a run of backslashes
--- before a bracket or at the end is halved.
function M.unescape(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local bs = s:match("^\\+", i)
    if bs then
      local nxt = s:sub(i + #bs, i + #bs)
      if nxt == "" or nxt == "[" or nxt == "]" then
        out[#out + 1] = string.rep("\\", math.floor(#bs / 2))
      else
        out[#out + 1] = bs
      end
      i = i + #bs
    else
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end
local unescape = M.unescape

--- Escape a link target for use inside [[...]] (org-link-escape):
--- backslashes before a bracket or at the end are doubled, and brackets
--- get a backslash.
function M.escape(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local bs = s:match("^\\*", i)
    local nxt = s:sub(i + #bs, i + #bs)
    if nxt == "[" or nxt == "]" then
      out[#out + 1] = bs .. bs .. "\\" .. nxt
      i = i + #bs + 1
    elseif nxt == "" then
      out[#out + 1] = bs .. bs
      i = n + 1
    elseif bs ~= "" then
      out[#out + 1] = bs
      i = i + #bs
    else
      out[#out + 1] = nxt
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Remove statistics cookies and collapse blanks (org-link--normalize-string).
--- With `context`, also strip surrounding parentheses and leading `#`/`*`.
function M.normalize_string(s, context)
  s = s:gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " ")
  s = vim.trim((s:gsub("[ \t]+", " ")))
  if context then
    while true do
      if s:sub(1, 1) == "(" and s:sub(-1) == ")" and #s >= 2 then
        s = vim.trim(s:sub(2, -2))
      elseif s:match("^[#*]+[ \t]*") then
        s = s:gsub("^[#*]+[ \t]*", "", 1)
      else
        break
      end
    end
  end
  return s
end

--- Replace bracket links in `s` by their description, or their target
--- (org-link-display-format).
function M.display_format(s)
  local out, init = {}, 1
  for _, l in ipairs(M.parse_links(s, { bracket_only = true })) do
    out[#out + 1] = s:sub(init, l.start_col - 1)
    out[#out + 1] = l.desc or l.raw_target
    init = l.end_col + 1
  end
  out[#out + 1] = s:sub(init)
  return table.concat(out)
end

local function split_words(s)
  return vim.split(vim.trim(s), "%s+", { trimempty = true })
end

local function upper_words(s)
  return vim.tbl_map(string.upper, split_words(s))
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local PLAIN_BAD = "[%s%[%]()<>]"

--- End of a plain link path starting at `i` (org-link-plain-re): balanced
--- parentheses (two levels) are allowed, and the link cannot end with
--- punctuation other than `/` or a closing parenthesis group.
local function scan_plain(text, i)
  local j, last = i, nil
  local n = #text
  while j <= n do
    local c = text:sub(j, j)
    if c == "(" then
      local k, closed = j + 1, false
      while k <= n do
        local d = text:sub(k, k)
        if d == ")" then
          closed = true
          break
        elseif d == "(" then
          local e = text:find(PLAIN_BAD, k + 1)
          if e and text:sub(e, e) == ")" then
            k = e + 1
          else
            break
          end
        elseif d:match(PLAIN_BAD) then
          break
        else
          k = k + 1
        end
      end
      if not closed then
        break
      end
      last = k
      j = k + 1
    elseif c:match(PLAIN_BAD) then
      break
    else
      if c == "/" or not c:match("%p") then
        last = j
      end
      j = j + 1
    end
  end
  return last
end

--- Parse every link in `text` (normally one line; bracket links may span
--- lines when `text` has several). Returns a list sorted by position.
---@param text string
---@param popts? { bracket_only?: boolean }
---@return org.Link[]
function M.parse_links(text, popts)
  popts = popts or {}
  local out = {}
  local covered = {}
  local function cover(s, e)
    for i = s, e do
      covered[i] = true
    end
  end
  -- bracket links
  local init = 1
  while true do
    local s = text:find("[[", init, true)
    if not s then
      break
    end
    -- find end of target (unescaped "]")
    local i = s + 2
    local target_end
    while i <= #text do
      local c = text:sub(i, i)
      if c == "\\" then
        local bs = text:match("^\\+", i)
        i = i + #bs
        if #bs % 2 == 1 and text:sub(i, i):match("[%[%]]") then
          i = i + 1
        end
      elseif c == "]" then
        target_end = i - 1
        break
      elseif c == "[" then
        break
      else
        i = i + 1
      end
    end
    local raw_target = target_end and text:sub(s + 2, target_end) or ""
    if not target_end or raw_target:match("^%s*$") then
      init = s + 2
    else
      local after = text:sub(target_end + 1, target_end + 2)
      local target = unescape(raw_target):gsub("[ \t]*\n[ \t]*", " ")
      if after == "]]" then
        out[#out + 1] = {
          raw = text:sub(s, target_end + 2),
          target = target,
          raw_target = raw_target,
          start_col = s,
          end_col = target_end + 2,
        }
        cover(s, target_end + 2)
        init = target_end + 3
      elseif after == "][" then
        local de = text:find("]]", target_end + 4, true)
        if de then
          out[#out + 1] = {
            raw = text:sub(s, de + 1),
            target = target,
            raw_target = raw_target,
            desc = text:sub(target_end + 3, de - 1),
            desc_start = target_end + 3,
            start_col = s,
            end_col = de + 1,
          }
          cover(s, de + 1)
          init = de + 2
        else
          init = s + 2
        end
      else
        init = s + 2
      end
    end
  end
  if not popts.bracket_only then
    -- angle links <type:path>
    init = 1
    while true do
      local s, e, inner = text:find("<([%a][%w+%-]*:[^>\n]+)>", init)
      if not s then
        break
      end
      local scheme = inner:match("^([%a][%w+%-]*):")
      if not covered[s] and is_type(scheme) then
        out[#out + 1] = { raw = text:sub(s, e), target = inner, start_col = s, end_col = e, angle = true }
        cover(s, e)
      end
      init = e + 1
    end
    -- plain links type:path
    init = 1
    while true do
      local s, colon, scheme = text:find("%f[%w]([%a][%w+%-]*):", init)
      if not s then
        break
      end
      local e = not covered[s] and is_type(scheme) and scan_plain(text, colon + 1) or nil
      if e then
        local raw = text:sub(s, e)
        out[#out + 1] = { raw = raw, target = raw, start_col = s, end_col = e, plain = true }
        cover(s, e)
        init = e + 1
      else
        init = colon + 1
      end
    end
  end
  table.sort(out, function(a, b)
    return a.start_col < b.start_col
  end)
  for _, l in ipairs(out) do
    M.classify(l)
  end
  return out
end

--- Fill `type` and `path` fields from `target`.
---@param link org.Link|{target: string}
function M.classify(link)
  local t = link.target
  local scheme, rest = t:match("^([%a][%w+%-]*):(.*)$")
  if t:match("^/") or t:match("^~") or t:match("^%.%.?/") or t:match("^%a:[/\\]") then
    link.type = "file"
    link.path = t
  elseif scheme and is_type(scheme) then
    link.type = M.URL_SCHEMES[scheme:lower()] and scheme:lower() or scheme
    link.path = rest
  elseif t:match("^%(.*%)$") then
    link.type = "coderef"
    link.path = t:sub(2, -2)
  elseif t:sub(1, 1) == "#" then
    link.type = "custom-id"
    link.path = t:sub(2)
  elseif t:sub(1, 1) == "*" then
    link.type = "heading"
    link.path = t:sub(2)
  else
    link.type = "fuzzy"
    link.path = t
  end
  return link
end

--- Radio targets `<<<text>>>` of the buffer, longest first.
function M.radio_targets(bufnr)
  local seen, out = {}, {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)) do
    for t in l:gmatch("<<<([^<>]-)>>>") do
      if vim.trim(t) ~= "" and not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  table.sort(out, function(a, b)
    return #a > #b
  end)
  return out
end

local function is_word_byte(c)
  return c ~= "" and (c:match("%w") ~= nil or c:byte() >= 128)
end

--- Radio links in `text`: occurrences of a radio target (spaces match any
--- whitespace, including a line break) surrounded by non-alphanumerics,
--- ignoring case (org-update-radio-target-regexp).
local function radio_matches(text, targets)
  local out = {}
  local lower = text:lower()
  local taken = {}
  for _, t in ipairs(targets) do
    local pat = table.concat(vim.tbl_map(vim.pesc, vim.split(t:lower(), " +", { trimempty = false })), "%s+")
    local init = 1
    while true do
      local s, e = lower:find(pat, init)
      if not s then
        break
      end
      if not is_word_byte(text:sub(s - 1, s - 1)) and not is_word_byte(text:sub(e + 1, e + 1)) and not taken[s] then
        -- not the <<<target>>> itself
        if text:sub(s - 3, s - 1) ~= "<<<" then
          out[#out + 1] = { s = s, e = e, target = t }
          for k = s, e do
            taken[k] = true
          end
        end
      end
      init = s + 1
    end
  end
  return out
end

--- Link under the cursor (or nil).
---@return org.Link|nil
function M.link_at_cursor()
  local lnum, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  for _, l in ipairs(M.parse_links(line)) do
    if col >= l.start_col and col <= l.end_col then
      l.lnum, l.end_lnum = lnum, lnum
      return l
    end
  end
  -- bracket links spanning lines
  local last = vim.api.nvim_buf_line_count(0)
  local first_l, last_l = math.max(1, lnum - 2), math.min(last, lnum + 2)
  local lines = vim.api.nvim_buf_get_lines(0, first_l - 1, last_l, false)
  local starts, off = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = off
    off = off + #l + 1
  end
  local function pos_of(offset)
    for i = #starts, 1, -1 do
      if offset > starts[i] then
        return first_l + i - 1, offset - starts[i]
      end
    end
    return first_l, offset
  end
  local text = table.concat(lines, "\n")
  local cur_off = starts[lnum - first_l + 1] + col
  for _, l in ipairs(M.parse_links(text, { bracket_only = true })) do
    if l.raw:find("\n", 1, true) and cur_off >= l.start_col and cur_off <= l.end_col then
      l.lnum, l.start_col = pos_of(l.start_col)
      l.end_lnum, l.end_col = pos_of(l.end_col)
      return l
    end
  end
  -- radio links: text matching a <<<target>>>
  if utils.is_org() and line ~= "" then
    local targets = M.radio_targets(0)
    if #targets > 0 then
      for _, m in ipairs(radio_matches(text, targets)) do
        if cur_off >= m.s and cur_off <= m.e then
          local sl, sc = pos_of(m.s)
          local el, ec = pos_of(m.e)
          return {
            raw = text:sub(m.s, m.e),
            target = m.target,
            type = "radio",
            path = m.target,
            start_col = sc,
            end_col = ec,
            lnum = sl,
            end_lnum = el,
          }
        end
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Abbreviations
---------------------------------------------------------------------------

--- Abbreviation definition for `name` (buffer #+LINK first, then config).
function M.abbreviation(name, file)
  if not name then
    return nil
  end
  file = file or (utils.is_org() and files.get_buffer(0) or nil)
  if file and file.settings.link_abbrevs[name] then
    return file.settings.link_abbrevs[name]
  end
  return (lopts().abbreviations or {})[name]
end

local function url_hex(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- Expand link abbreviations (org-link-expand-abbrev): `gh:user/repo` or
--- `gh::user/repo` -> `https://github.com/user/repo`; a bare `gh` expands
--- with an empty tag.
function M.expand_abbrev(target, file)
  local name, rest = target:match("^([^:]*)(.*)$")
  local def = M.abbreviation(name, file)
  if not def then
    return target
  end
  local tag = rest:match("^::?(.*)$") or ""
  if type(def) == "function" then
    return def(tag)
  end
  if def:find("%s", 1, true) then
    return (def:gsub("%%s", function()
      return tag
    end, 1))
  elseif def:find("%h", 1, true) then
    return (def:gsub("%%h", function()
      return url_hex(tag)
    end, 1))
  end
  return def .. tag
end

---------------------------------------------------------------------------
-- Emacs regexps
---------------------------------------------------------------------------

--- Translate an Emacs regexp to a Vim regexp (case-insensitive, like
--- org-occur). Covers the usual syntax: groups, shy groups, alternation,
--- `+ ? *` (also non-greedy), intervals, brackets, `\b \< \> \w \s-`
--- and buffer anchors; syntax classes other than whitespace and word
--- constituents are approximated.
function M.emacs_regexp_to_vim(re)
  local out = {}
  local i, n = 1, #re
  local function emit(s)
    out[#out + 1] = s
  end
  while i <= n do
    local c = re:sub(i, i)
    if c == "[" then
      -- bracket expression, copied with backslashes made literal
      local j = i + 1
      local buf = { "[" }
      if re:sub(j, j) == "^" then
        buf[#buf + 1] = "^"
        j = j + 1
      end
      if re:sub(j, j) == "]" then
        buf[#buf + 1] = "\\]"
        j = j + 1
      end
      while j <= n and re:sub(j, j) ~= "]" do
        local d = re:sub(j, j)
        if d == "[" and re:sub(j + 1, j + 1) == ":" then
          local e = re:find(":]", j + 2, true)
          if e then
            buf[#buf + 1] = re:sub(j, e + 1)
            j = e + 2
          else
            buf[#buf + 1] = "["
            j = j + 1
          end
        elseif d == "\\" then
          buf[#buf + 1] = "\\\\"
          j = j + 1
        else
          buf[#buf + 1] = d
          j = j + 1
        end
      end
      buf[#buf + 1] = "]"
      emit(table.concat(buf))
      i = j + 1
    elseif c == "\\" then
      local d = re:sub(i + 1, i + 1)
      i = i + 2
      if d == "(" then
        if re:sub(i, i + 1) == "?:" then
          emit("\\%(")
          i = i + 2
        else
          emit("\\(")
        end
      elseif d == ")" or d == "|" or d == "<" or d == ">" or d == "w" or d == "W" or d:match("%d") then
        emit("\\" .. d)
      elseif d == "{" then
        local e = re:find("\\}", i, true)
        if e then
          emit("\\{" .. re:sub(i, e - 1) .. "}")
          i = e + 2
        else
          emit("{")
        end
      elseif d == "`" then
        emit("\\%^")
      elseif d == "'" then
        emit("\\%$")
      elseif d == "b" then
        emit("\\%(\\<\\|\\>\\)")
      elseif d == "_" then
        local e = re:sub(i, i)
        i = i + 1
        emit(e == "<" and "\\<" or e == ">" and "\\>" or "")
      elseif d == "s" or d == "S" then
        local e = re:sub(i, i)
        i = i + 1
        if e == "w" or e == "_" then
          emit(d == "s" and "\\w" or "\\W")
        else
          emit(d == "s" and "\\s" or "\\S")
        end
      elseif d == "+" or d == "?" then
        emit(d)
      elseif d == "" then
        emit("\\\\")
      elseif d:match("[%.%*%[%]%$%^~/\\]") then
        emit("\\" .. d)
      else
        emit(d)
      end
    elseif c == "+" or c == "*" or c == "?" then
      if re:sub(i + 1, i + 1) == "?" then
        emit(c == "*" and "\\{-}" or c == "+" and "\\{-1,}" or "\\{-,1}")
        i = i + 2
      else
        emit(c == "+" and "\\+" or c == "?" and "\\=" or "*")
        i = i + 1
      end
    elseif c == "~" then
      emit("\\~")
      i = i + 1
    else
      emit(c)
      i = i + 1
    end
  end
  return "\\c" .. table.concat(out)
end

---------------------------------------------------------------------------
-- Windows (org-link-frame-setup)
---------------------------------------------------------------------------

local function normal_windows()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      out[#out + 1] = w
    end
  end
  return out
end

--- Make "another window" current, like `pop-to-buffer` with
--- `inhibit-same-window`: a window already showing `bufnr`, the previous
--- window, any other window, or a new split (below when the window is at
--- least 80 lines high, beside it when at least 160 columns wide, like
--- split-window-sensibly).
local function select_other_window(bufnr)
  local cur = vim.api.nvim_get_current_win()
  local others = vim.tbl_filter(function(w)
    return w ~= cur
  end, normal_windows())
  if bufnr then
    for _, w in ipairs(others) do
      if vim.api.nvim_win_get_buf(w) == bufnr then
        vim.api.nvim_set_current_win(w)
        return
      end
    end
  end
  if #others > 0 then
    -- the previous window, else the next one (like other-window)
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    vim.api.nvim_set_current_win(vim.tbl_contains(others, prev) and prev or others[1])
    return
  end
  if vim.api.nvim_win_get_height(cur) < 80 and vim.api.nvim_win_get_width(cur) >= 160 then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
end

--- How file: and id: links open: `links.frame_setup.file`
--- (org-link-frame-setup).
local function file_setup()
  local fs = lopts().frame_setup
  local v = type(fs) == "table" and fs.file or fs
  return v or "other-window"
end

--- Show `path` (a file name) or buffer `bufnr` according to `how`.
local function visit(path, how, bufnr)
  how = how or file_setup()
  if type(how) == "function" then
    return how(path)
  end
  bufnr = bufnr or (path and utils.find_buffer(path))
  if how == "other-window" then
    select_other_window(bufnr)
  elseif how == "split" or how == "vsplit" then
    vim.cmd(how)
  elseif how == "tab" then
    vim.cmd("tab split")
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_current_buf(bufnr)
  elseif path then
    vim.cmd("hide edit " .. vim.fn.fnameescape(path))
  end
end

---------------------------------------------------------------------------
-- Searching (org-link-search)
---------------------------------------------------------------------------

local function push_jump()
  vim.cmd("normal! m'")
end

local function goto_pos(lnum, col, stealth)
  push_jump()
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(lnum, last)), col or 0 })
  if not stealth then
    pcall(vim.cmd, "normal! zv")
  end
end

--- Text of lines `first`..`last` of the buffer, with functions mapping a
--- 1-based byte offset to { lnum, col0 } and back.
local function buffer_text(bufnr, first, last)
  first = first or 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last or -1, false)
  local starts, off = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = off
    off = off + #l + 1
  end
  local function pos(offset)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] < offset then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return first + lo - 1, offset - starts[lo] - 1
  end
  local function offset(lnum, col1)
    return (starts[lnum - first + 1] or 0) + col1
  end
  return table.concat(lines, "\n"), pos, offset, lines
end

local function words_pattern(words, sep)
  return table.concat(vim.tbl_map(function(w)
    return vim.pesc(w:lower())
  end, words), sep)
end

--- Insert a heading named `text` at the end of the buffer (level 1) or
--- as the last child of `container` (query-to-create).
local function create_heading(bufnr, text, container)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local after = container and container.end_line or #lines
  local level = container and container.level + 1 or 1
  local b = config.opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  local blank = v == true
  if v == "auto" then
    local file = files.get_buffer(bufnr)
    local prev = file:headline_at(after)
    blank = prev and prev.line > 1 and (lines[prev.line - 1] or ""):match("^%s*$") ~= nil or false
  end
  local new = { string.rep("*", level) .. " " .. text }
  if blank and after > 0 and not (lines[after] or ""):match("^%s*$") then
    table.insert(new, 1, "")
  end
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, new)
    after = 0
    goto_pos(#new, 0)
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, after, after, false, new)
  goto_pos(after + #new, 0)
end

--- Coderef `(label)` search in src and example blocks, honouring each
--- block's `-l "fmt"` switch.
local function search_coderef(lines, label)
  local blocks = require("org.babel.blocks")
  local i = 1
  while i <= #lines do
    local kind = lines[i]:lower():match("^%s*#%+begin_(%a+)")
    if kind == "src" or kind == "example" then
      local switches = " " .. vim.trim(lines[i]:match("^%s*#%+%a+_%a+(.*)$") or "")
      if kind == "src" then
        switches = switches:gsub("^ %S+", "", 1)
      end
      -- header arguments (" :results ...") follow the switches
      local h = switches:find("%s:%a")
      if h then
        switches = switches:sub(1, h - 1)
      end
      local pat = blocks.coderef_pattern(switches)
      local fmt = switches:match('%-l%s+"(.-)"') or "(ref:%s)"
      local j = i + 1
      while j <= #lines and not lines[j]:lower():match("^%s*#%+end_") do
        if lines[j]:match(pat) == label then
          local ref = fmt:gsub("%%s", function()
            return label
          end)
          local s = lines[j]:find(ref, 1, true)
          return j, (s or 1) - 1
        end
        j = j + 1
      end
      i = j
    end
    i = i + 1
  end
end

--- Search the current buffer for a link search string (org-link-search).
--- `#id` (CUSTOM_ID), `(label)` (coderef), `/regexp/` (sparse tree in Org
--- buffers, location list elsewhere), `*heading`, otherwise dedicated
--- `<<target>>`, `#+NAME:`, headline, then (see
--- `links.search_must_match_exact_headline`) query-to-create or text.
--- Returns true when found (cursor moved), else false and a message.
---@param search string
---@param sopts? { avoid?: integer[], container?: org.Headline, stealth?: boolean, range?: integer[] }
---@return boolean found, string|nil err
function M.search_in_buffer(search, sopts)
  sopts = sopts or {}
  if not search or vim.trim(search) == "" then
    return false, string.format('Invalid search string "%s"', tostring(search))
  end
  local bufnr = vim.api.nvim_get_current_buf()
  for _, fn in ipairs(lopts().search_functions or {}) do
    if fn(search) then
      return true
    end
  end
  local normalized = search:gsub("\n[ \t]*", " ")
  local starred = normalized:sub(1, 1) == "*"
  local words = split_words(starred and search:sub(2) or search)
  local is_org = utils.is_org(bufnr) or vim.api.nvim_buf_get_name(bufnr):match("%.org$") ~= nil
  local file = is_org and files.get_buffer(bufnr) or nil
  -- a range restricts the search (org-id-open narrows to the entry)
  local first, last = 1, vim.api.nvim_buf_line_count(bufnr)
  if sopts.range then
    first, last = sopts.range[1], sopts.range[2]
  end
  local headlines = {}
  for _, hl in ipairs(file and file.headlines or {}) do
    if hl.line >= first and hl.line <= last then
      headlines[#headlines + 1] = hl
    end
  end
  local text, pos, offset, lines = buffer_text(bufnr, first, last)
  local lower = text:lower()

  if normalized:sub(1, 1) == "#" then
    local id = normalized:sub(2):lower()
    for _, hl in ipairs(headlines) do
      local cid = hl.properties.CUSTOM_ID
      if cid and cid:lower() == id then
        goto_pos(hl.line, 0, sopts.stealth)
        return true
      end
    end
    return false, "No match for custom ID: " .. normalized:sub(2)
  end
  local coderef = normalized:match("^%((.*)%)$")
  if coderef then
    local l, c = search_coderef(lines, coderef)
    if l then
      goto_pos(first + l - 1, c, sopts.stealth)
      return true
    end
    return false, "No match for coderef: " .. coderef
  end
  local regex = normalized:match("^/(.*)/$")
  if regex then
    local vre = M.emacs_regexp_to_vim(search:match("^/(.*)/$"))
    local ok, re = pcall(vim.regex, vre)
    if not ok then
      return false, "Invalid regexp: " .. regex
    end
    if file then
      require("org.agenda.sparse").regexp(vre)
    else
      local items = {}
      for i, l in ipairs(lines) do
        local s = re:match_str(l)
        if s then
          items[#items + 1] = { bufnr = bufnr, lnum = first + i - 1, col = s + 1, text = l }
        end
      end
      vim.fn.setloclist(0, {}, "r", { title = "Occur: " .. regex, items = items })
      local win = vim.api.nvim_get_current_win()
      vim.cmd("lwindow")
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
      utils.notify(string.format("%d match%s for %s", #items, #items == 1 and "" or "es", regex))
    end
    return true
  end
  if #words == 0 then
    return false, "No match for fuzzy expression: " .. normalized
  end
  if not starred then
    -- dedicated target <<words>>
    local pat = "<<" .. words_pattern(words, "[ \t\n]+") .. ">>"
    local init = 1
    while true do
      local s, e = lower:find(pat, init)
      if not s then
        break
      end
      if text:sub(s - 1, s - 1) ~= "<" and text:sub(e + 1, e + 1) ~= ">" then
        local l, c = pos(s)
        goto_pos(l, c, sopts.stealth)
        return true
      end
      init = s + 1
    end
    -- #+NAME: words
    local want = upper_words(table.concat(words, " "))
    for i, l in ipairs(lines) do
      local name = l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]+(.-)[ \t]*$")
      if name and vim.deep_equal(upper_words(name), want) then
        goto_pos(first + i - 1, 0, sopts.stealth)
        return true
      end
    end
  end
  if file then
    local want = vim.tbl_map(string.upper, words)
    for _, hl in ipairs(headlines) do
      if vim.deep_equal(upper_words(M.normalize_string(hl.title)), want) then
        goto_pos(hl.line, 0, sopts.stealth)
        return true
      end
    end
    local must = lopts().search_must_match_exact_headline
    if must == nil then
      must = "query-to-create"
    end
    if must == "query-to-create" then
      if utils.confirm("No match - create this as a new heading?") then
        create_heading(bufnr, starred and search:sub(2) or search, sopts.container)
        return true
      end
    end
    if starred or must then
      return false, "No match for fuzzy expression: " .. normalized
    end
  end
  -- plain text search
  local avoid = sopts.avoid and offset(sopts.avoid[1], sopts.avoid[2]) or nil
  local pat = words_pattern(words, "[ \t\n]+")
  local init = 1
  while true do
    local s, e = lower:find(pat, init)
    if not s then
      break
    end
    local skip = avoid and s <= avoid and e >= avoid
    if not skip then
      -- inside a described bracket link but outside its description
      local l, c = pos(s)
      for _, lk in ipairs(M.parse_links(lines[l - first + 1], { bracket_only = true })) do
        if lk.desc and c + 1 >= lk.start_col and c + 1 <= lk.end_col then
          local ds, de = lk.desc_start, lk.desc_start + #lk.desc - 1
          if c + 1 < ds or c + 1 > de then
            skip = true
          end
        end
      end
      if not skip then
        goto_pos(l, c, sopts.stealth)
        return true
      end
    end
    init = s + 1
  end
  return false, "No match for fuzzy expression: " .. normalized
end

--- Go to the radio target `<<<target>>>` (org-link--search-radio-target).
function M.search_radio_target(target)
  local text, pos = buffer_text(0)
  local pat = "<<<" .. words_pattern(split_words(target), "[ \t]+\n?[ \t]*") .. ">>>"
  local s = text:lower():find(pat)
  if not s then
    return false, "No match for radio target: " .. target
  end
  local l, c = pos(s)
  goto_pos(l, c)
  return true
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

local function run_external(app, path)
  if type(app) == "function" then
    return app(path)
  end
  if app == "system" or app == "default" then
    return vim.ui.open(path)
  end
  local cmd = vim.split(app, "%s+", { trimempty = true })
  if app:find("%s", 1, true) and app:find("%%s") then
    cmd = vim.tbl_map(function(p)
      return (p:gsub("%%s", path))
    end, cmd)
  else
    cmd[#cmd + 1] = path
  end
  vim.system(cmd, { detach = true })
end

--- Directory used to resolve relative paths of links in `bufnr`.
local function base_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name ~= "" and not name:match("^%a[%w+%-]*://") then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  return vim.fn.getcwd()
end
M.base_dir = base_dir

--- Resolve a file link path relative to the buffer.
function M.resolve_path(path, bufnr)
  if path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr or 0)
    if name ~= "" then
      return vim.fs.normalize(name)
    end
  end
  path = vim.fn.expand(path)
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    path = base_dir(bufnr) .. "/" .. path
  end
  return vim.fs.normalize(path)
end

local function warn_err(err)
  if err then
    utils.warn(err)
  end
end

--- Open a file link (org-open-file). `app` is "vim" (C-u: always in
--- Neovim), "system" (C-u C-u) or nil.
local function open_file_link(path, search, o)
  o = o or {}
  local full = M.resolve_path(path, o.bufnr)
  local ext = (full:match("%.([%w]+)$") or ""):lower()
  local apps = lopts().file_apps or {}
  if o.app == "system" then
    return vim.ui.open(full)
  end
  if o.app ~= "vim" then
    local app = apps[ext]
    if app and app ~= "vim" and app ~= "emacs" then
      return run_external(app, full)
    end
    if EXTERNAL_EXT[ext] and not app then
      return vim.ui.open(full)
    end
  end
  visit(full, o.how)
  if search and search ~= "" then
    if search:match("^%d+$") then
      goto_pos(tonumber(search), 0)
      return true
    end
    local ok, err = M.search_in_buffer(search)
    warn_err(err)
    return ok
  end
  return true
end

local function run_in_terminal(argv, cwd)
  vim.cmd("botright new")
  if vim.fn.has("nvim-0.11") == 1 then
    return vim.fn.jobstart(argv, { term = true, cwd = cwd })
  end
  return vim.fn.termopen(argv, { cwd = cwd })
end

--- Run a `shell:` link in a terminal window, in the directory of the Org
--- file, after confirmation (org-link--open-shell).
local function open_shell(cmd, bufnr)
  local skip = lopts().shell_skip_confirm_regexp
  local skipped = false
  if type(skip) == "string" and skip ~= "" then
    local ok, re = pcall(vim.regex, skip)
    skipped = ok and re:match_str(cmd) ~= nil
  end
  local confirm = lopts().confirm_shell
  if not skipped and confirm ~= false then
    local yes
    if type(confirm) == "function" then
      yes = confirm(cmd)
    else
      yes = utils.confirm("Execute " .. cmd .. " in shell?")
    end
    if not yes then
      utils.warn("Abort")
      return false
    end
  end
  local argv = { vim.o.shell }
  vim.list_extend(argv, vim.split(vim.o.shellcmdflag, "%s+", { trimempty = true }))
  argv[#argv + 1] = cmd
  utils.notify("Executing " .. cmd)
  return run_in_terminal(argv, base_dir(bufnr))
end

--- Show an internal link's buffer in another window (C-u C-c C-o).
local function other_window_same_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local view = vim.fn.winsaveview()
  select_other_window(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.fn.winrestview(view)
end

--- Open a link target string (as written inside [[...]]).
---@param target string
---@param opts? { bufnr?: integer, split?: string, link?: org.Link, arg?: integer, avoid?: integer[] }
function M.open(target, opts)
  opts = opts or {}
  local arg = opts.arg or 0
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local file = utils.is_org(bufnr) and files.get_buffer(bufnr) or nil
  target = target:gsub("[ \t]*\n[ \t]*", " ")
  local expanded = M.expand_abbrev(target, file)
  local link = M.classify({ target = expanded })
  local translate = lopts().translation_function
  if translate and M.URL_SCHEMES[link.type] then
    local nt, np = translate(link.type, link.path)
    if nt then
      link.type, link.path = nt, np
      expanded = nt .. ":" .. np
    end
  end
  local lt = M.link_type(link.type)
  if lt and lt.follow then
    return lt.follow(link.path, link, arg)
  elseif lt then
    return false
  end
  local how = opts.split or nil

  local t = link.type
  if t == "http" or t == "https" or t == "ftp" or t == "mailto" or t == "news" or t == "irc" then
    return vim.ui.open(expanded)
  elseif t == "doi" then
    return vim.ui.open((lopts().doi_server_url or "https://doi.org/") .. link.path)
  elseif t == "file" or t == "file+sys" or t == "file+emacs" or t == "docview" then
    local path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local app = arg >= 16 and "system" or arg > 0 and "vim" or nil
    if t == "file+sys" then
      app = "system"
    elseif t == "file+emacs" then
      app = "vim"
    end
    return open_file_link(path, search, { bufnr = bufnr, how = how, app = app })
  elseif t == "id" then
    local id, option = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      id, option = p, s
    end
    local idm = require("org.id")
    local loc = idm.find(id)
    if not loc and option then
      -- an ID containing "::" (backwards compatibility)
      loc = idm.find(link.path)
      if loc then
        id, option = link.path, nil
      end
    end
    if not loc then
      utils.warn('Cannot find entry with ID "' .. id .. '"')
      return false
    end
    push_jump()
    local target_buf = loc.bufnr or (loc.filename and utils.find_buffer(loc.filename))
    if not (target_buf and target_buf == vim.api.nvim_get_current_buf()) then
      visit(loc.filename, how, target_buf)
    end
    local f = files.get_buffer(0)
    local hl = f and f:find_by_id(id)
    local lnum = hl and hl.line or loc.lnum or 1
    goto_pos(lnum, 0)
    if option then
      -- search within the entry's subtree (org-id-open narrows to it)
      local range = hl and { hl.line, hl.end_line } or nil
      local found, err = M.search_in_buffer(option, { range = range, container = hl })
      if not found then
        warn_err(err)
      end
      return found
    end
    return true
  elseif t == "shell" then
    return open_shell(link.path, bufnr)
  elseif t == "elisp" then
    utils.warn("elisp: links are not supported in Neovim (they need an Emacs Lisp interpreter)")
    return false
  elseif t == "help" then
    local ok, err = pcall(vim.cmd.help, link.path)
    if not ok then
      utils.warn(tostring(err))
    end
    return ok
  elseif t == "man" then
    local page, search = link.path:match("^(.-)::(.*)$")
    page = page or link.path
    local ok, err = pcall(vim.cmd, "Man " .. page)
    if not ok then
      utils.warn(tostring(err))
      return false
    end
    if search and search ~= "" then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.fn.search("\\V" .. vim.fn.escape(search, "\\"), "cW")
    end
    return true
  elseif t == "info" then
    local ifile, node = link.path:match("^([^#:]*)[#:]:?(.*)$")
    ifile = ifile or link.path
    if vim.fn.executable("info") == 0 then
      utils.warn("info: links need the `info` program")
      return false
    end
    local topic = "(" .. ifile .. ")" .. ((node and node ~= "") and node or "Top")
    return run_in_terminal({ "info", topic }, base_dir(bufnr))
  elseif t == "attachment" then
    local path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local full = require("org.attach").resolve_attachment(path, { bufnr = bufnr })
    if not full then
      utils.warn("Attachment not found: " .. path)
      return false
    end
    local app = arg >= 16 and "system" or arg > 0 and "vim" or nil
    return open_file_link(full, search, { bufnr = bufnr, how = how, app = app })
  end
  -- internal links: custom-id, heading, coderef, fuzzy
  if bufnr ~= vim.api.nvim_get_current_buf() and vim.api.nvim_buf_is_valid(bufnr) then
    -- followed from elsewhere (the agenda): search the link's buffer
    visit(nil, how, bufnr)
  elseif arg > 0 then
    other_window_same_buffer()
  else
    push_jump()
  end
  local search = expanded
  if t == "coderef" then
    search = "(" .. link.path .. ")"
  end
  local ok, err = M.search_in_buffer(search, { avoid = t == "fuzzy" and opts.avoid or nil })
  warn_err(err)
  return ok
end

--- Open the link under the cursor. Returns false when there is none. A
--- count stands for the Emacs prefix argument: open files in Neovim even
--- when an external app is configured and show internal links in another
--- window (C-u); 16 opens files with the system app (C-u C-u). Returns
--- true when a link was followed, nil when it could not be.
function M.open_at_point(arg)
  arg = arg or vim.v.count
  local link = M.link_at_cursor()
  if not link then
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if link.type == "radio" then
    if arg > 0 then
      other_window_same_buffer()
    else
      push_jump()
    end
    local ok, err = M.search_radio_target(link.path)
    warn_err(err)
    return ok or nil
  end
  -- not false: a failed search must not make the key fall back
  return M.open(link.target, {
    bufnr = bufnr,
    link = link,
    arg = arg,
    avoid = { link.lnum, link.start_col + 2 },
  }) ~= false or nil
end

---------------------------------------------------------------------------
-- Storing
---------------------------------------------------------------------------

--- Add to the stored links (org-link--add-to-stored-links).
local function add_stored(link, desc, quiet)
  for i, s in ipairs(M.stored) do
    if s.link == link and s.desc == desc then
      if i == 1 then
        if not quiet then
          utils.notify("This link has already been stored")
        end
        return M.stored[1]
      end
      table.remove(M.stored, i)
      table.insert(M.stored, 1, { link = link, desc = desc })
      if not quiet then
        utils.notify("Link moved to front: " .. (desc or link))
      end
      return M.stored[1]
    end
  end
  table.insert(M.stored, 1, { link = link, desc = desc })
  if not quiet then
    utils.notify("Stored: " .. (desc or link))
  end
  return M.stored[1]
end

local function display_path(path)
  return vim.fn.fnamemodify(path, ":~")
end

--- Name of the element at `lnum` (its `#+NAME:` line, or a src block /
--- table / block below one) and the line of the element start.
local function named_element_at(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name_pat = "^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$"
  local function name_above(l)
    local k = l - 1
    while k >= 1 and lines[k]:match("^%s*#%+[%w_]+:") do
      local nm = lines[k]:match(name_pat)
      if nm then
        -- the element starts at its first affiliated keyword
        local s = k
        while s > 1 and lines[s - 1]:match("^%s*#%+[%w_]+:") do
          s = s - 1
        end
        return nm, s
      end
      k = k - 1
    end
  end
  local line = lines[lnum] or ""
  local nm = line:match(name_pat)
  if nm and nm ~= "" then
    local s = lnum
    while s > 1 and lines[s - 1]:match("^%s*#%+[%w_]+:") do
      s = s - 1
    end
    return nm, s
  end
  if line:match("^%s*#%+[%w_]+:") then
    local k = lnum + 1
    while lines[k] and lines[k]:match("^%s*#%+[%w_]+:") and not lines[k]:lower():match("^%s*#%+begin_") do
      k = k + 1
    end
    return name_above(k)
  end
  if line:match("^%s*|") then
    local k = lnum
    while k > 1 and lines[k - 1]:match("^%s*|") do
      k = k - 1
    end
    return name_above(k)
  end
  -- inside a #+begin_ ... #+end_ block
  for k = lnum, 1, -1 do
    local l = lines[k]
    if k < lnum and l:lower():match("^%s*#%+end_") then
      return nil
    end
    if l:lower():match("^%s*#%+begin_") then
      return name_above(k)
    end
    if l:match("^%*+%s") then
      return nil
    end
  end
end

--- Link to a code line from a src / example edit buffer: `(label)`,
--- creating the `(ref:label)` when `interactive`.
local function coderef_link(bufnr, lnum, interactive)
  local src = vim.b[bufnr].org_special_source
  if not src or not vim.api.nvim_buf_is_valid(src) then
    return nil
  end
  local pat = require("org.babel.blocks").coderef_pattern(vim.b[bufnr].org_special_switches)
  local fmt = (vim.b[bufnr].org_special_switches or ""):match('%-l%s+"(.-)"') or "(ref:%s)"
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local label = line:match(pat)
  if not label then
    if not interactive then
      return nil
    end
    label = utils.input({ prompt = "Code line label: " })
    if not label or vim.trim(label) == "" then
      return nil
    end
    label = vim.trim(label)
    local ref = fmt:gsub("%%s", function()
      return label
    end)
    local pad = math.max(1, 79 - #ref - vim.fn.strdisplaywidth(line))
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line .. string.rep(" ", pad) .. ref })
  end
  local name = vim.api.nvim_buf_get_name(src)
  if name == "" then
    return { link = "(" .. label .. ")", desc = nil }
  end
  return { link = "file:" .. display_path(name) .. "::(" .. label .. ")", desc = nil }
end

--- Selection of Visual mode { srow, scol, erow, ecol } (1-based,
--- inclusive), leaving Visual mode; nil in other modes.
local function visual_region()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local srow, scol, erow, ecol = utils.visual_range()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  if mode == "V" then
    scol = 1
    ecol = #(vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or "")
  else
    local line = vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or ""
    local ch = vim.fn.strcharpart(line:sub(ecol), 0, 1)
    ecol = math.min(#line, ecol + math.max(#ch, 1) - 1)
  end
  return { srow, scol, erow, ecol }
end

--- Search string, description and position for a link to `lnum`
--- (org-link-precise-link-target). `region` = { srow, scol, erow, ecol }.
local function precise_target(bufnr, lnum, region, ctx)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result
  if region then
    local parts = vim.api.nvim_buf_get_text(bufnr, region[1] - 1, region[2] - 1, region[3] - 1, region[4], {})
    if type(ctx) == "number" and ctx > 0 then
      parts = vim.list_slice(parts, 1, ctx)
    end
    result = { search = M.normalize_string(table.concat(parts, "\n"), true), pos = { region[1], region[2] } }
  elseif vim.bo[bufnr].filetype == "org" then
    local file = files.get_buffer(bufnr)
    local name, name_line = named_element_at(bufnr, lnum)
    local hl = file:headline_at(lnum)
    if name then
      result = { search = name, desc = name, pos = { name_line, 1 } }
    elseif not hl then
      result = { search = M.normalize_string(lines[lnum] or "", true), pos = { lnum, 1 } }
    else
      local title = M.normalize_string(hl.title)
      local cid = hl.properties.CUSTOM_ID
      result = { search = cid and ("#" .. cid) or ("*" .. title), desc = title, pos = { hl.line, 0 }, hl = hl }
    end
  else
    result = { search = M.normalize_string(lines[lnum] or "", true), pos = { lnum, 1 } }
  end
  if result and result.search:match("%S") then
    return result
  end
end

--- `file:` link to `lnum` with a search string (org-link--file-link-to-here).
local function file_link_to_here(bufnr, lnum, region, ctx)
  local link = "file:" .. display_path(vim.api.nvim_buf_get_name(bufnr))
  local desc
  if ctx then
    local t = precise_target(bufnr, lnum, region, ctx)
    if t then
      link = link .. "::" .. t.search
      desc = t.desc
    end
  end
  return { link = link, desc = desc }
end

--- The ID to link to (org-id--get-id-to-store-link): the entry's, an
--- inherited one when `id.link_consider_parent_id`, created when `create`.
local function id_to_store(bufnr, hl, create, ctx)
  local idc = config.opts.id or {}
  local inherit = idc.link_consider_parent_id and idc.link_use_context ~= false and ctx
  if hl.properties.ID and hl.properties.ID ~= "" then
    return hl.properties.ID, hl
  end
  if inherit then
    local p = hl.parent
    while p do
      if p.properties.ID and p.properties.ID ~= "" then
        return p.properties.ID, p
      end
      p = p.parent
    end
  end
  if create then
    local id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
    return id, hl
  end
end

--- `id:` link to the entry at `lnum` when `links.use_id` asks for one
--- (org-id-store-link-maybe / org-id-store-link).
local function id_store_link(bufnr, lnum, region, ctx, interactive, force)
  if vim.bo[bufnr].filetype ~= "org" or vim.api.nvim_buf_get_name(bufnr) == "" then
    return nil
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return nil
  end
  local use = config.opts.links.use_id
  local create = force
    or use == true
    or (
      interactive
      and (
        use == "create-if-interactive"
        or (use == "create-if-interactive-and-no-custom-id" and not hl.properties.CUSTOM_ID)
      )
    )
  if not create and not (use and id_to_store(bufnr, hl, false, ctx)) then
    return nil
  end
  local idc = config.opts.id or {}
  local precise = ctx and idc.link_use_context ~= false and precise_target(bufnr, lnum, region, ctx) or nil
  local id, owner = id_to_store(bufnr, hl, true, ctx)
  if not id then
    return nil
  end
  owner = files.get_buffer(bufnr):headline_at(owner.line) or owner
  local link = "id:" .. id
  local desc = owner.title
  if precise and (precise.pos[1] > owner.line or (precise.pos[1] == owner.line and precise.pos[2] > 0)) then
    link = link .. "::" .. precise.search
    desc = precise.desc
  end
  return { link = link, desc = desc }
end

--- Store an `id:` link to the entry at the cursor, creating the ID, with
--- a search string when `id.link_use_context` applies (org-id-store-link).
function M.store_id_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local region = visual_region()
  local ctx = lopts().context_for_files
  if ctx == nil then
    ctx = true
  end
  local l = id_store_link(bufnr, vim.api.nvim_win_get_cursor(0)[1], region, ctx, true, true)
  if not l then
    return nil
  end
  return add_stored(l.link, l.desc and M.display_format(l.desc) or nil)
end

--- Link from a Vim help buffer: `help:tag` of the nearest tag above.
local function help_link(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)
  for i = #lines, 1, -1 do
    local tag = (" " .. lines[i] .. " "):match("%s%*([^%s*|]+)%*%s")
    if tag then
      return { link = "help:" .. tag, desc = nil }
    end
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
  return { link = "help:" .. name, desc = nil }
end

--- Link from a directory listing (netrw, oil): the file at the cursor.
local function directory_link(bufnr, lnum)
  local ft = vim.bo[bufnr].filetype
  if ft == "oil" then
    local ok, oil = pcall(require, "oil")
    if ok then
      local dir = oil.get_current_dir(bufnr)
      local entry = oil.get_cursor_entry()
      if dir then
        return { link = "file:" .. display_path(dir .. (entry and entry.name or "")), desc = nil }
      end
    end
    return nil
  end
  local dir = vim.b[bufnr].netrw_curdir or vim.api.nvim_buf_get_name(bufnr)
  if dir == "" or not utils.is_dir(dir) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local name = vim.trim(line):gsub("[*@/=|]$", "")
  if name ~= "" and not name:match("^[\"=]") and utils.exists(dir .. "/" .. name) then
    return { link = "file:" .. display_path(vim.fs.normalize(dir .. "/" .. name)), desc = nil }
  end
  return { link = "file:" .. display_path(vim.fs.normalize(dir)) .. "/", desc = nil }
end

--- Links from the `store` functions of custom link types.
local function custom_store(interactive)
  local found = {}
  local names = vim.tbl_keys(lopts().types or {})
  table.sort(names)
  for _, name in ipairs(names) do
    local t = M.link_type(name)
    if t and t.store then
      local r = t.store(interactive)
      if type(r) == "string" then
        r = { link = r }
      end
      if type(r) == "table" and r.link then
        found[#found + 1] = { name = name, link = r.link, desc = r.desc or r.description }
      end
    end
  end
  return found
end

local function in_coroutine()
  local _, main = coroutine.running()
  return not main
end

--- Compute a link to the current location without storing it.
---@param opts? { interactive?: boolean, bufnr?: integer, lnum?: integer, col?: integer, region?: integer[],
---  negate_context?: boolean, skip_custom?: boolean }
---@return { link: string, desc: string|nil, extra?: table }|nil
function M.link_to_location(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local is_cur = bufnr == vim.api.nvim_get_current_buf()
  local lnum = opts.lnum or (is_cur and vim.api.nvim_win_get_cursor(0)[1]) or 1
  local ctx = lopts().context_for_files
  if ctx == nil then
    ctx = true
  end
  if opts.negate_context then
    ctx = not ctx
  end
  local region = opts.region

  local function finish(r)
    if not r then
      return nil
    end
    if r.desc == "NONE" then
      r.desc = nil
    elseif r.desc then
      r.desc = M.display_format(r.desc)
    end
    return r
  end

  if not opts.skip_custom then
    local found = custom_store(opts.interactive)
    local idl
    if vim.bo[bufnr].filetype == "org" then
      idl = id_store_link(bufnr, lnum, region, ctx, opts.interactive)
      if idl then
        found[#found + 1] = { name = "id", link = idl.link, desc = idl.desc }
      end
    end
    if #found == 1 then
      return finish({ link = found[1].link, desc = found[1].desc, id = found[1].name == "id" })
    elseif #found > 1 then
      local pick = found[1]
      if opts.interactive and in_coroutine() then
        local _, idx = utils.select(
          vim.tbl_map(function(f)
            return f.name
          end, found),
          { prompt = "Store link with" }
        )
        if not idx then
          return nil
        end
        pick = found[idx]
      end
      return finish({ link = pick.link, desc = pick.desc, id = pick.name == "id" })
    end
  end

  if vim.bo[bufnr].filetype == "orgagenda" then
    -- in the agenda: a link to the entry of the item at the cursor
    local view = require("org.agenda.view")
    local item = view.item_at_cursor()
    local target = item and view.resolve_target(item)
    if not target then
      return nil
    end
    return M.link_to_location({
      bufnr = target.bufnr,
      lnum = target.lnum,
      interactive = opts.interactive,
      negate_context = opts.negate_context,
      skip_custom = opts.skip_custom,
    })
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match("^org%-special://") then
    return coderef_link(bufnr, lnum, opts.interactive)
  end
  local bt = vim.bo[bufnr].buftype
  if bt == "help" then
    return help_link(bufnr, lnum)
  end
  if vim.bo[bufnr].filetype == "man" then
    local page = name:match("^man://(.+)$")
    if page then
      return { link = "man:" .. page, desc = "Manpage for " .. page }
    end
  end
  if vim.bo[bufnr].filetype == "netrw" or vim.bo[bufnr].filetype == "oil" or (name ~= "" and utils.is_dir(name)) then
    return directory_link(bufnr, lnum)
  end
  if name == "" or bt ~= "" and bt ~= "acwrite" then
    return nil
  end
  if name:match("CAPTURE%-") then
    return nil
  end
  local path = display_path(name)
  if vim.bo[bufnr].filetype == "org" then
    -- a dedicated <<target>> under the cursor
    local cur_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local col = opts.col or (is_cur and not opts.lnum and (vim.api.nvim_win_get_cursor(0)[2] + 1)) or nil
    local init = 1
    while col and not region do
      local s, e, target = cur_line:find("<<([^<>]+)>>", init)
      if not s then
        break
      end
      -- Emacs wants a character around the target that is not < or >
      local before, after = cur_line:sub(s - 1, s - 1), cur_line:sub(e + 1, e + 1)
      if col >= s and col <= e and before ~= "" and after ~= "" and before ~= "<" and after ~= ">" then
        return { link = "file:" .. path .. "::" .. target, desc = nil }
      end
      init = e + 1
    end
  end
  return finish(file_link_to_here(bufnr, lnum, region, ctx))
end

--- Store a link to the current location (org-store-link). In Visual mode
--- the selection is the search string. A count stands for the prefix
--- argument: 4 negates `links.context_for_files`, 16 skips the `store`
--- functions of custom link types, 64 stores one link per selected line.
function M.store_link(arg)
  arg = arg or vim.v.count
  local region = visual_region()
  if region and arg >= 64 then
    local last
    for l = region[1], region[3] do
      local len = #(vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1] or "")
      if len > 0 then
        last = M.store_link_at({ region = { l, 1, l, len }, interactive = true }) or last
      end
    end
    return last
  end
  return M.store_link_at({
    region = region,
    interactive = true,
    negate_context = arg > 0 and arg < 16,
    skip_custom = arg >= 16,
  })
end

--- Store a link computed by `link_to_location(opts)`; in Org buffers an
--- extra `file:…::#custom-id` link is stored when the entry has one.
function M.store_link_at(opts)
  local l = M.link_to_location(opts)
  if not l then
    utils.warn("No method for storing a link from this buffer")
    return
  end
  add_stored(l.link, l.desc)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == "org" and vim.api.nvim_buf_get_name(bufnr) ~= "" and opts.interactive then
    local hl = files.get_buffer(bufnr):headline_at(vim.api.nvim_win_get_cursor(0)[1])
    if hl and hl.properties.CUSTOM_ID then
      local ctx = lopts().context_for_files
      if ctx == nil then
        ctx = true
      end
      if opts.negate_context then
        ctx = not ctx
      end
      local here = file_link_to_here(bufnr, vim.api.nvim_win_get_cursor(0)[1], opts.region, ctx)
      if here.desc then
        here.desc = M.display_format(here.desc)
      end
      if not (M.stored[1].link == here.link and M.stored[1].desc == here.desc) then
        add_stored(here.link, here.desc, true)
      end
    end
  end
  return M.stored[1]
end

--- Store a link programmatically.
function M.store(link, desc)
  return add_stored(link, desc, true)
end

---------------------------------------------------------------------------
-- Inserting
---------------------------------------------------------------------------

local PREFIXES = {
  "file:", "id:", "https://", "http://", "mailto:", "shell:", "help:", "man:", "attachment:", "doi:", "file+sys:",
}

--- File name completion relative to the directory of buffer `bufnr`.
local function complete_files(lead, bufnr)
  local expanded = vim.fn.expand(lead)
  if expanded:match("^/") or lead:match("^~") or expanded:match("^%a:[/\\]") then
    return vim.fn.getcompletion(lead, "file")
  end
  local base = base_dir(bufnr) .. "/"
  local out = {}
  for _, f in ipairs(vim.fn.getcompletion(base .. lead, "file")) do
    out[#out + 1] = f:sub(1, #base) == base and f:sub(#base + 1) or f
  end
  return out
end

M._complete_bufnr = nil

function M._complete(arglead, _, _)
  local bufnr = M._complete_bufnr or 0
  local out = {}
  local ftarget = arglead:match("^file:(.*)$")
  if ftarget then
    for _, f in ipairs(complete_files(ftarget, bufnr)) do
      out[#out + 1] = "file:" .. f
    end
    return out
  end
  if arglead:match("^[%./~]") then
    return complete_files(arglead, bufnr)
  end
  local candidates = {}
  for _, s in ipairs(M.stored) do
    candidates[#candidates + 1] = s.link
  end
  for _, s in ipairs(M.stored) do
    if s.desc then
      candidates[#candidates + 1] = s.desc
    end
  end
  for _, p in ipairs(PREFIXES) do
    candidates[#candidates + 1] = p
  end
  for name in pairs(lopts().abbreviations or {}) do
    candidates[#candidates + 1] = name .. ":"
  end
  for name in pairs(lopts().types or {}) do
    candidates[#candidates + 1] = name .. ":"
  end
  if vim.api.nvim_buf_is_valid(bufnr) and utils.is_org(bufnr) then
    for name in pairs(files.get_buffer(bufnr).settings.link_abbrevs) do
      candidates[#candidates + 1] = name .. ":"
    end
    for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
      candidates[#candidates + 1] = "*" .. hl:plain_title()
    end
  end
  local seen = {}
  for _, c in ipairs(candidates) do
    if not seen[c] and c:lower():find(arglead:lower(), 1, true) == 1 then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return out
end

function M._complete_file(arglead, _, _)
  return complete_files(arglead, M._complete_bufnr or 0)
end

--- Build a bracket link string (org-link-make-string). A description
--- containing `]]` or ending with `]` gets a zero width space so the link
--- stays valid.
function M.format(target, desc)
  if desc then
    desc = vim.trim(desc)
    if desc == "" then
      desc = nil
    end
  end
  if desc then
    desc = desc:gsub("%]$", "]" .. ZWSP)
    desc = desc:gsub("%]%]", "]" .. ZWSP .. "]")
    return "[[" .. M.escape(target) .. "][" .. desc .. "]]"
  end
  return "[[" .. M.escape(target) .. "]]"
end

--- Write `path` as `links.file_path_type` asks, relative to the directory
--- `dir` (org-link--normalize-filename).
function M.normalize_file_path(path, method, dir)
  method = method or lopts().file_path_type or "adaptive"
  if type(method) == "function" then
    return method(path)
  end
  local expanded = vim.fn.expand(path)
  if not expanded:match("^/") and not expanded:match("^%a:[/\\]") then
    expanded = dir .. "/" .. expanded
  end
  local full = vim.fs.normalize(vim.fn.fnamemodify(expanded, ":p"))
  if path:sub(-1) == "/" and full:sub(-1) ~= "/" then
    full = full .. "/"
  end
  if method == "absolute" then
    return vim.fn.fnamemodify(full, ":~")
  elseif method == "noabbrev" then
    return full
  end
  dir = vim.fs.normalize(dir):gsub("/$", "") .. "/"
  if method == "relative" then
    local a = vim.split(dir:gsub("/$", ""), "/", { plain = true })
    local b = vim.split(full, "/", { plain = true })
    local k = 1
    while k <= #a and k <= #b and a[k] == b[k] do
      k = k + 1
    end
    local parts = {}
    for _ = k, #a do
      parts[#parts + 1] = ".."
    end
    for j = k, #b do
      parts[#parts + 1] = b[j]
    end
    local rel = table.concat(parts, "/")
    return rel == "" and "." or rel
  end
  if full:sub(1, #dir) == dir then
    return full:sub(#dir + 1)
  end
  return vim.fn.fnamemodify(full, ":~")
end

--- Default description of a link: the type's `insert_description`, else
--- `links.make_description` (org-link-get-description).
local function default_description(link, desc)
  local scheme = link:match("^([%a][%w+%-]*):")
  local t = M.link_type(scheme)
  if t and t.insert_description ~= nil then
    local d = t.insert_description
    if type(d) == "function" then
      local ok, r = pcall(d, link, desc)
      return ok and r or nil
    end
    return d
  end
  local fn = lopts().make_description
  if type(fn) == "function" then
    local ok, r = pcall(fn, link, desc)
    return ok and r or nil
  end
  return desc
end

--- Format `link` for the current buffer (org-link-make-string-for-buffer):
--- strip <> of plain links, shorten links to this file to their search
--- option and write file paths per `links.file_path_type`.
function M.format_for_buffer(link, desc, fopts)
  fopts = fopts or {}
  local bufnr = fopts.bufnr or vim.api.nvim_get_current_buf()
  if link:match("^<[%a][%w+%-]*:.*>$") then
    link = link:sub(2, -2)
  end
  local cur = vim.api.nvim_buf_get_name(bufnr)
  if cur ~= "" then
    local p, s = link:match("^file:(.-)::(.*)$")
    if p and p ~= "" then
      local a = vim.uv.fs_realpath(vim.fn.expand(p)) or vim.fs.normalize(vim.fn.expand(p))
      local b = vim.uv.fs_realpath(cur) or vim.fs.normalize(cur)
      if a == b then
        link = s
      end
    end
  end
  local ftype, rest = link:match("^(file):(.*)$")
  if not ftype then
    ftype, rest = link:match("^(docview):(.*)$")
  end
  if ftype then
    local path, search = rest, nil
    local p, s = rest:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local orig = path
    if path == "" then
      path = cur
    end
    if path ~= "" then
      path = M.normalize_file_path(path, fopts.path_type, base_dir(bufnr))
    end
    link = ftype .. ":" .. path .. (search and ("::" .. search) or "")
    if desc == orig then
      desc = path
    end
  end
  if desc == nil then
    desc = default_description(link, nil)
  end
  if fopts.interactive then
    desc = utils.input({ prompt = "Description: ", default = desc or "" })
    if desc == nil then
      return nil
    end
  end
  if desc and not desc:match("%S") then
    desc = nil
  end
  return M.format(link, desc)
end

--- Insert `text` (may contain newlines) after the cursor character, or
--- replace the range { srow, scol, erow, ecol } (1-based, inclusive).
local function put_text(text, range)
  local parts = vim.split(text, "\n", { plain = true })
  local srow, scol0, erow, ecol0
  if range then
    srow, scol0, erow, ecol0 = range[1], range[2] - 1, range[3], range[4]
  else
    local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local at = line == "" and 0 or math.min(col0 + 1, #line)
    srow, scol0, erow, ecol0 = row, at, row, at
  end
  vim.api.nvim_buf_set_text(0, srow - 1, scol0, erow - 1, ecol0, parts)
  local last_row = srow + #parts - 1
  local last_col = (#parts == 1 and scol0 or 0) + #parts[#parts]
  vim.api.nvim_win_set_cursor(0, { last_row, math.max(0, last_col - 1) })
end

--- Read a file name and make a file link (org-link-complete-file). With
--- `absolute`, the path is absolute; otherwise relative when the file is
--- below the buffer's directory.
local function complete_file_link(bufnr, absolute)
  M._complete_bufnr = bufnr
  local ok, file = pcall(vim.fn.input, {
    prompt = "File: ",
    completion = "customlist,v:lua.require'org.links'._complete_file",
    cancelreturn = vim.NIL,
  })
  M._complete_bufnr = nil
  if not ok or file == vim.NIL or vim.trim(file) == "" then
    return nil
  end
  file = vim.trim(file)
  local full = M.resolve_path(file, bufnr)
  if absolute then
    return "file:" .. vim.fn.fnamemodify(full, ":~")
  end
  local dir = base_dir(bufnr) .. "/"
  if full:sub(1, #dir) == dir then
    return "file:" .. full:sub(#dir + 1)
  end
  return "file:" .. file
end

--- Completion for a link type entered alone (org-link--try-special-completion).
local function special_completion(scheme, bufnr)
  local t = M.link_type(scheme)
  if t and t.complete then
    return t.complete()
  end
  if scheme == "file" then
    return complete_file_link(bufnr)
  elseif scheme == "id" then
    local idm = require("org.id")
    local ids = idm.known_ids and idm.known_ids() or {}
    local id = utils.input_complete("ID: ", ids)
    return id and vim.trim(id) ~= "" and ("id:" .. vim.trim(id)) or nil
  elseif scheme == "attachment" then
    local list = require("org.attach").list({ bufnr = bufnr, lnum = vim.api.nvim_win_get_cursor(0)[1] })
    local names = vim.tbl_map(function(p)
      return vim.fn.fnamemodify(p, ":t")
    end, list or {})
    local name = utils.input_complete("Attachment: ", names)
    return name and vim.trim(name) ~= "" and ("attachment:" .. vim.trim(name)) or nil
  end
  local v = utils.input({ prompt = "Link (no completion): ", default = scheme .. ":" })
  return v
end

local function all_prefixes(bufnr)
  local out = {}
  for name in pairs(M.URL_SCHEMES) do
    out[name] = true
  end
  for name in pairs(lopts().types or {}) do
    out[name] = true
  end
  for name in pairs(lopts().abbreviations or {}) do
    out[name] = true
  end
  if utils.is_org(bufnr) then
    for name in pairs(files.get_buffer(bufnr).settings.link_abbrevs) do
      out[name] = true
    end
  end
  return out
end

local function remove_stored(link)
  for i, s in ipairs(M.stored) do
    if s.link == link then
      table.remove(M.stored, i)
      return
    end
  end
end

--- Insert (or edit) a link (org-insert-link). In Visual mode the selection
--- becomes the description. On a link, edit it; a plain or angle link
--- becomes a bracket link. An empty answer inserts the last stored link.
--- A count stands for the prefix argument: 4 (C-u) prompts for a file, 16
--- (C-u C-u) the same with an absolute path, 64 keeps (or removes) the
--- inserted stored link against `links.keep_stored_after_insertion`.
function M.insert_link(arg)
  arg = arg or vim.v.count
  local bufnr = vim.api.nvim_get_current_buf()
  local region = visual_region()
  local desc, link, range
  if region then
    local parts = vim.api.nvim_buf_get_text(0, region[1] - 1, region[2] - 1, region[3] - 1, region[4], {})
    desc = table.concat(parts, "\n")
    range = region
  else
    local existing = M.link_at_cursor()
    if existing and existing.type ~= "radio" then
      range = { existing.lnum, existing.start_col, existing.end_lnum or existing.lnum, existing.end_col }
      -- a bracket link keeps its description; a plain or angle link
      -- becomes a bracket link
      local default = existing.target
      if existing.raw_target then
        default = unescape(existing.raw_target)
        desc = existing.desc
      end
      local ok, v = pcall(vim.fn.input, { prompt = "Link: ", default = default, cancelreturn = vim.NIL })
      if not ok or v == vim.NIL then
        return
      end
      link = v
    end
  end
  if not link and arg > 0 and arg < 64 then
    link = complete_file_link(bufnr, arg >= 16)
    if not link then
      return
    end
  end
  if not link then
    M._complete_bufnr = bufnr
    local last = M.stored[1] and M.stored[1].link
    local ok, v = pcall(vim.fn.input, {
      prompt = last and ("Insert link (default " .. last .. "): ") or "Insert link: ",
      completion = "customlist,v:lua.require'org.links'._complete",
      cancelreturn = vim.NIL,
    })
    M._complete_bufnr = nil
    if not ok or v == vim.NIL then
      return
    end
    v = vim.trim(v)
    if v == "" then
      v = last
    end
    if not v or v == "" then
      utils.warn("No link selected")
      return
    end
    -- a stored link's description selects that link
    for _, s in ipairs(M.stored) do
      if s.desc and s.desc == v and s.link ~= v then
        v = s.link
        break
      end
    end
    local prefixes = all_prefixes(bufnr)
    local bare = v:match("^([%a][%w+%-]*):$") or v:match("^([%a][%w+%-]*)$")
    if bare and prefixes[bare] then
      v = special_completion(bare, bufnr)
      if not v or v == "" then
        return
      end
    end
    link = v
    for _, s in ipairs(M.stored) do
      if s.link == link then
        desc = desc or s.desc
        break
      end
    end
  end
  local keep = lopts().keep_stored_after_insertion and true or false
  if arg >= 64 then
    keep = not keep
  end
  local text = M.format_for_buffer(link, desc, {
    bufnr = bufnr,
    interactive = true,
    path_type = arg >= 16 and arg < 64 and "absolute" or nil,
  })
  if not text then
    return
  end
  if not keep then
    remove_stored(link)
  end
  put_text(text, range)
end

--- Insert stored links at the cursor (org-insert-all-links): each link is
--- `pre .. link .. post`. `n` inserts (and forgets) the last `n` links;
--- otherwise every link, forgotten unless `keep`.
local function insert_stored(n, keep, pre, post)
  if #M.stored == 0 then
    utils.notify("No link to insert")
    return
  end
  local chunks = {}
  local list
  if n then
    list = {}
    for _ = 1, n do
      local l = table.remove(M.stored, 1)
      if not l then
        break
      end
      list[#list + 1] = l
    end
  else
    list = vim.list_slice(M.stored, 1, #M.stored)
  end
  for _, s in ipairs(list) do
    chunks[#chunks + 1] = pre .. M.format_for_buffer(s.link, s.desc or "<no description>") .. post
    if not n and not keep then
      remove_stored(s.link)
    end
  end
  put_text(table.concat(chunks))
end

--- Insert the most recently stored link followed by a newline and forget
--- it (org-insert-last-stored-link). A count inserts that many links.
function M.insert_last_stored_link(arg)
  arg = arg or vim.v.count
  insert_stored(math.max(arg, 1), false, "", "\n")
end

--- Insert every stored link as a `- ` item and forget them
--- (org-insert-all-links). A count of 4 (C-u) keeps them.
function M.insert_all_links(arg)
  arg = arg or vim.v.count
  insert_stored(nil, arg == 4, "- ", "\n")
end

---------------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------------

--- Toggle descriptive / literal display of links in the buffer
--- (org-toggle-link-display). Only link concealing changes.
function M.toggle_link_display()
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.b[bufnr].org_link_descriptive
  if cur == nil then
    cur = config.opts.ui.conceal_links ~= false
  end
  vim.b[bufnr].org_link_descriptive = not cur
  if vim.wo.conceallevel == 0 then
    vim.wo.conceallevel = 2
  end
  if utils.is_org(bufnr) then
    vim.cmd("syntax clear")
    require("org.syntax").apply(bufnr)
  end
  utils.notify(cur and "Literal link display" or "Descriptive link display")
end

--- Lines whose links are not links for Emacs (src, example, export and
--- comment blocks, comments, fixed-width lines, node properties and
--- keywords other than TITLE, AUTHOR, DATE and CAPTION).
local function ignored_lines(lines)
  local skip = {}
  local block
  local in_props = false
  for i, l in ipairs(lines) do
    local low = l:lower()
    if block then
      skip[i] = true
      if low:match("^%s*#%+end_" .. block) then
        block = nil
      end
    else
      local kind = low:match("^%s*#%+begin_(%a+)")
      if kind == "src" or kind == "example" or kind == "export" or kind == "comment" then
        block = kind
        skip[i] = true
      elseif low:match("^%s*:properties:%s*$") then
        in_props = true
        skip[i] = true
      elseif in_props then
        skip[i] = true
        if low:match("^%s*:end:%s*$") then
          in_props = false
        end
      elseif l:match("^%s*#%s") or l:match("^%s*#$") or l:match("^%s*:%s") or l:match("^%s*:$") then
        skip[i] = true
      else
        local key = l:match("^%s*#%+([%w_]+):")
        if key and not ({ TITLE = true, AUTHOR = true, DATE = true, CAPTION = true })[key:upper()] then
          skip[i] = true
        end
      end
    end
  end
  return skip
end

--- Spans of inline code and verbatim (`~...~`, `=...=`) in `line`.
local function verbatim_spans(line)
  local spans = {}
  local init = 1
  while true do
    local s = line:find("[=~]", init)
    if not s then
      break
    end
    local m = line:sub(s, s)
    local pre = line:sub(s - 1, s - 1)
    local nxt = line:sub(s + 1, s + 1)
    if (pre == "" or pre:match("[%s%(%{'\"%-]")) and nxt ~= "" and not nxt:match("%s") then
      local e = s + 1
      local found
      while true do
        e = line:find(m, e + 1, true)
        if not e then
          break
        end
        local after = line:sub(e + 1, e + 1)
        if not line:sub(e - 1, e - 1):match("%s") and (after == "" or after:match("[%s%-%.,;:!%?'\"%)%}%[%]]")) then
          found = e
          break
        end
      end
      if found then
        spans[#spans + 1] = { s, found }
        init = found + 1
      else
        init = s + 1
      end
    else
      init = s + 1
    end
  end
  return spans
end

--- Links of `line` that Emacs treats as links.
local function real_links(line)
  local spans = verbatim_spans(line)
  return vim.tbl_filter(function(lk)
    for _, sp in ipairs(spans) do
      if lk.start_col >= sp[1] and lk.start_col <= sp[2] then
        return false
      end
    end
    return true
  end, M.parse_links(line))
end

M.verbatim_spans = verbatim_spans
M.real_links = real_links

M._search_failed = nil

--- Move to the next (dir = 1) or previous (dir = -1) link of any kind.
--- Repeating a failed search wraps around the buffer (org-next-link).
local function goto_link(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local last = #lines
  local skip = utils.is_org() and ignored_lines(lines) or {}
  local f = M._search_failed
  local wrapped = false
  if f and f.bufnr == bufnr and f.dir == dir and f.lnum == lnum and f.col == col then
    wrapped = true
    if dir > 0 then
      lnum, col = 1, 0
    else
      lnum, col = last, math.huge
    end
  end
  M._search_failed = nil
  local l = lnum
  while l >= 1 and l <= last do
    local found
    if not skip[l] then
      local list = real_links(lines[l])
      if dir > 0 then
        for _, lk in ipairs(list) do
          if l > lnum or lk.start_col > col or (wrapped and lk.start_col >= col) then
            found = lk
            break
          end
        end
      else
        for i = #list, 1, -1 do
          local lk = list[i]
          if l < lnum or lk.start_col < col then
            found = lk
            break
          end
        end
      end
    end
    if found then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { l, found.start_col - 1 })
      pcall(vim.cmd, "normal! zv")
      if wrapped then
        utils.notify(dir > 0 and "Link search wrapped back to beginning of buffer"
          or "Link search wrapped back to end of buffer")
      end
      return true
    end
    l = l + dir
  end
  local c = vim.api.nvim_win_get_cursor(0)
  M._search_failed = { bufnr = bufnr, dir = dir, lnum = c[1], col = c[2] + 1 }
  return false
end

function M.next_link()
  for _ = 1, math.max(vim.v.count, 1) do
    if not goto_link(1) then
      utils.notify("No further link found")
      return
    end
  end
end

function M.prev_link()
  for _ = 1, math.max(vim.v.count, 1) do
    if not goto_link(-1) then
      utils.notify("No further link found")
      return
    end
  end
end

--- Links in the entry at the cursor, from its headline to the next
--- headline, without duplicates (org-offer-links-in-entry). Links in
--- comments, keywords and properties count (org-open-at-point opens
--- them); links in src, example and export blocks and verbatim do not.
function M.entry_links()
  if not utils.is_org() then
    return {}
  end
  local lnum = utils.cursor()
  local hl = files.get_buffer(0):headline_at(lnum)
  if not hl then
    return {}
  end
  local out, seen = {}, {}
  local last = hl.body_end or hl.line
  local lines = vim.api.nvim_buf_get_lines(0, hl.line - 1, last, false)
  local block
  for l, line in ipairs(lines) do
    local low = line:lower()
    if block then
      if low:match("^%s*#%+end_" .. block) then
        block = nil
      end
    else
      local kind = low:match("^%s*#%+begin_(%a+)")
      if kind == "src" or kind == "example" or kind == "export" then
        block = kind
      else
        for _, lk in ipairs(real_links(line)) do
          if not seen[lk.raw] then
            seen[lk.raw] = true
            lk.lnum = hl.line + l - 1
            out[#out + 1] = lk
          end
        end
      end
    end
  end
  return out
end

--- On a headline without a link at the cursor, open one of the entry's
--- links, or all of them (org-offer-links-in-entry). Without links, open
--- the entry's attachment directory when it exists. Returns false when
--- there is nothing to open.
function M.open_entry_links(arg)
  arg = arg or vim.v.count
  local list = M.entry_links()
  local bufnr = vim.api.nvim_get_current_buf()
  if #list == 0 then
    local ok, dir = pcall(function()
      return require("org.attach").dir_for({ bufnr = bufnr, lnum = utils.cursor() })
    end)
    if ok and dir and utils.is_dir(dir) then
      utils.notify("Opening attachment")
      vim.cmd("edit " .. vim.fn.fnameescape(dir))
      return true
    end
    utils.notify("No links")
    return false
  end
  local chosen = { list[1] }
  if #list > 1 then
    local labels = {}
    for i, lk in ipairs(list) do
      labels[i] = lk.desc and (lk.desc .. " (" .. lk.target .. ")") or lk.target
    end
    labels[#labels + 1] = "Open all links"
    local pick, idx = utils.select(labels, { prompt = "Select link to open" })
    if not pick then
      return
    end
    chosen = idx > #list and list or { list[idx] }
  end
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  for i, lk in ipairs(chosen) do
    if i > 1 and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_buf(win, bufnr)
      vim.api.nvim_win_set_cursor(win, pos)
    end
    M.open(lk.target, { bufnr = bufnr, link = lk, arg = arg, avoid = { lk.lnum, lk.start_col + 2 } })
  end
  return true
end

--- Tag of the headline under the cursor, when the cursor is on the tags.
local function tag_at_cursor(line, col)
  local s, e = line:find("%s:[^%s]+:%s*$")
  if not s then
    return nil
  end
  s = s + 1
  e = line:find(":%s*$", s + 1)
  if col < s or col > e then
    return nil
  end
  local pos = s
  for tag in line:sub(s + 1, e - 1):gmatch("[^:]+") do
    -- the colon before a tag belongs to it
    if col >= pos and col <= pos + #tag then
      return tag
    end
    pos = pos + #tag + 1
  end
end

--- C-c C-o: open the link / footnote / date at point; on the tags of a
--- headline, show a tags agenda for the tag; elsewhere on a headline,
--- offer the entry's links (org-open-at-point).
function M.open_at_point_or_entry()
  local arg = vim.v.count
  local r = require("org.context").open_at_point()
  if r ~= false then
    return r
  end
  local line = vim.api.nvim_get_current_line()
  if not require("org.parser").headline_level(line) then
    return false
  end
  local _, col = utils.cursor()
  local tag = tag_at_cursor(line, col)
  if tag then
    return require("org.agenda").open_tags(tag, arg > 0)
  end
  return M.open_entry_links(arg)
end

--- Export a link with its type's `export` function (org-link-parameters
--- `:export`). `backend` is "html", "md", "latex" or "ascii". Returns nil
--- when the type has none (or it returns nil).
function M.export_link(path, desc, backend)
  local scheme, rest = path:match("^([%a][%w+%-]*):(.*)$")
  local t = M.link_type(scheme)
  if t and type(t.export) == "function" then
    local r = t.export(rest, desc, backend)
    if type(r) == "string" then
      return r
    end
  end
end

--- C-c ' on `#+INCLUDE:`, `#+SETUPFILE:` or `#+BIBLIOGRAPHY:` visits the
--- file (org-edit-special). Returns false on other lines.
function M.open_keyword_file(line, bufnr)
  local key, value = line:match("^%s*#%+([%w_]+):%s*(.-)%s*$")
  if not key or not ({ INCLUDE = true, SETUPFILE = true, BIBLIOGRAPHY = true })[key:upper()] then
    return false
  end
  if value == "" then
    utils.warn("No file to edit")
    return true
  end
  local f = value:match('^"(.-)"') or value:match("^%S+")
  if f:match("^%a[%w+.%-]*://") then
    utils.warn("Files located with a URL cannot be edited")
    return true
  end
  M.open("file:" .. M.resolve_path(f, bufnr or 0), { bufnr = bufnr })
  return true
end

--- Jump back to the position before the last link was followed
--- (org-mark-ring-goto).
function M.mark_ring_goto()
  vim.cmd("normal! \15")
end

return M
