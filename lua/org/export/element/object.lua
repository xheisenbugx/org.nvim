---@mod org.export.element.object Export parser: objects
---
--- Sub/superscripts, entities, LaTeX fragments, the object dispatcher
--- (object_at), citations, macros and parse_objects.
---
--- Part of org.export.element, which loads it.

local entities = require("org.export.entities")
local shared = require("org.export.element.shared")

local M = require("org.export.element")

local trim = shared.trim
local P = shared.P
local word_char = shared.word_char
local EMPH = shared.EMPH
local balanced_square = shared.balanced_square
local paired = shared.paired

--- Sub/superscript at p (org-match-substring-regexp).
local function subsup(s, p)
  if p <= 1 then
    return nil
  end
  local prev = s:sub(p - 1, p - 1)
  if prev:match("[ \t\n]") then
    return nil
  end
  local c = s:sub(p + 1, p + 1)
  if c == "{" then
    local inner, e = paired(s, p + 1, "{")
    if inner then
      return inner, e, true
    end
    return nil
  elseif c == "(" then
    local inner, e = paired(s, p + 1, "(")
    if inner then
      return "(" .. inner .. ")", e, false
    end
    return nil
  elseif c == "*" then
    return "*", p + 2, false
  end
  -- [+-]?[[:alnum:].,\\]*[[:alnum:]]
  local k = p + 1
  local sign = s:sub(k, k)
  if sign == "+" or sign == "-" then
    k = k + 1
  end
  local run = s:match("^[%w%.,\\\128-\255]*", k)
  if not run or run == "" then
    return nil
  end
  -- back off to the last alnum
  local last = #run
  while last > 0 and not run:sub(last, last):match("[%w\128-\255]") do
    last = last - 1
  end
  if last == 0 then
    return nil
  end
  local e = k + last
  return s:sub(p + 1, e - 1), e, false
end

--- Entity name at p (after the backslash).
local function entity_at(s, p)
  local sp = s:match("^_( +)", p + 1)
  if sp then
    local name = "_" .. sp
    if entities[name] then
      return name, p + 1 + #name, false
    end
    return nil
  end
  local name = s:match("^(there4)", p + 1) or s:match("^(sup[123])", p + 1) or s:match("^(frac[13][24])", p + 1)
  if not name then
    name = s:match("^(%a+)", p + 1)
  end
  if not name then
    return nil
  end
  local e = p + 1 + #name
  local brackets = false
  if s:sub(e, e + 1) == "{}" then
    brackets = true
  elseif s:sub(e, e):match("%a") then
    return nil
  end
  if not entities[name] and not (M.user_entities and M.user_entities[name]) then
    return nil
  end
  return name, e + (brackets and 2 or 0), brackets
end

