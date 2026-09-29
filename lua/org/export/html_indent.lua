---@mod org.export.html_indent Indentation of exported HTML (org-html-indent)
---
--- Emacs indents the output with `indent-region` in the major mode
--- `set-auto-mode` picks for it: a full document is in mhtml-mode (the SGML
--- indentation of sgml-mode, with the CSS and JavaScript of <style> and
--- <script> indented by their own modes), a body-only fragment in
--- fundamental-mode (every line takes the indentation of the first one).
--- This is a port of sgml-calculate-indent; <style> and <script> contents
--- are indented by bracket depth (4 columns, continuation lines aligned
--- after an opening brace), which covers the code Org writes there.

local M = {}

local BASIC = 2 -- sgml-basic-offset
local SUB = 4 -- css-indent-offset / js-indent-level
local TAB = 8

-- sgml-empty-tags and sgml-unclosed-tags of html-mode
local EMPTY_TAGS = {
  "area",
  "base",
  "basefont",
  "br",
  "col",
  "frame",
  "hr",
  "img",
  "input",
  "isindex",
  "link",
  "meta",
  "source",
  "param",
  "wbr",
}
local UNCLOSED_TAGS = {
  "body",
  "colgroup",
  "dd",
  "dt",
  "head",
  "html",
  "li",
  "option",
  "p",
  "tbody",
  "td",
  "tfoot",
  "th",
  "thead",
  "tr",
}
local EMPTY, UNCLOSED = {}, {}
for _, t in ipairs(EMPTY_TAGS) do
  EMPTY[t] = true
end
for _, t in ipairs(UNCLOSED_TAGS) do
  UNCLOSED[t] = true
end
local SENSITIVE = { pre = true, textarea = true }

local function key(l, c)
  return l * 100000 + c
end

