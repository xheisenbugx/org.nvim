---@mod org.export.element.list Export parser: plain lists
---
--- org-element--list-struct and the plain-list / item parsers.
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local blank = shared.blank
local indentation = shared.indentation
local headline_stars = shared.headline_stars
local drawer_name = shared.drawer_name
local is_end_line = shared.is_end_line
local item_match = shared.item_match
local P = shared.P
local skip_blank = shared.skip_blank
local after = shared.after
local find_line = shared.find_line
local attach = shared.attach

---------------------------------------------------------------------------
-- Plain lists (org-element--list-struct / plain-list / item parsers)
---------------------------------------------------------------------------

--- Full item match (org-list-full-item-re).
local function full_item(l)
  local ind, bullet, rest = l:match("^([ \t]*)([%-%+%*][ \t]+)(.*)$")
  if not ind then
    ind, bullet = l:match("^([ \t]*)([%-%+%*])$")
    rest = ""
  end
  if not ind then
    ind, bullet, rest = l:match("^([ \t]*)(%w+[%.%)][ \t]+)(.*)$")
    if not ind then
      ind, bullet = l:match("^([ \t]*)(%w+[%.%)])$")
      rest = ""
    end
  end
  if not ind then
    return nil
  end
  local r = { ind = ind, bullet = bullet }
  local counter, rest2 = rest:match("^%[@([%w]+)%][ \t]*(.*)$")
  if not counter then
    counter, rest2 = rest:match("^%[@start:([%w]+)%][ \t]*(.*)$")
  end
  if counter then
    r.counter = counter
    rest = rest2
  end
  local box, rest3 = rest:match("^(%[[ X%-]%])[ \t]+(.*)$")
  if not box then
    box = rest:match("^(%[[ X%-]%])$")
    rest3 = box and "" or nil
  end
  if box then
    r.checkbox = box
    rest = rest3
  end
  -- tag: greedy up to the last " ::" followed by blank or end
  local tag, after_tag
  local best
  local s = 1
  while true do
    local a, b = rest:find("[ \t]+::", s)
    if not a then
      break
    end
    local nextc = rest:sub(b + 1, b + 1)
    if nextc == "" or nextc:match("[ \t]") then
      best = { a, b }
    end
    s = b + 1
  end
  if best then
    tag = rest:sub(1, best[1] - 1)
    after_tag = rest:sub(best[2] + 1):gsub("^[ \t]+", "")
    r.tag = tag
    r.after_tag = after_tag
  end
  r.rest = rest
  return r
end

function P:list_struct(L, i, e)
  local items, struct = {}, {}
  local alpha = self.opts.alpha
  local j = i
  local function close_all(endline)
    for _, it in ipairs(items) do
      it.last = endline
      struct[#struct + 1] = it
    end
    items = {}
  end
  while true do
    if j > e then
      -- at limit: end before trailing blanks
      local k = e
      while k >= i and blank(L[k]) do
        k = k - 1
      end
      close_all(k)
      break
    end
    local l = L[j]
    if blank(l) and j + 1 <= e and blank(L[j + 1]) then
      close_all(j - 1)
      break
    end
    local ind = item_match(l, alpha, self.opts.term)
    if ind then
      while #items > 0 and ind <= items[#items].ind do
        local it = table.remove(items)
        it.last = j - 1
        struct[#struct + 1] = it
      end
      local fi = full_item(l)
      items[#items + 1] = {
        line = j,
        ind = ind,
        bullet = fi.bullet,
        counter = fi.counter,
        checkbox = fi.checkbox,
        tag = fi.bullet:match("^[%-%+%*]") and fi.tag or nil,
        full = fi,
      }
      j = j + 1
    elseif blank(l) then
      j = j + 1
    elseif l:match("^%*+ ") and headline_stars(l) >= self.inlinetask_min then
      -- skip inline tasks
      local origin = j + 1
      local k = origin
      while k <= e and not L[k]:match("^%*+ ") do
        k = k + 1
      end
      if k <= e and L[k]:match("^%*+ [ \t]*END[ \t]*$") then
        j = k + 1
      else
        j = origin
      end
    else
      local ind2 = indentation(l)
      local k = j - 1
      while k >= i and blank(L[k]) do
        k = k - 1
      end
      local done = false
      while #items > 0 and ind2 <= items[#items].ind do
        local it = table.remove(items)
        it.last = k
        struct[#struct + 1] = it
        if #items == 0 then
          done = true
        end
      end
      if done then
        break
      end
      -- skip blocks and drawers
      local bt = l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn](_%S+)") or (l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]:") and ":")
      if bt then
        local endp = bt == ":" and "^[ \t]*#%+end:?[ \t]*$" or ("^[ \t]*#%+end" .. vim.pesc(bt:lower()) .. "[ \t]*$")
        local k2 = find_line(L, j + 1, e, function(x)
          return x:lower():match(endp) ~= nil
        end)
        if k2 then
          j = k2
        end
      elseif drawer_name(l) then
        local k2 = find_line(L, j + 1, e, is_end_line)
        if k2 then
          j = k2
        end
      end
      j = j + 1
    end
  end
  table.sort(struct, function(a, b)
    return a.line < b.line
  end)
  local by_line = {}
  for _, it in ipairs(struct) do
    by_line[it.line] = it
  end
  return struct, by_line
