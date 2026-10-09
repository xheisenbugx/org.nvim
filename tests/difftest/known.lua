-- Known differences between org.nvim and Emacs Org 9.8.10 that `make
-- difftest` finds on generated documents. A diff hunk matching an entry
-- doesn't fail the run (the report counts it); any other hunk does.
--
-- Intentional differences belong in NORMALISE (tests/emacs_parity.lua,
-- documented under :h org-differences), not here. This list is for real
-- bugs not fixed yet (or Emacs behaviour still to decide on): each entry
-- says what differs, and goes away with the fix. Keep the entries narrow,
-- so that they don't hide other bugs.
--
--   oracle  Lua pattern for the oracle name (anchored), e.g. "export%-.*"
--   emacs   Lua pattern searched in the hunk's Emacs lines (joined by \n)
--   ours    the same for org.nvim's lines
--   either  Lua pattern searched in the Emacs or in org.nvim's lines
--   input   Lua pattern one line of the input document must match, or a
--           function(lines) -> boolean
--   same    function(text) -> string: the hunk matches when both sides
--           (their lines joined by \n) are equal once rewritten by it
--   broad   the `same` rewrite erases a lot (digits, whitespace, line
--           order): when several rewrites apply to one hunk, it goes last
--   moves   the `same` rewrite sorts lines: the hunks left unknown (lines
--           moved between them) match together when it makes all their
--           lines equal
--   reason  what's wrong
-- Every field given must match. A hunk that no entry matches alone but
-- that all applicable `same` rewrites together make equal (two known
-- differences next to each other) is known too.
---@class difftest.Known
---@field oracle? string
---@field emacs? string
---@field ours? string
---@field either? string
---@field input? string|fun(lines: string[]): boolean
---@field same? fun(text: string): string
---@field broad? boolean
---@field moves? boolean
---@field reason string

local INLINETASK = "^%*%*%*%*%*%*%*%*%*%*%*%*%*%*%*+ "

--- `s` with all whitespace runs as one space.
local function squash(s)
  return (s:gsub("%s+", " "))
end

