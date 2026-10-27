---@mod org.ui.highlight.block Blocks and LaTeX
---
--- Part of org.ui.highlight (the parser highlighter): block delimiter lines, the bodies of example, export, comment, quote and verse blocks (src block bodies: org.ui.src_highlight and the included syntaxes), dynamic blocks, and LaTeX fragments and environments (`ui.highlight_latex_and_related`).
---
--- Blocks are a port of org-fontify-meta-lines-and-blocks-1: a
--- `#+begin_NAME` line opens a block when a `#+end_NAME` line or a
--- headline follows (org.ui.emphasis `kinds` finds them); its begin and end
--- lines are drawn whole in orgBlockDelimiter (org-block-begin-line,
--- org-block-end-line), never spell checked. The body of a src, export or
--- example block (org-protecting-blocks) is org-block under the faces of
--- its language: when an included syntax or tree-sitter draws the language
--- (org.syntax `orgSrcBlock_*` regions, org.ui.src_highlight), its colours
--- are left alone and the body gets orgSrcBlock, a group without
--- attributes (one can be given to it); otherwise it is orgBlock. None of
--- it is spell checked but what an included syntax checks (its comments). Quote and verse bodies
--- are Org text on orgQuoteBlock (`:h org-highlights`; Emacs only with
--- org-fontify-quote-and-verse-blocks). Comment, center and special
--- blocks draw only their delimiters (their body is Org text to Emacs's
--- font-lock: it isn't a protecting block), and dynamic blocks nothing
--- here: `#+BEGIN:` and `#+END:` are keyword lines (org-meta-line, the
--- meta part). The value of a `#+CAPTION:` is org-block.
---
--- LaTeX is a port of org-do-latex-and-related: fragments (`$x$`, `$...$`,
--- `$$...$$`, `\(...\)`, `\[...\]`) and environments (`\begin{x}` at the
--- start of a line up to `\end{x}`) in orgLatex, entities (`\alpha`) in
--- orgLatexEntity and sub/superscripts (`ui.use_sub_superscripts`, a
--- buffer's `#+OPTIONS: ^:`) in orgLatexScript, found left to right the
--- way Emacs's combined regexp finds them, none spell checked. As with the
--- syntax engine, `\(`, `\[` and `$$` fragments don't go over an empty line
--- and nothing goes over a headline. "native" draws like "latex" (the tex
--- syntax isn't included with this highlighter).

local M = {}

local E = require("org.ui.emphasis")
local H = require("org.ui.highlight")

local byte, find = string.byte, string.find

--- How far up the begin line of a block open before the lines drawn is
--- looked for (as far as org.ui.highlight `window` looks for the block).
local BLOCK_LOOK = 3000
--- How far up the begin line of a LaTeX environment open before the lines
--- drawn is looked for, and down its end.
local LOOK = 1000

-- Blocks --------------------------------------------------------------------

--- Per Vim syntax and runtimepath / engine: how src bodies of it are drawn
--- ("treesitter", "syntax" or false), as org.syntax `highlighter` decides.
local drawn_cache = {} ---@type table<string, string|false>
local drawn_key ---@type string?

local function has_syntax(name)
  return #vim.api.nvim_get_runtime_file("syntax/" .. name .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("syntax/" .. name .. ".lua", false) > 0
end

--- How the body of a src or export block of `lang` is drawn by another
--- highlighter: "treesitter" (org.ui.src_highlight), "syntax" (the
--- language's syntax included by org.syntax) or false (not at all: it is
--- orgBlock).
---@param lang string
---@return string|false
local function drawn_by(lang)
  local ts = require("org.ui.src_highlight")
  local engine = ts.engine()
  if not engine then
    return false
  end
  local key = vim.o.runtimepath .. "\0" .. tostring(engine)
  if key ~= drawn_key then
    drawn_key, drawn_cache = key, {}
  end
  local syn = require("org.syntax").syntax_of(lang)
  local v = drawn_cache[syn]
  if v == nil then
    v = false
    if engine ~= "syntax" and ts.ts_lang_of_syntax(syn) then
      v = "treesitter"
    elseif
      engine ~= "treesitter"
      and syn ~= ""
      and syn:lower() ~= "org"
      and syn:match("^[%w_]+$")
      and has_syntax(syn)
    then
      v = "syntax"
    end
    drawn_cache[syn] = v
  end
  return v
end
M._drawn_by = drawn_by

--- The language of a `#+begin_src LANG` or `#+begin_export LANG` line
--- (ending at a blank, as the org.syntax regions take it).
---@param line string
---@return string?
local function language(line)
  local kind, lang = line:match("^[ \t]*#%+[bB][eE][gG][iI][nN]_(%a+)[ \t]+([^ \t]+)")
  if kind and (kind:lower() == "src" or kind:lower() == "export") then
    return lang
  end
end

--- `#+CAPTION:` or `#+CAPTION[short]:` and the blanks after it: the byte
--- the value starts at (org-block in Emacs), or nil.
---@param line string
---@return integer?
local function caption_value(line)
  local s = line:match("^[ \t]*()#%+")
  if not s or not line:sub(s + 2, s + 8):lower():find("^caption") then
    return nil
  end
  local p = s + 9
  local c = byte(line, p)
  if c == 91 then -- "[": up to the last "]:" (a greedy ".*")
    local last
    local from = p
    while true do
      local e = find(line, "]:", from, true)
      if not e then
        break
      end
      last, from = e, e + 1
    end
    if not last then
      return nil
    end
    p = last + 1
  elseif c ~= 58 then
    return nil
  end
  return line:match("^[ \t]*()", p + 1)
end

---@param ctx org.ui.highlight.Ctx
local function paint_blocks(ctx)
  local lines, roles, emit = ctx.lines, ctx.roles, ctx.emit
  local element = H.PRIO.element
  local delimiter = { hl_group = "orgBlockDelimiter", priority = element, spell = false }
  local verbatim = { hl_group = "orgBlock", priority = element, spell = false }
  -- (no attributes: org-block under the faces of the language)
  local native = { hl_group = "orgSrcBlock", priority = element }
  local native_nospell = { hl_group = "orgSrcBlock", priority = element, spell = false }
  local quote = { hl_group = "orgQuoteBlock", priority = element }
  local caption = { hl_group = "orgBlock", priority = element }
  -- how each verbatim block's body is drawn (by its begin line)
  local how = {} ---@type table<org.ui.emphasis.Block, string|false>
  local function body_of(block, i)
    local v = how[block]
    if v ~= nil then
      return v
    end
    v = false
    if block.name == "src" or block.name == "export" then
      -- the begin line: above, in the lines or before them
      local begin
      for j = i - 1, 1, -1 do
        local r = roles[j]
        if not r or r.block ~= block then
          break
        end
        if r.role == "begin" then
          begin = lines[j]
          break
        end
      end
      if not begin and roles[1] and roles[1].block == block and roles[1].role ~= "begin" then
        local above = ctx.get_lines(ctx.row0 - BLOCK_LOOK, ctx.row0)
        for j = #above, 1, -1 do
          local name, begins = E.block_line(above[j])
          if name == block.name and begins then
            begin = above[j]
            break
          end
        end
      end
      local lang = begin and language(begin)
      if lang then
        v = drawn_by(lang) or drawn_by(lang:lower())
      end
    end
    how[block] = v
    return v
  end
  for i = 1, #lines do
    local line = lines[i]
    local r = roles[i]
    if r then
      local n = #line
      if r.role ~= "body" then
        emit(i, 0, n, delimiter)
      elseif n > 0 then
        local block = r.block
        if block.verbatim then
          local v = body_of(block, i)
          if not v then
            emit(i, 0, n, verbatim)
          elseif v == "treesitter" then
            -- (the orgSrcBlock_ region of org.syntax keeps it out of spell
            -- checking too)
            emit(i, 0, n, native_nospell)
          else
            -- (spelling: as the included syntax says)
            emit(i, 0, n, native)
          end
        elseif block.name == "quote" or block.name == "verse" then
          emit(i, 0, n, quote)
        end
      end
    else
      local v = caption_value(line)
      if v and v <= #line then
        emit(i, v - 1, #line, caption)
      end
    end
  end
end

-- LaTeX ---------------------------------------------------------------------

---@param c? integer
local function blank(c)
  return c == 32 or c == 9
end

--- A letter ([[:alpha:]]: bytes of non-ASCII characters count as letters).
---@param c? integer
local function alpha(c)
  return c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c >= 128)
end

---@param c? integer
local function alnum(c)
  return c ~= nil and (alpha(c) or (c >= 48 and c <= 57))
end

--- What may follow the closing `$` of an inline fragment: punctuation, a
--- blank, a bracket or a quote, or the end of the line.
---@param c? integer
local function after_dollar(c)
  return c == nil or c == 10 or blank(c) or (c > 32 and c < 128 and c ~= 36 and not alnum(c))
end

--- Bytes that can't start an inline `$` fragment's text ([^ \t\n,;.$]).
---@param c? integer
local function bad_first(c)
  return c == nil or c == 10 or blank(c) or c == 44 or c == 59 or c == 46 or c == 36
end

--- The body of a sub/superscript at byte `p` of `s`, after its `_` or `^`
--- (org-match-substring-regexp): braces or parentheses nested up to three
--- deep (on one line), `*`, or an optional sign and letters, digits, `.`,
--- `,` and `\` ending with a letter or digit; with `braces` only braces.
--- The byte after it, or nil.
---@param s string
---@param p integer
---@param braces boolean
---@return integer?
local function script_body(s, p, braces)
  local c = byte(s, p)
  if c == 123 or (c == 40 and not braces) then
    local close = c == 123 and 125 or 41
    local depth = 0
    for k = p, #s do
      local b = byte(s, k)
      if b == 10 then
        return nil
      elseif b == c then
        depth = depth + 1
        if depth > 3 then
          return nil
        end
      elseif b == close then
        depth = depth - 1
        if depth == 0 then
          return k + 1
        end
      end
    end
    return nil
  end
  if braces then
    return nil
  end
  if c == 42 then
    return p + 1
  end
  local k = p
  if c == 43 or c == 45 then
    k = k + 1
  end
  local last
  while true do
    local b = byte(s, k)
    if alnum(b) then
      last = k
    elseif b ~= 46 and b ~= 44 and b ~= 92 then
      break
    end
    k = k + 1
  end
  return last and last + 1
end

--- An entity at the backslash at byte `t` of `s`: `\there4`, `\sup1`..3,
--- `\frac12` and the like or `\` and letters, followed by the end of the
--- line, `{}` or anything but a letter, which it takes (unless a blank, the
--- way Emacs leaves trailing blanks out). The byte after it, or nil.
---@param s string
---@param t integer
---@return integer?
local function entity(s, t)
  local e
  for _, special in ipairs({ "there4", "sup[123]", "frac[13][24]" }) do
    local m = s:match("^" .. special .. "()", t + 1)
    if m and not alpha(byte(s, m)) then
      e = m
      break
    end
  end
  if not e then
    local m = s:match("^%a+()", t + 1)
    if not m or alpha(byte(s, m)) then
      return nil
    end
    e = m
  end
  local b = byte(s, e)
  if b == 123 and byte(s, e + 1) == 125 then
    return e + 2
  elseif b and b ~= 10 and not blank(b) then
    return e + 1
  end
  return e
end

---@class org.ui.highlight.block.Latex
---@field fragments boolean "latex" or "native"
---@field entities boolean
---@field scripts boolean|string false, true or "{}"

--- What LaTeX the buffer highlights (`ui.highlight_latex_and_related`,
--- org-compute-latex-and-related-regexp), or nil for nothing.
---@param ui table
---@return org.ui.highlight.block.Latex?
local function latex_options(ui)
  local list = ui.highlight_latex_and_related
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  local set = {}
  for _, v in ipairs(list) do
    set[v] = true
  end
  local scripts = false ---@type boolean|string
  if set.script and ui.use_sub_superscripts ~= false then
    scripts = ui.use_sub_superscripts == "{}" and "{}" or true
  end
  local fragments = (set.latex or set.native) == true
  if not (fragments or set.entities or scripts) then
    return nil
  end
  return { fragments = fragments, entities = set.entities == true, scripts = scripts }
end

--- The name of the environment a line begins (`\begin{NAME}` after
--- blanks), and the byte after its `}`.
---@param line string
---@return string?, integer?
local function env_begin(line)
  return line:match("^[ \t]*\\begin{([%w*]+)}()")
end

--- The kinds of lines LaTeX is looked for in: Org text, tables and the
--- comments of quote blocks; not keywords, comments, fixed-width lines,
--- the info keywords and block delimiters (Emacs draws its own face over
--- them), nor the bodies of src, example and export blocks.
local SCANNED = { text = true, table = true, qcomment = true }

---@param ctx org.ui.highlight.Ctx
---@param o org.ui.highlight.block.Latex
local function paint_latex(ctx, o)
  local lines, kinds, roles = ctx.lines, ctx.kinds, ctx.roles
  local n = #lines
  local s = table.concat(lines, "\n")
  if not (find(s, "\\", 1, true) or (o.fragments and find(s, "$", 1, true)) or (o.scripts and find(s, "[_^]"))) then
    return
  end
  local starts = {} ---@type integer[]
  local scanned = {} ---@type boolean[]
  local star = {} ---@type boolean[]
  local pos = 1
  for i, line in ipairs(lines) do
    starts[i] = pos
    pos = pos + #line + 1
    local r = roles[i]
    scanned[i] = SCANNED[kinds[i]] == true and not (r and r.role ~= "body")
    star[i] = E.star_line(line)
  end
  starts[n + 1] = #s + 2
  -- Per line: where an inline fragment that starts on it has to end (the
  -- start of the next empty, headline or unscanned line), and where an
  -- environment (the next headline).
  local inline_stop, env_stop = {}, {} ---@type integer[], integer[]
  local istop, estop = #s + 1, #s + 1
  for i = n, 1, -1 do
    inline_stop[i], env_stop[i] = istop, estop
    if star[i] or not scanned[i] or not find(lines[i], "%S") then
      istop = starts[i]
    end
    if star[i] then
      estop = starts[i]
    end
  end
  --- The line of byte `p` (a binary search).
  local function line_at(p)
    local lo, hi = 1, n
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= p then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return lo
  end

  local prio = H.PRIO.object
  local LATEX = { hl_group = "orgLatex", priority = prio, spell = false }
  local ENTITY = { hl_group = "orgLatexEntity", priority = prio, spell = false }
  local SCRIPT = { hl_group = "orgLatexScript", priority = prio, spell = false }
  -- (marks come in the order of the text)
  local li = 1
  --- Mark bytes [a, b) of `s`, on the scanned lines.
  local function mark(a, b, opts)
    while starts[li + 1] <= a do
      li = li + 1
    end
    local l = li
    while l <= n and starts[l] < b do
      if scanned[l] then
        local ls = starts[l]
        ctx.emit(l, math.max(a, ls) - ls, math.min(b, ls + #lines[l]) - ls, opts)
      end
      l = l + 1
    end
  end

  -- The next match of a plain string at or after a byte, kept while the
  -- bytes asked for grow: the scan stays linear however many openers find
  -- no closer.
  local memo = {} ---@type table<string, integer|false>
  local function next_of(needle, from)
    local m = memo[needle]
    if m == nil or (m and m < from) then
      m = find(s, needle, from, true) or false
      memo[needle] = m
    end
    return m or nil
  end

  -- Whether `\end{NAME}` follows the lines before a headline (in the
  -- buffer, LOOK lines at most).
  local below = {} ---@type table<string, boolean>
  local function closed_below(name)
    local v = below[name]
    if v ~= nil then
      return v
    end
    v = false
    local needle = "\\end{" .. name .. "}"
    local row = ctx.row0 + n
    local stop = math.min(ctx.bottom, row + LOOK)
    while row < stop do
      local chunk = ctx.get_lines(row, math.min(stop, row + 256))
      local found = nil ---@type boolean?
      for _, line in ipairs(chunk) do
        if E.star_line(line) then
          found = false
          break
        elseif find(line, needle, 1, true) then
          found = true
          break
        end
      end
      if found ~= nil then
        v = found
        break
      end
      row = row + #chunk
    end
    below[name] = v
    return v
  end
  --- The end of the environment NAME whose `\begin{NAME}` ends before byte
  --- `from` (the byte after its `\end{NAME}` and the blanks after that),
  --- when it closes before byte `stop` (or below the lines).
  local function env_end(name, from, stop)
    local needle = "\\end{" .. name .. "}"
    local e = find(s, needle, from + 1, true)
    if e and e + #needle <= stop then
      e = e + #needle
      while blank(byte(s, e)) do
        e = e + 1
      end
      return e
    end
    if stop > #s and closed_below(name) then
      return #s + 1
    end
  end

  local p = 1
  -- An environment open before the lines: its begin line is above them,
  -- after the headline above.
  if o.fragments and ctx.row0 > ctx.top and not star[1] then
    local above = ctx.get_lines(ctx.row0 - LOOK, ctx.row0)
    local open ---@type string?
    for k = #above, 1, -1 do
      local line = above[k]
      if E.star_line(line) then
        break
      end
      local name, after = env_begin(line)
      if name then
        open = name
        -- (whether it is closed before the lines)
        if find(line, "\\end{" .. name .. "}", after, true) then
          open = nil
        else
          for j = k + 1, #above do
            if find(above[j], "\\end{" .. name .. "}", 1, true) then
              open = nil
              break
            end
          end
        end
        break
      end
    end
    if open then
      local e = env_end(open, 0, env_stop[1])
      if e then
        mark(1, e, LATEX)
        p = e
      end
    end
  end

  local trigger = o.fragments and "[%$\\_%^]" or o.scripts and "[\\_%^]" or "\\"
  while true do
    local t = find(s, trigger, p)
    if not t then
      break
    end
    local l = line_at(t)
    if not scanned[l] then
      p = starts[l + 1]
    else
      local c = byte(s, t)
      local stop = inline_stop[l]
      local done ---@type integer?
      -- Emacs's combined regexp: the match that starts first, and of those
      -- the first of latex, entities, scripts
      if c == 94 or c == 95 then
        -- a script after the byte before (org-match-substring-regexp)
        local b = byte(s, t - 1)
        if o.scripts and t > p and b and b ~= 10 and not blank(b) then
          done = script_body(s, t + 1, o.scripts == "{}")
          if done then
            mark(t, done, SCRIPT)
          end
        end
      elseif c == 36 then
        -- $x$ and $...$ (from the byte before, or the start of a line)
        local b = t > 1 and byte(s, t - 1) or nil
        local c2 = byte(s, t + 1)
        if o.fragments and b ~= 36 and (t > p or b == nil or b == 10) and not bad_first(c2) then
          if byte(s, t + 2) == 36 then
            if after_dollar(byte(s, t + 3)) then
              done = t + 3
            end
          else
            local e = next_of("$", t + 1)
            local last = e and byte(s, e - 1)
            if
              e
              and e < stop
              and (last == 59 or not bad_first(last))
              and after_dollar(byte(s, e + 1))
              and line_at(e) - l <= 2
            then
              done = e + 1
            end
          end
          if done then
            mark(t, done, LATEX)
          end
        end
        if not done and o.fragments and c2 == 36 then
          local e = next_of("$$", t + 2)
          if e and e + 2 <= stop then
            done = e + 2
            mark(t, done, LATEX)
          end
        end
      else
        local c2 = byte(s, t + 1)
        local ls = starts[l]
        if o.fragments and c2 == 98 and ls >= p then
          -- \begin{NAME} at the start of the line, from the line's start
          local name, after = env_begin(lines[l])
          if name and ls + #lines[l]:match("^[ \t]*") == t then
            done = env_end(name, ls + after - 1, env_stop[l])
            if done then
              mark(ls, done, LATEX)
            end
          end
        end
        if not done and o.fragments and (c2 == 40 or c2 == 91) then
          local e = next_of(c2 == 40 and "\\)" or "\\]", t + 2)
          if e and e + 2 <= stop then
            done = e + 2
            mark(t, done, LATEX)
          end
        end
        if not done and o.entities and c2 and c2 < 128 and alpha(c2) then
          done = entity(s, t)
          if done then
            mark(t, done, ENTITY)
          end
        end
      end
      if not done and o.scripts and c ~= 94 and c ~= 95 then
        -- a script after this byte
        local c2 = byte(s, t + 1)
        if c2 == 94 or c2 == 95 then
          done = script_body(s, t + 2, o.scripts == "{}")
          if done then
            mark(t + 1, done, SCRIPT)
          end
        end
      end
      p = done or t + 1
    end
  end
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  paint_blocks(ctx)
  local o = latex_options(ctx.ui)
  if o then
    paint_latex(ctx, o)
  end
end

return M
