---@mod org.export.csl.xml XML and HTML fragments like Emacs' libxml parser
---
--- An element is `{ tag = "name", attrs = { { "attr", "value" }... },
--- [1..n] = children }`, children being strings or elements. Comments
--- are `{ tag = "comment" }`. Whitespace-only text between elements is
--- dropped (libxml's "blanks" heuristic), entities are decoded.

local U = require("org.export.csl.util")

local X = {}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = U.char(0xA0) }

local function decode_entities(s, html)
  return (s:gsub("&(#?[%w]+);", function(e)
    if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
      local n = tonumber(e:sub(3), 16)
      return n and U.char(n) or nil
    elseif e:sub(1, 1) == "#" then
      local n = tonumber(e:sub(2))
      return n and U.char(n) or nil
    end
    local r = ENTITIES[e]
    if not r and not html then
      return nil
    end
    return r
  end))
end
X.decode_entities = decode_entities

local function parse_attrs(s, html)
  local attrs = {}
  for name, q, value in s:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
    local _ = q
    local key = html and name:lower() or name
    if not html then
      -- libxml gives local names; namespace declarations are not attributes
      if key == "xmlns" or key:match("^xmlns:") then
        key = nil
      else
        key = key:gsub("^[^:]+:", "")
      end
    end
    if key then
      -- XML attribute-value normalization: tabs and newlines become spaces
      if not html then
        value = value:gsub("[\t\n\r]", " ")
      end
      attrs[#attrs + 1] = { key, decode_entities(value, html) }
    end
  end
  return attrs
end

local function is_blank(s)
  return s:match("^[ \t\r\n]*$") ~= nil
end

--- Parse an XML document; returns the root element.
function X.parse(s)
  local root = { tag = "top", attrs = {} }
  local stack = { root }
  local pos = 1
  local n = #s
  local function top()
    return stack[#stack]
  end
  local function add_text(text, next_is_close)
    if text == "" then
      return
    end
    local node = top()
    if is_blank(text) then
      local keep = false
      if #node == 0 and next_is_close then
        keep = true
      elseif #node > 0 and type(node[#node]) == "string" then
        keep = true
      elseif #node > 0 and type(node[1]) == "string" then
        keep = true
      end
      if not keep or node == root then
        return
      end
    end
    text = decode_entities(text)
    if type(node[#node]) == "string" then
      node[#node] = node[#node] .. text
    else
      node[#node + 1] = text
    end
  end
  while pos <= n do
    local lt = s:find("<", pos, true)
    if not lt then
      add_text(s:sub(pos), false)
      break
    end
    if lt > pos then
      add_text(s:sub(pos, lt - 1), s:sub(lt + 1, lt + 1) == "/")
    end
    if s:sub(lt, lt + 3) == "<!--" then
      local close = s:find("-->", lt + 4, true) or n
      local node = top()
      node[#node + 1] = { tag = "comment", attrs = {}, s:sub(lt + 4, close - 1) }
      pos = close + 3
    elseif s:sub(lt, lt + 8) == "<![CDATA[" then
      local close = s:find("]]>", lt + 9, true) or n
      local node = top()
      local text = s:sub(lt + 9, close - 1)
      if type(node[#node]) == "string" then
        node[#node] = node[#node] .. text
      else
        node[#node + 1] = text
      end
      pos = close + 3
    elseif s:sub(lt, lt + 1) == "<?" then
      local close = s:find("?>", lt + 2, true) or n
      pos = close + 2
    elseif s:sub(lt, lt + 1) == "<!" then
      local close = s:find(">", lt + 2, true) or n
      pos = close + 1
    elseif s:sub(lt, lt + 1) == "</" then
      local close = s:find(">", lt + 2, true) or n
      if #stack > 1 then
        table.remove(stack)
      end
      pos = close + 1
    else
      local close = lt + 1
      local quote
      while close <= n do
        local c = s:sub(close, close)
        if quote then
          if c == quote then
            quote = nil
          end
        elseif c == '"' or c == "'" then
          quote = c
        elseif c == ">" then
          break
        end
        close = close + 1
      end
      local body = s:sub(lt + 1, close - 1)
      local selfclose = body:sub(-1) == "/"
      if selfclose then
        body = body:sub(1, -2)
      end
      local tag, rest = body:match("^([^%s/>]+)(.*)$")
      local el = { tag = tag, attrs = parse_attrs(rest or "") }
      local node = top()
      node[#node + 1] = el
      if not selfclose then
        stack[#stack + 1] = el
      end
      pos = close + 1
    end
  end
  for _, c in ipairs(root) do
    if type(c) == "table" and c.tag ~= "comment" then
      return c
    end
  end
  return root
end

--- citeproc-lib-remove-xml-comments
function X.remove_comments(tree)
  local out = { tag = tree.tag, attrs = tree.attrs }
  for _, c in ipairs(tree) do
    if type(c) == "string" then
      out[#out + 1] = c
    elseif c.tag ~= "comment" then
      out[#out + 1] = X.remove_comments(c)
    end
  end
  return out
end

--- Element children of `el` (strings removed).
function X.elements(el)
  local out = {}
  for _, c in ipairs(el) do
    if type(c) == "table" then
      out[#out + 1] = c
    end
  end
  return out
end

---------------------------------------------------------------------------
-- HTML fragments (libxml-parse-html-region on inline markup)
---------------------------------------------------------------------------

local VOID = { br = true, img = true, hr = true, input = true, meta = true, link = true, wbr = true }

--- Parse an HTML fragment; returns the list of body children (the
--- implicit <p> around inline content removed like citeproc does).
function X.parse_html_fragment(s)
  local root = { tag = "p", attrs = {} }
  local stack = { root }
  local pos, n = 1, #s
  local function add_text(text)
    if text == "" then
      return
    end
    local node = stack[#stack]
    text = decode_entities(text, true)
    if type(node[#node]) == "string" then
      node[#node] = node[#node] .. text
    else
      node[#node + 1] = text
    end
  end
  while pos <= n do
    local lt = s:find("<", pos, true)
    if not lt then
      add_text(s:sub(pos))
      break
    end
    local tagm = s:match("^</?[%a][^>]*>", lt)
    if not tagm then
      add_text(s:sub(pos, lt))
      pos = lt + 1
    else
      if lt > pos then
        add_text(s:sub(pos, lt - 1))
      end
      if tagm:sub(2, 2) == "/" then
        local name = tagm:match("^</%s*([%w]+)"):lower()
        -- close the innermost open element of that name
        for k = #stack, 2, -1 do
          if stack[k].tag == name then
            for _ = k, #stack do
              table.remove(stack)
            end
            break
          end
        end
      else
        local name, rest = tagm:match("^<([%w]+)(.-)/?>$")
        name = name:lower()
        local el = { tag = name, attrs = parse_attrs(rest or "", true) }
        local node = stack[#stack]
        node[#node + 1] = el
        if not VOID[name] and tagm:sub(-2) ~= "/>" then
          stack[#stack + 1] = el
        end
      end
      pos = lt + #tagm
    end
  end
  local out = {}
  for _, c in ipairs(root) do
    out[#out + 1] = c
  end
  return out
end

return X
