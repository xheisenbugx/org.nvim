---@mod org.export.element.elements Export parser: element parsers
---
--- Headlines, planning, drawers, sections, clocks, inline tasks,
--- keywords, blocks, footnote definitions and tables.
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local blank = shared.blank
local trim = shared.trim
local headline_stars = shared.headline_stars
local is_comment_line = shared.is_comment_line
local is_planning_line = shared.is_planning_line
local drawer_name = shared.drawer_name
local is_end_line = shared.is_end_line
local is_fixed_width = shared.is_fixed_width
local is_footnote_def = shared.is_footnote_def
local latex_env_begin = shared.latex_env_begin
local is_table_line = shared.is_table_line
local affiliated_match = shared.affiliated_match
local P = shared.P
local skip_blank = shared.skip_blank
local after = shared.after
local find_line = shared.find_line
local attach = shared.attach
local block_end = shared.block_end
local switches_props = shared.switches_props
local unescape = shared.unescape

--- Headline.
function P:headline(L, i, e)
  local level = headline_stars(L[i])
  local j = i + 1
  while j <= e do
    local n = headline_stars(L[j])
    if n and n <= level then
      break
    end
    j = j + 1
  end
  local last = j - 1
  local cb = skip_blank(L, i + 1, last)
  local node = M.node("headline", { level = level, true_level = level })
  local saved = self.current_headline
  node.props = {}
  self:headline_meta(node, L, i, j - 1)
  self.current_headline = node
  self:headline_title(node, L[i])
  if cb <= last then
    node.pre_blank = cb - i - 1
    node.post_blank = 0
    self.prev_is_headline = cb == i + 1
    local first_mode = "section"
    self.current_headline = node
    local children = {}
    local k = cb
    while k <= last do
      if headline_stars(L[k]) and headline_stars(L[k]) < self.inlinetask_min then
        local h, nxt = self:headline(L, k, last)
        h.parent = node
        children[#children + 1] = h
        k = nxt
      else
        -- section until next headline
        local sec, nxt = self:section(L, k, last, first_mode)
        sec.parent = node
        children[#children + 1] = sec
        k = nxt
      end
      first_mode = nil
    end
    M.adopt(node, children)
  else
    node.pre_blank = 0
    node.post_blank = last - i
  end
  self.current_headline = saved
  return node, j
end

--- Parse the title part of a headline line.
function P:headline_title(node, line, inlinetask)
  local rest = line:match("^%*+ +(.*)$") or ""
  rest = rest:gsub("^[ \t]+", "")
  local todo_cfg = self.opts.todo
  local word = rest:match("^(%S+)")
  if
    word
    and todo_cfg
    and todo_cfg:is_keyword(word)
    and (rest:sub(#word + 1) == "" or rest:sub(#word + 1):match("^ "))
  then
    node.todo_keyword = word
    node.todo_type = todo_cfg:is_done(word) and "done" or "todo"
    rest = rest:sub(#word + 1):gsub("^[ \t]+", "")
  end
  local prio = rest:match("^%[#([A-Z0-9]+)%]")
  if prio and (tonumber(prio) == nil or tonumber(prio) <= 64) then
    node.priority = prio
    rest = rest:gsub("^%[#[A-Z0-9]+%] ?", "")
  end
  if rest:match("^COMMENT$") or rest:match("^COMMENT ") then
    node.commentedp = true
    rest = rest:gsub("^COMMENT[ \t]*", "")
  end
  local tags = {}
  local before, tagstr = rest:match("^(.-)[ \t]+(:[%w_@#%%:\128-\255]+:)[ \t]*$")
  if not before then
    tagstr = rest:match("^(:[%w_@#%%:\128-\255]+:)[ \t]*$")
    before = tagstr and "" or nil
  end
  if tagstr then
    for t in tagstr:gmatch("[^:]+") do
      tags[#tags + 1] = t
    end
    rest = before
  end
  node.tags = tags
  node.raw_value = trim(rest)
  node.archivedp = vim.tbl_contains(tags, "ARCHIVE")
  node.title = self:parse_objects(trim(rest), M.RESTRICTIONS[inlinetask and "inlinetask" or "headline"], node)
  node.footnote_section_p = self.opts.footnote_section ~= nil and node.raw_value == self.opts.footnote_section
end

--- Planning and property drawer right after the headline line.
function P:headline_meta(node, L, i, last)
  node.props = node.props or {}
  local k = i + 1
  if k <= last and is_planning_line(L[k]) then
    local p = self:planning_values(L[k])
    node.scheduled, node.deadline, node.closed = p.scheduled, p.deadline, p.closed
    k = k + 1
  end
  if k <= last and L[k]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$") then
    local j = k + 1
    while j <= last and not is_end_line(L[j]) do
      local key, value = L[j]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
      if not key then
        break
      end
      local up = key:upper()
      local base = up:match("^(.-)%+$")
      if base and node.props[base] then
        node.props[base] = node.props[base] .. " " .. value
      else
        node.props[base or up] = value
      end
      j = j + 1
    end
  end
end

function P:planning_values(line)
  local out = {}
  for kw, pos in line:gmatch("(%u+):[ \t]*()[<%[][^>%]]+[>%]]") do
    local t = self:parse_timestamp(line, pos)
    if t then
      out[kw:lower()] = t
    end
  end
  return out
end

function P:planning(L, i, e)
  local pb, nxt = after(L, i, e)
  local p = self:planning_values(L[i])
  return M.node("planning", { post_blank = pb, scheduled = p.scheduled, deadline = p.deadline, closed = p.closed }), nxt
end

function P:property_drawer(L, i, j, e)
  local pb, nxt = after(L, j, e)
  local node = M.node("property-drawer", { post_blank = pb })
  local kids = {}
  for k = i + 1, j - 1 do
    local key, value = L[k]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
    if key then
      kids[#kids + 1] = M.node("node-property", { key = key, value = value ~= "" and value or nil })
    end
  end
  M.adopt(node, kids)
  return node, nxt
end

function P:section(L, i, e, mode)
  local j = i
  while j <= e do
    if j > i and self:is_headline(L[j]) then
      break
    end
    j = j + 1
  end
  local node = M.node("section", { post_blank = 0 })
  local child_mode = (mode == "first-section") and "top-comment" or "planning"
  if child_mode == "planning" and not self.prev_is_headline then
    child_mode = "planning"
  end
  M.adopt(node, self:parse_elements(L, i, j - 1, child_mode, node))
  return node, j
end

function P:comment(L, i, e)
  local j = i
  local vals = {}
  while j <= e and is_comment_line(L[j]) do
    vals[#vals + 1] = L[j]:match("^[ \t]*# ?(.*)$") or ""
    j = j + 1
  end
  local pb, nxt = after(L, j - 1, e)
  return M.node("comment", { post_blank = pb, value = table.concat(vals, "\n") }), nxt
end

function P:clock(L, i, e)
  local l = L[i]
  local rest = l:match("CLOCK:[ \t]*(.*)$")
  local ts = self:parse_timestamp(rest, 1)
  local duration = l:match("=>[ \t]*(%S+)[ \t]*$")
  local pb, nxt = after(L, i, e)
  return M.node(
    "clock",
    { post_blank = pb, value = ts, duration = duration, status = duration and "closed" or "running" }
  ),
    nxt
end

function P:inlinetask(L, i, e)
  local node = M.node("inlinetask", { level = headline_stars(L[i]) })
  self:headline_title(node, L[i], true)
  local task_end
  for j = i + 1, e do
    if L[j]:match("^%*+ ") then
      if L[j]:match("^%*+ [ \t]*END[ \t]*$") then
        task_end = j
      end
      break
    end
  end
  local pb, nxt
  if task_end then
    self:headline_meta(node, L, i, task_end - 1)
    local cb = skip_blank(L, i + 1, task_end - 1)
    if cb <= task_end - 1 then
      node.pre_blank = cb - i - 1
      self.prev_is_headline = cb == i + 1
      M.adopt(node, self:parse_elements(L, cb, task_end - 1, "planning", node))
    end
    pb, nxt = after(L, task_end, e)
  else
    pb, nxt = after(L, i, e)
  end
  node.post_blank = pb
  return node, nxt
end

function P:keyword(L, i, e, aff)
  local key, value = L[i]:match("^[ \t]*#%+(%S-):[ \t]*(.-)[ \t]*$")
  local pb, nxt = after(L, i, e)
  return attach(M.node("keyword", { post_blank = pb, key = (key or ""):upper(), value = value or "" }), aff), nxt
end

function P:babel_call(L, i, e, aff)
  local value = L[i]:match("^[ \t]*#%+[Cc][Aa][Ll][Ll]:[ \t]*(.-)[ \t]*$") or ""
  local call = value:match("^([^%[%]%(%)]+)")
  local pb, nxt = after(L, i, e)
  local node = attach(M.node("babel-call", { post_blank = pb, value = value, call = call and trim(call) }), aff)
  local rest = value:sub(#(call or "") + 1)
  local inside = rest:match("^%b[]")
  if inside then
    node.inside_header = inside:sub(2, -2)
    rest = rest:sub(#inside + 1)
  end
  local args = rest:match("^%b()")
  if args then
    node.arguments = args:sub(2, -2)
    rest = rest:sub(#args + 1)
  end
  node.end_header = trim(rest) ~= "" and trim(rest) or nil
  return node, nxt
end

function P:dynamic_block(L, i, e, aff)
  local j = find_line(L, i + 1, e, function(x)
    return x:match("^[ \t]*#%+[Ee][Nn][Dd]:?[ \t]*$") ~= nil
  end)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local name, args = L[i]:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:[ \t]*(%S+)[ \t]*(.-)[ \t]*$")
  local pb, nxt = after(L, j, e)
  local node =
    attach(M.node("dynamic-block", { post_blank = pb, block_name = name, arguments = args ~= "" and args or nil }), aff)
  if j > i + 1 then
    M.adopt(node, self:block_contents(L, i + 1, j - 1, node))
  end
  return node, nxt
end

function P:drawer(L, i, e, aff)
  local j = find_line(L, i + 1, e, is_end_line)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local name = drawer_name(L[i])
  local pb, nxt = after(L, j, e)
  local node = attach(M.node("drawer", { post_blank = pb, drawer_name = name }), aff)
  local cb = skip_blank(L, i + 1, j - 1)
  node.pre_blank = cb - i - 1
  if cb <= j - 1 then
    M.adopt(node, self:parse_elements(L, cb, j - 1, nil, node))
  end
  return node, nxt
end

function P:fixed_width(L, i, e, aff)
  local j = i
  local vals = {}
  while j <= e and is_fixed_width(L[j]) do
    vals[#vals + 1] = L[j]:gsub("^[ \t]*: ?", "")
    j = j + 1
  end
  local pb, nxt = after(L, j - 1, e)
  return attach(M.node("fixed-width", { post_blank = pb, value = table.concat(vals, "\n") }), aff), nxt
end

function P:latex_environment(L, i, e, aff)
  local env = latex_env_begin(L[i])
  local endp = "\\end{" .. env .. "}"
  local j = find_line(L, i, e, function(x)
    local s = x:find(endp, 1, true)
    return s ~= nil and x:sub(s + #endp):match("^[ \t]*$") ~= nil
  end)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local value = table.concat(vim.list_slice(L, i, j), "\n") .. "\n"
  return attach(M.node("latex-environment", { post_blank = pb, value = value }), aff), nxt
end

function P:footnote_definition(L, i, e, aff)
  local label, rest = L[i]:match("^%[fn:([%w%-_]+)%](.*)$")
  -- end: next headline, footnote definition, or two blank lines
  local j = i + 1
  local stop = e + 1
  while j <= e do
    local l = L[j]
    if l:match("^%*+ ") then
      stop = j
      break
    elseif is_footnote_def(l) then
      -- before any affiliated keyword above
      local k = j
      while k - 1 > i and affiliated_match(L[k - 1]) do
        k = k - 1
      end
      stop = k
      break
    elseif blank(l) and blank(L[j + 1]) and j + 1 <= e then
      stop = skip_blank(L, j, e)
      break
    end
    j = j + 1
  end
  local last = stop - 1
  -- contents end before trailing blanks
  local ce = last
  while ce >= i + 1 and blank(L[ce]) do
    ce = ce - 1
  end
  local pb = last - ce
  local node = attach(M.node("footnote-definition", { post_blank = pb, label = label, pre_blank = 0 }), aff)
  local first = rest:gsub("^[ \t]+", "")
  local body
  local not_bol = false
  if first ~= "" then
    body = { first }
    vim.list_extend(body, vim.list_slice(L, i + 1, ce))
    not_bol = true
  else
    local cb = skip_blank(L, i + 1, ce)
    if cb <= ce then
      node.pre_blank = cb - i - 1
      body = vim.list_slice(L, cb, ce)
    end
  end
  if body then
    M.adopt(node, self:parse_elements(body, 1, #body, nil, node, not_bol))
  end
  return node, stop
end

function P:raw_block(L, i, e, aff, btype, name)
  local j = block_end(L, i, e, name)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local body = vim.list_slice(L, i + 1, j - 1)
  local node = attach(M.node(btype, { post_blank = pb }), aff)
  local head = L[i]
  if btype == "src-block" then
    local rest = head:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc](.*)$") or ""
    local lang = rest:match("^ +(%S+)")
    if lang then
      rest = rest:gsub("^ +%S+", "", 1)
    end
    -- switches: -l "fmt", -i, -k, -r, -n N, +n N
    local switches = {}
    while true do
      local sw = rest:match('^( +%-l "[^"]+")')
        or rest:match("^( +%-[ikr])%f[%s%z]")
        or rest:match("^( +[%-%+]n *%d*)%f[%s%z]")
      if not sw then
        break
      end
      switches[#switches + 1] = trim(sw)
      rest = rest:sub(#sw + 1)
    end
    node.language = lang
    node.switches = #switches > 0 and table.concat(switches, " ") or nil
    local params = trim(rest)
    node.parameters = params ~= "" and params or nil
    switches_props(node.switches, node)
    node.value = table.concat(unescape(body), "\n") .. (#body > 0 and "\n" or "")
  elseif btype == "example-block" then
    local sw = head:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ee][Xx][Aa][Mm][Pp][Ll][Ee] +(.*)$")
    node.switches = sw and trim(sw) ~= "" and trim(sw) or nil
    switches_props(node.switches, node)
    node.value = table.concat(unescape(body), "\n") .. (#body > 0 and "\n" or "")
  elseif btype == "export-block" then
    local be = head:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ee][Xx][Pp][Oo][Rr][Tt][ \t]+(%S+)")
    node.back_end_type = be and be:upper() or nil
    node.value = table.concat(unescape(body), "\n") .. (#body > 0 and "\n" or "")
  else
    node.value = table.concat(body, "\n") .. (#body > 0 and "\n" or "")
  end
  return node, nxt
end

function P:verse_block(L, i, e, aff, name)
  local j = block_end(L, i, e, name)
  if not j then
    return self:paragraph(L, i, e, aff)
  end
  local pb, nxt = after(L, j, e)
  local node = attach(M.node("verse-block", { post_blank = pb }), aff)
  local body = M.remove_indentation(vim.list_slice(L, i + 1, j - 1))
  local text = table.concat(body, "\n") .. (#body > 0 and "\n" or "")
  node.contents = self:parse_objects(text, M.RESTRICTIONS["verse-block"], node)
  return node, nxt
end

function P:table(L, i, e, aff)
  local orgtype = is_table_line(L[i])
  local j = i
  if orgtype then
    while j <= e and is_table_line(L[j]) do
      j = j + 1
    end
  else
    while j <= e and L[j]:match("^[ \t]*[%+|]") do
      j = j + 1
    end
  end
  local last = j - 1
  local tblfm = {}
  while j <= e and L[j]:match("^[ \t]*#%+[Tt][Bb][Ll][Ff][Mm]: +") do
    tblfm[#tblfm + 1] = L[j]:match("^[ \t]*#%+[Tt][Bb][Ll][Ff][Mm]: +(.-)[ \t]*$")
    j = j + 1
  end
  local pb, nxt = after(L, j - 1, e)
  local node =
    attach(M.node("table", { post_blank = pb, tblfm = tblfm, table_type = orgtype and "org" or "table.el" }), aff)
  if not orgtype then
    node.value = table.concat(vim.list_slice(L, i, last), "\n") .. "\n"
    return node, nxt
  end
  local rows = {}
  for k = i, last do
    local l = L[k]
    local row
    if l:match("^[ \t]*|%-") then
      row = M.node("table-row", { row_type = "rule" })
    else
      row = M.node("table-row", { row_type = "standard" })
      local content = l:match("^[ \t]*|(.*)$"):gsub("[ \t]+$", "")
      local cells = {}
      local pos = 1
      while pos <= #content do
        local bar = content:find("|", pos, true)
        local raw = content:sub(pos, (bar or (#content + 1)) - 1)
        local cell = M.node("table-cell", {})
        cell.contents = self:parse_objects(trim(raw), M.RESTRICTIONS["table-cell"], cell)
        cell.parent = row
        cells[#cells + 1] = cell
        if not bar then
          break
        end
        pos = bar + 1
      end
      row.contents = cells
    end
    row.parent = node
    rows[#rows + 1] = row
  end
  node.contents = rows
  return node, nxt
end
