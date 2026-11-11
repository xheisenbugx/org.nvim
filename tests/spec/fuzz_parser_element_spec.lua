-- Fuzz: the editing parser (org.parser, used by the commands, the agenda
-- and the clock) and the export parser (org.export.element, a port of
-- org-element checked against Emacs) read random Org text the same way
-- where they both model it: headlines (level, TODO keyword, priority,
-- COMMENT, title, tags, archived), inline tasks, planning, property
-- drawers and clock lines; and org.lists reads the plain list items
-- (bullet, checkbox, counter) org.export.element does. The documents
-- come from tests/helpers/fuzz.lua (meant to break parsers) and
-- tests/difftest/gen.lua (mostly well-formed). A few fixed seeds by
-- default; see tests/helpers/fuzz.lua for ORG_FUZZ_ITERATIONS /
-- ORG_FUZZ_SEED. A disagreement is a bug in one of them: check
-- org-element.el (or Emacs) for the right reading, fix that parser and
-- add the minimal input to fuzz_regressions_spec.lua. Only a fix too large
-- to make goes in KNOWN, with its reason.
local fuzz = require("tests.helpers.fuzz")
local dgen = require("tests.difftest.gen")
local parser = require("org.parser")
local E = require("org.export.element")

local SEEDS = fuzz.seeds(40)

---------------------------------------------------------------------------
-- One shape for both sides
---------------------------------------------------------------------------

local function hm(h, m)
  return h and ("%02d:%02d"):format(h, m or 0) or ""
end

local function ymd(y, mo, d)
  return ("%04d-%02d-%02d"):format(y, mo, d)
end

--- A timestamp as "<type> <start>/<end> <repeater> <warning>".
local function stamp(kind, y1, mo1, d1, h1, m1, y2, mo2, d2, h2, m2, rep, warn)
  return ("%s %s %s/%s %s %s %s"):format(kind, ymd(y1, mo1, d1), hm(h1, m1), ymd(y2, mo2, d2), hm(h2, m2), rep, warn)
end

--- org.Date (org.date) in that shape.
local function from_date(d)
  if not d then
    return nil
  end
  local e = d.range_end
  local range = e ~= nil or d.end_hour ~= nil
  local kind = (d.active and "active" or "inactive") .. (range and "-range" or "")
  local y2, mo2, d2, h2, m2 = d.year, d.month, d.day, d.hour, d.min
  if e then
    -- an end without a time has the start's in org.export.element, as
    -- in org-element-timestamp-parser
    y2, mo2, d2, h2, m2 = e.year, e.month, e.day, e.hour or d.hour, e.hour and e.min or d.min
  elseif d.end_hour then
    h2, m2 = d.end_hour, d.end_min
  end
  local r = d.repeater or (e and e.repeater)
  local w = d.warning or (e and e.warning)
  local rep = r and (r.type .. r.value .. r.unit) or ""
  local warn = w and (w.type .. w.value .. w.unit) or ""
  return stamp(kind, d.year, d.month, d.day, d.hour, d.min, y2, mo2, d2, h2, m2, rep, warn)
end

local REPEAT = { cumulate = "+", ["catch-up"] = "++", restart = ".+" }
local WARN = { all = "-", first = "--" }

--- A timestamp node (org.export.element) in that shape.
local function from_node(t)
  if not t then
    return nil
  end
  local rep = t.repeater_type and (REPEAT[t.repeater_type] .. t.repeater_value .. t.repeater_unit) or ""
  local warn = t.warning_type and (WARN[t.warning_type] .. t.warning_value .. t.warning_unit) or ""
  return stamp(
    t.ts_type,
    t.year_start,
    t.month_start,
    t.day_start,
    t.hour_start,
    t.minute_start,
    t.year_end,
    t.month_end,
    t.day_end,
    t.hour_end,
    t.minute_end,
    rep,
    warn
  )
end

---------------------------------------------------------------------------
-- The two parses
---------------------------------------------------------------------------