function P:latex_fragment(s, p)
  local c = s:sub(p, p)
  local e
  if c ~= "$" then
    local c2 = s:sub(p + 1, p + 1)
    if c2 == "(" then
      local k = s:find("\\)", p + 2, true)
      e = k and k + 2
    elseif c2 == "[" then
      local k = s:find("\\]", p + 2, true)
      e = k and k + 2
    else
      local m = s:match("^\\%a+%*?", p)
      if not m then
        return nil
      end
      local k = p + #m
      while true do
        local g = s:match("^%[[^%]%[\n{}]*%]", k) or s:match("^{[^{}\n]*}", k)
        if not g then
          break
        end
        k = k + #g
      end
      e = k
    end
  elseif s:sub(p + 1, p + 1) == "$" then
    local k = s:find("$$", p + 2, true)
    e = k and k + 2
  else
    local prev = p > 1 and s:sub(p - 1, p - 1) or ""
    local nxt = s:sub(p + 1, p + 1)
    if prev == "$" or nxt:match("^[ \t\n,%.;]") or nxt == "" then
      return nil
    end
    local k = s:find("$", p + 1, true)
    if not k then
      return nil
    end
    local before = s:sub(k - 1, k - 1)
    if before:match("[ \t\n,%.]") then
      return nil
    end
    local after_c = s:sub(k + 1, k + 1)
    if not (after_c == "" or after_c:match("[%p%s]")) then
      return nil
    end
    e = k + 1
  end
  if not e then
    return nil
  end
  local ws = s:match("^[ \t]*", e)
  return M.node("latex-fragment", { value = s:sub(p, e - 1), post_blank = #ws }), e + #ws
end

--- Try to parse an object at position p. Returns node, next position.
function P:object_at(s, p, R)
  local c = s:sub(p, p)
  local rest2 = s:sub(p, p + 4)
  if (rest2:sub(1, 5) == "call_") and R["inline-babel-call"] and not word_char(p > 1 and s:sub(p - 1, p - 1) or "") then
    local name = s:match("^call_([^ \t\n%[%(]+)", p)
    if name then
      local k = p + 5 + #name
      local inside, k2
      if s:sub(k, k) == "[" then
        inside, k2 = paired(s, k, "[")
        if not inside then
          return nil
        end
        k = k2
      end
      local args, k3 = paired(s, k, "(")
      if not args then
        return nil
      end
      k = k3
      local endh
      if s:sub(k, k) == "[" then
        local eh, k4 = paired(s, k, "[")
        if eh then
          endh, k = eh, k4
        end
      end
      local ws = s:match("^[ \t]*", k)
      return M.node("inline-babel-call", {
        call = name,
        inside_header = inside and trim(inside) ~= "" and trim(inside) or nil,
        arguments = args ~= "" and args or nil,
        end_header = endh and trim(endh) ~= "" and trim(endh) or nil,
        value = s:sub(p, k - 1),
        post_blank = #ws,
      }),
        k + #ws
    end
  end
  if rest2:sub(1, 4) == "src_" and R["inline-src-block"] and not word_char(p > 1 and s:sub(p - 1, p - 1) or "") then
    local lang = s:match("^src_([^ \t\n%[{]+)", p)
    if lang then
      local k = p + 4 + #lang
      local params
      if s:sub(k, k) == "[" then
        local pr, k2 = paired(s, k, "[")
        if not pr then
          return nil
        end
        params, k = pr, k2
      end
      local body, k3 = paired(s, k, "{")
      if body then
        local ws = s:match("^[ \t]*", k3)
        return M.node("inline-src-block", {
          language = lang,
          parameters = params and trim(params) ~= "" and trim(params:gsub("\n[ \t]*", " ")) or nil,
          value = body,
          post_blank = #ws,
        }),
          k3 + #ws
      end
    end
  end
  if c == "^" then
    if R.superscript then
      local inner, e, br = subsup(s, p)
      if inner then
        local ws = s:match("^[ \t]*", e)
        return M.node("superscript", { inner = inner, use_brackets = br, post_blank = #ws }), e + #ws
      end
    end
  elseif c == "_" then
    if R.underline then
      local n, e = self:emphasis(s, p)
      if n then
        return n, e
      end
    end
    if R.subscript then
      local inner, e, br = subsup(s, p)
      if inner then
        local ws = s:match("^[ \t]*", e)
        return M.node("subscript", { inner = inner, use_brackets = br, post_blank = #ws }), e + #ws
      end
    end
  elseif EMPH[c] then
    if R[EMPH[c]] then
      return self:emphasis(s, p)
    end
  elseif c == "@" then
    if R["export-snippet"] then
      local be = s:match("^@@([%-%w]+):", p)
      if be then
        local start = p + 3 + #be
        local close = s:find("@@", start, true)
        if close then
          local e = close + 2
          local ws = s:match("^[ \t]*", e)
          return M.node("export-snippet", { back_end = be, value = s:sub(start, close - 1), post_blank = #ws }), e + #ws
        end
      end
    end
  elseif c == "{" then
    if R.macro and s:sub(p, p + 2) == "{{{" then
      local name = s:match("^{{{(%a[%-%w_]*)", p)
      if name then
        local k = p + 3 + #name
        local args
        local e
        if s:sub(k, k + 2) == "}}}" then
          e = k + 3
        elseif s:sub(k, k) == "(" then
          local close = s:find(")}}}", k, true)
          if close then
            args = s:sub(k + 1, close - 1)
            e = close + 4
          end
        end
        if e then
          local ws = s:match("^[ \t]*", e)
          return M.node("macro", {
            key = name:lower(),
            value = s:sub(p, e - 1),
            args = args and M.macro_args(trim((args:gsub("[ \t\r\n]+", " ")))) or nil,
            post_blank = #ws,
          }),
            e + #ws
        end
      end
    end
  elseif c == "$" then
    if R["latex-fragment"] then
      return self:latex_fragment(s, p)
    end
  elseif c == "<" then
    if s:sub(p + 1, p + 1) == "<" then
      if R["radio-target"] and s:sub(p + 2, p + 2) == "<" then
        local v = s:match("^<<<([^<>\n \t][^<>\n]-)>>>", p) or s:match("^<<<([^<>\n \t])>>>", p)
        if v and not v:match("[ \t]$") then
          local e = p + #v + 6
          local ws = s:match("^[ \t]*", e)
          local node = M.node("radio-target", { value = v, post_blank = #ws })
          node.contents = self:parse_objects(v, M.RESTRICTIONS["radio-target"], node)
          return node, e + #ws
        end
      end
      if R.target then
        local v = s:match("^<<([^<>\n \t][^<>\n]-)>>", p) or s:match("^<<([^<>\n \t])>>", p)
        if v and not v:match("[ \t]$") then
          local e = p + #v + 4
          local ws = s:match("^[ \t]*", e)
          return M.node("target", { value = v, post_blank = #ws }), e + #ws
        end
      end
    else
      if R.timestamp then
        local n, e = self:parse_timestamp(s, p)
        if n then
          return n, e
        end
      end
      if R.link then
        return self:link_at(s, p)
      end
    end
  elseif c == "\\" then
    if s:sub(p + 1, p + 1) == "\\" then
      if R["line-break"] and s:match("^\\\\[ \t]*\n", p) or (R["line-break"] and s:match("^\\\\[ \t]*$", p)) then
        local prev = p > 1 and s:sub(p - 1, p - 1) or ""
        if prev ~= "\\" then
          local ws = s:match("^\\\\([ \t]*)", p)
          local e = p + 2 + #ws
          if s:sub(e, e) == "\n" then
            e = e + 1
          end
          return M.node("line-break", { post_blank = 0 }), e
        end
      end
    else
      if R.entity then
        local name, e, br = entity_at(s, p)
        if name then
          local ws = s:match("^[ \t]*", e)
          return M.node("entity", { name = name, use_brackets = br, post_blank = #ws }), e + #ws
        end
      end
      if R["latex-fragment"] then
        return self:latex_fragment(s, p)
      end
    end
  elseif c == "[" then
    local c2 = s:sub(p + 1, p + 1)
    if c2 == "[" then
      if R.link then
        return self:link_at(s, p)
      end
    elseif c2 == "f" and s:sub(p, p + 3) == "[fn:" then
      if R["footnote-reference"] then
        local label = s:match("^%[fn:([%w%-_]*)", p)
        local k = p + 4 + #label
        local ftype
        if s:sub(k, k) == ":" then
          ftype = "inline"
        elseif s:sub(k, k) == "]" and label ~= "" then
          ftype = "standard"
        else
          return nil
        end
        local close = balanced_square(s, p)
        if not close then
          return nil
        end
        local ws = s:match("^[ \t]*", close + 1)
        local node = M.node("footnote-reference", {
          label = label ~= "" and label or nil,
          fn_type = ftype,
          post_blank = #ws,
        })
        if ftype == "inline" then
          node.contents = self:parse_objects(s:sub(k + 1, close - 1), M.RESTRICTIONS["footnote-reference"], node)
        end
        return node, close + 1 + #ws
      end
    elseif c2 == "c" and (s:sub(p, p + 5) == "[cite:" or s:sub(p, p + 5) == "[cite/") then
      if R.citation then
        return self:citation(s, p)
      end
    elseif c2 == "%" or c2 == "/" then
      if R["statistics-cookie"] then
        local v = s:match("^(%[%d*%%%])", p) or s:match("^(%[%d*/%d*%])", p)
        if v then
          local ws = s:match("^[ \t]*", p + #v)
          return M.node("statistics-cookie", { value = v, post_blank = #ws }), p + #v + #ws
        end
      end
    else
      if R.timestamp then
        local n, e = self:parse_timestamp(s, p)
        if n then
          return n, e
        end
      end
      if R["statistics-cookie"] then
        local v = s:match("^(%[%d*%%%])", p) or s:match("^(%[%d*/%d*%])", p)
        if v then
          local ws = s:match("^[ \t]*", p + #v)
          return M.node("statistics-cookie", { value = v, post_blank = #ws }), p + #v + #ws
        end
      end
    end
  elseif c:match("%a") then
    if R.link then
      return self:link_at(s, p)
    end
  end
  return nil
end

--- Citation key (org-element-citation-key-re): "@" then word characters
--- or any of -.:?!`'/*@+|(){}<>&_^$#%~.
local CITE_KEY = "()@([%w\128-\255%-%.:%?!`'/%*@%+|%(%){}<>&_%^%$#%%~]+)()"

--- Citation at p: [cite/style:prefix;@key suffix;...]
--- (org-element-citation-parser).
function P:citation(s, p)
  local style, colon = s:match("^%[cite/([/_%w%-]+)()", p)
  local start
  if style then
    if s:sub(colon, colon) ~= ":" then
      return nil
    end
    start = colon + 1
  elseif s:sub(p, p + 5) == "[cite:" then
    start = p + 6
  else
    return nil
  end
  -- Ignore blanks between cite type and prefix or key.
  start = s:match("^[ \t\n]*()", start)
  local close = balanced_square(s, p)
  if not close then
    return nil
  end
  local inner = s:sub(1, close - 1)
  local _, _, first_key_end = inner:match(CITE_KEY, start)
  if not first_key_end then
    return nil
  end
  local ws = s:match("^[ \t]*", close + 1)
  local node = M.node("citation", { style = style, post_blank = #ws, raw = s:sub(p, close) })
  local types = M.RESTRICTIONS["citation-reference"]
  -- Common prefix: text before the last ";" preceding the first key.
  local cbeg = start
  local semi
  for i = first_key_end - 1, start, -1 do
    if s:sub(i, i) == ";" then
      semi = i
      break
    end
  end
  if semi then
    if start < semi then
      node.prefix = self:parse_objects(s:sub(start, semi - 1), types, node)
    end
    cbeg = semi + 1
  end
  -- Common suffix: text after the last ";" when no key follows it.
  local cend = close - 1
  while cend >= first_key_end and s:sub(cend, cend):match("[ \r\t\n]") do
    cend = cend - 1
  end
  cend = cend + 1 -- exclusive end
  semi = nil
  for i = cend - 1, first_key_end, -1 do
    if s:sub(i, i) == ";" then
      semi = i
      break
    end
  end
  if semi and not s:sub(semi + 1, cend - 1):find(CITE_KEY) then
    if semi + 1 < cend then
      node.suffix = self:parse_objects(s:sub(semi + 1, cend - 1), types, node)
    end
    cend = semi
  end
  -- References, separated by ";" (org-element-citation-reference-parser).
  local refs = {}
  for part in (s:sub(cbeg, cend - 1) .. ";"):gmatch("([^;]*);") do
    local kpos, key, kend = part:match(CITE_KEY)
    if kpos then
      local ref = M.node("citation-reference", { key = key, post_blank = 0 })
      if kpos > 1 then
        ref.prefix = self:parse_objects(part:sub(1, kpos - 1), types, ref)
      end
      if kend <= #part then
        ref.suffix = self:parse_objects(part:sub(kend), types, ref)
      end
      ref.parent = node
      refs[#refs + 1] = ref
    end
  end
  if #refs == 0 then
    return nil
  end
  node.contents = refs
  return node, close + 1 + #ws
end

--- Split macro arguments (org-macro-extract-arguments).
function M.macro_args(s)
  local out = {}
  local cur = {}
  local i = 1
  while i <= #s do
    local bs = s:match("^\\*", i)
    if #bs > 0 and s:sub(i + #bs, i + #bs) == "," then
      cur[#cur + 1] = string.rep("\\", math.floor(#bs / 2))
      if #bs % 2 == 0 then
        out[#out + 1] = table.concat(cur)
        cur = {}
      else
        cur[#cur + 1] = ","
      end
      i = i + #bs + 1
    elseif s:sub(i, i) == "," then
      out[#out + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      local k = #bs > 0 and #bs or 1
      cur[#cur + 1] = s:sub(i, i + k - 1)
      i = i + k
    end
  end
  out[#out + 1] = table.concat(cur)
  return out
end

--- Parse objects of string `s` allowed by restriction set R.
---@return table[] nodes
function P:parse_objects(s, R, parent, depth)
  depth = depth or 0
  local out = {}
  local buf_start = 1
  local p = 1
  local n = #s
  local expansions = 0
  local function flush(upto)
    if upto >= buf_start then
      local t = M.text(s:sub(buf_start, upto), parent)
      out[#out + 1] = t
    end
  end
  local lows = #self.radios > 0 and s:lower() or nil
  while p <= n do
    local node, e = self:object_at(s, p, R)
    if not node and R.link and lows then
      node, e = self:radio_at(s, p, lows)
    end
    local replaced = false
    if node then
      if node.type == "macro" and self.opts.macro and expansions < 10000 then
        local value = self.opts.macro(node, self)
        if value ~= nil then
          -- textual replacement, then continue lexing from here
          local ws = string.rep(" ", node.post_blank)
          s = s:sub(1, p - 1) .. value .. ws .. s:sub(e)
          n = #s
          lows = lows and s:lower()
          expansions = expansions + 1
          node = nil
          replaced = true
        end
      end
    end
    if node then
      flush(p - 1)
      node.parent = parent
      if node.inner then
        node.contents =
          self:parse_objects(node.inner, M.RESTRICTIONS[node.type] or M.RESTRICTIONS.paragraph, node, depth)
        node.inner = nil
      end
      out[#out + 1] = node
      p = e
      buf_start = e
    elseif not replaced then
      p = p + 1
    end
  end
  flush(n)
  return out
end

--- Parse objects of a secondary string (org-element-parse-secondary-string).
function P:secondary(s, restriction, parent)
  if s == nil or s == "" then
    return nil
  end
  return self:parse_objects(s, M.RESTRICTIONS[restriction] or M.RESTRICTIONS.keyword, parent)
end