--- `s` line by line through `fn`.
local function each_line(s, fn)
  local out = {}
  for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
    out[#out + 1] = fn(l)
  end
  return table.concat(out, "\n")
end

local function is_item(l)
  return l:match("^%s*[%-%+] ") or l:match("^%s*[%-%+]$") or l:match("^%s*%d+[%.%)] ") or l:match("^%s*%d+[%.%)]$")
end

--- Whether a plain list item (or a line of its body) comes right before
--- an inline task (blank lines between).
local function inlinetask_after_list(lines)
  for i = 2, #lines do
    if lines[i]:match(INLINETASK) then
      local j = i - 1
      while j > 1 and lines[j]:match("^%s*$") do
        j = j - 1
      end
      if is_item(lines[j]) or lines[j]:match("^%s+%S") then
        return true
      end
    end
  end
  return false
end

--- Whether a link has more than one possible target: two headlines with
--- the same title and a "*title" link, or <<target>> twice. Inline tasks
--- aren't headlines a "*title" link reaches.
local function ambiguous_links(lines)
  local seen, dup, link = {}, false, false
  for _, l in ipairs(lines) do
    local title = not l:match(INLINETASK) and l:match("^%*+ (.-)%s*$")
    if title then
      title = title
        :gsub("^%u%u+ ", "")
        :gsub("^%[#%a%] ", "")
        :gsub("%s+:[%w_@:]+:$", "")
        :gsub("%s*%[%d*[/%%]%d*%]", "")
        :lower()
      dup = dup or seen[title] or false
      seen[title] = true
    end
    link = link or l:find("[[*", 1, true) ~= nil
  end
  if dup and link then
    return true
  end
  local targets = 0
  for _, l in ipairs(lines) do
    for _ in l:gmatch("[^<]<<target>>") do
      targets = targets + 1
    end
    for _ in l:gmatch("^<<target>>") do
      targets = targets + 1
    end
  end
  return targets > 1
end

--- Whether an inline task comes before the first headline.
local function inlinetask_before_headline(lines)
  for _, l in ipairs(lines) do
    if l:match(INLINETASK) then
      return true
    elseif l:match("^%*+ ") then
      return false
    end
  end
  return false
end

--- Per line of `lines`, whether it's in a subtree that isn't exported
--- (a COMMENT headline or a :noexport: tag).
local function excluded_lines(lines)
  local out, level = {}, nil -- level: of the excluded subtree we're in
  for i, l in ipairs(lines) do
    local stars, rest = l:match("^(%*+) (.*)$")
    if stars and not l:match(INLINETASK) then
      if level and #stars <= level then
        level = nil
      end
      if not level then
        local r = rest
          :gsub("^%u+ ", function(kw)
            return kw == "COMMENT " and kw or ""
          end)
          :gsub("^%[#%a%] ", "")
        local tags = rest:match("%s(:[%w_@:]+:)$")
        if r:match("^COMMENT%f[%s%z]") or (tags and tags:find(":noexport:", 1, true)) then
          level = #stars
        end
      end
    end
    out[i] = level ~= nil
  end
  return out
end

--- Whether a footnote label is defined twice (in exported parts).
local function duplicate_footnotes(lines)
  local seen = {}
  local excluded = excluded_lines(lines)
  for i, l in ipairs(lines) do
    local label = not excluded[i] and l:match("^%[fn:([^%]]+)%]")
    if label then
      if seen[label] then
        return true
      end
      seen[label] = true
    end
  end
  return false
end

local INLINETASK_IN_LIST = [[An inline task right after a plain list:
      Emacs ends the list before it, org.nvim exports it inside the last
      item.]]

---@type difftest.Known[]
return {
  {
    oracle = "export%-latex",
    reason = [[A backslash next to another: "\\ x" is "$\backslash$\ x" in Emacs
      (org-latex-plain-text only escapes a backslash not preceded by one,
      which leaves broken LaTeX), "$\backslash$$\backslash$ x" in org.nvim.
      Emacs bug? Decide whether to follow it.]],
    same = function(s)
      return (s:gsub("%$\\backslash%$%$\\backslash%$", "\0"):gsub("%$\\backslash%$\\", "\0"))
    end,
  },
  {
    oracle = "export%-org",
    reason = [[Org export of plain lists: Emacs writes ordered bullets with
      "." whatever the source used (org-plain-list-ordered-item-terminator
      is t); org.nvim keeps "1)".]],
    ours = "%d%) ",
    same = function(s)
      return each_line(s, function(l)
        return (l:gsub("^(%s*%d+)%)", "%1."))
      end)
    end,
  },
  {
    oracle = "export%-org",
    reason = [[Org export of nested plain lists: sub-lists are indented deeper
      than in Emacs (by a description tag's width), and a parent's checkbox
      isn't recomputed from its children as Emacs does.]],
    either = "\n%s+[%-%+] ",
    same = function(s)
      return each_line(s, function(l)
        if is_item(l) or l:match("^%s+%S") then
          l = vim.trim(l):gsub("%[[ X%-]%]", "[?]")
        end
        return l
      end)
    end,
  },
  {
    oracle = "export%-org",
    reason = [[Org export of an item with a checkbox and nothing else, followed
      by a sub-list: org.nvim puts the first sub-item on the parent's line
      ("- [X] - [-]").]],
    ours = "%[[ X%-]%] [%-%+%d]+[%.%)]? ",
  },
  {
    oracle = "export%-org",
    reason = [[Org export aligns headline tags by byte length instead of
      display width: after a non-ASCII title (日本語) they land too far left.]],
    either = "[\128-\255]",
    same = function(s)
      return each_line(s, function(l)
        if l:match("^%*+ .*%s:[%w_@:]+:$") then
          l = squash(l)
        end
        return l
      end)
    end,
  },
  {
    oracle = "visibility",
    reason = [[The END line of an inline task ("*************** END") is hidden
      by Emacs in OVERVIEW and CONTENTS (S-TAB), shown by org.nvim.]],
    emacs = "h %*+ [Ee][Nn][Dd]",
    same = function(s)
      return each_line(s, function(l)
        return (l:gsub("^[hv] (%*%*%*%*%*%*%*%*%*%*%*%*%*%*%*+ [Ee][Nn][Dd])", "? %1"))
      end)
    end,
  },
  {
    oracle = "visibility",
    reason = [[A drawer before the first headline (:NOTES: ... :END:) is
      folded by Emacs on S-TAB, left open by org.nvim.]],
    input = "^:%u+:$",
    emacs = "h :END:",
  },
  -- an inline task after a list, by back-end: the differences that
  -- putting the task inside the last item makes, and only those
  {
    oracle = "export%-ascii",
    reason = INLINETASK_IN_LIST .. [[ ASCII: the task's box (and what
      follows it in the item) is indented further and wrapped narrower.]],
    input = inlinetask_after_list,
    emacs = "^%s%s%s%s+%S",
    ours = "^%s%s%s%s+%S",
    broad = true,
    same = function(s)
      return (s:gsub("%s+", ""))
    end,
  },
  {
    oracle = "export%-html",
    reason = INLINETASK_IN_LIST .. [[ HTML: the item's text in a <p>, the
      list closed after the task's </div>.]],
    input = inlinetask_after_list,
    either = "</[oud]l>",
    broad = true,
    same = function(s)
      return (s:gsub("</?p>", ""):gsub("</li>", ""):gsub("</dd>", ""):gsub("</[oud]l>", ""):gsub("%s+", ""))
    end,
  },
  {
    oracle = "export%-latex",
    reason = INLINETASK_IN_LIST .. [[ LaTeX: the list's \end{...} after
      the task.]],
    input = inlinetask_after_list,
    either = "^\\end{%a+}",
    same = function(s)
      return (each_line(s, function(l)
        return (l:gsub("^\\end{%a+}$", ""))
      end):gsub("\n", ""))
    end,
  },
  {
    oracle = "export%-md",
    reason = INLINETASK_IN_LIST .. [[ Markdown: the task's HTML indented
      as the item's body.]],
    input = inlinetask_after_list,
    either = 'class="inlinetask"',
    same = function(s)
      return each_line(s, vim.trim)
    end,
  },
  {
    oracle = "export%-org",
    reason = INLINETASK_IN_LIST .. [[ Org: the task (and the item's body
      lines) indented as the item's body.]],
    input = inlinetask_after_list,
    either = "^%s+%S",
    same = function(s)
      return each_line(s, vim.trim)
    end,
  },
  {
    oracle = "export%-.*",
    reason = [[A link with more than one possible target (two headlines titled
      "Alpha" and a "*Alpha" link, or <<target>> twice): Emacs and org.nvim
      pick different ones (so section numbers and reference ids differ).]],
    input = ambiguous_links,
    broad = true,
    moves = true,
    same = function(s)
      -- the reference ids (custom or not) and the "See section <number
      -- or title>" of ASCII only, in any line order
      s = s:gsub("ID%d+", "ID#"):gsub("#custom%d*", "#ID#"):gsub("(See section )%d[%d%.]*", "%1#")
      s = s:gsub("(See section )(%a+)", function(see, title)
        return see .. title:lower()
      end)
      local lines = vim.split(s, "\n", { plain = true })
      table.sort(lines)
      return table.concat(lines, "\n")
    end,
  },
  {
    oracle = "export%-.*",
    reason = [[A timestamp with a habit repeater (<... .+2d/4d>): org.nvim
      exports it without the "/4d".]],
    emacs = "[%.%+]%d+[hdwmy]/%d+[hdwmy]",
  },
  {
    oracle = "export%-.*",
    reason = [[A macro that expands to nothing at the start of a line: Emacs
      expands macros before parsing, so the line can become empty (and
      split a paragraph) or stop continuing a list item; org.nvim parses
      first, and keeps the space after the macro at the start of the
      line. Only where the lines, list items and paragraphs break (and
      that space) differs.]],
    input = "^%s*{{{title}}}",
    broad = true,
    moves = true,
    same = function(s)
      return (s:gsub("</?p>", ""):gsub("</li>", ""):gsub("</[ou]l>", ""):gsub("%s+", ""))
    end,
  },
  {
    oracle = "export%-.*",
    reason = [[A property drawer without its :END: line: Emacs doesn't read
      it as a drawer (no CUSTOM_ID), org.nvim does.]],
    input = function(lines)
      for i, l in ipairs(lines) do
        if l == ":PROPERTIES:" then
          local j = i + 1
          while lines[j] and lines[j]:match("^:[%w_%-]+:") and lines[j] ~= ":END:" do
            j = j + 1
          end
          if lines[j] ~= ":END:" then
            return true
          end
        end
      end
      return false
    end,
  },
  {
    oracle = "export%-.*",
    reason = [[A footnote label defined twice: Emacs and org.nvim export
      different definitions.]],
    input = duplicate_footnotes,
  },
  {
    oracle = "export%-.*",
    reason = [[A description item with an empty tag ("- :: text") is a plain
      item for Emacs, a description item with an empty term for org.nvim.]],
    input = "^%s*[%-%+] ::",
  },
  {
    oracle = "export%-.*",
    reason = [[A description item whose tag is a macro that expands to nothing
      ("- {{{title}}} :: text"): Emacs expands macros before parsing, so
      it's a plain item; org.nvim exports a description item.]],
    input = "^%s*[%-%+] .*{{{title}}} ::",
    either = "::",
  },
  {
    oracle = "export%-latex",
    reason = [[The same (a description item whose tag is a macro that expands
      to nothing), where the LaTeX list ends: \end{description} in
      org.nvim.]],
    input = "^%s*[%-%+] .*{{{title}}} ::",
    emacs = "^\\end{itemize}$",
    ours = "^\\end{description}$",
  },
  {
    oracle = "export%-latex",
    reason = [[An entity in a caption ("#+CAPTION: A \alpha"): Emacs exports
      it as in the text, "\(\alpha\)"; org.nvim's \captionof keeps
      "\alpha".]],
    emacs = "\\caption",
    same = function(s)
      return (s:gsub("\\%((\\%a+)\\%)", "%1"))
    end,
  },
  {
    oracle = "export%-ascii",
    reason = [[A block holding only a blank line: org.nvim's ASCII export
      prints a "| " line, Emacs a blank one.]],
    ours = "|%s*$",
    input = "^#%+begin_",
  },
  {
    oracle = "agenda",
    reason = [[Habit consistency graphs differ (which days get a "*").]],
    same = function(s)
      return (s:gsub("[ %*!]*![ %*!]*", "!"))
    end,
  },
  {
    oracle = "agenda",
    reason = [[A headline with a TODO keyword and no title: org.nvim's agenda
      line ends with a space after the keyword.]],
    same = function(s)
      return (s:gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", ""))
    end,
  },
  {
    oracle = "agenda",
    reason = [[A date range in a planning line (SCHEDULED: <a>--<b>) also
      gives Emacs a block entry ("(2/5): ...") on each day of the range, and
      a time of day; org.nvim shows only the planning entry.]],
    emacs = "%(%d+/%d+%):",
  },
  {
    oracle = "agenda",
    reason = [[A headline that is only tags ("* :work:"): Emacs shows the tags
      as the title too, org.nvim an empty title.]],
    emacs = "%s(:[%w_@:]+:)%s+%1",
  },
  {
    oracle = "agenda",
    reason = [[Tag order: Emacs lists inherited tags, then the local ones as
      written; org.nvim reorders them (a local tag that is also inherited
      moves first).]],
    same = function(s)
      return (
        s:gsub(":([%w_@:]+):", function(tags)
          local t = vim.split(tags, ":+")
          table.sort(t)
          return ":" .. table.concat(t, ":") .. ":"
        end)
      )
    end,
  },
  {
    oracle = "agenda",
    reason = [[The END line of an inline task shows in org.nvim's tags matches
      (as a headline with the tags of the task's outline), not in Emacs'.]],
    ours = "^%s*[%w_]+:%s+[Ee][Nn][Dd]%s",
    same = function(s)
      return (("\n" .. s):gsub("\n%s*[%w_]+:%s+[Ee][Nn][Dd]%s[^\n]*", "")):sub(2)
    end,
  },
  {
    oracle = "table",
    reason = [[Formulas over text or out-of-range references: Emacs (Calc)
      keeps symbolic results ("42 + title") or leaves the field; org.nvim
      writes #ERROR.]],
    ours = "#ERROR",
  },
  {
    oracle = "table",
    reason = [[A Calc function over a text field: Emacs keeps the call
      unevaluated ("vsum(task)"), org.nvim gives the text.]],
    emacs = "%l+%(%a",
  },
  {
    oracle = "table",
    reason = [[A Calc vector over a quoted field ($3=$1..$2 with "quoted"):
      Emacs shows the string as character codes ([113, 117, ...]),
      org.nvim as the text.]],
    emacs = "%[%d+, %d+, %d+",
  },
  {
    oracle = "table",
    reason = [[A table with an empty #+TBLFM line: Emacs leaves it alone
      (nothing to compute), org.nvim aligns it.]],
    input = "^#%+TBLFM:%s*$",
    same = function(s)
      return (s:gsub("[ %-]+", ""))
    end,
  },
  {
    oracle = "visibility",
    reason = [[Indented lines (sub-items, item bodies, blank lines between
      them) of a plain list before the first headline: org.nvim folds them
      on S-TAB, Emacs leaves them visible.]],
    emacs = "v  ",
    same = function(s)
      -- an indented line, or a blank one before an indented line (a
      -- blank line inside the list)
      local lines = vim.split(s, "\n", { plain = true })
      for i = #lines, 1, -1 do
        local l = lines[i]
        if l:match("^[hv]  +") then
          lines[i] = "?" .. l:sub(2)
        elseif l:match("^[hv] $") and (lines[i + 1] or ""):match("^%?  +") then
          lines[i] = "? "
        end
      end
      return table.concat(lines, "\n")
    end,
  },
  {
    oracle = "agenda",
    reason = [[A plain timestamp with a repeater and a warning delay, as
      <2026-09-24 Thu +1w -4d>: Emacs doesn't show its repeats, org.nvim
      does.]],
    input = "<%d%d%d%d%-%d%d%-%d%d[^>]* [%.%+]+%d+[hdwmy][^>]* %-%-?%d+[hdwmy]>",
    emacs = "^$",
  },
  {
    oracle = "agenda",
    reason = [[A date range in a planning line whose end has a time
      (SCHEDULED: <a>--<b 11:15>): Emacs shows the entry at that time,
      org.nvim without one.]],
    input = "%u+: <[^>]+>%-%-<[^>]* %d%d?:%d%d>",
    either = "[DS]%l+[:%.]",
  },
  {
    oracle = "agenda",
    reason = [[A timestamp under an inline task before the first headline
      gives org.nvim an agenda entry (titled by the inline task), not
      Emacs.]],
    input = inlinetask_before_headline,
    emacs = "^$",
  },
  {
    oracle = "export%-.*",
    reason = [[A date range whose start has a time and whose end has none, as
      <2026-10-01 17:30>--<2026-10-03 Sat>, is exported by Emacs with the
      start's time on the end too (org-element-timestamp-interpreter), by
      org.nvim without.]],
    emacs = "%a%a%a %d%d:%d%d[%]>&]",
    same = function(s)
      return (squash(s):gsub("(%d%d%d%d%-%d%d%-%d%d %a+) %d%d:%d%d", "%1"):gsub("(%a%a%a) %d%d:%d%d([%]>])", "%1%2"))
    end,
  },
  {
    oracle = "export%-.*",
    reason = [[A macro that expands to nothing ("{{{title}}}" without
      #+title) next to a space: Emacs drops the space (at the start or end
      of a paragraph or headline), org.nvim keeps it.]],
    input = "{{{title}}}",
    same = function(s)
      -- line by line: the lines break at the same places
      return each_line(s, function(l)
        return (vim.trim(l:gsub("  +", " ")):gsub("([>%[#{]) ", "%1"):gsub(" ([}<\\%]&])", "%1"))
      end)
    end,
  },
}
