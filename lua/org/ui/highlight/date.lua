---@mod org.ui.highlight.date Dates and planning
---
--- Part of org.ui.highlight (the parser highlighter): timestamps and ranges (active and inactive), SCHEDULED / DEADLINE / CLOSED, CLOCK lines and their durations, diary sexps.
---
--- A port of what org-set-font-lock-defaults draws for them: dates
--- (org-activate-dates, org-tsr-regexp-both: org-date), the planning and
--- clock keywords ("\\<SCHEDULED:" ...: org-special-keyword), diary sexps
--- ("^&?%%(.*\\|<%%([^>\n]*?>": org-sexp-date) and the COMMENT keyword of
--- a headline (org-special-keyword), plus the duration of a clock line,
--- which org.nvim draws (orgClockDuration) and Emacs doesn't. Emacs matches
--- them on every line, inside verbatim and code, tables, fixed-width lines
--- and the body of quote and special blocks too; then
--- org-fontify-meta-lines-and-blocks puts its own face in place of theirs
--- on comments, keywords and block begin and end lines, and src, example
--- and export blocks get the faces of their language: those lines draw
--- none of them.

local M = {}

local H = require("org.ui.highlight")

local byte = string.byte

local PRIO = H.PRIO

-- (word characters in Org's syntax table: letters, digits, $ % ' and
-- non-ASCII characters; "\\<" matches where the byte before isn't one)
local WORD = {} ---@type table<integer, boolean>
for c = 48, 57 do
  WORD[c] = true
end
for c = 65, 90 do
  WORD[c] = true
  WORD[c + 32] = true
end
for c = 128, 255 do
  WORD[c] = true
end
WORD[36], WORD[37], WORD[39] = true, true, true

-- org-deadline-string, org-scheduled-string, org-closed-string,
-- org-clock-string
local SPECIAL = { "SCHEDULED:", "DEADLINE:", "CLOSED:", "CLOCK:" }

--- The first match of `pattern` (a closing bracket) in `s` at or after a
--- position, for positions that go up: the last answer stands for every
--- position up to itself (many dates before one closing bracket, or none,
--- search the line once).
---@return fun(from: integer): integer?
local function finder(s, pattern)
  local last_from, last_at = math.huge, nil ---@type integer, integer?
  return function(from)
    if from >= last_from and (last_at == nil or from <= last_at) then
      return last_at
    end
    last_from, last_at = from, s:find(pattern, from)
    return last_at
  end
end

local function is_digit(b)
  return b ~= nil and b >= 48 and b <= 57
end

--- The end (inclusive) of the timestamp of `s` at `p` (org-ts-regexp-both:
--- "[" or "<", a date, then the closing bracket of either kind right after
--- it or after a space and the shortest text), or nil.
---@param close fun(from: integer): integer?
---@return integer?
local function stamp_at(s, p, close)
  local o = byte(s, p)
  if o ~= 91 and o ~= 60 then
    return nil
  end
  for k = 1, 10 do
    local b = byte(s, p + k)
    if k == 5 or k == 8 then
      if b ~= 45 then
        return nil
      end
    elseif not is_digit(b) then
      return nil
    end
  end
  local b = byte(s, p + 11)
  if b == 93 or b == 62 then
    return p + 11
  elseif b == 32 then
    return close(p + 12)
  end
end

--- Paint the timestamps and ranges of line `i` (org-activate-dates);
--- `nospell`: only leave them out of spell checking.
---@param nospell? boolean
local function stamps(ctx, i, line, nospell)
  if not line:find("%d%d%d%d%-%d%d%-%d%d") then
    return
  end
  local close = finder(line, "[%]>]")
  local pos = 1
  while true do
    local p = line:find("[%[<]%d%d%d%d%-%d%d%-%d%d", pos)
    if not p then
      return
    end
    local e = stamp_at(line, p, close)
    if not e then
      pos = p + 1
    else
      -- a range: one to three dashes, then a second timestamp
      local d = 0
      while d < 3 and byte(line, e + 1 + d) == 45 do
        d = d + 1
      end
      if d > 0 then
        local e2 = stamp_at(line, e + 1 + d, close)
        if e2 then
          e = e2
        end
      end
      -- (not after "[": a link's target, a date in brackets twice. Emacs's
      -- matcher then stops drawing dates up to the end of the region
      -- font-lock draws, a bug not copied: only this one is left out)
      if p == 1 or byte(line, p - 1) ~= 91 then
        local group = byte(line, p) == 91 and "orgTimestampInactive" or "orgTimestamp"
        ctx.emit(i, p - 1, e, { hl_group = not nospell and group or nil, priority = PRIO.object, spell = false })
      end
      pos = e + 1
    end
  end
end

--- Paint the planning and clock keywords of line `i`, anywhere on it.
local function specials(ctx, i, line)
  for _, kw in ipairs(SPECIAL) do
    local pos = 1
    while true do
      local p = line:find(kw, pos, true)
      if not p then
        break
      end
      if not WORD[byte(line, p - 1) or 32] then
        local group = kw == "CLOCK:" and "orgClock" or "orgPlanning"
        ctx.emit(i, p - 1, p - 1 + #kw, { hl_group = group, priority = PRIO.object, spell = false })
      end
      pos = p + #kw
    end
  end
end

--- Paint the durations of clock line `i` ("=> 1:30" after CLOCK:).
local function durations(ctx, i, line)
  local s = line:match("^[ \t]*CLOCK:()")
  if not s then
    return
  end
  local pos = s
  while true do
    local p = line:find("=>", pos, true)
    if not p then
      return
    end
    local e = line:match("^=>[ \t]*%-?%d+:%d%d()", p)
    if e then
      ctx.emit(i, p - 1, e - 1, { hl_group = "orgClockDuration", priority = PRIO.object, spell = false })
    end
    pos = p + 2
  end
end

--- Paint the diary sexps of line `i`: the rest of a line that starts with
--- "%%(" (or "&%%("), else each "<%%(...>".
local function sexps(ctx, i, line)
  local s = line:match("^&?()%%%%%(")
  if s then
    ctx.emit(i, 0, #line, { hl_group = "orgSexpDate", priority = PRIO.object, spell = false })
    return
  end
  if not line:find("<%%(", 1, true) then
    return
  end
  local gt = finder(line, ">")
  local pos = 1
  while true do
    local p = line:find("<%%(", pos, true)
    if not p then
      return
    end
    local e = gt(p + 4)
    if not e then
      return
    end
    ctx.emit(i, p - 1, e, { hl_group = "orgSexpDate", priority = PRIO.object, spell = false })
    pos = e + 1
  end
end

--- Paint the COMMENT keyword of headline `i`: after the stars, an optional
--- TODO keyword and an optional priority cookie, followed by a space or
--- the end of the line.
---@param todo? table the file's TODO keywords (org.todo_keywords)
local function comment(ctx, i, line, todo)
  local p = line:match("^%*+()")
  if not p or byte(line, p) ~= 32 then
    return
  end
  --- The end of " +COMMENT" at q, followed by a space or the end.
  local function at(q)
    local r = line:match("^ +()", q)
    if r and line:sub(r, r + 6) == "COMMENT" then
      local b = byte(line, r + 7)
      if b == nil or b == 32 then
        return r
      end
    end
  end
  --- After an optional priority cookie at q.
  local function after_priority(q)
    local r = at(q)
    if r then
      return r
    end
    local c = line:match("^ +%[#[%u%d]%]()", q)
      or line:match("^ +%[#[1-5]%d%]()", q)
      or line:match("^ +%[#6[0-4]%]()", q)
    return c and at(c)
  end
  local r = after_priority(p)
  if not r and todo then
    local w, e = line:match("^ +([^ \t]+)()", p)
    if w and todo:is_keyword(w) then
      r = after_priority(e)
    end
  end
  if r then
    ctx.emit(i, r - 1, r + 6, { hl_group = "orgHeadlineComment", priority = PRIO.object, spell = false })
  end
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local lines, kinds = ctx.lines, ctx.kinds
  local todo = ctx.file and ctx.file.settings and ctx.file.settings.todo
  local from = math.max(1, ctx.first - ctx.row0 + 1)
  local to = math.min(#lines, ctx.last - ctx.row0 + 1)
  for i = from, to do
    local line = lines[i]
    local kind = kinds[i]
    -- (comments, keywords and the begin and end lines of blocks get their
    -- face in place of these, org-fontify-meta-lines-and-blocks; src,
    -- example and export blocks the faces of their language)
    if kind ~= "comment" and kind ~= "info" and kind ~= "none" then
      if byte(line, 1) == 42 then
        comment(ctx, i, line, todo)
      end
      if line:find("[%[<]") then
        stamps(ctx, i, line)
      end
      if line:find("[DSC]") then
        specials(ctx, i, line)
        durations(ctx, i, line)
      end
      if line:find("%%(", 1, true) then
        sexps(ctx, i, line)
      end
    elseif kind == "none" and not ctx.roles[i] and line:find("^[ \t]*#%+[cC][aA][pP][tT][iI][oO][nN]") then
      -- a caption is spell checked (org.ui.highlight.block), but not its
      -- timestamps (org--flyspell-object-check-p)
      stamps(ctx, i, line, true)
    end
  end
end

return M
