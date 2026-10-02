---@mod org.feed RSS and Atom feeds (org-feed)
---
--- Port of org-feed.el. Each feed in `feed.feeds` (org-feed-alist) is read
--- and its new items are added as children of an inbox headline in a target
--- file. The feed's GUIDs and a SHA-1 of each item are kept in a drawer
--- (`:FEEDSTATUS:`) under the inbox, in the same Lisp form Emacs writes, so
--- an item is added only once and changed items can be detected; files can
--- be updated from Emacs and Neovim alike.
---
--- A feed is a table:
---   { name = "Slashdot", url = "https://rss.slashdot.org/Slashdot/slashdot",
---     file = "~/org/feeds.org", headline = "Slashdot Entries", ...options }
--- or the positional Emacs form { "Slashdot", url, file, headline, ...options }.
--- Options: template, filter, formatter, new_handler, changed_handler,
--- parse_feed, parse_entry, drawer, retrieve_method (see |org-feed|).

local config = require("org.config")
local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- XML
---------------------------------------------------------------------------

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

--- UTF-8 encoding of a code point.
local function utf8_char(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  elseif n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  elseif n < 0x110000 then
    return string.char(
      0xF0 + math.floor(n / 0x40000),
      0x80 + math.floor(n / 0x1000) % 0x40,
      0x80 + math.floor(n / 0x40) % 0x40,
      0x80 + n % 0x40
    )
  end
end

--- Replace the five XML entities and character references
--- (xml-substitute-special); unknown entities are left alone.
---@param s string
---@return string
function M.decode_entities(s)
  return (
    s:gsub("&(#?[%w]+);", function(ref)
      local n
      if ref:match("^#[xX]%x+$") then
        n = tonumber(ref:sub(3), 16)
      elseif ref:match("^#%d+$") then
        n = tonumber(ref:sub(2))
      else
        return ENTITIES[ref]
      end
      return n and utf8_char(n)
    end)
  )
end

--- Text of an XML fragment: entities decoded and `<![CDATA[...]]>`
--- sections unwrapped (Emacs keeps CDATA markers in RSS fields).
---@param s string
---@return string
function M.decode(s)
  local out, i = {}, 1
  while true do
    local cs, ce = s:find("<![CDATA[", i, true)
    out[#out + 1] = M.decode_entities(s:sub(i, cs and cs - 1 or #s))
    if not cs then
      break
    end
    local close = s:find("]]>", ce + 1, true)
    out[#out + 1] = s:sub(ce + 1, close and close - 1 or #s)
    if not close then
      break
    end
    i = close + 3
  end
  return table.concat(out)
end

---@class org.feed.XmlNode
---@field tag string
---@field attrs table<string, string>
---@field attr_order string[] attribute names in document order
---@field children (org.feed.XmlNode|string)[]
---@field s integer byte offset of `<tag`
---@field e? integer byte offset of the last `>` of the element

--- Append text to `node`, merged with a preceding text child unless `new`
--- (xml.el starts a new string at a CDATA section).
local function add_text(node, text, new)
  if text == "" then
    return
  end
  local last = node.children[#node.children]
  if type(last) == "string" and not new then
    node.children[#node.children] = last .. text
  else
    node.children[#node.children + 1] = text
  end
end

--- Parse XML leniently into a tree of `{ tag, attrs, children }` nodes
--- (strings for text, entities decoded, CDATA kept as text). Comments,
--- processing instructions and DOCTYPE are skipped; unclosed elements are
--- closed at the end, stray end tags are ignored.
---@param text string
---@return org.feed.XmlNode document node, its children are the top-level elements
function M.parse_xml(text)
  local doc = { tag = "#document", attrs = {}, attr_order = {}, children = {}, s = 1 }
  local stack = { doc }
  local i, n = 1, #text
  while i <= n do
    local cur = stack[#stack]
    local lt = text:find("<", i, true)
    if not lt then
      add_text(cur, M.decode_entities(text:sub(i)))
      break
    end
    add_text(cur, M.decode_entities(text:sub(i, lt - 1)))
    if text:sub(lt, lt + 3) == "<!--" then
      local e = text:find("-->", lt + 4, true)
      i = e and e + 3 or n + 1
    elseif text:sub(lt, lt + 8) == "<![CDATA[" then
      local e = text:find("]]>", lt + 9, true)
      add_text(cur, text:sub(lt + 9, e and e - 1 or n), true)
      i = e and e + 3 or n + 1
    elseif text:sub(lt + 1, lt + 1) == "?" then
      local e = text:find("?>", lt + 2, true)
      i = e and e + 2 or n + 1
    elseif text:sub(lt + 1, lt + 1) == "!" then
      -- <!DOCTYPE ...> with an optional [internal subset]
      local j, depth = lt + 2, 0
      while j <= n do
        local c = text:sub(j, j)
        if c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
        elseif c == ">" and depth <= 0 then
          break
        end
        j = j + 1
      end
      i = j + 1
    elseif text:sub(lt + 1, lt + 1) == "/" then
      local name, e = text:match("^</%s*([^%s>]+)%s*>()", lt)
      if not name then
        add_text(cur, "<")
        i = lt + 1
      else
        for k = #stack, 2, -1 do
          if stack[k].tag == name then
            stack[k].e = e - 1
            for _ = #stack, k, -1 do
              table.remove(stack)
            end
            break
          end
        end
        i = e
      end
    else
      local name, j = text:match("^<([%a_:][%w_:%.%-]*)()", lt)
      if not name then
        add_text(cur, "<")
        i = lt + 1
      else
        local node = { tag = name, attrs = {}, attr_order = {}, children = {}, s = lt }
        local closed = false
        while true do
          j = text:match("^%s*()", j)
          if j > n then
            break
          elseif text:sub(j, j) == ">" then
            j = j + 1
            break
          elseif text:sub(j, j + 1) == "/>" then
            j, closed = j + 2, true
            break
          end
          local attr, after = text:match("^([^%s=/>]+)()", j)
          if not attr then
            j = j + 1
          else
            local value = ""
            local eq = text:match("^%s*=%s*()", after)
            if eq then
              local q = text:sub(eq, eq)
              if q == '"' or q == "'" then
                local close = text:find(q, eq + 1, true) or n + 1
                value, after = text:sub(eq + 1, close - 1), close + 1
              else
                local v, a2 = text:match("^([^%s>]*)()", eq)
                value, after = v, a2
              end
            end
            if node.attrs[attr] == nil then
              node.attr_order[#node.attr_order + 1] = attr
            end
            node.attrs[attr] = M.decode_entities(value)
            j = after
          end
        end
        cur.children[#cur.children + 1] = node
        if closed then
          node.e = j - 1
        else
          stack[#stack + 1] = node
        end
        i = j
      end
    end
  end
  return doc
end

--- Local name of a tag (without a namespace prefix).
local function local_name(tag)
  return tag:match("[^:]*$")
end

--- Child elements of `node` named `tag` (namespace prefixes ignored).
---@param node org.feed.XmlNode
---@param tag string
---@return org.feed.XmlNode[]
function M.xml_children(node, tag)
  local out = {}
  for _, c in ipairs(node and node.children or {}) do
    if type(c) == "table" and local_name(c.tag) == tag then
      out[#out + 1] = c
    end
  end
  return out
end

--- Concatenated text of a node and its descendants.
---@param node org.feed.XmlNode|string|nil
---@return string
function M.xml_text(node)
  if not node then
    return ""
  elseif type(node) == "string" then
    return node
  end
  local out = {}
  for _, c in ipairs(node.children) do
    out[#out + 1] = M.xml_text(c)
  end
  return table.concat(out)
end

local function escape_xml(s, attr)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  if attr then
    s = s:gsub('"', "&quot;")
  end
  return s
end

--- Serialize nodes back to XML markup.
---@param nodes (org.feed.XmlNode|string)[]
---@return string
function M.xml_serialize(nodes)
  local out = {}
  for _, c in ipairs(nodes) do
    if type(c) == "string" then
      out[#out + 1] = escape_xml(c)
    else
      local attrs = {}
      for _, k in ipairs(c.attr_order) do
        attrs[#attrs + 1] = (' %s="%s"'):format(k, escape_xml(c.attrs[k], true))
      end
      local open = "<" .. c.tag .. table.concat(attrs)
      if #c.children == 0 then
        out[#out + 1] = open .. "/>"
      else
        out[#out + 1] = open .. ">" .. M.xml_serialize(c.children) .. "</" .. c.tag .. ">"
      end
    end
  end
  return table.concat(out)
end

local function lisp_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The printed Lisp form of a node as parsed by xml.el
--- (`(tag ((attr . "value")...) children...)`): what Emacs hashes to
--- detect changed Atom entries.
---@param node org.feed.XmlNode|string
---@return string
function M.xml_lisp_form(node)
  if type(node) == "string" then
    return lisp_string(node)
  end
  local parts = { node.tag }
  if #node.attr_order == 0 then
    parts[2] = "nil"
  else
    local attrs = {}
    for _, k in ipairs(node.attr_order) do
      attrs[#attrs + 1] = ("(%s . %s)"):format(k, lisp_string(node.attrs[k]))
    end
    parts[2] = "(" .. table.concat(attrs, " ") .. ")"
  end
  for _, c in ipairs(node.children) do
    parts[#parts + 1] = M.xml_lisp_form(c)
  end
  return "(" .. table.concat(parts, " ") .. ")"
end

---------------------------------------------------------------------------
-- Feed parsing
---------------------------------------------------------------------------

---@class org.feed.Entry
---@field guid? string
---@field item_full_text string raw text of the item (hashed to detect changes)
---@field guid_permalink? boolean the guid is a permalink (RSS)
---@field handled? boolean the item was handled before (set by update)
---@field [string] any fields of the item: title, link, description, pubDate, ...

--- Find `<name\>...>` (the opening tag on one line) from `pos` in `lower`
--- (the lower-cased text), like the `<item\\>.*?>` search of org-feed.
local function find_open(lower, name, pos)
  while true do
    local s, e = lower:find("<" .. name .. "%f[^%w]", pos)
    if not s then
      return nil
    end
    local gt = lower:find(">", e + 1, true)
    local nl = lower:find("\n", e + 1, true)
    if gt and not (nl and nl < gt) then
      return s, gt
    end
    pos = e + 1
  end
end

--- Split an RSS feed into items (org-feed-parse-rss-feed): each entry has
--- the `guid` and the text between `<item>` and `</item>` as
--- `item_full_text`, whose SHA-1 is the one Emacs stores.
---@param text string
---@return org.feed.Entry[]
function M.parse_rss_feed(text)
  local lower = text:lower()
  local entries, pos = {}, 1
  while true do
    local _, gt = find_open(lower, "item", pos)
    if not gt then
      break
    end
    local close = lower:find("</item>", gt + 1, true)
    if not close then
      break
    end
    local item = text:sub(gt + 1, close - 1)
    local guid
    local ilower = item:lower()
    local _, ggt = find_open(ilower, "guid", 1)
    if ggt then
      local gclose = ilower:find("</guid>", ggt + 1, true)
      if gclose then
        guid = M.decode(item:sub(ggt + 1, gclose - 1))
      end
    end
    entries[#entries + 1] = { guid = guid, item_full_text = item }
    pos = close
  end
  return entries
end

--- Add the fields of an RSS item (org-feed-parse-rss-entry): every
--- `<tag>value</tag>` becomes `entry[tag]` (case as written, entities
--- decoded, CDATA unwrapped), and `guid_permalink` is set unless the guid
--- has `isPermaLink="false"`.
---@param entry org.feed.Entry
---@return org.feed.Entry
function M.parse_rss_entry(entry)
  local text = entry.item_full_text or ""
  local lower = text:lower()
  local pos = 1
  while true do
    local s, name = text:match("()<(%a+)", pos)
    if not s then
      break
    end
    local after = s + 1 + #name
    local gt = text:find(">", after, true)
    local nl = text:find("\n", after, true)
    local close
    if not text:sub(after, after):match("%w") and gt and not (nl and nl < gt) then
      close = lower:find("</" .. name:lower() .. ">", gt + 1, true)
    end
    if close then
      entry[name] = M.decode(text:sub(gt + 1, close - 1))
      pos = close + #name + 3
    else
      pos = s + 1
    end
  end
  if not lower:find('ispermalink[ \t]*=[ \t]*"false"') then
    entry.guid_permalink = true
  end
  return entry
end

--- The root element of a parsed document.
local function root_element(doc)
  for _, c in ipairs(doc.children) do
    if type(c) == "table" then
      return c
    end
  end
end

--- Split an Atom feed into entries (org-feed-parse-atom-feed): `guid` is
--- the entry's `<id>`, `item_full_text` the printed Lisp form Emacs
--- hashes and `xml` the parsed entry.
---@param text string
---@return org.feed.Entry[]
function M.parse_atom_feed(text)
  local feed = root_element(M.parse_xml(text))
  local entries = {}
  for _, e in ipairs(M.xml_children(feed, "entry")) do
    local id = M.xml_children(e, "id")[1]
    entries[#entries + 1] = {
      guid = id and M.xml_text(id) or nil,
      item_full_text = M.xml_lisp_form(e),
      xml = e,
    }
  end
  return entries
end

--- Add the fields of an Atom entry (org-feed-parse-atom-entry): `link`
--- (the first `<link href>`), `title` and `description` (from `<content>`:
--- text and html as text, xhtml as markup; `<summary>` when there is no
--- content), plus the `id`, `updated`, `published` and `summary` texts.
---@param entry org.feed.Entry
---@return org.feed.Entry
function M.parse_atom_entry(entry)
  local xml = entry.xml or root_element(M.parse_xml(entry.item_full_text or ""))
  if not xml then
    return entry
  end
  local link = M.xml_children(xml, "link")[1]
  entry.link = link and link.attrs.href or nil
  local title = M.xml_children(xml, "title")[1]
  entry.title = title and M.xml_text(title) or nil
  for _, field in ipairs({ "id", "updated", "published", "summary" }) do
    local node = M.xml_children(xml, field)[1]
    if node and entry[field] == nil then
      entry[field] = vim.trim(M.xml_text(node))
    end
  end
  local content = M.xml_children(xml, "content")[1] or M.xml_children(xml, "summary")[1]
  if content then
    local ctype = content.attrs.type
    if ctype == nil or ctype == "text" or ctype == "html" then
      entry.description = M.xml_text(content)
    elseif ctype == "xhtml" then
      entry.description = M.xml_serialize(content.children)
    else
      entry.description = ("Unknown `%s' content."):format(ctype)
    end
  end
  return entry
end

--- Whether a feed text looks like Atom (a `<feed>` root, no RSS items).
local function is_atom(text)
  local lower = text:lower()
  return lower:find("<feed[%s>]") ~= nil and not find_open(lower, "item", 1)
end

---------------------------------------------------------------------------
-- The status drawer (a Lisp list, as Emacs writes it)
---------------------------------------------------------------------------

--- Read Lisp data: lists, strings, symbols (`t`, `nil`) and numbers.
---@param s string
---@return any value, string? err
function M.read_lisp(s)
  local i, n = 1, #s
  local function skip()
    while i <= n do
      local c = s:sub(i, i)
      if c:match("%s") then
        i = i + 1
      elseif c == ";" then
        i = (s:find("\n", i, true) or n) + 1
      else
        break
      end
    end
  end
  local read
  read = function()
    skip()
    local c = s:sub(i, i)
    if c == "" then
      error("end of input", 0)
    elseif c == "(" then
      i = i + 1
      local list = { n = 0 }
      while true do
        skip()
        local d = s:sub(i, i)
        if d == ")" then
          i = i + 1
          return list
        elseif d == "" then
          error("unbalanced parentheses", 0)
        end
        list.n = list.n + 1
        list[list.n] = read()
      end
    elseif c == '"' then
      local out = {}
      i = i + 1
      while true do
        local d = s:sub(i, i)
        if d == "" then
          error("unterminated string", 0)
        elseif d == "\\" then
          local nxt = s:sub(i + 1, i + 1)
          out[#out + 1] = ({ n = "\n", t = "\t", ["\n"] = "" })[nxt] or nxt
          i = i + 2
        elseif d == '"' then
          i = i + 1
          return table.concat(out)
        else
          out[#out + 1] = d
          i = i + 1
        end
      end
    else
      local atom = s:match("^[^%s()\"';]+", i)
      if not atom then
        error("unexpected " .. c, 0)
      end
      i = i + #atom
      if atom == "nil" then
        return vim.NIL
      elseif atom == "t" then
        return true
      end
      return tonumber(atom) or atom
    end
  end
  local ok, value = pcall(read)
  if not ok then
    return nil, value
  end
  return value
end

---@class org.feed.Status
---@field guid? string
---@field handled boolean
---@field hash? string

--- Status entries as the Lisp list Emacs writes with `pp`, one per line.
---@param status org.feed.Status[]
---@return string[]
function M.format_status(status)
  if #status == 0 then
    return { "nil" }
  end
  local lines = {}
  for k, st in ipairs(status) do
    local item = ("(%s %s %s)"):format(
      st.guid and lisp_string(st.guid) or "nil",
      st.handled and "t" or "nil",
      st.hash and lisp_string(st.hash) or "nil"
    )
    lines[k] = (k == 1 and "(" or " ") .. item .. (k == #status and ")" or "")
  end
  return lines
end

--- Parse the status drawer text into entries.
---@param text string
---@return org.feed.Status[]|nil, string? err
function M.parse_status(text)
  local value, err = M.read_lisp(text)
  if value == nil then
    return nil, err
  end
  local out = {}
  if value == vim.NIL then
    return out
  elseif type(value) ~= "table" then
    return nil, "not a list"
  end
  for k = 1, value.n do
    local e = value[k]
    if type(e) == "table" then
      out[#out + 1] = {
        guid = type(e[1]) == "string" and e[1] or nil,
        handled = e[2] ~= nil and e[2] ~= vim.NIL and e[2] ~= false,
        hash = type(e[3]) == "string" and e[3] or nil,
      }
    end
  end
  return out
end

---------------------------------------------------------------------------
-- The inbox
---------------------------------------------------------------------------

local function heading_level(line)
  local stars = line:match("^(%*+)[ \t]")
  return stars and #stars or (line:match("^%*+$") and #line) or nil
end

--- Line after the inbox subtree (0-based end, exclusive): the next heading
--- of the same or a higher level, or the line count.
local function subtree_end(lines, lnum)
  local level = heading_level(lines[lnum])
  for k = lnum + 1, #lines do
    local l = heading_level(lines[k])
    if l and l <= level then
      return k - 1
    end
  end
  return #lines
end

--- First heading after `lnum` (1-based) or nil.
local function next_heading(lines, lnum)
  for k = lnum + 1, #lines do
    if heading_level(lines[k]) then
      return k
    end
  end
end

--- Line of the headline `heading` in the buffer (any level, optional
--- tags), creating it at the end of the buffer when missing
--- (org-feed-goto-inbox-internal).
---@param bufnr integer
---@param heading string
---@return integer lnum
function M.find_or_create_inbox(bufnr, heading)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pat = "^%*+[ \t]+" .. vim.pesc(heading) .. "[ \t]*$"
  local tagged = "^%*+[ \t]+" .. vim.pesc(heading) .. "[ \t]*:.*:[ \t]*$"
  for k, l in ipairs(lines) do
    if l:match(pat) or l:match(tagged) then
      return k
    end
  end
  -- Emacs inserts "\n\n* HEADING\n\n" at the end of the buffer
  local new = { "", "", "* " .. heading, "" }
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new)
    return 3
  end
  vim.api.nvim_buf_set_lines(bufnr, #lines, #lines, false, new)
  return #lines + 3
end

--- The status drawer of the inbox at `lnum`: the drawer line and its
--- `:END:` line, or nil. Errors when the drawer has no `:END:` inside the
--- inbox subtree, so that rewriting it never deletes the text after it.
local function find_drawer(lines, lnum, drawer)
  local stop = subtree_end(lines, lnum)
  local pat = "^[ \t]*:" .. vim.pesc(drawer) .. ":[ \t]*$"
  for k = lnum + 1, stop do
    if lines[k]:match(pat) then
      for j = k + 1, stop do
        if lines[j]:match("^[ \t]*:END:") then
          return k, j
        end
      end
      error(("Unterminated :%s: drawer under %s"):format(drawer, lines[lnum]), 0)
    end
  end
end

--- Read the status stored in the inbox drawer (org-feed-read-previous-status).
---@return org.feed.Status[]
function M.read_status(bufnr, lnum, drawer)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = find_drawer(lines, lnum, drawer)
  if not s then
    return {}
  end
  local text = table.concat(vim.list_slice(lines, s + 1, e - 1), "\n")
  local status, err = M.parse_status(text)
  if not status then
    error(("Invalid :%s: drawer: %s"):format(drawer, err), 0)
  end
  return status
end

--- Write the status into the inbox drawer, creating the drawer before the
--- first heading after the inbox (org-feed-write-status).
function M.write_status(bufnr, lnum, drawer, status)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local body = M.format_status(status)
  local s, e = find_drawer(lines, lnum, drawer)
  if s then
    vim.api.nvim_buf_set_lines(bufnr, s, e - 1, false, body)
    return
  end
  local at = (next_heading(lines, lnum) or #lines + 1) - 1
  local block = { "  :" .. drawer .. ":" }
  vim.list_extend(block, body)
  block[#block + 1] = "  :END:"
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
end

--- Insert formatted entries at the end of the inbox subtree, their top
--- headings one level below the inbox (org-feed-add-items, pasting like
--- org-paste-subtree).
---@param bufnr integer
---@param lnum integer inbox headline
---@param texts string[] formatted entries
function M.add_items(bufnr, lnum, texts)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local level = heading_level(lines[lnum])
  if not level then
    error("Wrong position", 0)
  end
  local new_level = level + require("org.structure").level_increment(bufnr)
  local at = subtree_end(lines, lnum)
  for _, text in ipairs(texts) do
    local item = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
    local old
    for _, l in ipairs(item) do
      old = heading_level(l)
      if old or not l:match("^[ \t\r]*$") then
        break
      end
    end
    local shift = old and new_level - old or 0
    if shift ~= 0 then
      for k, l in ipairs(item) do
        local stars = l:match("^(%*+)[ \t]") or (l:match("^%*+$") and l)
        if stars then
          item[k] = ("*"):rep(math.max(1, #stars + shift)) .. l:sub(#stars + 1)
        end
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, item)
    at = at + #item
  end
end

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------

--- Date of an entry from its `pubDate` (RFC 822 or ISO 8601; the time
--- zone is ignored like Emacs's org-read-date), else now. A date without
--- a time gets the current time.
---@param entry org.feed.Entry
---@return table date
function M.entry_date(entry)
  local date = require("org.date")
  local now = date.now()
  local s = type(entry.pubDate) == "string" and entry.pubDate or nil
  if not s then
    return now
  end
  local y, mo, d, rest = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)")
  if y then
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  else
    local dd, mon, yy, r = s:match("(%d%d?)%s+(%a%a%a)%a*%.?%s+(%d%d%d?%d?)(.*)")
    local months = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6 }
    months = vim.tbl_extend("force", months, { jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 })
    if dd and months[mon:lower()] then
      y, mo, d, rest = tonumber(yy), months[mon:lower()], tonumber(dd), r
      if y < 100 then
        y = date.small_year_to_year(y)
      end
    end
  end
  local result
  if y then
    local h, mi = (rest or ""):match("^[Tt%s]+(%d%d?):(%d%d)")
    result = date.Date.new({ year = y, month = mo, day = d, hour = tonumber(h), min = tonumber(mi) })
  else
    result = date.read_date(s, now)
  end
  if not result then
    return now
  end
  if not result.hour then
    result = result:clone({ hour = now.hour, min = now.min })
  end
  return result
end

--- Position of the `)` closing the `(` at `p`, skipping strings.
local function balanced_paren(s, p)
  local depth, quote, k = 0, nil, p
  while k <= #s do
    local ch = s:sub(k, k)
    if quote then
      if ch == "\\" then
        k = k + 1
      elseif ch == quote then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then
        return k
      end
    end
    k = k + 1
  end
end

--- Indent the lines after the first of `s` by `n` spaces
--- (org-feed-make-indented-block).
local function indented_block(s, n)
  if not s:find("\n", 1, true) then
    return s
  end
  local parts = {}
  for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
    if l ~= "" then
      parts[#parts + 1] = l
    end
  end
  return table.concat(parts, "\n" .. (" "):rep(n))
end

--- Expand the `%name` escapes of `text`; `lookup(name)` gives the value
--- or nil (the escape is then dropped) and whether it is an item field,
--- indented when alone on its line. `\%` keeps a literal `%`.
local function expand_simple(text, lookup, in_expr)
  local out, i = {}, 1
  while true do
    local p, e, name = text:find("%%(%a+)", i)
    if not p then
      out[#out + 1] = text:sub(i)
      break
    end
    local bs = #(text:sub(i, p - 1):match("\\*$"))
    if bs % 2 == 1 then
      out[#out + 1] = text:sub(i, p - 2) .. text:sub(p, e)
    else
      out[#out + 1] = text:sub(i, p - 1)
      local v, field = lookup(name)
      if v ~= nil then
        v = tostring(v)
        if in_expr then
          v = v:gsub('"', '\\"')
        else
          -- a field alone on its line: indent its continuation lines
          local bol = (text:sub(1, p - 1):match(".*\n()") or 1)
          local line = text:sub(bol, (text:find("\n", e + 1, true) or #text + 1) - 1)
          local indent = line:match("^([ \t]*)%%" .. name .. "[ \t]*$")
          if indent and field then
            v = indented_block(v, vim.fn.strdisplaywidth(indent))
          end
        end
        out[#out + 1] = v
      end
    end
    i = e + 1
  end
  return table.concat(out)
end

--- Format an entry as Org text (org-feed-format-entry), with `formatter`
--- or `template` (default `feed.default_template`). Escapes: `%h` title
--- (or the first line of the description), `%t`/`%T` active date (and
--- time) from `pubDate` or now, `%u`/`%U` inactive, `%a` link from the
--- guid when it is a permalink, else `link`, `%name` any field of the item
--- (`%title`, `%description`, `%pubDate`, ...), and `%(expr)` a Lua
--- expression (the entry is `entry`).
---@param entry org.feed.Entry
---@param template? string
---@param formatter? fun(entry: org.feed.Entry): string
---@return string
function M.format_entry(entry, template, formatter)
  if formatter then
    return formatter(entry)
  end
  template = template or config.opts.feed.default_template
  local dline
  for _, l in ipairs(vim.split(entry.description or "???", "\n", { plain = true })) do
    if l ~= "" then
      dline = l
      break
    end
  end
  local time = M.entry_date(entry)
  local function stamp(with_time, active)
    local d = time:clone({ active = active })
    if not with_time then
      d = d:clone({ hour = vim.NIL, min = vim.NIL })
    end
    return d:to_string()
  end
  local link = (entry.guid_permalink and entry.guid) or entry.link
  local special = {
    h = entry.title or dline or "???",
    t = stamp(false, true),
    T = stamp(true, true),
    u = stamp(false, false),
    U = stamp(true, false),
    a = link and ("[[%s]]\n"):format(link) or "",
  }
  local function lookup(name)
    if special[name] then
      return special[name]
    end
    local v = entry[name]
    if type(v) == "string" or type(v) == "number" then
      return v, true
    end
  end
  local exprs = {}
  local marked, i = {}, 1
  while true do
    local p = template:find("%(", i, true)
    local close = p and balanced_paren(template, p + 1)
    if not close then
      marked[#marked + 1] = template:sub(i)
      break
    end
    marked[#marked + 1] = template:sub(i, p - 1)
    exprs[#exprs + 1] = template:sub(p + 2, close - 1)
    marked[#marked + 1] = "\31" .. #exprs .. "\31"
    i = close + 1
  end
  local text = expand_simple(table.concat(marked), lookup)
  text = text:gsub("\31(%d+)\31", function(idx)
    local expr = expand_simple(exprs[tonumber(idx)], lookup, true)
    local chunk, err = loadstring("return " .. expr)
    local ok, res = false, err
    if chunk then
      setfenv(chunk, setmetatable({ entry = entry }, { __index = _G }))
      ok, res = pcall(chunk)
    end
    if not ok then
      utils.warn("Feed template %(" .. expr .. "): " .. tostring(res))
      return ""
    end
    return res == nil and "" or tostring(res)
  end)
  return text
end

---------------------------------------------------------------------------
-- Retrieval
---------------------------------------------------------------------------

--- Get the text at `url` (org-feed-get-feed). `file://` URLs and local
--- paths are read directly; other URLs use `method`: "curl", "wget" or a
--- function(url) returning the text.
---@param url string
---@param method? "curl"|"wget"|fun(url: string): string?
---@return string|nil text, string? err
function M.get_feed(url, method)
  method = method or config.opts.feed.retrieve_method
  if type(method) == "function" then
    local ok, text = pcall(method, url)
    if not ok then
      return nil, tostring(text)
    end
    return text
  end
  local path = url:match("^file://(.*)$")
  if path or not url:match("^%a[%w+.-]*://") then
    path = utils.expand(vim.uri_decode(path or url))
    local fd = io.open(path, "rb")
    if not fd then
      return nil, "cannot read " .. path
    end
    local text = fd:read("*a")
    fd:close()
    return text
  end
  local cmd
  if method == "wget" then
    cmd = { "wget", "-q", "-O", "-", url }
  else
    cmd = { "curl", "--silent", "--location", url }
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil, cmd[1] .. " is not installed"
  end
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok then
    return nil, tostring(res)
  elseif res.code ~= 0 then
    return nil, ("%s exited with %d"):format(cmd[1], res.code)
  end
  return res.stdout
end

---------------------------------------------------------------------------
-- Feeds
---------------------------------------------------------------------------

---@class org.feed.Feed
---@field name string
---@field url string
---@field file? string
---@field headline string
---@field template? string
---@field filter? fun(entry: org.feed.Entry): org.feed.Entry?
---@field formatter? fun(entry: org.feed.Entry): string
---@field new_handler? fun(entries: org.feed.Entry[], ctx: table)
---@field changed_handler? fun(entries: org.feed.Entry[], ctx: table)
---@field parse_feed? "rss"|"atom"|fun(text: string): org.feed.Entry[]
---@field parse_entry? "rss"|"atom"|fun(entry: org.feed.Entry): org.feed.Entry
---@field drawer? string
---@field retrieve_method? "curl"|"wget"|fun(url: string): string?

--- Feed `f` with the positional Emacs form resolved.
local function normalize(f)
  return vim.tbl_extend("force", f, {
    name = f.name or f[1],
    url = f.url or f[2],
    file = f.file or f[3],
    headline = f.headline or f[4],
  })
end

--- Configured feeds, normalized.
---@return org.feed.Feed[]
function M.feeds()
  local out = {}
  for _, f in ipairs(config.opts.feed.feeds or {}) do
    out[#out + 1] = normalize(f)
  end
  return out
end

--- Names of the configured feeds.
---@return string[]
function M.names()
  return vim.tbl_map(function(f)
    return f.name
  end, M.feeds())
end

---@param feed string|org.feed.Feed
---@return org.feed.Feed
local function resolve(feed)
  if type(feed) == "table" then
    return normalize(feed)
  end
  for _, f in ipairs(M.feeds()) do
    if f.name == feed then
      return f
    end
  end
  error("No such feed in feed.feeds: " .. tostring(feed), 0)
end

--- A feed with its url and headline checked.
local function checked(feed)
  feed = resolve(feed)
  if not feed.url or not feed.headline then
    error(("Feed %s needs a url and a headline"):format(tostring(feed.name)), 0)
  end
  return feed
end

local PARSERS = {
  rss = { M.parse_rss_feed, M.parse_rss_entry },
  atom = { M.parse_atom_feed, M.parse_atom_entry },
}

--- The target file of a feed: its `file`, else the current buffer's file.
local function target_file(feed)
  if feed.file then
    return utils.expand(feed.file)
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    error(("Feed %s has no file and the current buffer has none"):format(feed.name), 0)
  end
  return name
end

local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
end

--- Call a handler with the cursor on the inbox headline of `bufnr`.
local function call_handler(fn, entries, bufnr, lnum, feed)
  vim.api.nvim_buf_call(bufnr, function()
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    fn(entries, { bufnr = bufnr, lnum = lnum, feed = feed })
  end)
end

--- Get new items from a feed into its inbox (org-feed-update). Returns the
--- number of new items. With `retrieve_only`, return the feed text.
---@param feed string|org.feed.Feed a name in `feed.feeds`, or a feed
---@param retrieve_only? boolean
---@return integer|string
function M.update(feed, retrieve_only)
  feed = checked(feed)
  local opts = config.opts.feed
  local name = feed.name
  local text, err = M.get_feed(feed.url, feed.retrieve_method or opts.retrieve_method)
  if not text then
    error(("Cannot get feed %s%s"):format(name, err and (": " .. err) or ""), 0)
  end
  if retrieve_only then
    return text
  end
  local default = PARSERS[(feed.parse_feed == nil and is_atom(text)) and "atom" or "rss"]
  local parse_feed, parse_entry = feed.parse_feed, feed.parse_entry
  if type(parse_feed) == "string" then
    parse_feed = (PARSERS[parse_feed] or error("Unknown parse_feed: " .. parse_feed, 0))[1]
    default = PARSERS[feed.parse_feed]
  end
  if type(parse_entry) == "string" then
    parse_entry = (PARSERS[parse_entry] or error("Unknown parse_entry: " .. parse_entry, 0))[2]
  end
  parse_feed, parse_entry = parse_feed or default[1], parse_entry or default[2]
  local drawer = feed.drawer or opts.drawer
  local template = feed.template or opts.default_template
  local sha1 = require("org.babel.sha1").hex

  local entries = parse_feed(text) or {}
  local file = target_file(feed)
  local bufnr = utils.load_buffer(file)
  local inbox = M.find_or_create_inbox(bufnr, feed.headline)
  local old = M.read_status(bufnr, inbox, drawer)
  -- the first status of each guid (nil guids under a key of their own)
  local by_guid = {}
  for _, st in ipairs(old) do
    local k = st.guid == nil and vim.NIL or st.guid
    by_guid[k] = by_guid[k] or st
  end
  local function old_of(guid)
    return by_guid[guid == nil and vim.NIL or guid]
  end

  -- new: never handled; changed: handled and the hash differs
  local new, changed = {}, {}
  -- the SHA-1 of each item, computed once (it is most of the time spent)
  local hashes = {}
  for i, e in ipairs(entries) do
    hashes[i] = sha1(e.item_full_text or "")
  end
  for i, e in ipairs(entries) do
    local st = old_of(e.guid)
    e.handled = st and st.handled or false
    if not e.handled then
      table.insert(new, 1, e)
    elseif st.hash and hashes[i] ~= st.hash then
      table.insert(changed, 1, e)
    end
  end
  new = vim.tbl_map(parse_entry, new)
  changed = vim.tbl_map(parse_entry, changed)
  if feed.filter then
    local function keep(list)
      local out = {}
      for _, e in ipairs(list) do
        local r = feed.filter(e)
        if r then
          out[#out + 1] = r == true and e or r
        end
      end
      return out
    end
    new, changed = keep(new), keep(changed)
  end
  if #new == 0 and #changed == 0 then
    utils.notify("No new items in feed " .. name)
    return 0
  end

  local handled_now = {}
  for _, e in ipairs(vim.list_extend(vim.list_extend({}, new), changed)) do
    handled_now[e.guid or vim.NIL] = true
  end
  local status = {}
  for i, e in ipairs(entries) do
    status[#status + 1] = {
      guid = e.guid,
      handled = handled_now[e.guid or vim.NIL] or e.handled or false,
      hash = hashes[i],
    }
  end

  fire("OrgFeedBeforeAdding", { feed = name, file = file, bufnr = bufnr })
  if #new > 0 then
    if feed.new_handler then
      call_handler(feed.new_handler, new, bufnr, inbox, feed)
    else
      local texts = {}
      for _, e in ipairs(new) do
        texts[#texts + 1] = M.format_entry(e, template, feed.formatter)
      end
      M.add_items(bufnr, inbox, texts)
    end
  end
  if feed.changed_handler and #changed > 0 then
    call_handler(feed.changed_handler, changed, bufnr, inbox, feed)
  end
  -- written last, so a failure above leaves the old status
  M.write_status(bufnr, inbox, drawer, status)

  if opts.save_after_adding then
    utils.save_buffer_or_warn(bufnr)
  end
  utils.notify(
    ("Added %d new item%s from feed %s to file %s, heading %s"):format(
      #new,
      #new > 1 and "s" or "",
      name,
      vim.fn.fnamemodify(file, ":t"),
      feed.headline
    )
  )
  fire("OrgFeedAfterAdding", { feed = name, file = file, bufnr = bufnr, count = #new })
  return #new
end

--- Update every feed in `feed.feeds` (org-feed-update-all). Returns the
--- number of new entries and of unavailable feeds.
---@return integer entries, integer errors
function M.update_all()
  local feeds = M.feeds()
  local total, errors = 0, 0
  local notify = utils.notify
  for _, f in ipairs(feeds) do
    -- per-feed messages are replaced by the summary, like Emacs's echo area
    utils.notify = function() end
    local ok, n = pcall(M.update, f)
    utils.notify = notify
    if ok and type(n) == "number" then
      total = total + n
    else
      errors = errors + 1
    end
  end
  local what = total == 0 and "No new entries" or total == 1 and "1 new entry" or (total .. " new entries")
  utils.notify(
    ("%s from %d %s%s"):format(
      what,
      #feeds,
      #feeds == 1 and "feed" or "feeds",
      errors == 0 and "" or (" (unavailable feeds: %d)"):format(errors)
    )
  )
  return total, errors
end

--- Ask for a feed name (the only feed when `single` and there is one).
local function choose(arg, single)
  if arg and arg ~= "" then
    return arg
  end
  local names = M.names()
  if #names == 0 then
    utils.warn("No feeds configured (feed.feeds)")
    return nil
  elseif single and #names == 1 then
    return names[1]
  end
  return utils.select(names, { prompt = "Feed name" })
end

--- `:Org feed_update [name]` (org-feed-update): prompts without a name.
function M.update_command(arg)
  local name = choose(arg, false)
  if name then
    local ok, err = pcall(M.update, name)
    if not ok then
      utils.error(tostring(err))
    end
  end
end

--- Go to the inbox of a feed (org-feed-goto-inbox), creating the headline
--- when missing. Prompts for the feed unless there is only one.
function M.goto_inbox(arg)
  local name = choose(type(arg) == "string" and arg or nil, true)
  if not name then
    return
  end
  local ok, feed = pcall(checked, name)
  if not ok then
    utils.error(feed)
    return
  end
  local file = target_file(feed)
  local bufnr = utils.load_buffer(file)
  local lnum = M.find_or_create_inbox(bufnr, feed.headline)
  utils.open_file(file, lnum)
end

--- Show the raw text of a feed in a scratch buffer (org-feed-show-raw-feed).
function M.show_raw(arg)
  local name = choose(type(arg) == "string" and arg or nil, true)
  if not name then
    return
  end
  local ok, text = pcall(M.update, name, true)
  if not ok then
    utils.error(tostring(text))
    return
  end
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, "*Org feed " .. name .. "*")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true }))
  vim.bo[buf].filetype = "xml"
end

return M
