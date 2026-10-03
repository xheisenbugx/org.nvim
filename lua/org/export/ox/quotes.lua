---@mod org.export.ox.quotes Smart quotes and translations
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local cfg = M.cfg

---------------------------------------------------------------------------
-- Smart quotes
---------------------------------------------------------------------------

local function is_word(c)
  return c ~= nil and c ~= "" and (c:match("[%w_]") ~= nil or c:byte() > 127)
end
local function is_space(c)
  return c ~= nil and c:match("^[ \t\n\r]$") ~= nil
end
local function is_punct(c)
  return c ~= nil and c:match("^[%.,;:!%?%-]$") ~= nil
end
local function is_open(c)
  return c ~= nil and c:match("^[%(%[{]$") ~= nil
end
local function is_close(c)
  return c ~= nil and c:match("^[%)%]}]$") ~= nil
end
local function is_quote(c)
  return c == '"'
end

--- Quote status of every quote in plain-text nodes of the same parent.
function M.smart_quote_status(node, info)
  local parent = node.parent
  local cache = info.smart_quote_cache
  local key = parent or node
  local status = cache[key]
  if not status then
    status = {}
    local level1_open = false
    local full = {}
    local list = element.siblings(node) or { node }
    element.map(list, "plain-text", function(text)
      local s = text.value
      local cur = {}
      local start = 1
      while true do
        local a = s:find("['\"]", start)
        if not a then
          break
        end
        local ch = s:sub(a, a)
        local st
        if ch == '"' then
          level1_open = not level1_open
          st = level1_open and "primary_opening" or "primary_closing"
        elseif not level1_open then
          st = "apostrophe"
        else
          local prev
          if a > 1 then
            prev = s:sub(a - 1, a - 1)
          else
            local p = M.get_previous_element(text, info)
            if not p then
              prev = nil
            elseif p.type == "plain-text" then
              prev = p.value:sub(-1)
            elseif (p.post_blank or 0) == 0 then
              prev = "no-blank"
            else
              prev = "blank"
            end
          end
          local nxt
          if a + 1 <= #s then
            nxt = s:sub(a + 1, a + 1)
          else
            local n = M.get_next_element(text, info)
            if not n then
              nxt = nil
            elseif n.type == "plain-text" then
              nxt = n.value:sub(1, 1)
            else
              nxt = "no-blank"
            end
          end
          local function strp(x)
            return x ~= nil and x ~= "blank" and x ~= "no-blank"
          end
          local allow_open = (
            strp(prev) and (is_quote(prev) or is_space(prev) or is_open(prev)) or (prev == "blank" or prev == nil)
          ) and (strp(nxt) and (is_word(nxt) or is_punct(nxt)) or nxt == "no-blank")
          local allow_close = (strp(prev) and (is_word(prev) or is_punct(prev)) or prev == "no-blank")
            and (
              strp(nxt) and (is_space(nxt) or is_close(nxt) or is_punct(nxt) or is_quote(nxt))
              or (nxt == "blank" or nxt == nil)
            )
          if allow_open and allow_close then
            st = "apostrophe"
          elseif allow_open then
            st = "secondary_opening"
          elseif allow_close then
            st = "secondary_closing"
          else
            st = "apostrophe"
          end
        end
        cur[#cur + 1] = { st = st }
        start = a + 1
      end
      if #cur > 0 then
        full[#full + 1] = { text, cur }
      end
    end, { no_recursion = element.RECURSIVE_OBJECTS, ignore = info.ignore })
    -- unbalanced quotes become apostrophes
    local primary, secondary = {}, {}
    for _, sub in ipairs(full) do
      for _, q in ipairs(sub[2]) do
        if q.st == "primary_opening" then
          primary[#primary + 1] = q
        elseif q.st == "secondary_opening" then
          secondary[#secondary + 1] = q
        elseif q.st == "secondary_closing" then
          if #secondary > 0 then
            table.remove(secondary)
          else
            q.st = "apostrophe"
          end
        elseif q.st == "primary_closing" then
          for _, o in ipairs(secondary) do
            o.st = "apostrophe"
          end
          secondary = {}
          table.remove(primary)
        end
      end
    end
    if #primary > 0 then
      local marker = primary[#primary]
      marker.st = nil
      local after_marker = false
      for _, sub in ipairs(full) do
        for _, q in ipairs(sub[2]) do
          if q == marker then
            after_marker = true
          end
          if after_marker and (q.st == "secondary_opening" or q.st == "secondary_closing") then
            q.st = "apostrophe"
          end
        end
      end
    end
    for _, sub in ipairs(full) do
      status[sub[1]] = sub[2]
    end
    cache[key] = status
  end
  return status[node]
end

--- Replace quotes of plain text `s` (from `node`) by smart quotes.
function M.activate_smart_quotes(s, encoding, info, node)
  local status = node and M.smart_quote_status(node, info)
  if not status then
    return s
  end
  local lang = info.language or "en"
  info.smart_quotes_table = info.smart_quotes_table or {}
  local quotes = info.smart_quotes_table[lang]
  if quotes == nil then
    -- org-export-smart-quotes-alist: a language given by the user replaces
    -- its Emacs entry
    quotes = (cfg().smart_quotes_alist or {})[lang] or require("org.export.dictionary").smart_quotes[lang]
    info.smart_quotes_table[lang] = quotes or false
  end
  local i = 0
  return (
    s:gsub("['\"]", function(m)
      i = i + 1
      local st = status[i] and status[i].st
      local tr = st and quotes and quotes[st] and quotes[st][encoding]
      return tr or m
    end)
  )
end

---------------------------------------------------------------------------
-- Translation
---------------------------------------------------------------------------

function M.translate(s, encoding, info)
  local dict = require("org.export.dictionary").dictionary
  local entry = dict[s]
  local lang = info and info.language or "en"
  local tr = entry and entry[lang]
  if tr then
    return tr[encoding] or tr.default or s
  end
  return s
end