--- What org.parser reads: one entry per headline and inline task.
local function editing(lines)
  local file = parser.parse(lines)
  local out = {}
  for i, hl in ipairs(file.headlines) do
    local clocks = {}
    for k, c in ipairs(hl.clocks) do
      clocks[k] = ("%s => %s"):format(from_date(c.start), tostring(c.minutes))
      if c["end"] then
        clocks[k] = from_date(c.start) .. " -- " .. from_date(c["end"]) .. " => " .. tostring(c.minutes)
      end
    end
    out[i] = {
      line = hl.line,
      endless = hl.inlinetask and hl.end_line == hl.line,
      type = hl.inlinetask and "inlinetask" or "headline",
      level = hl.level,
      todo = hl.todo,
      priority = hl.priority,
      commented = hl.commented,
      title = hl.title,
      tags = hl.tags,
      archived = hl:is_archived(),
      scheduled = from_date(hl.planning.scheduled),
      deadline = from_date(hl.planning.deadline),
      closed = from_date(hl.planning.closed),
      properties = hl.properties,
      clocks = clocks,
    }
  end
  return out, file
end

--- The clock elements of a headline's or inline task's own text (not of
--- the entries nested in it).
local function own_clocks(node)
  local out = {}
  local function walk(n)
    for _, c in ipairs(n.contents or {}) do
      if c.type == "clock" then
        out[#out + 1] = c
      elseif c.type ~= "headline" and c.type ~= "inlinetask" then
        walk(c)
      end
    end
  end
  walk(node)
  return out
end

--- One end of a clock's range, as org.parser's clock start or end.
local function point(y, mo, d, h, mi)
  return stamp("inactive", y, mo, d, h, mi, y, mo, d, h, mi, "", "")
end

local function minutes(duration)
  local h, m = (duration or ""):match("^(%-?%d+):(%d%d)$")
  if not h then
    return nil
  end
  h, m = tonumber(h), tonumber(m)
  return h < 0 and h * 60 - m or h * 60 + m
end

--- What org.export.element reads, in the same shape.
local function export(lines, file)
  local min = parser.inlinetask_min_level()
  local data = E.parse(lines, { todo = file.settings.todo, inlinetask_min_level = min or 1000 })
  return E.map(data, { headline = true, inlinetask = true }, function(n)
    local clocks = {}
    for k, c in ipairs(own_clocks(n)) do
      local t = c.value
      local s = from_node(t)
      if c.status == "running" then
        clocks[k] = ("%s => nil"):format(s)
      else
        -- org.parser keeps the two ends apart: compare them that way
        local first = point(t.year_start, t.month_start, t.day_start, t.hour_start, t.minute_start)
        local last = point(t.year_end, t.month_end, t.day_end, t.hour_end, t.minute_end)
        clocks[k] = ("%s -- %s => %s"):format(first, last, tostring(minutes(c.duration)))
      end
    end
    return {
      type = n.type,
      level = n.level,
      todo = n.todo_keyword,
      priority = n.priority,
      commented = n.commentedp == true,
      title = n.raw_value,
      tags = n.tags,
      archived = n.archivedp == true,
      scheduled = from_node(n.scheduled),
      deadline = from_node(n.deadline),
      closed = from_node(n.closed),
      properties = n.props or {},
      clocks = clocks,
    }
  end)
end

---------------------------------------------------------------------------
-- Comparing
---------------------------------------------------------------------------

local FIELDS = {
  "type",
  "level",
  "todo",
  "priority",
  "commented",
  "title",
  "tags",
  "archived",
  "scheduled",
  "deadline",
  "closed",
  "properties",
  "clocks",
  "all_clocks",
}

--- Disagreements the parsers are known to have, each with the reason it is
--- not fixed. `fn(field, a, b, entry, lines)` returns true to skip one.
local KNOWN = {
  {
    -- org-element reads "<2024-01-02 Tue" up to the next ">" or "]",
    -- whatever comes between (another "<", a "]" closing a "<"), as one
    -- timestamp (org-ts-regexp-both). org.date only reads well-formed
    -- ones, and every agenda, clock and planning command builds on it;
    -- matching Emacs there would change what counts as a date everywhere.
    reason = "a planning timestamp that is not well-formed",
    fn = function(field, _, _, entry, lines)
      if field ~= "scheduled" and field ~= "deadline" and field ~= "closed" then
        return false
      end
      local line = lines[entry.line + 1] or ""
      for p in line:gmatch("()[<%[]%d%d%d%d%-") do
        local ts = line:sub(p)
        local c = ts:find("[>%]]")
        local open = ts:sub(1, 1)
        if not c or ts:sub(2, c - 1):find("[<%[]") or (open == "<") ~= (ts:sub(c, c) == ">") then
          return true
        end
      end
      return false
    end,
  },
}

local function known(field, a, b, entry, lines)
  for _, k in ipairs(KNOWN) do
    if k.fn(field, a, b, entry, lines) then
      return true
    end
  end
  return false
end

--- The one representation difference: the lines after an inline task
--- without an END line. org-element ends the task on its heading and
--- gives them to the enclosing section; org.parser gives them to the
--- task, as org-clock-sum and the SCHEDULED special property (org-entry-get
--- on the task's heading) read them. So such a task's planning, properties
--- and clocks are not compared, and the clocks of an outline entry are
--- compared together with those of its inline tasks.
local function normalise(entries)
  local owner
  for _, x in ipairs(entries) do
    x.all_clocks = {}
    if x.type == "headline" then
      owner = x
    end
    vim.list_extend((owner or x).all_clocks, x.clocks)
  end
  for _, x in ipairs(entries) do
    if x.type == "inlinetask" then
      x.all_clocks = nil
    end
    if x.endless then
      x.scheduled, x.deadline, x.closed, x.properties, x.clocks = nil, nil, nil, nil, nil
    elseif x.type == "headline" then
      x.clocks = nil
    end
  end
end

-- blocks whose contents org-element reads as text, not as elements
local RAW_BLOCKS = { src = true, example = true, export = true, comment = true, verse = true }

--- Whether line `l`, an inline task's heading, lies inside a block whose
--- contents are text. org-element reads no inline task there; org.parser,
--- like org-inlinetask's commands and the outline, finds the heading by
--- its stars alone, and reading blocks first would slow down the scan of
--- every line for headings.
local function in_raw_block(lines, l)
  for i = l - 1, 1, -1 do
    local name = lines[i]:lower():match("^%s*#%+begin_(%S+)")
    if name then
      if not RAW_BLOCKS[name] then
        return false
      end
      local close = "^%s*#%+end_" .. vim.pesc(name) .. "%s*$"
      for j = l + 1, #lines do
        if lines[j]:lower():match(close) then
          return true
        elseif parser.outline_level(lines[j]) then
          return false
        end
      end
      return false
    elseif parser.outline_level(lines[i]) or lines[i]:lower():match("^%s*#%+end_") then
      return false
    end
  end
  return false
end

local function check(lines)
  local ok_, a, file = pcall(editing, lines)
  if not ok_ then
    error({ fuzz = "org.parser: " .. tostring(a) }, 0)
  end
  for i = #a, 1, -1 do
    if a[i].type == "inlinetask" and in_raw_block(lines, a[i].line) then
      table.remove(a, i)
    end
  end
  local ok2, b = pcall(export, lines, file)
  if not ok2 then
    error({ fuzz = "org.export.element: " .. tostring(b) }, 0)
  end
  if #a ~= #b then
    error({ fuzz = ("%d headlines in org.parser, %d in org.export.element"):format(#a, #b) }, 0)
  end
  for i, x in ipairs(a) do
    b[i].endless = x.endless
  end
  normalise(a)
  normalise(b)
  for i, x in ipairs(a) do
    local y = b[i]
    for _, f in ipairs(FIELDS) do
      if not vim.deep_equal(x[f], y[f]) and not known(f, x[f], y[f], x, lines) then
        error({
          fuzz = ("%s of the headline on line %d: org.parser %s, org.export.element %s"):format(
            f,
            x.line,
            vim.inspect(x[f]),
            vim.inspect(y[f])
          ),
        }, 0)
      end
    end
  end
end

--- Plain list items in document order, as org.lists reads each region
--- between two headings and as org.export.element reads the document.
--- An inline task line is no heading: a block, and a section, run over
--- it (org-element, and org.lists through the parser's sections).
local function items(lines, data)
  local lists = require("org.lists")
  local a, b = {}, {}
  local min = parser.inlinetask_min_level()
  local function heading(line)
    local level = parser.headline_level(line)
    return level ~= nil and (not min or level < min)
  end
  -- org-list-forbidden-blocks leaves comment blocks out: org-list reads
  -- items there, org-element reads the block's text as raw
  local raw = {}
  local l = 1
  while l <= #lines do
    if lines[l]:lower():match("^%s*#%+begin_comment%f[%s%z]") then
      for j = l + 1, #lines do
        if heading(lines[j]) then
          break
        elseif lines[j]:lower():match("^%s*#%+end_comment%s*$") then
          for k = l + 1, j - 1 do
            raw[k] = true
          end
          l = j
          break
        end
      end
    end
    l = l + 1
  end
  local from = 1
  for i = 1, #lines + 1 do
    if i > #lines or heading(lines[i]) then
      local _, all = lists.parse_region(lines, from, i - 1)
      for _, it in ipairs(all) do
        local c = it.counter
        a[#a + 1] = not raw[it.lnum]
            and {
              line = it.lnum,
              bullet = it.bullet,
              checkbox = it.checkbox,
              counter = c and (tonumber(c) or (c:upper():byte() - 64)),
            }
          or nil
      end
      from = i + 1
    end
  end
  E.map(data, "item", function(n)
    b[#b + 1] = {
      bullet = vim.trim(n.bullet),
      checkbox = ({ off = " ", on = "X", trans = "-" })[n.checkbox],
      counter = n.counter,
    }
  end)
  return a, b
end

--- Whether a block's #+begin_ and #+end_ lines are in different elements,
--- a drawer's :END: between them: org-list (org-in-block-p) still finds
--- the block by searching the text, org-element reads no block there.
local function straddling_block(lines)
  for i, l in ipairs(lines) do
    local name = l:lower():match("^%s*#%+begin_(%S+)")
    if name then
      local close = "^%s*#%+end_" .. vim.pesc(name) .. "%s*$"
      local drawer_end = false
      for j = i + 1, #lines do
        local lj = lines[j]:lower()
        if lj:match(close) then
          if drawer_end then
            return true
          end
          break
        end
        drawer_end = drawer_end or lj:match("^%s*:end:%s*$") ~= nil
      end
    end
  end
  return false
end

local function check_items(lines)
  if straddling_block(lines) then
    return
  end
  local file = parser.parse(lines)
  local min = parser.inlinetask_min_level()
  local data = E.parse(lines, { todo = file.settings.todo, inlinetask_min_level = min or 1000 })
  local a, b = items(lines, data)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i], b[i]
    if not x or not y then
      error({ fuzz = ("%d items in org.lists, %d in org.export.element"):format(#a, #b) }, 0)
    end
    for _, f in ipairs({ "bullet", "checkbox", "counter" }) do
      -- "[x]" is an unchecked box to org-list (and org.lists), no box to
      -- org-element (which only knows "[ ]", "[X]" and "[-]")
      local lower_x = f == "checkbox" and x[f] == " " and y[f] == nil and lines[x.line]:find("[x]", 1, true)
      if x[f] ~= y[f] and not lower_x then
        error({
          fuzz = ("%s of the item on line %d: org.lists %s, org.export.element %s"):format(
            f,
            x.line,
            vim.inspect(x[f]),
            vim.inspect(y[f])
          ),
        }, 0)
      end
    end
  end
end

local function failure(err)
  return type(err) == "table" and err.fuzz or tostring(err)
end

--- The kind of a failure to keep while shrinking: what disagreed, without
--- numbers or the values read.
local function kind(msg)
  return fuzz.kind((msg:gsub(": org%.%a+ .*", "")))
end

local function verify(seed, lines, check)
  local ok_, err = pcall(check, lines)
  if ok_ then
    return
  end
  local msg = failure(err)
  local k = kind(msg)
  local small = fuzz.shrink(lines, function(cand)
    local o, e = pcall(check, cand)
    return not o and kind(failure(e)) == k
  end)
  -- the message of the minimal input names its own line and values
  local _, e = pcall(check, small)
  error(fuzz.report(seed, msg, lines, small, "minimal: " .. failure(e)), 0)
end

local function run(fn)
  for _, seed in ipairs(SEEDS) do
    verify(seed, fuzz.doc(fuzz.rng(seed), { crlf = false }), fn)
    verify(seed, dgen.doc(seed), fn)
  end
end

describe("fuzz org.parser against org.export.element", function()
  describe("with inline tasks", function()
    with_config({ inlinetask_min_level = 15 })
    it("read headlines, planning, properties and clocks the same", function()
      run(check)
    end)
  end)

  describe("plain lists", function()
    with_config({ inlinetask_min_level = 15 })
    it("read the same items", function()
      run(check_items)
    end)
  end)

  describe("without inline tasks", function()
    with_config({ inlinetask_min_level = false })
    it("read headlines, planning, properties and clocks the same", function()
      run(check)
    end)
  end)
end)
