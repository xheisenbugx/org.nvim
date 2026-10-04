---@mod org.links.search Link search strings (org-link-search)
---
--- Where a link's search string points in a buffer or file
--- (search_location, search_in_buffer, radio targets) and the Emacs
--- regexp translation `/regexp/` searches use. Part of org.links,
--- which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

local lopts = shared.lopts
local split_words = shared.split_words
local upper_words = shared.upper_words

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
    require("org.fold").reveal_cursor("link-search")
  end
end

--- Text of `lines`, lines `first`.. of a buffer, with functions mapping a
--- 1-based byte offset to { lnum, col0 } and back.
local function lines_text(lines, first)
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

--- Text of lines `first`..`last` of the buffer, with functions mapping a
--- 1-based byte offset to { lnum, col0 } and back.
local function buffer_text(bufnr, first, last)
  first = first or 1
  return lines_text(vim.api.nvim_buf_get_lines(bufnr, first - 1, last or -1, false), first)
end

local function words_pattern(words, sep)
  return table.concat(
    vim.tbl_map(function(w)
      return vim.pesc(w:lower())
    end, words),
    sep
  )
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
      local fmt = blocks.coderef_format(switches)
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

--- Where a link search string points (org-link-search), found without
--- moving the cursor or changing anything, in `src` (see `search_source`):
--- `#id` (CUSTOM_ID), `(label)` (coderef), `*heading`, otherwise
--- dedicated `<<target>>`, `#+NAME:`, headline, then (see
--- `links.search_must_match_exact_headline`) text. Following a link
--- (`search_in_buffer`) and `org.api` resolving one both use it, so they
--- agree. Returns the line (1-based) and column (0-based) of the match,
--- else nil, nil, a message and, for a search that does more than move
--- the cursor, its kind: "regexp" (`/regexp/`: a sparse tree or occur) or
--- "create" (no match, and query-to-create offers to make the heading).
--- `sopts.must_match` stands for `links.search_must_match_exact_headline`
--- (export binds it to t).
---@param search string
---@param src { lines: string[], file?: org.File }
---@param sopts? { avoid?: integer[], range?: integer[], must_match?: boolean|"query-to-create" }
---@return integer|nil lnum, integer|nil col, string|nil err, "regexp"|"create"|nil kind
function M.search_location(search, src, sopts)
  sopts = sopts or {}
  if not search or vim.trim(search) == "" then
    return nil, nil, string.format('Invalid search string "%s"', tostring(search))
  end
  local normalized = search:gsub("\n[ \t]*", " ")
  local starred = normalized:sub(1, 1) == "*"
  local words = split_words(starred and search:sub(2) or search)
  local file = src.file
  -- a range restricts the search (org-id-open narrows to the entry)
  local first, last = 1, #src.lines
  if sopts.range then
    first, last = sopts.range[1], sopts.range[2]
  end
  local headlines = {}
  for _, hl in ipairs(file and file.headlines or {}) do
    if hl.line >= first and hl.line <= last then
      headlines[#headlines + 1] = hl
    end
  end
  local text, pos, offset, lines = lines_text(vim.list_slice(src.lines, first, last), first)
  local lower = text:lower()

  if normalized:sub(1, 1) == "#" then
    local id = normalized:sub(2):lower()
    -- the file-level property drawer (org-find-property: point-min)
    local fcid = file and first == 1 and file.properties and file.properties.CUSTOM_ID
    if fcid and fcid:lower() == id then
      return 1, 0
    end
    for _, hl in ipairs(headlines) do
      local cid = hl.properties.CUSTOM_ID
      if cid and cid:lower() == id then
        return hl.line, 0
      end
    end
    return nil, nil, "No match for custom ID: " .. normalized:sub(2)
  end
  local coderef = normalized:match("^%((.*)%)$")
  if coderef then
    local l, c = search_coderef(lines, coderef)
    if l then
      return first + l - 1, c
    end
    return nil, nil, "No match for coderef: " .. coderef
  end
  if normalized:match("^/(.*)/$") then
    return nil, nil, nil, "regexp"
  end
  if #words == 0 then
    return nil, nil, "No match for fuzzy expression: " .. normalized
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
        -- a real target, not text in a link (org-link-search checks
        -- that `org-element-context` is a target)
        local l, c = pos(s)
        if not M.in_bracket_link(lines[l - first + 1], c + 1) then
          return l, c
        end
      end
      init = s + 1
    end
    -- #+NAME: words
    local want = upper_words(table.concat(words, " "))
    for i, l in ipairs(lines) do
      local name = l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]+(.-)[ \t]*$")
      if name and vim.deep_equal(upper_words(name), want) then
        return first + i - 1, 0
      end
    end
  end
  if file then
    local want = vim.tbl_map(string.upper, words)
    for _, hl in ipairs(headlines) do
      if vim.deep_equal(upper_words(M.normalize_string(hl.title)), want) then
        return hl.line, 0
      end
    end
    local must = sopts.must_match
    if must == nil then
      must = lopts().search_must_match_exact_headline
    end
    if must == nil then
      must = "query-to-create"
    end
    if must == "query-to-create" then
      return nil, nil, "No match for fuzzy expression: " .. normalized, "create"
    end
    if starred or must then
      return nil, nil, "No match for fuzzy expression: " .. normalized
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
        return l, c
      end
    end
    init = s + 1
  end
  return nil, nil, "No match for fuzzy expression: " .. normalized
