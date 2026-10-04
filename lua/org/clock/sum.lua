---@mod org.clock.sum Clock sums (org-clock-sum)
---
--- Minutes clocked per headline within a range, clipped to its bounds,
--- with the running clock optionally counted.
---
--- Part of org.clock, which loads it.

local date = require("org.date")
local shared = require("org.clock.shared")

local M = require("org.clock")

local at_minutes = shared.at_minutes
local clock_cfg = shared.clock_cfg

--- The running clock's headline, if it is in `file`: its line and start.
local function running_in(file)
  if not M.state or not file.filename or vim.fs.normalize(file.filename) ~= vim.fs.normalize(M.state.path) then
    return nil
  end
  local start = date.parse(M.state.start)
  for _, hl in ipairs(file.headlines) do
    for _, c in ipairs(hl.clocks) do
      if not c["end"] and start and c.start:minutes() == start:minutes() then
        return hl, start
      end
    end
  end
end

--- Report bounds use civil minutes; convert them to local instants before
--- clipping so a clock spanning a DST change retains its real duration.
---@return number|nil from_s, number|nil to_s the bounds as local instants
local function clip_bounds(from_min, to_min)
  return from_min and at_minutes(from_min):to_time(), to_min and at_minutes(to_min):to_time()
end

--- Minutes of a clock within the bounds from `clip_bounds`.
local function clipped_clock_minutes(start, stop, from_s, to_s)
  local s, e = start:to_time(), stop:to_time()
  if from_s and from_s > s then
    s = from_s
  end
  if to_s and to_s < e then
    e = to_s
  end
  return math.max(0, math.floor((e - s) / 60))
end

--- Clock sums of a file (org-clock-sum): for each headline in the scanned
--- region, the minutes clocked in its subtree within [ts, te). With a
--- matcher, only matching entries contribute their own clocks, and their
--- ancestors are listed to show them.
---@return table<org.Headline, integer> times listed headlines and their time
---@return integer total
local function clock_sum(roots, ts, te, pred)
  local times, total = {}, 0
  local include_running = clock_cfg().report_include_clocking_task
  local run_hl, run_start
  if include_running and ts and te and roots[1] then
    run_hl, run_start = running_in(roots[1].file)
  end
  local ts_s, te_s = clip_bounds(ts, te)
  local function own(hl)
    local t = 0
    for _, c in ipairs(hl.clocks) do
      if c["end"] then
        t = t + clipped_clock_minutes(c.start, c["end"], ts_s, te_s)
      end
    end
    if hl == run_hl and run_start:minutes() >= ts and run_start:minutes() <= te then
      t = t + math.max(0, date.elapsed_minutes(run_start, date.now()))
    end
    return t
  end
  -- returns the subtree's time and whether a listed descendant forces
  -- the headline into the table
  local function visit(hl)
    local sub, forced = 0, false
    for _, child in ipairs(hl.children) do
      local ct, cl = visit(child)
      sub = sub + ct
      forced = forced or cl
    end
    local included = not pred or pred(hl)
    local t1 = own(hl)
    local time = sub + (included and t1 or 0)
    local listed = (t1 > 0 or sub > 0) and (included or (pred ~= nil and forced))
    if listed then
      times[hl] = time
    end
    if included then
      total = total + t1
    end
    return time, listed
  end
  for _, hl in ipairs(roots) do
    visit(hl)
  end
  return times, total
end

--- Minutes clocked in a headline subtree, clipped to [from_min, to_min).
---@param hl org.Headline
---@param from_min? integer
---@param to_min? integer
---@param own_only? boolean exclude children
function M.sum_minutes(hl, from_min, to_min, own_only)
  if own_only then
    local total = 0
    local from_s, to_s = clip_bounds(from_min, to_min)
    for _, c in ipairs(hl.clocks) do
      if c["end"] then
        total = total + clipped_clock_minutes(c.start, c["end"], from_s, to_s)
      end
    end
    return total
  end
  local times = clock_sum({ hl }, from_min, to_min)
  return times[hl] or 0
end

-- for the parts loaded after this one
shared.clock_sum = clock_sum
