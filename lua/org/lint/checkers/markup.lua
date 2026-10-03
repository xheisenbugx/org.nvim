---@mod org.lint.checkers.markup org-lint checkers: lists, priorities, LaTeX, Beamer, timestamps and clocks
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local data = require("org.lint.data")
local timestamp = require("org.lint.timestamp")
local helpers = require("org.lint.helpers")

local trim = util.trim
local BEAMER_FRAME_ENVIRONMENT = data.BEAMER_FRAME_ENVIRONMENT
local parse_timestamp = timestamp.parse_timestamp
local interpret_timestamp = timestamp.interpret_timestamp
local map_type = helpers.map_type
local map_objects = helpers.map_objects
local at_begin = helpers.at_begin
local at_obj = helpers.at_obj
local priority_bounds = helpers.priority_bounds

local C = {}

C["item-number"] = function(doc)
  local out = {}
  for _, it in ipairs(map_type(doc, "item")) do
    local st = it.item
    if not st.counter then
      local bullet = st.bullet
      local bn
      local letter = bullet:match("%a")
      if letter then
        bn = letter:upper():byte() - 64
      elseif bullet:match("%d+") then
        bn = tonumber(bullet:match("%d+"))
      end
      if bn then
        -- relative number among siblings (counters restart the count)
        local siblings = {}
        for _, c in ipairs(it.parent.children) do
          if c.type == "item" then
            siblings[#siblings + 1] = c
          end
        end
        local idx
        for x, c in ipairs(siblings) do
          if c == it then
            idx = x
          end
        end
        local seq, counter = 0, nil
        local x = idx
        while x >= 1 do
          counter = siblings[x].item.counter
          if counter then
            break
          end
          x = x - 1
          if x >= 1 then
            seq = seq + 1
          end
        end
        local true_n
        if not counter then
          true_n = seq + 1
        elseif counter:match("%a") then
          true_n = counter:match("%a"):upper():byte() - 64 + seq
        else
          true_n = tonumber(counter:match("%d+")) + seq
        end
        if bn ~= true_n then
          out[#out + 1] = at_begin(
            it,
            string.format(
              'Bullet counter "%s" is not the same with item position %d.  Consider adding manual [@%d] counter.',
              bullet,
              true_n,
              bn
            )
          )
        end
      end
    end
  end
  return out
end

C["priority"] = function(doc)
  local out = {}
  local hi, lo = priority_bounds(doc)
  local function valid(p, ignore_bounds)
    if not ((p >= 0 and p <= 64) or (p >= 65 and p <= 90)) then
      return false
    end
    return ignore_bounds or (lo >= p and p >= hi)
  end
  for _, h in ipairs(map_type(doc, "headline")) do
    local p = h.priority
    if p then
      if not valid(p) and valid(p, true) then
        local s = p <= 64 and tostring(p) or string.char(p)
        out[#out + 1] = at_begin(h, string.format("Out-of-bounds priority '%s'", s))
      end
    else
      local whole, g1, g2 = h.raw_value:match("^(%[#([^%[%]]*)(%]*))")
      if whole then
        if g2 == "" then
          out[#out + 1] = at_begin(h, string.format("Malformed priority '%s'", whole))
        else
          out[#out + 1] = at_begin(h, string.format("Invalid priority '%s'", g1))
        end
      end
    end
  end
  return out
end

C["LaTeX-$-fragment"] = function(doc)
  local out = {}
  for _, o in ipairs(map_objects(doc, "latex-fragment")) do
    if o.value:match("^%$[^%$]") then
      out[#out + 1] = at_obj(o, "Potentially confusing LaTeX fragment format.  Prefer using more reliable \\(...\\)")
    end
  end
  return out
end

-- Objects whose contents cannot hold a LaTeX fragment.
local NO_LATEX = {
  verbatim = true,
  code = true,
  timestamp = true,
  macro = true,
  ["inline-src-block"] = true,
  ["inline-babel-call"] = true,
  ["export-snippet"] = true,
  entity = true,
  target = true,
}

C["LaTeX-$"] = function(doc)
  local out = {}
  local containers = {
    paragraph = true,
    headline = true,
    keyword = true,
    ["table-row"] = true,
    ["verse-block"] = true,
    item = true,
  }
  for lnum, l in ipairs(doc.lines) do
    local init = 1
    while true do
      local s, e = l:find("%$%.%d", init)
      if not s then
        break
      end
      local point = e + 1
      local el = doc:element_at(lnum, point)
      if el and containers[el.type] then
        local ok = true
        for _, o in ipairs(doc.objects) do
          if o.lnum == lnum and o.element == el and NO_LATEX[o.type] then
            local len = o.e - o.b - (o.post_blank or 0)
            if o.col <= point and point < o.col + len then
              ok = false
            end
          end
        end
        if ok then
          table.insert(out, 1, {
            lnum,
            point,
            "$ symbol potentially matching LaTeX fragment boundary.  Consider using \\dollar entity.",
          })
        end
      end
      init = e + 1
    end
  end
  return out
end

C["beamer-frame"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local init = 1
    while true do
      local s, e = l:find("\\begin{" .. BEAMER_FRAME_ENVIRONMENT .. "}", init, true)
      local s2, e2 = l:find("\\end{" .. BEAMER_FRAME_ENVIRONMENT .. "}", init, true)
      if s2 and (not s or s2 < s) then
        s, e = s2, e2
      end
      if not s then
        break
      end
      table.insert(out, 1, {
        lnum,
        s,
        "Beamer frame name may cause error when exporting.  Consider customizing `org-beamer-frame-environment'.",
      })
      init = e + 1
    end
  end
  return out
end

C["timestamp-syntax"] = function(doc)
  local out = {}
  for _, o in ipairs(map_objects(doc, "timestamp")) do
    local expected = interpret_timestamp(o)
    if expected then
      expected = expected .. string.rep(" ", o.post_blank or 0)
      local actual = o.text
      if expected ~= actual then
        out[#out + 1] = at_obj(o, string.format("Potentially malformed timestamp %s.  Parsed as: %s", actual, expected))
      end
    end
  end
  return out
end

C["clock-syntax"] = function(doc)
  local out = {}
  for _, c in ipairs(map_type(doc, "clock")) do
    local l = doc.lines[c.begin]
    local p = l:find(":", 1, true) + 1
    p = p + #l:match("^[ \t]*", p)
    local ts = parse_timestamp(l, p, #l)
    local duration
    local arrow = l:find("=> ", 1, true)
    if arrow then
      local q = arrow + 3
      q = q + #l:match("^[ \t]*", q)
      duration = l:sub(q):match("^(%S+)[ \t]*$")
    end
    local interp = interpret_timestamp(ts)
    local expected = "CLOCK: " .. (interp or "")
    if duration then
      local parts = {}
      for x in duration:gmatch("[^:]+") do
        parts[#parts + 1] = x
      end
      if #parts >= 2 then
        expected = expected .. " => " .. string.format("%2s:%2s", parts[1], parts[2])
      end
    end
    expected = expected:gsub("[ \t\n]+$", "")
    local actual = trim(l)
    if expected ~= actual then
      out[#out + 1] =
        at_begin(c, string.format("Potentially malformed CLOCK: line\n           %s\nParsed as: %s", actual, expected))
    end
  end
  return out
end

C["planning-inactive"] = function(doc)
  local out = {}
  for _, p in ipairs(map_type(doc, "planning")) do
    local function inactive(ts)
      return ts and (ts.kind == "inactive" or ts.kind == "inactive-range")
    end
    if inactive(p.scheduled) then
      out[#out + 1] = at_begin(p, "Inactive timestamp in SCHEDULED will not appear in agenda.")
    elseif inactive(p.deadline) then
      out[#out + 1] = at_begin(p, "Inactive timestamp in DEADLINE will not appear in agenda.")
    end
  end
  return out
end

return C
