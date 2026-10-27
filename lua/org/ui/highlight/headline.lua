---@mod org.ui.highlight.headline Headlines
---
--- Part of org.ui.highlight (the parser highlighter): the level faces of headlines (and of the stars only with `ui.level_color_stars_only`), TODO keywords (`ui.todo_keyword_faces`), priority cookies (`ui.priority_faces`), tags (`ui.tag_faces`), COMMENT, the text of DONE / TODO headlines (`ui.fontify_done_headline`, `ui.fontify_todo_headline`), ARCHIVE headlines and inline tasks.
---
--- A port of the headline rules of org-set-font-lock-defaults, each found
--- the way its regexp finds it, in one pass over the line:
---
---   "^\(\**\)\(\* \)\(.*\)"                      the level face (org-get-level-face)
---   org-heading-keyword-regexp-format            the keyword, the DONE / TODO text
---   "^\*+.*?\(\[#\(A\)\] ?\)"                    the first priority cookie
---   org-tag-line-re                              the tags
---   "^\*+ \(.*:ARCHIVE:.*\)"                     org-archived
---   "^\*+\(?: +KW\)?\(?: +\[#P\]\)? +COMMENT"    the COMMENT keyword
---
--- and org-inlinetask-fontify for inline tasks. Emacs prepends the later
--- rules' faces, so they get the higher priorities here.

-- Not compiled by the JIT, like org.ui.highlight (see the comment there).
if jit then
  jit.off(true, true)
end

local M = {}

local byte = string.byte

local H = require("org.ui.highlight")
local PRIO = H.PRIO

-- (bytes)
local STAR, SPACE, TAB, LBRACKET, RBRACKET, COLON = 42, 32, 9, 91, 93, 58

--- The headline text: over the level face, under what it holds (Emacs
--- prepends org-headline-done / org-headline-todo to the level face, then
--- the priority and tag faces to it).
local TEXT = PRIO.element + 1
--- org-archived: prepended after the keyword, priority and tags, so the
--- whole headline is dimmed (the objects and emphasis in it keep theirs).
local ARCHIVED = PRIO.part + 1
--- Inline tasks: org.ui.decorations draws them in OrgInlinetask at
--- priority 150; what Emacs prepends to org-inlinetask (the keyword, the
--- DONE text, priority, tags) goes over it.
local INLINE = 150 - PRIO.element

--- Whether byte b is a blank of the headline regexps ([ \t]).
local function blank(b)
  return b == SPACE or b == TAB
end

--- The value of the priority cookie at byte i of `line` ("[#" there) and
--- the byte after it, or nil: org-priority-value-regexp, "[A-Z]", "[0-9]",
--- "[1-5][0-9]" or "6[0-4]" before the "]".
---@param line string
---@param i integer
---@return string?, integer?
local function cookie_at(line, i)
  local c = byte(line, i + 2)
  if not c then
    return nil
  end
  if c >= 65 and c <= 90 then
    if byte(line, i + 3) == RBRACKET then
      return string.char(c), i + 4
    end
    return nil
  end
  if c < 48 or c > 57 then
    return nil
  end
  local d = byte(line, i + 3)
  if d == RBRACKET then
    return string.char(c), i + 4
  end
  if d and d >= 48 and d <= 57 and byte(line, i + 4) == RBRACKET then
    local n = (c - 48) * 10 + d - 48
    if n >= 10 and n <= 64 then
      return string.char(c, d), i + 5
    end
  end
  return nil
end

--- The first priority cookie of `line` at or after byte `from`: its start
--- byte, value and the byte after it.
---@return integer?, string?, integer?
local function first_cookie(line, from)
  local i = line:find("[#", from, true)
  while i do
    local v, e = cookie_at(line, i)
    if v then
      return i, v, e
    end
    i = line:find("[#", i + 1, true)
  end
end

--- The group of a priority cookie: `ui.priority_faces` (keys "A", 10 or
--- "10"), else orgPriorityA/B/C, else orgPriority.
local function priority_group(ui, v)
  local faces = ui.priority_faces
  if faces and next(faces) then
    if faces[v] ~= nil or faces[tonumber(v)] ~= nil then
      return require("org.highlights").face_group("orgPriorityFace_", faces[v] ~= nil and v or tonumber(v))
    end
  end
  if v == "A" or v == "B" or v == "C" then
    return "orgPriority" .. v
  end
  return "orgPriority"
end

