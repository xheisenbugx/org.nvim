---@mod org.extensions.lsp.diagnostics org-lint reports as diagnostics
---
--- A buffer is linted in slices: the document is parsed in one step, then
--- the checkers run a few milliseconds at a time on later event-loop
--- ticks, so typing isn't held up for the whole lint of a large buffer.

local util = require("org.extensions.lsp.util")

local M = {}

local SEVERITY = { error = 1, warning = 2, information = 3, info = 3, hint = 4 }

--- Milliseconds of checkers run per event-loop tick.
M.SLICE_MS = 12

local function severity(name)
  if type(name) == "number" then
    return name
  end
  return SEVERITY[tostring(name):lower()] or 2
end

--- The checkers to run: `diagnostics.checkers` (default: org-lint's
--- default set) minus `diagnostics.exclude`.
---@return string[]
function M.checkers()
  local lint = require("org.lint")
  local o = util.opts().diagnostics or {}
  local names = o.checkers or lint.checker_names()
  local skip = {}
  for _, n in ipairs(o.exclude or {}) do
    skip[n] = true
  end
  return vim.tbl_filter(function(n)
    return not skip[n]
  end, names)
end

-- Diagnostics of org-lint reports (sorted by position) on `lines`.
local function to_diagnostics(reports, lines)
  local sev = (util.opts().diagnostics or {}).severity or {}
  local out = {}
  for _, r in ipairs(reports) do
    local lnum = math.max(1, math.min(r.lnum, #lines))
    local line = lines[lnum] or ""
    local col = math.max(1, math.min(r.col, #line + 1))
    -- up to the end of the word at the column (or the line)
    local e = line:find("%s", col) or (#line + 1)
    if e <= col then
      e = #line + 1
    end
    local s_ = (sev.checkers or {})[r.checker] or (r.trust == "low" and sev.low or sev.high)
    out[#out + 1] = {
      range = { start = util.pos(lnum, col), ["end"] = util.pos(lnum, e) },
      severity = severity(s_ or (r.trust == "low" and "Warning" or "Error")),
      source = "org-lint",
      code = r.checker,
      message = r.message:gsub("%s*\n%s*", " "),
      data = { checker = r.checker, lnum = r.lnum, col = r.col },
    }
  end
  return out
end

--- A lint of a buffer done in steps: `step(budget_ms)` works for about
--- that long and returns the diagnostics once every checker has run (nil
--- before). The first step parses the document.
---@param bufnr integer
---@return fun(budget_ms?: number): table[]|nil
function M.job(bufnr)
  local lint = require("org.lint")
  local uv = vim.uv or vim.loop
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local names = M.checkers()
  -- org-lint runs its checkers in reverse registration order: keep it for
  -- reports on the same position
  local rank = {}
  for i, c in ipairs(lint.checkers) do
    rank[c[1]] = -i
  end
  table.sort(names, function(a, b)
    return (rank[a] or 0) < (rank[b] or 0)
  end)
  local doc, map, objects
  local i, reports = 0, {}
  return function(budget)
    local stop = uv.hrtime() + (budget or math.huge) * 1e6
    if not doc then
      -- text the transclusion extension inserted belongs to its source:
      -- lint the buffer without it and map the reports back
      local foreign = util.foreign(bufnr)
      local own
      if foreign then
        own, map = {}, {}
        for n, l in ipairs(lines) do
          if not foreign[n] then
            own[#own + 1] = l
            map[#own] = n
          end
        end
      end
      -- the elements now, the objects on the next step
      doc = lint.document(bufnr, own, budget ~= nil)
      objects = budget == nil
      if budget then
        return nil
      end
    elseif not objects then
      doc:collect_objects()
      objects = true
      return nil
    elseif i < #names then
      -- at least one checker per step
      i = i + 1
      vim.list_extend(reports, lint.check(doc, { names[i] }))
    end
    while i < #names and uv.hrtime() < stop do
      i = i + 1
      vim.list_extend(reports, lint.check(doc, { names[i] }))
    end
    if i < #names then
      return nil
    end
    for k, r in ipairs(reports) do
      r._i = k
      if map then
        r.lnum = map[r.lnum] or map[#map] or 1
      end
    end
    table.sort(reports, function(a, b)
      if a.lnum ~= b.lnum then
        return a.lnum < b.lnum
      end
      if a.col ~= b.col then
        return a.col < b.col
      end
      return a._i < b._i
    end)
    return to_diagnostics(reports, lines)
  end
end

--- Diagnostics of a buffer (all at once).
---@param bufnr integer
---@return table[] Diagnostic[]
function M.compute(bufnr)
  return M.job(bufnr)()
end

--- Debounced publisher: `schedule(bufnr, delay?, on_change?)` lints the
--- buffer after `diagnostics.debounce` ms without changes (longer when the
--- last lint took long) and calls `publish(uri, diagnostics)`. A buffer is
--- not linted again at the same changedtick, and a buffer longer than
--- `diagnostics.max_lines` is not linted on changes, only when opened and
--- written. A lint runs in slices; a change meanwhile starts it over.
---@param publish fun(uri: string, diagnostics: table[])
function M.scheduler(publish)
  local uv = vim.uv or vim.loop
  local timers = {}
  -- changedtick linted last, how long that took (ms), and the lint in
  -- progress, per buffer
  local linted, cost, running = {}, {}, {}
  local self = {}

  local function fail(bufnr, err)
    publish(vim.uri_from_bufnr(bufnr), {
      {
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        severity = 1,
        source = "org-lint",
        message = "org-lint failed: " .. tostring(err),
      },
    })
  end

  function self.cancel(bufnr)
    local t = timers[bufnr]
    if t then
      timers[bufnr] = nil
      if not t:is_closing() then
        t:stop()
        t:close()
      end
    end
    running[bufnr] = nil
  end

  --- Lint `bufnr` now; with `sync`, in one go (else in slices).
  function self.run(bufnr, sync)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    if linted[bufnr] == tick then
      return
    end
    local ok, job = pcall(M.job, bufnr)
    if not ok then
      linted[bufnr] = tick
      return fail(bufnr, job)
    end
    local me = {}
    running[bufnr] = me
    local spent = 0
    local function step()
      if running[bufnr] ~= me then
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
        -- changed meanwhile: the didChange that follows schedules a lint
        running[bufnr] = nil
        return
      end
      local t0 = uv.hrtime()
      local okj, diags = pcall(job, not sync and M.SLICE_MS or nil)
      spent = spent + (uv.hrtime() - t0) / 1e6
      if okj and not diags then
        vim.schedule(step)
        return
      end
      running[bufnr] = nil
      linted[bufnr], cost[bufnr] = tick, spent
      if not okj then
        return fail(bufnr, diags)
      end
      publish(vim.uri_from_bufnr(bufnr), diags)
    end
    step()
  end

  --- Lint `bufnr` after `delay` ms (default: the debounce). `on_change`:
  --- the buffer was edited (large buffers wait for a write).
  function self.schedule(bufnr, delay, on_change)
    local o = util.opts().diagnostics or {}
    local max = o.max_lines
    if on_change and max and max > 0 and vim.api.nvim_buf_line_count(bufnr) > max then
      return
    end
    self.cancel(bufnr)
    if not delay then
      -- never lint more than about a third of the time while typing
      delay = math.max(o.debounce or 500, math.floor(2 * (cost[bufnr] or 0)))
    end
    local t = uv.new_timer()
    timers[bufnr] = t
    t:start(
      delay,
      0,
      vim.schedule_wrap(function()
        if timers[bufnr] ~= t then
          return
        end
        timers[bufnr] = nil
        if not t:is_closing() then
          t:close()
        end
        self.run(bufnr)
      end)
    )
  end

  function self.clear(bufnr)
    self.cancel(bufnr)
    linted[bufnr], cost[bufnr] = nil, nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      publish(vim.uri_from_bufnr(bufnr), {})
    end
  end

  function self.stop()
    for b in pairs(timers) do
      self.cancel(b)
    end
    linted, cost, running = {}, {}, {}
  end

  return self
end

return M