end

function P:plain_list(L, i, e, aff, struct_info)
  local struct, by_line
  if struct_info then
    struct, by_line = struct_info[1], struct_info[2]
  else
    struct, by_line = self:list_struct(L, i, e)
  end
  local first = by_line[i]
  if not first then
    return self:paragraph(L, i, e, aff)
  end
  local ltype
  if L[i]:match("^[ \t]*[%w]") then
    ltype = "ordered"
  elseif first.tag then
    ltype = "descriptive"
  else
    ltype = "unordered"
  end
  -- siblings: items with the same indentation, each starting right
  -- where the previous one ends
  local items = {}
  local it = first
  while it do
    items[#items + 1] = it
    local nxt = by_line[it.last + 1]
    if nxt and nxt.ind == first.ind then
      it = nxt
    else
      break
    end
  end
  local last_item = items[#items]
  local ce = last_item.last
  while ce >= i and blank(L[ce]) do
    ce = ce - 1
  end
  local pb, nxt = after(L, ce, e)
  local node = attach(M.node("plain-list", { post_blank = pb, list_type = ltype }), aff)
  local kids = {}
  for _, item in ipairs(items) do
    kids[#kids + 1] = self:item(L, item, item.last, struct, by_line, ltype)
  end
  M.adopt(node, kids)
  return node, nxt
end

function P:item(L, it, iend, struct, by_line, ltype)
  local fi = it.full
  local node = M.node("item", { bullet = it.bullet, pre_blank = 0 })
  if it.checkbox == "[ ]" then
    node.checkbox = "off"
  elseif it.checkbox == "[X]" then
    node.checkbox = "on"
  elseif it.checkbox == "[-]" then
    node.checkbox = "trans"
  end
  if it.counter then
    local c = it.counter
    node.counter = tonumber(c) or (c:upper():byte() - 64)
  end
  -- contents end before trailing blanks
  local ce = iend
  while ce > it.line and blank(L[ce]) do
    ce = ce - 1
  end
  node.post_blank = iend - ce
  -- ordered items cannot have tags: their contents start at the tag
  local first = (fi.tag and it.tag) and fi.after_tag or fi.rest
  if it.tag then
    node.tag = self:parse_objects(it.tag, M.RESTRICTIONS.item, node)
  end
  first = first:gsub("^[ \t]+", "")
  local body
  local not_bol = false
  if first ~= "" then
    body = { first }
    vim.list_extend(body, vim.list_slice(L, it.line + 1, ce))
    not_bol = true
  else
    local cb = skip_blank(L, it.line + 1, ce)
    if cb <= ce then
      node.pre_blank = cb - it.line - 1
      body = vim.list_slice(L, cb, ce)
    end
  end
  if body then
    -- sub-structure lines are offset: rebuild struct for the body
    M.adopt(node, self:parse_elements(body, 1, #body, nil, node, not_bol))
  else
    -- without contents, Emacs counts the lines from the item's own line
    -- (count-lines begin end)
    node.post_blank = iend - it.line + 1
  end
  return node
end