--- Whether the tag group bytes [s, e] of `line` match
--- org-tag--group-enclosed-re: ":" then tag characters and colons
--- ([:alnum:]_@#%, non-ASCII letters too) then ":".
local function tag_group(line, s, e)
  return e - s >= 2
    and byte(line, s) == COLON
    and byte(line, e) == COLON
    and line:sub(s + 1, e - 1):find("^[%w_@#%%:\128-\255]+$") ~= nil
end

--- The level of a headline of `n` stars (org-get-level-face): with
--- odd levels only, 1 + n / 2.
local function level_of(n, odd)
  return odd and (1 + math.floor(n / 2)) or n
end

--- Whether only odd levels are used (`#+STARTUP: odd` / `oddeven`, else
--- the `odd_levels_only` option).
---@param ctx org.ui.highlight.Ctx
local function odd_levels(ctx)
  local st = ctx.file and ctx.file.settings and ctx.file.settings.startup or {}
  if st.odd then
    return true
  elseif st.oddeven then
    return false
  end
  return require("org.config").opts.odd_levels_only == true
end

--- Paint headline `line` (lines[i], `n` stars).
---@param ctx org.ui.highlight.Ctx
---@param i integer
---@param line string
---@param n integer
---@param o table what `M.paint` worked out for every line
local function headline(ctx, i, line, n, o)
  local emit, ui, len = ctx.emit, ctx.ui, #line
  local inline = o.min_inline ~= nil and n >= o.min_inline
  local up = inline and INLINE or 0
  if inline then
    -- org-inlinetask-fontify: the stars but the last two in org-hide (the
    -- first one in org-warning with org-inlinetask-show-first-star, which
    -- org.ui.decorations draws), the rest in org-inlinetask (also drawn
    -- by org.ui.decorations): no level face
    if n > 2 then
      emit(i, o.first_star and 1 or 0, n - 2, { hl_group = "OrgHiddenStars", priority = PRIO.element })
    end
  else
    local level = level_of(n, o.odd)
    local group = "orgHeadlineLevel" .. ((level - 1) % 8 + 1)
    -- the leading stars in org-hide with org-hide-leading-stars, the last
    -- star and the blank after it in the level face, the text in it too
    -- unless org-level-color-stars-only
    local lead = 0
    if ui.hide_leading_stars and n > 1 then
      lead = n - 1
      emit(i, 0, lead, { hl_group = "OrgHiddenStars", priority = PRIO.element })
    end
    if ui.level_color_stars_only then
      emit(i, lead, n + 1, { hl_group = group, priority = PRIO.element + 1 })
      emit(i, n + 1, len, { hl_group = "orgHeadlineText", priority = PRIO.element })
    else
      -- (not on a column cookie after a "|": Emacs's rule for table
      -- cookies, "| *<[lrc]?[0-9]*>", replaces every face under it,
      -- in a headline too; the table part draws it)
      local from = lead
      local at = 1
      while true do
        local bar, cs, ce = line:match("()|[ ]*()<[lrc]?%d*>()", at)
        if not bar then
          break
        end
        emit(i, from, cs - 1, { hl_group = group, priority = PRIO.element })
        from, at = ce - 1, ce
      end
      emit(i, from, len, { hl_group = group, priority = PRIO.element })
    end
  end

  -- the TODO keyword: after the stars and blanks (" +"), followed by " "
  -- or by blanks to the end of the line
  local todo = o.todo
  local ks = n + 2
  while byte(line, ks) == SPACE do
    ks = ks + 1
  end
  local ke = ks
  while ke <= len and not blank(byte(line, ke)) do
    ke = ke + 1
  end
  local word = line:sub(ks, ke - 1)
  local kw = ke > ks and todo and todo:get(word) or nil
  if kw and byte(line, ke) == TAB and line:find("[^ \t]", ke) then
    kw = nil
  end
  local after_kw = ks -- (the first byte after the keyword's blanks)
  if kw then
    local faces = ui.todo_keyword_faces
    local group = faces and faces[word] ~= nil and ("orgTodoKw_" .. word:gsub("[^%w_]", "_"))
      or (kw.done and "orgDone" or "orgTodo")
    emit(i, ks - 1, ke - 1, { hl_group = group, priority = PRIO.part + up, spell = false })
    -- the text after it ("\(?: +\(.*?\)\)?[ \t]*$"): from its first
    -- character that isn't " " to its last that isn't blank
    local bs = ke
    while byte(line, bs) == SPACE do
      bs = bs + 1
    end
    after_kw = bs
    local be = len
    while be >= bs and blank(byte(line, be)) do
      be = be - 1
    end
    if be >= bs and bs > ke then
      if kw.done and ui.fontify_done_headline ~= false then
        emit(i, bs - 1, be, { hl_group = "orgHeadlineDone", priority = TEXT + up })
      elseif not kw.done and ui.fontify_todo_headline then
        emit(i, bs - 1, be, { hl_group = "orgHeadlineTodo", priority = TEXT + up })
      end
    end
  end

  -- the first priority cookie after the stars
  local ps, pv, pe = first_cookie(line, n + 1)
  if ps and pv and pe then
    emit(i, ps - 1, pe - 1, { hl_group = priority_group(ui, pv), priority = PRIO.part + up, spell = false })
  end

  -- tags: the last word, when it is a tag group (org-tag-line-re)
  local te = len
  while te > n + 1 and blank(byte(line, te)) do
    te = te - 1
  end
  local ts = te
  while ts > n + 2 and not blank(byte(line, ts - 1)) do
    ts = ts - 1
  end
  if te > n + 1 and tag_group(line, ts, te) then
    emit(i, ts - 1, te, { hl_group = "orgTags", priority = PRIO.part + up, spell = false })
    local faces = ui.tag_faces
    if faces and next(faces) then
      -- org-font-lock-add-tag-faces: each tag of org-tag-faces
      local hls = require("org.highlights")
      local s = ts + 1
      while s < te do
        local e = line:find(":", s, true) or te
        local tag = line:sub(s, e - 1)
        if tag ~= "" and faces[tag] ~= nil then
          emit(i, s - 1, e - 1, { hl_group = hls.face_group("orgTagFace_", tag), priority = PRIO.part + 1 + up })
        end
        s = e + 1
      end
    end
    if vim.b[ctx.bufnr].org_beamer_mode then
      -- org-beamer-mode: the B_env and BMCOL tags in org-beamer-tag (like
      -- the orgBeamerTag match org.export.beamer_mode adds to the syntax)
      local s = ts + 1
      while s < te do
        local e = line:find(":", s, true) or te
        local tag = line:sub(s, e - 1)
        if tag == "BMCOL" or tag:find("^B_%l+$") then
          emit(i, s - 1, e - 1, { hl_group = "orgBeamerTag", priority = PRIO.part + 2 + up })
        end
        s = e + 1
      end
    end
  end

  -- ARCHIVE anywhere after the stars and blank: the rest of the line
  if line:find(":ARCHIVE:", n + 2, true) then
    emit(i, n + 1, len, { hl_group = "orgHeadlineArchived", priority = ARCHIVED + up })
  end

  -- COMMENT (org-comment-string) after the stars' blanks, an optional
  -- keyword and blanks, an optional priority cookie and blanks, then " "
  -- or the end of the line
  local function comment_at(c)
    if line:sub(c, c + 6) ~= "COMMENT" then
      return nil
    end
    local b = byte(line, c + 7)
    return (b == nil or b == SPACE) and c or nil
  end
  local function comment_from(c)
    local at = comment_at(c)
    if not at and byte(line, c) == LBRACKET then
      local v, e = cookie_at(line, c)
      if v and e and byte(line, e) == SPACE then
        while byte(line, e) == SPACE do
          e = e + 1
        end
        at = comment_at(e)
      end
    end
    return at
  end
  local at = comment_from(ks) or (kw and byte(line, ke) == SPACE and comment_from(after_kw)) or nil
  if at then
    emit(i, at - 1, at + 6, { hl_group = "orgHeadlineComment", priority = PRIO.object + 1 + up, spell = false })
  end
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local lines, kinds = ctx.lines, ctx.kinds
  local from = math.max(1, ctx.first - ctx.row0 + 1)
  local to = math.min(#lines, ctx.last - ctx.row0 + 1)
  local o = nil ---@type table?
  for i = from, to do
    local line = lines[i]
    if byte(line, 1) == STAR then
      if not o then
        local min_inline = require("org.parser").inlinetask_min_level()
        o = {
          todo = ctx.file and ctx.file.settings and ctx.file.settings.todo,
          odd = odd_levels(ctx),
          min_inline = min_inline,
          first_star = min_inline and require("org.config").opts.inlinetask_show_first_star or false,
        }
      end
      local n = line:match("^%*+()") - 1
      if byte(line, n + 1) == SPACE then
        headline(ctx, i, line, n, o)
      elseif kinds[i] ~= "none" then
        -- Emacs matches the priority cookie after "^\*+" on any line
        -- (org-font-lock-add-priority-faces): "*Note:* [#A]" has one too
        local ps, pv, pe = first_cookie(line, n + 1)
        if ps and pv and pe then
          ctx.emit(i, ps - 1, pe - 1, { hl_group = priority_group(ctx.ui, pv), priority = PRIO.part, spell = false })
        end
      end
    end
  end
end

return M
