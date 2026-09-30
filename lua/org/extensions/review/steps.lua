---@mod org.extensions.review.steps Builtin steps of the weekly review
---
--- A step is a table:
---
---   name         identifier (used by `:Org review <name>` and the state file)
---   title        shown in the header
---   description  one line under the header
---   items        `function(ctx) -> item[]`: the entries the step lists
---   lines        `function(ctx) -> string[]`: extra text above the items
---   questions    list of questions answered with notes (the reflect step)
---   keys         `{ lhs = function(item, session) }`: keys of this step only
---
--- An item is `{ hl = org.Headline, path = string, lnum = integer, info? =
--- string }` (or `{ text = string }` for a line that is not an entry).
--- `ctx` has `opts` (the extension's options), `today` and `now` (org.date),
--- `files` (the agenda files) and `state` (the saved review state).

local date = require("org.date")

local M = {}

local function item(hl, info)
  return { hl = hl, path = hl.file.filename, lnum = hl.line, info = info }
end

local function each(ctx, fn)
  require("org.agenda.items").each_headline(ctx.files, {}, fn)
end

local function set(list)
  local out = {}
  for _, v in ipairs(list or {}) do
    out[v] = true
  end
  return out
end

--- Files holding the inbox: `inbox` (a path or list), else `default_notes_file`.
---@return string[]
function M.inbox_paths(opts)
  local config = require("org.config")
  local utils = require("org.utils")
  local inbox = opts.inbox
  if inbox == nil or inbox == "" then
    inbox = config.opts.default_notes_file
  end
  local out = {}
  for _, p in ipairs(type(inbox) == "table" and inbox or { inbox }) do
    out[#out + 1] = utils.expand(p)
  end
  return out
end

--- Short relative-day text: "today", "in 3 d", "5 d ago".
local function rel(days)
  if days == 0 then
    return "today"
  elseif days == 1 then
    return "tomorrow"
  elseif days == -1 then
    return "yesterday"
  elseif days > 0 then
    return string.format("in %d d", days)
  end
  return string.format("%d d ago", -days)
end
M.rel = rel

M.builtin = {}

M.builtin.inbox = {
  title = "Empty the inbox",
  description = "Process every entry: refile, schedule, set a TODO state, delete or skip it.",
  items = function(ctx)
    local files = require("org.files")
    local out = {}
    for _, path in ipairs(M.inbox_paths(ctx.opts)) do
      local f = files.get(path)
      for _, hl in ipairs(f and f.children or {}) do
        out[#out + 1] = item(hl)
      end
    end
    return out
  end,
}

M.builtin.stuck = {
  title = "Stuck projects",
  description = "Projects without a next action (agenda.stuck_projects). Give each one a next step.",
  items = function(ctx)
    local ok, list = pcall(require("org.agenda.items").stuck, ctx.files, {})
    if not ok then
      return { { text = tostring(list) } }
    end
    local out = {}
    for _, it in ipairs(list) do
      if it.headline then
        out[#out + 1] = item(it.headline)
      end
    end
    return out
  end,
}

M.builtin.waiting = {
  title = "Waiting for",
  description = "Delegated and blocked entries. Follow up, or change their state.",
  items = function(ctx)
    local kws = set(ctx.opts.waiting_keywords)
    local out = {}
    each(ctx, function(hl)
      if hl.todo and kws[hl.todo] then
        out[#out + 1] = item(hl)
      end
    end)
    return out
  end,
}

M.builtin.overdue = {
  title = "Overdue",
  description = "Open entries scheduled or due before today. Reschedule, do or drop them.",
  items = function(ctx)
    local today = ctx.today:days()
    local out = {}
    each(ctx, function(hl)
      if not hl:is_todo() then
        return
      end
      local worst, what
      for _, kind in ipairs({ "deadline", "scheduled" }) do
        local ts = hl.planning[kind]
        if ts and ts:days() < today and (not worst or ts:days() < worst) then
          worst, what = ts:days(), kind
        end
      end
      if worst then
        local it = item(hl, string.format("%s %s", what == "deadline" and "due" or "scheduled", rel(worst - today)))
        it.sort = worst
        out[#out + 1] = it
      end
    end)
    table.sort(out, function(a, b)
      return a.sort < b.sort
    end)
    return out
  end,
}

M.builtin.upcoming = {
  title = "Coming up",
  description = "Scheduled, due and dated entries of the next days. Prepare for them.",
  items = function(ctx)
    local from = ctx.today:days()
    local to = from + (tonumber(ctx.opts.upcoming_days) or 14) - 1
    local out = {}
    each(ctx, function(hl)
      if hl:is_done() then
        return
      end
      local first, what
      local function consider(ts, kind)
        if not ts or not ts.active then
          return
        end
        local occ = date.occurrences(ts, from, to)[1]
        if occ and (not first or occ:days() < first:days()) then
          first, what = occ, kind
        end
      end
      consider(hl.planning.deadline, "due")
      consider(hl.planning.scheduled, "scheduled")
      for _, t in ipairs(hl.timestamps or {}) do
        consider(t.date, "")
      end
      if first then
        local when = string.format("%s %s", first:dayname(), first:to_date_string():sub(6))
        if first.hour then
          when = when .. " " .. first:time_string()
        end
        local it = item(hl, vim.trim(when .. " " .. what))
        it.sort = first:days() * 1440 + (first.hour or 0) * 60 + (first.min or 0)
        out[#out + 1] = it
      end
    end)
    table.sort(out, function(a, b)
      return a.sort < b.sort
    end)
    return out
  end,
}

M.builtin.someday = {
  title = "Someday / maybe",
  description = "Ideas on hold. Activate the ones whose time has come, drop the stale ones.",
  items = function(ctx)
    local s = ctx.opts.someday or {}
    local tags, kws = set(s.tags), set(s.keywords)
    local out = {}
    each(ctx, function(hl)
      if hl:is_done() then
        return
      end
      local hit = hl.todo and kws[hl.todo]
      for _, t in ipairs(hl.tags) do
        hit = hit or tags[t]
      end
      if hit then
        out[#out + 1] = item(hl)
      end
    end)
    return out
  end,
}

--- Minutes clocked per entry in the `days` before `now`: list of
--- { hl, minutes } by time spent, and the total.
function M.clock_summary(files, now, days)
  local to = now:minutes()
  local from = to - days * 1440
  local out, total = {}, 0
  require("org.agenda.items").each_headline(files, { all = true }, function(hl)
    local m = hl:clocked_minutes(from, to, false)
    if m > 0 then
      out[#out + 1] = { hl = hl, minutes = m }
      total = total + m
    end
  end)
  table.sort(out, function(a, b)
    return a.minutes > b.minutes
  end)
  return out, total
end

M.builtin.clock = {
  title = "Time spent",
  description = "Where the time of the past week went (closed clocks).",
  lines = function(ctx)
    local days = tonumber(ctx.opts.clock_days) or 7
    local _, total = M.clock_summary(ctx.files, ctx.now, days)
    return { string.format("Clocked in the last %d days: %s", days, date.format_duration(total)) }
  end,
  items = function(ctx)
    local list = M.clock_summary(ctx.files, ctx.now, tonumber(ctx.opts.clock_days) or 7)
    local out = {}
    for i, e in ipairs(list) do
      if i > (tonumber(ctx.opts.clock_top) or 10) then
        break
      end
      out[#out + 1] = item(e.hl, date.format_duration(e.minutes))
    end
    return out
  end,
}

M.builtin.reflect = {
  title = "Reflect",
  description = "Answer each question (<CR>); the answers go into the review log.",
  reflect = true,
}

M.order = { "inbox", "stuck", "waiting", "overdue", "upcoming", "someday", "clock", "reflect" }

--- Resolve the `steps` option into step tables: builtin names, `{ "name",
--- overrides... }`, custom step tables and functions (the step's `items`).
---@param list any[]
---@return table[] steps, string[] errors
function M.resolve(list)
  local out, errors = {}, {}
  for i, s in ipairs(list or M.order) do
    local step
    if type(s) == "string" then
      step = M.builtin[s] and vim.tbl_extend("force", { name = s }, M.builtin[s])
      if not step then
        errors[#errors + 1] = "unknown review step: " .. s
      end
    elseif type(s) == "function" then
      step = { name = "step" .. i, title = "Step " .. i, items = s }
    elseif type(s) == "table" then
      local base = type(s[1]) == "string" and M.builtin[s[1]]
      if type(s[1]) == "string" and not base then
        errors[#errors + 1] = "unknown review step: " .. s[1]
      else
        step = vim.tbl_extend("force", { name = s[1] or ("step" .. i), title = s[1] or ("Step " .. i) }, base or {}, s)
        step[1] = nil
        if base then
          step.name = s.name or s[1]
        end
      end
    else
      errors[#errors + 1] = "invalid review step #" .. i
    end
    if step then
      out[#out + 1] = step
    end
  end
  return out, errors
end

return M
