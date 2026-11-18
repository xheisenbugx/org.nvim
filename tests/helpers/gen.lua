-- Pathological Org input for the perf budgets (tests/spec/perf_budgets_spec.lua)
-- and for benchmarking by hand:
--
--   local gen = require("tests.helpers.gen")
--   local lines = gen.headlines(10000)
--
-- Every generator is deterministic (no randomness, or a generator with a
-- fixed seed), so a timing compares the same text from run to run, and
-- returns a list of lines.
local M = {}

local WORDS = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }

--- `n` characters of plain prose.
function M.prose(n)
  local parts, len, i = {}, 0, 0
  while len < n do
    i = i + 1
    local w = WORDS[(i - 1) % #WORDS + 1]
    parts[#parts + 1] = w
    len = len + #w + 1
  end
  return table.concat(parts, " "):sub(1, n)
end

--- `n` characters of prose that is mostly markup: emphasis, verbatim,
--- links, timestamps, footnotes, entities, macros.
function M.marked(n)
  local pieces = {
    "*bold*",
    "/italic/",
    "=verb=",
    "~code~",
    "+strike+",
    "_under_",
    "[[https://example.com/a][link]]",
    "[[file:x.org][file]]",
    "<2026-10-05 Mon 10:00>",
    "[2026-10-05 Mon]",
    "[fn:: note]",
    "\\alpha",
    "{{{title}}}",
    "=code=",
    "@@html:<b>@@",
    "word",
  }
  local parts, len, i = {}, 0, 0
  while len < n do
    i = i + 1
    local p = pieces[(i - 1) % #pieces + 1]
    parts[#parts + 1] = p
    len = len + #p + 1
  end
  return table.concat(parts, " "):sub(1, n)
end

--- `n` characters of unbalanced markup characters, the worst case for
--- regexps that look for a closing marker: `* / = ~ + _ [[ <`.
function M.markers(n)
  local chunk = "*a /b =c ~d +e _f [[g <h *i/ =j~ [fn: {{{ "
  return string.rep(chunk, math.ceil(n / #chunk)):sub(1, n)
end

--- `n` characters without a blank (a hash or a minified blob).
function M.blob(n)
  local chunk = "a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuVwXyZ+-"
  return string.rep(chunk, math.ceil(n / #chunk)):sub(1, n)
end

--- One file with a headline and each kind of long line, `n` chars each.
function M.long_lines(n)
  return {
    "* Long lines",
    M.blob(n),
    "",
    M.prose(n),
    "",
    M.marked(n),
    "",
    M.markers(n),
    "",
    "- " .. M.prose(n) .. " :: term",
    "",
    "| " .. M.prose(n) .. " |",
    "",
    "** " .. M.prose(n) .. " :tag:",
    "after",
  }
end

--- Headlines nested `depth` levels deep, each with a body line.
function M.deep_headlines(depth)
  local out = {}
  for l = 1, depth do
    out[#out + 1] = string.rep("*", l) .. " Level " .. l
    out[#out + 1] = "text " .. l
  end
  return out
end

--- A plain list nested `depth` levels deep, and back out.
function M.deep_list(depth)
  local out = { "* Lists" }
  for l = 1, depth do
    out[#out + 1] = string.rep("  ", l - 1) .. "- item " .. l
  end
  for l = depth, 1, -1 do
    out[#out + 1] = string.rep("  ", l - 1) .. "- back " .. l
  end
  return out
end

--- Blocks and drawers nested `depth` levels deep (blocks inside special
--- blocks, a drawer inside each).
function M.deep_blocks(depth)
  local out = { "* Blocks" }
  for l = 1, depth do
    out[#out + 1] = "#+begin_b" .. l
    out[#out + 1] = ":D" .. l .. ":"
    out[#out + 1] = "in " .. l
    out[#out + 1] = ":END:"
  end
  out[#out + 1] = "#+begin_src lua"
  out[#out + 1] = "print(1)"
  out[#out + 1] = "#+end_src"
  for l = depth, 1, -1 do
    out[#out + 1] = "#+end_b" .. l
  end
  return out
end

--- `n` headlines with TODO keywords, priorities, tags, planning,
--- properties, a logbook with clocks, and a body. About 12 lines each.
function M.headlines(n)
  local out = { "#+TITLE: Big", "#+FILETAGS: :big:", "" }
  local kws = { "TODO", "DONE", "", "TODO", "" }
  for i = 1, n do
    local level = (i % 3) + 1
    local kw = kws[i % #kws + 1]
    local day = (i % 28) + 1
    local month = (i % 12) + 1
    out[#out + 1] = ("%s %s%s[#%s] Task number %d :t%d:shared:"):format(
      string.rep("*", level),
      kw,
      kw ~= "" and " " or "",
      ({ "A", "B", "C" })[i % 3 + 1],
      i,
      i % 50
    )
    if i % 2 == 0 then
      out[#out + 1] = ("SCHEDULED: <2026-%02d-%02d Mon 09:00> DEADLINE: <2026-%02d-%02d Tue>"):format(
        month,
        day,
        month,
        (day % 28) + 1
      )
    end
    out[#out + 1] = ":PROPERTIES:"
    out[#out + 1] = ":ID: id-" .. i
    out[#out + 1] = ":EFFORT: 1:00"
    out[#out + 1] = ":END:"
    out[#out + 1] = ":LOGBOOK:"
    out[#out + 1] = ("CLOCK: [2026-%02d-%02d Mon 09:00]--[2026-%02d-%02d Mon 10:30] =>  1:30"):format(
      month,
      day,
      month,
      day
    )
    out[#out + 1] = ":END:"
    out[#out + 1] = "Body with a [[https://example.com/" .. i .. "][link]] and *bold* text."
    out[#out + 1] = "- item one"
    out[#out + 1] = "- [ ] item two"
  end
  return out
end

--- `n` CLOCK lines, 400 per scheduled task (a task clocked most days of
--- a year), on about 300 days of 2026.
function M.clocks(n)
  local out = { "#+TITLE: Clocks", "" }
  local per = 400
  for i = 1, math.max(1, math.floor(n / per)) do
    out[#out + 1] = ("* TODO Long task %d"):format(i)
    out[#out + 1] = "SCHEDULED: <2026-11-01 Sun>"
    out[#out + 1] = ":LOGBOOK:"
    for k = 1, per do
      local d, m = 1 + (k % 28), 1 + (k % 11)
      out[#out + 1] = ("CLOCK: [2026-%02d-%02d Mon 09:%02d]--[2026-%02d-%02d Mon 10:%02d] =>  1:00"):format(
        m,
        d,
        k % 60,
        m,
        d,
        k % 60
      )
    end
    out[#out + 1] = ":END:"
  end
  return out
end

--- A table of `rows` x `cols`, with a header, and optionally a #+TBLFM.
function M.table(rows, cols, opts)
  opts = opts or {}
  local out = { "* Table" }
  local head = {}
  for c = 1, cols do
    head[c] = "h" .. c
  end
  out[#out + 1] = "| " .. table.concat(head, " | ") .. " |"
  out[#out + 1] = "|" .. string.rep("---+", cols - 1) .. "---|"
  for r = 1, rows do
    local cells = {}
    for c = 1, cols do
      cells[c] = tostring(r * c)
    end
    if opts.long_cell and r == 1 then
      cells[1] = M.prose(opts.long_cell)
    end
    out[#out + 1] = "|" .. table.concat(cells, "|") .. "|"
  end
  if opts.formula then
    out[#out + 1] = "#+TBLFM: " .. opts.formula
  end
  return out
end

--- `blocks` Lua src blocks of `size` lines each, under a headline every 10
--- blocks, with a paragraph between blocks (a literate config).
function M.src_blocks(blocks, size)
  local out = {}
  for b = 1, blocks do
    if b % 10 == 1 then
      out[#out + 1] = "* Section " .. b
    end
    out[#out + 1] = "Block " .. b .. ": " .. M.prose(60)
    out[#out + 1] = "#+begin_src lua"
    for i = 1, size do
      local k = i % 4
      if k == 0 then
        out[#out + 1] = ("local v%d = { name = %q, n = %d } -- entry %d"):format(i, WORDS[i % #WORDS + 1], i, i)
      elseif k == 1 then
        out[#out + 1] = ("if v%d and v%d.n > %d then return %q end"):format(i - 1, i - 1, i, "s" .. i)
      elseif k == 2 then
        out[#out + 1] = ("local function f%d(a, b) return a .. b, %d end"):format(i, i)
      else
        out[#out + 1] = ('print(f%d(%q, "x"), #{ 1, 2, 3 })'):format(i - 1, WORDS[i % #WORDS + 1])
      end
    end
    out[#out + 1] = "#+end_src"
  end
  return out
end

--- `n` lines: headlines every 20 lines, prose in between (a big notes file).
function M.big_file(n)
  local out = {}
  for i = 1, n do
    if i % 20 == 1 then
      out[i] = string.rep("*", (math.floor(i / 20) % 3) + 1) .. " Section " .. i
    else
      out[i] = M.prose(60 + (i % 20))
    end
  end
  return out
end

--- A paragraph of `n` lines with links, targets and footnote references,
--- then the definitions.
function M.links_footnotes(n)
  local out = { "* Links" }
  for i = 1, n do
    out[#out + 1] = ("See [[https://example.com/%d][site %d]], [[file:f%d.org]], <<t%d>> [[t%d]] and a note[fn:%d]."):format(
      i,
      i,
      i,
      i,
      i,
      i
    )
  end
  out[#out + 1] = "* Footnotes"
  for i = 1, n do
    out[#out + 1] = ("[fn:%d] Note %d."):format(i, i)
  end
  return out
end

local DAY_NAMES = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

--- An Org date `days` days from `anchor` ({ year, month, day }): "2026-05-13
--- Wed", with `time` ("09:00") when given.
local function org_date(anchor, days, time)
  local t = os.time({ year = anchor.year, month = anchor.month, day = anchor.day + days, hour = 12 })
  local d = os.date("*t", t) --[[@as osdate]]
  return ("%04d-%02d-%02d %s%s"):format(d.year, d.month, d.day, DAY_NAMES[d.wday], time and (" " .. time) or "")
end

--- A realistic agenda corpus for benchmarks (scripts/bench.lua): `files`
--- files of `per_file` headlines each (default 200 x 250, 50,000
--- headlines), around the date `anchor` (default 2026-05-13). Headlines
--- are one to three levels deep; about half have a TODO keyword of
--- `#+TODO: TODO NEXT WAITING | DONE CANCELLED`, and they have
--- priorities, tags from a pool of 30 (with FILETAGS), SCHEDULED (a third)
--- and DEADLINE (an eighth) dates within two months of the anchor, some
--- with times, repeaters (+1w, .+1d, ++1m) and warning periods, habits
--- (STYLE habit with a logbook of state changes), properties, clocks,
--- plain active timestamps and a body. Pseudo-random from a fixed seed:
--- the same corpus every time. Returns a list of { name, lines }.
---@param files? integer
---@param per_file? integer
---@param anchor? { year: integer, month: integer, day: integer }
---@return { name: string, lines: string[] }[]
function M.agenda_corpus(files, per_file, anchor)
  files, per_file = files or 200, per_file or 250
  anchor = anchor or { year = 2026, month = 5, day = 13 }
  local seed = 12345
  -- (Park-Miller: math.random differs between builds; the products stay
  -- below 2^53, exact in a double)
  local function rand(n)
    seed = (seed * 16807) % 2147483647
    return seed % n + 1
  end
  local function pick(list)
    return list[rand(#list)]
  end
  local tags = {}
  for i = 1, 30 do
    tags[i] = ({ "work", "home", "errand", "call", "email", "read", "urgent", "project" })[(i - 1) % 8 + 1]
      .. (i > 8 and tostring(math.floor((i - 1) / 8)) or "")
  end
  local kws = { "TODO", "TODO", "TODO", "NEXT", "WAITING", "DONE", "CANCELLED" }
  local repeaters = { " +1w", " .+1d", " ++1m", " +2d" }
  local out = {}
  for f = 1, files do
    local lines = {
      "#+TITLE: Project " .. f,
      "#+TODO: TODO NEXT WAITING | DONE CANCELLED",
      "#+FILETAGS: :" .. pick(tags) .. ":",
      "#+CATEGORY: proj" .. f,
      "",
    }
    local level = 1
    for h = 1, per_file do
      if h > 1 then
        level = math.max(1, math.min(3, level + ({ -1, 0, 0, 1 })[rand(4)]))
      end
      local kw = rand(2) == 1 and pick(kws) or nil
      local habit = kw == "TODO" and rand(40) == 1
      local title = ("%s %s%sTask %d.%d %s"):format(
        string.rep("*", level),
        kw and (kw .. " ") or "",
        rand(5) == 1 and ("[#" .. pick({ "A", "B", "C" }) .. "] ") or "",
        f,
        h,
        M.prose(10 + rand(30))
      )
      if rand(3) == 1 then
        local t1, t2 = pick(tags), pick(tags)
        title = title .. "   :" .. t1 .. (t2 ~= t1 and (":" .. t2) or "") .. ":"
      end
      lines[#lines + 1] = title
      local planning = {}
      if habit then
        planning[#planning + 1] = ("SCHEDULED: <%s .+%dd>"):format(org_date(anchor, rand(5) - 3), rand(3))
      else
        if rand(3) == 1 then
          local time = rand(4) == 1 and ("%02d:%02d"):format(7 + rand(12), (rand(4) - 1) * 15) or nil
          local rep = rand(12) == 1 and pick(repeaters) or ""
          planning[#planning + 1] = ("SCHEDULED: <%s%s>"):format(org_date(anchor, rand(120) - 60, time), rep)
        end
        if rand(8) == 1 then
          local warn = rand(3) == 1 and (" -" .. rand(7) .. "d") or ""
          planning[#planning + 1] = ("DEADLINE: <%s%s>"):format(org_date(anchor, rand(120) - 60), warn)
        end
      end
      if kw == "DONE" or kw == "CANCELLED" then
        planning[#planning + 1] = ("CLOSED: [%s]"):format(org_date(anchor, -rand(30), "18:00"))
      end
      if #planning > 0 then
        lines[#lines + 1] = table.concat(planning, " ")
      end
      if habit or rand(4) == 1 then
        lines[#lines + 1] = ":PROPERTIES:"
        lines[#lines + 1] = ":ID: c" .. f .. "-" .. h
        if habit then
          lines[#lines + 1] = ":STYLE: habit"
        else
          lines[#lines + 1] = ":EFFORT: " .. rand(3) .. ":00"
        end
        lines[#lines + 1] = ":END:"
      end
      if habit then
        lines[#lines + 1] = ":LOGBOOK:"
        for d = 1, 10 do
          lines[#lines + 1] = ('- State "DONE"       from "TODO"       [%s]'):format(
            org_date(anchor, -d * rand(3), "08:00")
          )
        end
        lines[#lines + 1] = ":END:"
      elseif rand(6) == 1 then
        local d = rand(60) - 50
        lines[#lines + 1] = ":LOGBOOK:"
        lines[#lines + 1] = ("CLOCK: [%s]--[%s] =>  1:30"):format(
          org_date(anchor, d, "09:00"),
          org_date(anchor, d, "10:30")
        )
        lines[#lines + 1] = ":END:"
      end
      if rand(20) == 1 then
        lines[#lines + 1] = ("Meeting on <%s>."):format(org_date(anchor, rand(60) - 30, "14:00"))
      end
      for _ = 1, rand(3) - 1 do
        lines[#lines + 1] = M.prose(40 + rand(60))
      end
      if rand(10) == 1 then
        lines[#lines + 1] = "- [ ] " .. M.prose(20)
        lines[#lines + 1] = "- [X] " .. M.prose(20)
      end
    end
    out[#out + 1] = { name = ("project%03d.org"):format(f), lines = lines }
  end
  return out
end

return M
