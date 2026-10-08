---@mod org.lint.element org-lint: the element parser
---
--- `Doc`, the parsed document, and its element methods, following
--- org-element. lua/org/lint/object.lua adds the object methods and
--- `parse`.

local util = require("org.lint.util")
local data = require("org.lint.data")
local timestamp = require("org.lint.timestamp")

local trim = util.trim
local is_blank = util.is_blank
local nw = util.nw
local balanced = util.balanced
local AFFILIATED = data.AFFILIATED
local TRANSLATION = data.TRANSLATION
local parse_timestamp = timestamp.parse_timestamp

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
  if
    l:match("^[ \t]*[%-+*][ \t]")
    or l:match("^[ \t]*[%-+*]$")
    or l:match("^[ \t]*%d+[%.%)][ \t]")
    or l:match("^[ \t]*%d+[%.%)]$")
  then
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
  local ts, tagstr = line:match("()[ \t]+(:[%w_@#%%:\128-\255]+:)[ \t]*$", back)
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
      local ts = parse_timestamp(l, p, #l)
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
  return require("org.babel.blocks").unescape(lines)
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
      local m = r:match('^( +%-l ".+")')
        or r:match("^( +%-[ikr])")
        or r:match("^( +[%-+]n *%d+)")
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

return {
  Doc = Doc,
  new_el = new_el,
  match_drawer = match_drawer,
}