end

--- What a link search looks in (`search_location`): the lines of buffer
--- `bufnr`, with their parse in an Org buffer; without a buffer, the
--- lines of file `path` (loaded in a buffer or read from disk, parsed when
--- it's an Org file), as following the link would open it. nil when the
--- file can't be read.
---@param bufnr? integer
---@param path? string
---@return { lines: string[], file?: org.File }|nil
function M.search_source(bufnr, path)
  bufnr = bufnr or (path and utils.find_buffer(path))
  if bufnr then
    local is_org = utils.is_org(bufnr) or vim.api.nvim_buf_get_name(bufnr):match("%.org$") ~= nil
    return {
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      file = is_org and files.get_buffer(bufnr) or nil,
    }
  end
  if not path then
    return nil
  end
  if vim.filetype.match({ filename = path }) == "org" then
    local f = files.get(path)
    return f and { lines = f.lines, file = f } or nil
  end
  local lines = utils.readfile(path)
  return lines and { lines = lines } or nil
end

--- Search the current buffer for a link search string (org-link-search,
--- see `search_location`) and move the cursor there. First the
--- `links.search_functions` and a BibTeX key search; a `/regexp/` makes a
--- sparse tree in Org buffers, a location list elsewhere; a missing
--- heading may be created (query-to-create). Returns true when found
--- (cursor moved), else false and a message.
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
  -- a key in a BibTeX file (org-execute-file-search-in-bibtex)
  if require("org.bibtex").file_search(search) then
    return true
  end
  local src = M.search_source(bufnr) --[[@as { lines: string[], file?: org.File }]]
  local lnum, col, err, kind = M.search_location(search, src, sopts)
  if lnum then
    goto_pos(lnum, col, sopts.stealth)
    return true
  end
  local normalized = search:gsub("\n[ \t]*", " ")
  if kind == "regexp" then
    local regex = normalized:match("^/(.*)/$")
    local vre = M.emacs_regexp_to_vim(search:match("^/(.*)/$"))
    local ok, re = pcall(vim.regex, vre)
    if not ok then
      return false, "Invalid regexp: " .. regex
    end
    if src.file then
      require("org.agenda.sparse").regexp(vre)
    else
      local first, last = 1, #src.lines
      if sopts.range then
        first, last = sopts.range[1], sopts.range[2]
      end
      local items = {}
      for i = first, math.min(last, #src.lines) do
        local l = src.lines[i]
        local s = re:match_str(l)
        if s then
          items[#items + 1] = { bufnr = bufnr, lnum = i, col = s + 1, text = l }
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
  if kind == "create" and utils.confirm("No match - create this as a new heading?") then
    local starred = normalized:sub(1, 1) == "*"
    create_heading(bufnr, starred and search:sub(2) or search, sopts.container)
    return true
  end
  return false, err
end

--- Go to the radio target `<<<target>>>` (org-link--search-radio-target).
function M.search_radio_target(target)
  local text, pos = buffer_text(0)
  local pat = "<<<" .. words_pattern(split_words(target), "[ \t]+\n?[ \t]*") .. ">>>"
  local lower = text:lower()
  local init = 1
  while true do
    local s = lower:find(pat, init)
    if not s then
      return false, "No match for radio target: " .. target
    end
    local l, c = pos(s)
    -- not one in a link's description (org-element-context)
    if not M.in_bracket_link(vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1], c + 1) then
      goto_pos(l, c)
      return true
    end
    init = s + 1
  end
end

-- for the parts loaded after this one
shared.goto_pos = goto_pos
shared.push_jump = push_jump
