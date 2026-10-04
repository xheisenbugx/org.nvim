---@mod org.links.parse Reading links: strings, parsing, abbreviations
---
--- Escaping and normalising link strings, parsing bracket, angle,
--- plain and radio links out of text (parse_links, classify,
--- link_at_cursor) and expanding link abbreviations. Part of
--- org.links, which loads it.

local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

local is_type = shared.is_type
local lopts = shared.lopts

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

local OPENER, CLOSER = "[<(%[]", "[%]>)]"

--- End of a parenthesis group `<([` ... `])>` (one nested level) starting
--- at `j`, or nil.
local function scan_group(text, j)
  local k, n = j + 1, #text
  while k <= n do
    local d = text:sub(k, k)
    if d:match(CLOSER) then
      return k
    elseif d:match(OPENER) then
      local e = text:find(PLAIN_BAD, k + 1)
      if e and text:sub(e, e):match(CLOSER) then
        k = e + 1
      else
        return nil
      end
    elseif d:match(PLAIN_BAD) then
      return nil
    else
      k = k + 1
    end
  end
end

--- End of a plain link path starting at `i` (org-link-plain-re): groups in
--- `<([` and `])>` (two levels) are allowed, the path has at least two
--- elements, and it cannot end with punctuation other than `-`, `/` or a
--- group.
local function scan_plain(text, i)
  local j, last, tokens = i, nil, 0
  local n = #text
  while j <= n do
    local c = text:sub(j, j)
    if c:match(OPENER) then
      local k = scan_group(text, j)
      if not k then
        break
      end
      tokens = tokens + 1
      -- the path needs at least two elements
      if tokens > 1 then
        last = k
      end
      j = k + 1
    elseif c:match(PLAIN_BAD) then
      break
    else
      tokens = tokens + 1
      if tokens > 1 and (c == "/" or c == "-" or not c:match("%p")) then
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

--- Whether byte `col1` (1-based) of `line` is inside a bracket link. A
--- `<<target>>` or `<<<radio target>>>` there is only text: a link's
--- description holds no targets (org-element-object-restrictions), so
--- Emacs, which checks `org-element-context`, skips it.
function M.in_bracket_link(line, col1)
  if not line:find("[[", 1, true) then
    return false
  end
  for _, lk in ipairs(M.parse_links(line, { bracket_only = true })) do
    if col1 >= lk.start_col and col1 <= lk.end_col then
      return true
    end
  end
  return false
end

--- `<<target>>` and `<<<radio>>>` spans of a line: { s, e, text, radio, ts, te }
--- where ts..te is the text inside the brackets.
function M.line_targets(line)
  local out = {}
  local init = 1
  while true do
    local s = line:find("<<", init, true)
    if not s then
      break
    end
    local radio = line:sub(s + 2, s + 2) == "<"
    local open = radio and 3 or 2
    local close = radio and ">>>" or ">>"
    local ce = line:find(close, s + open, true)
    local text = ce and line:sub(s + open, ce - 1)
    if
      text
      and text ~= ""
      and not text:find("[<>\n]")
      and not text:match("^%s")
      and not text:match("%s$")
      and line:sub(s - 1, s - 1) ~= "<"
      and line:sub(ce + #close, ce + #close) ~= ">"
      -- text in a link's description is no target (org-element-context)
      and not M.in_bracket_link(line, s)
    then
      out[#out + 1] = {
        s = s,
        e = ce + #close - 1,
        ts = s + open,
        te = ce - 1,
        text = text,
        radio = radio,
      }
      init = ce + #close
    else
      init = s + 2
    end
  end
  return out
end

--- Byte (1-based) where `<<name>>` (`name` taken literally) starts in
--- `line` outside any bracket link, else nil.
---@param line string
---@param name string
---@return integer|nil
function M.find_target(line, name)
  local init = 1
  while true do
    local at = line:find("<<" .. name .. ">>", init, true)
    if not at or not M.in_bracket_link(line, at) then
      return at
    end
    init = at + 1
  end
end

--- Radio targets `<<<text>>>` of the buffer, longest first.
function M.radio_targets(bufnr)
  local seen, out = {}, {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)) do
    for s, t in l:gmatch("()<<<([^<>]-)>>>") do
      if vim.trim(t) ~= "" and not seen[t] and not M.in_bracket_link(l, s) then
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

-- `%(function)` expansions by abbreviation and tag, and the functions
-- Emacs refused (org-link-expand-abbrev then disables the abbreviation)
local abbrev_calls, abbrev_refused = {}, {}

--- An abbreviation `rpl` containing `%(function)` for `tag`: FUNCTION is
--- called with the tag in a separate Emacs (`babel.emacs_lisp`, whose
--- `args` can load the function), where Emacs only calls functions whose
--- `org-link-abbrev-safe` or `pure` property is t. Returns nil (the link
--- stays as it is) when it can't be called.
---@return string|nil
function M.abbrev_call(rpl, tag)
  local s, e, fname = rpl:find("%%%(([^)]+)%)")
  if not s or abbrev_refused[fname] then
    return nil
  end
  local key = rpl .. "\0" .. tag
  if abbrev_calls[key] then
    return abbrev_calls[key]
  end
  local elisp = require("org.babel.elisp")
  local printed, err
  if elisp.command() then
    printed, err = elisp.eval_external(
      string.format(
        [[(let ((f (intern-soft %s)))
  (if (or (eq t (get f 'org-link-abbrev-safe)) (eq t (get f 'pure)))
      (let ((v (funcall f %s)))
        (if (stringp v) v (error "%%s did not return a string: %%S" f v)))
    (error "Disabling unsafe link abbrev: %%s
You may mark function safe via (put '%%s 'org-link-abbrev-safe t)" %s f)))]],
        elisp.lisp_string(fname),
        elisp.lisp_string(tag),
        elisp.lisp_string(rpl)
      )
    )
  else
    err = "link abbreviation " .. rpl .. " needs an Emacs to call " .. fname .. " (babel.emacs_lisp)"
  end
  local ok, v = pcall(require("org.table.elisp").read, printed or "")
  if not printed or not ok or type(v) ~= "string" then
    abbrev_refused[fname] = true
    utils.warn(tostring(err or printed))
    return nil
  end
  abbrev_calls[key] = rpl:sub(1, s - 1) .. v .. rpl:sub(e + 1)
  return abbrev_calls[key]
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
  if def:find("%(", 1, true) then
    local expanded = M.abbrev_call(def, tag)
    return expanded or target
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

-- for the parts loaded after this one
shared.split_words = split_words
shared.unescape = unescape
shared.upper_words = upper_words