--- Tokens of the document: tags, comments, processing instructions and
--- declarations with their (line, col) spans, and the <script>/<style>
--- content regions.
local function tokenize(lines, xml)
  local tokens, regions = {}, {}
  local li, col = 1, 1
  local raw -- name of the <script>/<style> element whose content we are in
  local raw_start
  local function find_across(pat, l, c, plain)
    while l <= #lines do
      local a, b = lines[l]:find(pat, c, plain)
      if a then
        return l, a, b
      end
      l, c = l + 1, 1
    end
  end
  while li <= #lines do
    local line = lines[li]
    if raw then
      local lower = line:lower()
      local a = lower:find("</" .. raw, col, true)
      if a then
        regions[#regions + 1] = { s = raw_start, e = key(li, a) }
        raw = nil
        col = a
      else
        li, col = li + 1, 1
      end
    else
      local a = line:find("<", col, true)
      if not a then
        li, col = li + 1, 1
      else
        local rest = line:sub(a)
        local tok
        if rest:sub(1, 4) == "<!--" then
          local l2, _, b2 = find_across("-->", li, a + 4, true)
          tok = { kind = "comment", sl = li, sc = a, el = l2 or #lines, ec = b2 or #lines[#lines] }
        elseif rest:sub(1, 2) == "<?" then
          local l2, _, b2 = find_across("?>", li, a + 2, true)
          tok = { kind = "pi", sl = li, sc = a, el = l2 or #lines, ec = b2 or #lines[#lines] }
        elseif rest:match("^<![%a%[]") then
          local l2, b2 = find_across(">", li, a + 2, true)
          tok = { kind = "decl", sl = li, sc = a, el = l2 or #lines, ec = b2 or #lines[#lines] }
        elseif rest:match("^</?[%a]") then
          local close = rest:sub(2, 2) == "/"
          local name = rest:match("^</?([%a][%w%-_.:]*)"):lower()
          -- the end of the tag, skipping quoted attribute values
          local l2, c2, q = li, a + 1, nil
          local found
          while l2 <= #lines and not found do
            local s = lines[l2]
            while c2 <= #s do
              local ch = s:sub(c2, c2)
              if q then
                if ch == q then
                  q = nil
                end
              elseif ch == '"' or ch == "'" then
                q = ch
              elseif ch == ">" then
                found = true
                break
              end
              c2 = c2 + 1
            end
            if not found then
              l2, c2 = l2 + 1, 1
            end
          end
          if not found then
            l2, c2 = #lines, #lines[#lines]
          end
          local kind = close and "close" or "open"
          if not close and ((c2 > 1 and lines[l2]:sub(c2 - 1, c2 - 1) == "/") or (not xml and EMPTY[name])) then
            kind = "empty"
          end
          tok = { kind = kind, name = name, sl = li, sc = a, el = l2, ec = c2 }
          if kind == "open" and (name == "script" or name == "style") then
            raw, raw_start = name, key(l2, c2 + 1)
          end
        end
        if tok then
          tokens[#tokens + 1] = tok
          li, col = tok.el, tok.ec + 1
        else
          col = a + 1
        end
      end
    end
  end
  return tokens, regions
end

local function indentation(line)
  local ws = line:match("^[ \t]*")
  local w = 0
  for ch in ws:gmatch(".") do
    w = ch == "\t" and (math.floor(w / TAB) + 1) * TAB or w + 1
  end
  return w, #ws
end

--- The display column of byte `c` (1-based) of `line`.
local function column(line, c)
  local w = 0
  for i = 1, c - 1 do
    local ch = line:sub(i, i)
    if ch == "\t" then
      w = (math.floor(w / TAB) + 1) * TAB
    elseif not ch:match("[\128-\191]") then
      w = w + 1
    end
  end
  return w
end

local function indent_string(n)
  return string.rep("\t", math.floor(n / TAB)) .. string.rep(" ", n % TAB)
end

--- Indent `text` like org-html-final-function with org-html-indent.
---@param text string
---@return string
function M.indent(text)
  local trailing = text:match("\n$") and "\n" or ""
  local lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  local head = text:sub(1, 400)
  local doc = head:match("^%s*<%?xml")
    or head:match("^%s*<![Dd][Oo][Cc][Tt][Yy][Pp][Ee]")
    or head:match("^%s*<[Hh][Tt][Mm][Ll]")
  if not doc then
    -- fundamental-mode: indent-relative gives every line the first line's
    -- indentation
    local _, n = indentation(lines[1] or "")
    local ind = (lines[1] or ""):sub(1, n)
    for i, l in ipairs(lines) do
      if l ~= "" then
        lines[i] = ind .. (l:gsub("^[ \t]+", ""))
      end
    end
    return table.concat(lines, "\n") .. trailing
  end
  local xml = head:match("^%s*<%?xml") ~= nil or head:match("<![Dd][Oo][Cc][Tt][Yy][Pp][Ee][^>]*XHTML") ~= nil
  local tokens, regions = tokenize(lines, xml)
  local function col_of(l, c)
    return column(lines[l], c)
  end
  local function at_indentation(t)
    return not lines[t.sl]:sub(1, t.sc - 1):match("%S")
  end
  --- Tokens ending before position (l, c), latest first.
  local function before(l, c)
    local k = key(l, c)
    local i = #tokens
    return function()
      while i >= 1 do
        local t = tokens[i]
        i = i - 1
        if key(t.el, t.ec) < k then
          return t
        end
      end
    end
  end
  --- sgml-get-context from (l, c); `until` nil or "empty". Returns the
  --- open tags (outermost first) and the tag parsing stopped at.
  local function get_context(l, c, until_)
    local stack, ignore, context = {}, {}, {}
    local cur -- the last parsed tag
    local iter = before(l, c)
    while true do
      local cond = #stack > 0
        or (until_ ~= "empty" and #context == 0)
        or not (cur and at_indentation(cur))
        or (#context > 0 and cur ~= context[1] and not xml and UNCLOSED[context[1].name])
      if not cond then
        break
      end
      local t = iter()
      if not t then
        break
      end
      cur = t
      if t.kind == "open" then
        if #stack == 0 then
          if not ignore[t.name] then
            table.insert(context, 1, t)
            ignore = {}
          end
        elseif t.name == stack[1] then
          table.remove(stack, 1)
        elseif not xml then
          if not UNCLOSED[t.name] then
            -- drop the matching close tag deeper in the stack
            for k = 2, #stack do
              if stack[k] == t.name then
                table.remove(stack, k)
                break
              end
            end
          end
        else
          table.remove(stack, 1)
        end
        if #stack == 0 and not xml and UNCLOSED[t.name] then
          ignore[t.name] = true
        end
      elseif t.kind == "close" then
        if xml or not EMPTY[t.name] then
          table.insert(stack, 1, t.name)
        end
      end
    end
    return context, cur
  end
  --- The token containing (l, c) strictly after its start, if any.
  local function inside_token(l, c)
    local k = key(l, c)
    for _, t in ipairs(tokens) do
      if key(t.sl, t.sc) < k and k <= key(t.el, t.ec) then
        return t
      end
      if key(t.sl, t.sc) > k then
        break
      end
    end
  end
  --- Start of the text run containing (l, c): the end of the last token before.
  local function text_start(l, c)
    local t = before(l, c)()
    return t and key(t.el, t.ec + 1) or 0
  end
  local function region_at(l, c)
    local k = key(l, c)
    for _, r in ipairs(regions) do
      if r.s <= k and k < r.e then
        return r
      end
    end
  end

  --- sgml-calculate-indent for a text line (nil = leave it alone).
  local function sgml_indent(l, c)
    -- whitespace-sensitive elements (pre, textarea): leave their lines
    local ctx = get_context(l, c, nil)
    for _, t in ipairs(ctx) do
      if SENSITIVE[t.name] then
        return nil
      end
    end
    local line = lines[l]
    local here = c
    -- skip the close tags that start the line
    while line:sub(here, here + 1) == "</" do
      local e = line:find(">", here, true)
      if not e then
        break
      end
      here = e + 1
      here = here + #(line:match("^[ \t]*", here))
    end
    local unclosed = line:sub(here):match("^<([%a][%w%-_.:]*)")
    unclosed = unclosed and UNCLOSED[unclosed:lower()] and unclosed:lower() or nil
    -- align on the previous line when it is text of the same run (only
    -- when no close tag was skipped: Emacs looks back from after them)
    if not unclosed and here == c then
      local p = l - 1
      while p >= 1 and not lines[p]:match("%S") do
        p = p - 1
      end
      if p >= 1 then
        local _, nb = indentation(lines[p])
        if key(p, nb + 1) > text_start(l, c) then
          return indentation(lines[p])
        end
      end
    end
    local context, anchor = get_context(l, here, unclosed and nil or "empty")
    -- innermost first
    local rev = {}
    for i = #context, 1, -1 do
      rev[#rev + 1] = context[i]
    end
    while #rev > 0 and unclosed and rev[1].name == unclosed do
      table.remove(rev, 1)
    end
    if #rev > 0 then
      -- align on the first element after the nearest open tag
      local t = rev[1]
      local nl, nc = t.el, t.ec + 1
      while nl <= #lines do
        local s = lines[nl]:find("%S", nc)
        if s then
          nc = s
          break
        end
        nl, nc = nl + 1, 1
      end
      if nl <= #lines and key(nl, nc) < key(l, here) and not lines[nl]:sub(1, nc - 1):match("%S") then
        return col_of(nl, nc)
      end
    end
    local base = anchor and col_of(anchor.sl, anchor.sc) or 0
    return base + BASIC * #rev
  end

  local function tag_indent(t)
    if t.kind == "decl" then
      return 1
    elseif t.kind ~= "open" and t.kind ~= "empty" and t.kind ~= "close" then
      return nil
    end
    local s = lines[t.sl]
    local after_name = s:find("[ \t\n]", t.sc) or (#s + 1)
    local attr = s:find("%S", after_name)
    if attr and key(t.sl, attr) <= key(t.el, t.ec) then
      return col_of(t.sl, attr)
    end
    return col_of(t.sl, t.sc) + BASIC
  end

  --- Bracket-depth indentation of <style>/<script> contents.
  local function sub_indent(r, l, c)
    local rl, rc = math.floor(r.s / 100000), r.s % 100000
    local base = sgml_indent(rl, rc) or 0
    local stack = {}
    local q
    local in_comment = false
    for ln = rl, l do
      local s = lines[ln]
      local from = ln == rl and rc or 1
      local to = ln == l and c - 1 or #s
      local i = from
      while i <= to do
        local ch = s:sub(i, i)
        if in_comment then
          if s:sub(i, i + 1) == "*/" then
            in_comment = false
            i = i + 1
          end
        elseif q then
          if ch == "\\" then
            i = i + 1
          elseif ch == q then
            q = nil
          end
        elseif s:sub(i, i + 1) == "/*" then
          in_comment = true
          i = i + 1
        elseif s:sub(i, i + 1) == "//" then
          break
        elseif ch == '"' or ch == "'" or ch == "`" then
          q = ch
        elseif ch == "{" or ch == "[" or ch == "(" then
          stack[#stack + 1] = { ln, i }
        elseif ch == "}" or ch == "]" or ch == ")" then
          stack[#stack] = nil
        end
        i = i + 1
      end
    end
    if in_comment then
      -- lines inside a comment keep their indentation
      return nil
    end
    local first = lines[l]:sub(c, c)
    local closing = first == "}" or first == "]" or first == ")"
    local open = stack[#stack]
    if open and not closing then
      local after = lines[open[1]]:find("%S", open[2] + 1)
      if after then
        return col_of(open[1], after)
      end
    end
    local depth = #stack - (closing and 1 or 0)
    if depth <= 0 then
      return base
    end
    -- nested levels count from the indentation of the line opening them
    local o = stack[closing and #stack or #stack]
    if closing then
      return indentation(lines[o[1]])
    end
    return indentation(lines[o[1]]) + SUB
  end

  for l = 1, #lines do
    local line = lines[l]
    if line ~= "" then
      local _, nb = indentation(line)
      local c = nb + 1
      local target
      local r = region_at(l, c)
      if r and line:sub(c, c + 1) ~= "</" then
        target = sub_indent(r, l, c)
      else
        local t = inside_token(l, c)
        if t then
          target = tag_indent(t)
        else
          target = sgml_indent(l, c)
        end
      end
      if target then
        local new = indent_string(target) .. line:sub(nb + 1)
        if new ~= line then
          local delta = #new - #line
          lines[l] = new
          -- shift the tokens of this line
          for _, t in ipairs(tokens) do
            if t.sl == l then
              t.sc = t.sc + delta
            end
            if t.el == l then
              t.ec = t.ec + delta
            end
          end
          for _, rg in ipairs(regions) do
            if math.floor(rg.s / 100000) == l then
              rg.s = rg.s + delta
            end
            if math.floor(rg.e / 100000) == l then
              rg.e = rg.e + delta
            end
          end
        end
      end
    end
  end
  return table.concat(lines, "\n") .. trailing
end

return M
