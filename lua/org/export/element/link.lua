---@mod org.export.element.link Export parser: links
---
--- Bracket, angle and plain links, link abbreviations and radio
--- targets.
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local P = shared.P
local word_char = shared.word_char

--- Balanced square brackets starting at p (s:sub(p,p) == "[").
local function balanced_square(s, p)
  local depth = 0
  for k = p, #s do
    local c = s:sub(k, k)
    if c == "[" then
      depth = depth + 1
    elseif c == "]" then
      depth = depth - 1
      if depth == 0 then
        return k
      end
    end
  end
end

--- Parse paired brackets `open` at p: returns inner, end index or nil.
local function paired(s, p, open)
  local close = ({ ["["] = "]", ["("] = ")", ["{"] = "}" })[open]
  if s:sub(p, p) ~= open then
    return nil
  end
  local depth = 0
  for k = p, #s do
    local c = s:sub(k, k)
    if c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then
        return s:sub(p + 1, k - 1), k + 1
      end
    end
  end
end

function P:link_type_of(raw)
  local t = raw:match("^([%w%+%-]+):")
  if t and (self.link_types[t] or (self.opts.extra_link_types and self.opts.extra_link_types[t])) then
    return t, raw:sub(#t + 2)
  end
end

--- Expand #+LINK / config link abbreviations.
function P:expand_abbrev(link)
  local key, tag = link:match("^([^:]*)::?(.*)$")
  if not key then
    key = link
  end
  local abbrevs = self.opts.abbrevs or {}
  local rpl = abbrevs[key]
  if rpl == nil then
    return link
  end
  if type(rpl) == "function" then
    local ok, v = pcall(rpl, tag or "")
    return ok and v or link
  end
  if rpl:find("%(", 1, true) then
    return require("org.links").abbrev_call(rpl, tag or "") or link
  end
  if rpl:find("%s", 1, true) then
    return (rpl:gsub("%%s", function()
      return tag or ""
    end))
  elseif rpl:find("%h", 1, true) then
    return (
      rpl:gsub("%%h", function()
        return (tag or ""):gsub("[^%w%-_%.~]", function(ch)
          return string.format("%%%02X", ch:byte())
        end)
      end)
    )
  end
  return rpl .. (tag or "")
end

local function link_unescape(s)
  return (
    s:gsub("(\\+)([%[%]])", function(bs, ch)
      return string.rep("\\", math.floor(#bs / 2)) .. ch
    end):gsub("(\\+)$", function(bs)
      return string.rep("\\", math.floor(#bs / 2))
    end)
  )
end

function P:make_link(raw, format, desc_text, e, s, desc_off)
  local ltype, path
  local explicit = false
  if require("org.utils").is_absolute(raw) or raw:match("^~") or raw:match("^%.%.?/") then
    ltype, path = "file", raw
  else
    local t, p2 = self:link_type_of(raw)
    if t then
      ltype, path, explicit = t, p2, true
    elseif raw:match("^%(.*%)$") then
      ltype, path = "coderef", raw:sub(2, -2)
    elseif raw:sub(1, 1) == "#" then
      ltype, path = "custom-id", raw:sub(2)
    else
      ltype, path = "fuzzy", raw
    end
  end
  local node = M.node("link", {
    link_type = ltype,
    type_explicit = explicit,
    path = path,
    format = format,
    raw_link = raw,
  })
  local app = ltype:match("^file%+(.+)$")
  if ltype == "file" or app then
    node.application = app
    node.link_type = "file"
    local p2, opt = node.path:match("^(.-)::(.*)$")
    if p2 then
      node.path = p2
      node.search_option = opt
    end
    node.path = node.path:gsub("^///*(%a:)/", "%1/")
  end
  if desc_text then
    node.contents = self:parse_contents(desc_text, M.RESTRICTIONS.link, node, desc_off)
  end
  local ws = s:match("^[ \t]*", e)
  node.post_blank = #ws
  return node, e + #ws
end

--- Plain link path at s:sub(p) after "type:" (org-link-plain-re).
local function plain_path(s, p)
  local k = p
  local n = #s
  local last_ok = nil
  while k <= n do
    local c = s:sub(k, k)
    if c:match("[%s%[%]%(%)<>]") then
      if c == "(" or c == "[" or c == "<" then
        -- balanced group (one level of nesting)
        local close = ({ ["("] = ")", ["["] = "]", ["<"] = ">" })[c]
        local depth, j = 0, k
        local ok = false
        while j <= n do
          local cj = s:sub(j, j)
          if cj:match("%s") then
            break
          end
          if cj == "(" or cj == "[" or cj == "<" then
            depth = depth + 1
          elseif cj == ")" or cj == "]" or cj == ">" then
            depth = depth - 1
            if depth == 0 then
              ok = cj == close
              break
            end
          end
          j = j + 1
        end
        if ok then
          k = j + 1
          last_ok = j
        else
          break
        end
      else
        break
      end
    else
      if not c:match("[%p]") or c == "/" or c == "-" or c:byte() > 127 then
        last_ok = k
      end
      k = k + 1
    end
  end
  if last_ok and last_ok >= p then
    return s:sub(p, last_ok), last_ok + 1
  end
end

function P:link_at(s, p)
  local c = s:sub(p, p)
  if c == "[" and s:sub(p + 1, p + 1) == "[" then
    -- bracket link
    local k = p + 2
    local n = #s
    local path_end
    while k <= n do
      local ch = s:sub(k, k)
      if ch == "\\" then
        k = k + 2
      elseif ch == "[" then
        return nil
      elseif ch == "]" then
        path_end = k
        break
      else
        k = k + 1
      end
    end
    if not path_end or path_end == p + 2 then
      return nil
    end
    local rawpath = s:sub(p + 2, path_end - 1)
    local desc, e
    if s:sub(path_end + 1, path_end + 1) == "]" then
      e = path_end + 2
    elseif s:sub(path_end + 1, path_end + 1) == "[" then
      local close = s:find("]]", path_end + 2, true)
      if not close or close == path_end + 2 then
        return nil
      end
      desc = s:sub(path_end + 2, close - 1)
      e = close + 2
    else
      return nil
    end
    local raw = rawpath:gsub("[ \t]*\n[ \t]*", " ")
    raw = self:expand_abbrev(link_unescape(raw))
    return self:make_link(raw, "bracket", desc, e, s, path_end + 2)
  elseif c == "<" then
    local t, rest = s:match("^<([%w%+%-]+):([^>]*)>", p)
    if t and (self.link_types[t] or (self.opts.extra_link_types and self.opts.extra_link_types[t])) then
      local e = p + #t + #rest + 3
      local node, e2 = self:make_link(t .. ":" .. rest:gsub("[ \t]*\n[ \t]*", ""), "angle", nil, e, s)
      node.raw_link = t .. ":" .. rest
      return node, e2
    end
    return nil
  else
    -- plain link
    local prev = p > 1 and s:sub(p - 1, p - 1) or ""
    if word_char(prev) then
      return nil
    end
    -- (only as far as the longest link type: from each word of a long run
    -- of letters, digits, "+" and "-", the pattern went to its end)
    if not self.max_link_type then
      local n = 0
      for _, set in ipairs({ self.link_types, self.opts.extra_link_types or {} }) do
        for k in pairs(set) do
          n = math.max(n, type(k) == "string" and #k or 0)
        end
      end
      self.max_link_type = n
    end
    local t = s:sub(p, p + self.max_link_type):match("^([%w%+%-]+):")
    if not t or not (self.link_types[t] or (self.opts.extra_link_types and self.opts.extra_link_types[t])) then
      return nil
    end
    local path, e = plain_path(s, p + #t + 1)
    if not path then
      return nil
    end
    return self:make_link(t .. ":" .. path, "plain", nil, e, s)
  end
end

--- Radio link at p: returns node, end.
function P:radio_at(s, p, lows)
  if #self.radios == 0 then
    return nil
  end
  local prev = p > 1 and s:sub(p - 1, p - 1) or ""
  if word_char(prev) then
    return nil
  end
  local low = (lows or s:lower()):sub(p)
  for _, words in ipairs(self.radios) do
    local pos = 1
    local ok = true
    for wi, w in ipairs(words) do
      if low:sub(pos, pos + #w - 1) ~= w then
        ok = false
        break
      end
      pos = pos + #w
      if wi < #words then
        local ws = low:match("^[ \t\n]+", pos)
        if not ws then
          ok = false
          break
        end
        pos = pos + #ws
      end
    end
    if ok then
      local nextc = low:sub(pos, pos)
      if not word_char(nextc) then
        local text = s:sub(p, p + pos - 2)
        local node = M.node("link", { link_type = "radio", path = text, format = "plain", raw_link = text })
        node.contents = self:parse_contents(text, M.RESTRICTIONS["radio-target"], node, p)
        local e = p + pos - 1
        local ws = s:match("^[ \t]*", e)
        node.post_blank = #ws
        return node, e + #ws
      end
    end
  end
end

-- Locals the later parts share
shared.balanced_square = balanced_square
shared.paired = paired
