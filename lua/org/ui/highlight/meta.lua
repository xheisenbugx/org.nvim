---@mod org.ui.highlight.meta Keywords, drawers and comments
---
--- Part of org.ui.highlight (the parser highlighter): #+KEYWORD lines, the TITLE and document info keywords (`ui.hidden_keywords`), comments, drawers, node properties, fixed-width lines and horizontal rules.
---
--- A port of what Emacs Org draws there (org-set-font-lock-defaults):
--- org-property-re (org-special-keyword on ":NAME:", org-property-value
--- on the value, on any line), org-fontify-drawers (org-drawer from colon
--- to colon), org-activate-code (org-code from the colon of a fixed-width
--- line) and, for the lines starting with "#", the keyword branches of
--- org-fontify-meta-lines-and-blocks-1: comments, the document info
--- keywords (or their keyword hidden, org-hidden-keywords), captions and
--- every other "#+" line. The begin and end lines of blocks are
--- org.ui.highlight.block's; the lines in a block aren't meta lines (Emacs
--- goes on after the end line), and in src, example and export blocks
--- nothing of this is drawn (the block's own fontification replaces it).
---
--- Each line is matched from its start with anchored patterns, once: time
--- linear in the length of the lines.

-- Not compiled by the JIT, like org.ui.highlight (see the comment there).
if jit then
  jit.off(true, true)
end

local M = {}

local H = require("org.ui.highlight")
local E = require("org.ui.emphasis")

local byte = string.byte

-- (org-element-document-info-keywords, lowercase, with the colon)
local INFO = { title = true, subtitle = true, author = true, email = true, date = true }

--- Whether byte b is a blank (space or tab).
local function blank(b)
  return b == 32 or b == 9
end

--- The end (1-based, inclusive) of `line` without its trailing blanks,
--- from `from` on (from - 1 when it's all blanks).
local function trimmed_end(line, from)
  local e = #line
  while e >= from and blank(byte(line, e)) do
    e = e - 1
  end
  return e
end

--- The first byte at or after `i` that isn't a blank.
local function skip_blanks(line, i)
  while blank(byte(line, i)) do
    i = i + 1
  end
  return i
end

---@param ctx org.ui.highlight.Ctx
---@return table<string, boolean>
local function hidden_keywords(ctx)
  local hidden = {}
  for _, k in ipairs(ctx.ui.hidden_keywords or {}) do
    hidden[tostring(k):lower()] = true
  end
  return hidden
end

--- A line starting with "#" after its indentation (at `s`): the branches
--- of org-fontify-meta-lines-and-blocks-1 that aren't blocks.
---@param ctx org.ui.highlight.Ctx
---@param i integer
---@param line string
---@param s integer
---@param hidden table<string, boolean>
local function meta_line(ctx, i, line, s, hidden)
  local emit = ctx.emit
  local n = #line
  local c2 = byte(line, s + 1)
  if c2 == nil or c2 == 32 then
    -- a comment: font-lock-comment-face over the whole line (spell
    -- checked, like the syntax group with @Spell)
    emit(i, 0, n, { hl_group = "orgComment", priority = H.PRIO.object + 1 })
    return
  elseif c2 == 9 then
    -- "#" and a tab: not a comment (org-comment-regexp), but Emacs draws
    -- it as a keyword, all of it in org-meta-line (spell checked: to
    -- org-element it's a paragraph, as the syntax engine's comment is)
    emit(i, 0, n, { hl_group = "orgKeyword", priority = H.PRIO.object + 1 })
    -- (but its links, as flyspell leaves them out)
    local _, found = E._links(line, ctx.link_types or E.link_types(), function()
      return 1
    end, function(x)
      return x == 1 and 1 or n + 2
    end)
    for _, f in ipairs(found) do
      emit(i, f[1] - 1, f[2], { priority = H.PRIO.object + 1, spell = false })
    end
    return
  elseif c2 ~= 43 then -- "+"
    return
  end
  -- "#+" letters, an optional colon, an optional "_" and letters
  local key_end = line:match("^#%+%a+()", s) ---@type integer?
  if not key_end then
    -- (no face, but a keyword to org-element, "#+1x: ...": not spell
    -- checked, like the syntax engine's orgKeyword)
    if line:find("^#%+%S+:", s) then
      emit(i, 0, n, { priority = H.PRIO.object + 1, spell = false })
    end
    return
  end
  local key = line:sub(s + 2, key_end - 1):lower()
  local colon = byte(line, key_end) == 58
  local after = colon and key_end + 1 or key_end -- (after "#+KEY:")
  local suffix_end = line:match("^_%a+()", after) ---@type integer?
  if suffix_end and key == "begin" and not colon then
    -- a block's begin line (org.ui.highlight.block's; one that opens no
    -- block draws nothing in Emacs either)
    return
  end
  if colon and not suffix_end and INFO[key] then
    -- the keyword (from the start of the line) in org-document-info-keyword,
    -- or hidden; the value after the blanks in org-document-title or
    -- org-document-info
    local title = key == "title"
    emit(i, 0, after - 1, {
      hl_group = title and "orgTitleKeyword" or "orgInfoKeyword",
      priority = H.PRIO.object + 1,
      spell = false,
      conceal = hidden[key] and "" or nil,
    })
    local v = skip_blanks(line, after)
    emit(
      i,
      v - 1,
      n,
      { hl_group = title and "orgTitle" or "orgInfoValue", priority = H.PRIO.object + 1, spell = false }
    )
    return
  end
  if key:sub(1, 7) == "caption" then
    -- "#+caption", an optional "[short caption]" and a colon in
    -- org-meta-line; the caption itself is org-block, drawn by the block
    -- part (anything else after "#+caption": the whole line in
    -- org-meta-line)
    local e = line:match("^#%+[cC][aA][pP][tT][iI][oO][nN]:()", s)
      or line:match("^#%+[cC][aA][pP][tT][iI][oO][nN]%[.*%]:()", s)
    if e then
      emit(i, 0, e - 1, { hl_group = "orgKeyword", priority = H.PRIO.object + 1, spell = false })
      return
    end
  end
  -- any other keyword: the whole line in org-meta-line (the keyword, up to
  -- the last colon of its first word, in orgKeyword, like the syntax), not
  -- spell checked. A line with no colon after its first word ("#+key
  -- text") isn't a keyword to org-element but a paragraph, spell checked
  -- (by flyspell and the syntax engine), unless it is a block line, such
  -- as an end line that closes nothing.
  local k = line:match("^#%+%S+:()", s)
  local spell ---@type boolean?
  if k or E.block_line(line) then
    spell = false
  end
  k = k or n + 1
  emit(i, 0, k - 1, { hl_group = "orgKeyword", priority = H.PRIO.object + 1, spell = spell })
  emit(i, k - 1, n, { hl_group = "orgKeywordValue", priority = H.PRIO.object + 1, spell = spell })
end

--- A line starting with ":" after its indentation (at `s`): a drawer line,
--- a property or a fixed-width line.
---@param ctx org.ui.highlight.Ctx
---@param i integer
---@param line string
---@param s integer
local function colon_line(ctx, i, line, s)
  local emit = ctx.emit
  local n = #line
  local c2 = byte(line, s + 1)
  if c2 == nil or c2 == 32 then
    -- org-activate-code: ":" then a space or the end of the line
    emit(i, s - 1, n, { hl_group = "orgFixedWidth", priority = H.PRIO.part, spell = false })
    return
  end
  -- org-drawer-regexp: ":NAME:" and blanks
  local d = E.word_end(line, s + 1) ---@type integer?
  d = d > s + 1 and byte(line, d) == 58 and d + 1 or nil
  if d and skip_blanks(line, d) > n then
    emit(i, s - 1, d - 1, { hl_group = "orgDrawer", priority = H.PRIO.part, spell = false })
    return
  end
  -- org-property-re: ":NAME:" (NAME: non-blanks, colons too) ends where the
  -- first word does, then the end of the line or blanks and the value
  local w = line:match("^%S+()", s) ---@type integer
  if w - s < 3 or byte(line, w - 1) ~= 58 then
    return
  end
  emit(i, s - 1, w - 1, { hl_group = "orgPropertyKey", priority = H.PRIO.part, spell = false })
  local v = skip_blanks(line, w)
  local e = trimmed_end(line, v)
  if e >= v then
    -- (not on the diary sexps and planning keywords, which Emacs draws
    -- over it)
    for _, r in
      ipairs(require("org.ui.highlight.date").minus(v, e, require("org.ui.highlight.date").override_spans(line)))
    do
      emit(i, r[1] - 1, r[2], { hl_group = "orgPropertyValue", priority = H.PRIO.part, spell = false })
    end
  end
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local lines, roles = ctx.lines, ctx.roles
  local from = math.max(1, ctx.first - ctx.row0 + 1)
  local to = math.min(#lines, ctx.last - ctx.row0 + 1)
  local hidden ---@type table<string, boolean>?
  for i = from, to do
    local line = lines[i]
    local role = roles[i]
    -- (nothing in a src, example or export block)
    if not (role and role.block.verbatim) and not E.star_line(line) then
      local s = line:match("^[ \t]*()") ---@type integer
      local c = byte(line, s)
      if c == 35 then -- #
        -- (the lines of a block aren't meta lines, its begin and end
        -- lines are the block's)
        if not role then
          hidden = hidden or hidden_keywords(ctx)
          meta_line(ctx, i, line, s, hidden)
        end
      elseif c == 58 then -- :
        colon_line(ctx, i, line, s)
      elseif c == 45 and line:find("^%-%-%-%-%-+[ \t]*$", s) then
        -- a horizontal rule (no face in Emacs; drawn like the syntax)
        ctx.emit(i, 0, #line, { hl_group = "orgHorizontalRule", priority = H.PRIO.element, spell = false })
      end
    end
  end
end

return M
