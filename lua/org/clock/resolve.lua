---@mod org.clock.resolve Resolving open and idle clocks (org-resolve-clocks)
---
--- Find dangling clocks and ask how to resolve them, or the idle time
--- of the running clock.
---
--- Part of org.clock, which loads it.

local date = require("org.date")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local at_instant = shared.at_instant
local buf_path = shared.buf_path
local clock_cfg = shared.clock_cfg
local delete_clock_line = shared.delete_clock_line
local instant_minutes = shared.instant_minutes
local mark_ns = shared.mark_ns
local mode_line_heading = shared.mode_line_heading
local now_minutes = shared.now_minutes
local persist = shared.persist
local start_timers = shared.start_timers
local unnamed = shared.unnamed

---------------------------------------------------------------------------
-- Resolving open clocks
---------------------------------------------------------------------------

--- Open CLOCK lines in the agenda files and loaded org buffers:
--- list of { bufnr, lnum, start, title, active }. The running clock is
--- included only with `with_active`.
function M.dangling_clocks(with_active)
  local out, seen = {}, {}
  local running_buf, running_lnum = M.find_open_clock()
  local function scan(bufnr)
    if seen[bufnr] then
      return
    end
    seen[bufnr] = true
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      local c = l:find("CLOCK:", 1, true) and parser.parse_clock_line(l)
      local active = bufnr == running_buf and i == running_lnum
      if c and not c["end"] and (with_active or not active) then
        local hl = files.get_buffer(bufnr):headline_at(i)
        out[#out + 1] = {
          bufnr = bufnr,
          lnum = i,
          start = c.start,
          title = hl and hl:plain_title() or "?",
          active = active,
        }
      end
    end
  end
  for _, f in ipairs(files.agenda_files()) do
    if f.filename and utils.exists(f.filename) then
      scan(utils.load_buffer(f.filename))
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      scan(b)
    end
  end
  return out
end

--- Close the open CLOCK line of `clock` at `stop` (Unix minutes).
--- `stop` in Unix minutes; nil clocks out now, rounded like a plain clock
--- out (org-clock-clock-out passes no time, org-clock-rounding-minutes).
local function close_clock(clock, stop)
  local at = stop and at_instant(stop) or nil
  if clock.active then
    return M.clock_out({ at = at, quiet = true })
  end
  -- like org-with-clock: clock out of the dangling clock as if it were the
  -- running one (state switch, note, 0:00 removal), then restore the
  -- running clock
  local lnum = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, clock.mark, {})[1] + 1
  local hl = files.get_buffer(clock.bufnr):headline_at(lnum)
  local saved = M.state
  M.state = {
    path = buf_path(clock.bufnr) or "",
    bufnr = unnamed(clock.bufnr),
    start = clock.start:clone({ active = false }):to_string({ range = false }),
    title = hl and mode_line_heading(hl) or "?",
  }
  local ok, err = pcall(M.clock_out, { at = at, quiet = true })
  M.state = saved
  if saved then
    persist()
    start_timers()
  end
  if not ok then
    error(err, 0)
  end
end

--- Apply a resolution to an open clock (org-clock-resolve-clock).
--- `to` is nil (cancel), "now", or a time in Unix minutes.
local function resolve_clock(clock, to, out_time, close, restart, ctx)
  local head = clock.head
  local function heading_target()
    local l = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, head, {})[1] + 1
    return { bufnr = clock.bufnr, lnum = l }
  end
  if to == nil then
    if clock.active then
      M.clock_cancel()
    else
      local lnum = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, clock.mark, {})[1] + 1
      delete_clock_line(clock.bufnr, lnum)
    end
    if restart and not ctx.clocking_in then
      M.clock_in(heading_target(), { no_count = true, clocking_in = true })
    end
  elseif to == "now" then
    if close or ctx.clocking_in then
      close_clock(clock)
    elseif not clock.active then
      M.clock_in(heading_target(), { resume = true, no_count = true, clocking_in = true })
    end
  else
    if to > now_minutes() then
      error("Clock resolution must refer to a time in the past", 0)
    end
    close_clock(clock, out_time or to)
    if ctx.clocking_in then
      return
    elseif close then
      M.leftover = not out_time and at_instant(to):minutes() or nil
    else
      M.clock_in(heading_target(), {
        at = out_time and at_instant(to) or nil,
        no_count = true,
        clocking_in = true,
        resolving_idle = ctx.idle,
      })
    end
  end
end

--- Ask how to resolve an open clock (org-clock-resolve). `clock` is
--- `{ bufnr, lnum, start, active }`, `prompt` a function returning the
--- question, `last_valid` (civil minutes) the last time the clock was known to be
--- valid (its start for a dangling clock, the start of the idle time).
---
--- Keys: k/K keep N minutes, t/T keep until a time, g/G got back N minutes
--- ago, s/S subtract the idle time, C cancel, j/J jump, i/q ignore.
--- Uppercase leaves the clock stopped.
---@param opts? { clocking_in?: boolean, idle?: boolean, last_valid_time?: number }
function M.resolve(clock, prompt, last_valid, opts)
  opts = opts or {}
  -- Idle detection already knows the exact instant; retain it through
  -- repeated local times during the autumn DST transition.
  last_valid = opts.last_valid_time and opts.last_valid_time / 60 or instant_minutes(last_valid)
  local ui = require("org.ui")
  clock.mark = vim.api.nvim_buf_set_extmark(clock.bufnr, mark_ns, clock.lnum - 1, 0, {})
  local hl = files.get_buffer(clock.bufnr):headline_at(clock.lnum)
  clock.head = vim.api.nvim_buf_set_extmark(clock.bufnr, mark_ns, (hl and hl.line or clock.lnum) - 1, 0, {})
  shared.resolving = true
  local ok, err = pcall(function()
    local title = prompt(clock) .. (hl and (": " .. hl:plain_title()) or "")
    local ch
    if clock_cfg().resolve_expert then
      -- org-clock-resolve-expert: no help window, just the prompt
      repeat
        ch = utils.getchar(title .. " [jkKtTgGSscCiq]? ")
      until ch == nil or ("jJkKtTgGsSCiq"):find(ch, 1, true)
    else
      ch = ui.menu({
        title = title,
        items = {
          { key = "k", label = "Keep X minutes of the idle time (default all), stay clocked in", value = "k" },
          { key = "K", label = "Keep X minutes, then clock out", value = "K" },
          { key = "t", label = "Keep the time until a given time, stay clocked in", value = "t" },
          { key = "T", label = "Keep the time until a given time, then clock out", value = "T" },
          { key = "g", label = "Got back X minutes ago (clock in again from then)", value = "g" },
          { key = "G", label = "Got back X minutes ago, stay clocked out", value = "G" },
          { key = "s", label = "Subtract the idle time, clock in again now", value = "s" },
          { key = "S", label = "Subtract the idle time, then clock out", value = "S" },
          { key = "C", label = "Cancel the clock altogether", value = "C" },
          { key = "j", label = "Jump to the clock", value = "j" },
          { key = "J", label = "Clock out now and jump to the clock", value = "J" },
          { key = "i", label = "Ignore (keep all the idle time)", value = "i" },
          { key = "q", label = "Quit", value = "q" },
        },
      })
    end
    if ch == nil or ch == "i" or ch == "q" then
      return
    end
    local now = now_minutes()
    local default = math.floor(now - last_valid)
    local keep, gotback
    if ch == "k" or ch == "K" then
      local v = utils.input({ prompt = string.format("Keep how many minutes (default %d): ", default) })
      if v == nil then
        return
      end
      keep = tonumber(vim.trim(v)) or default
    elseif ch == "t" or ch == "T" then
      local v = utils.input({ prompt = "Keep until (date/time): " })
      local d = v and v ~= "" and date.read_date(v, at_instant(last_valid):start_of("day"))
      if not d then
        return
      end
      keep = math.floor(d:to_time() / 60 - last_valid)
    elseif ch == "g" or ch == "G" then
      local v = utils.input({ prompt = string.format("Got back how many minutes ago (default %d): ", default) })
      if v == nil then
        return
      end
      gotback = tonumber(vim.trim(v)) or default
    end
    if ch == "j" or ch == "J" then
      if ch == "J" then
        resolve_clock(clock, "now", nil, true, false, opts)
      end
      local lnum = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, clock.mark, {})[1] + 1
      utils.open_file(vim.api.nvim_buf_get_name(clock.bufnr), lnum)
      return
    end
    local subtract = ch == "s" or ch == "S"
    -- less than 45 seconds on the clock before going away
    local barely_started = (last_valid - clock.start:to_time() / 60) < 0.75
    local start_over = subtract and barely_started
    local to
    if ch == "C" or start_over then
      to = nil
    elseif subtract or gotback == 0 then
      to = last_valid
    elseif keep == default or gotback == default then
      to = "now"
    elseif keep then
      to = last_valid + keep
    elseif gotback then
      to = now - gotback
    end
    local close = ch == "K" or ch == "G" or ch == "S" or ch == "T"
    local restart = start_over and not (ch == "K" or ch == "G" or ch == "S" or ch == "C")
    resolve_clock(clock, to, gotback and last_valid or nil, close, restart, opts)
  end)
  shared.resolving = false
  vim.api.nvim_buf_del_extmark(clock.bufnr, mark_ns, clock.mark)
  vim.api.nvim_buf_del_extmark(clock.bufnr, mark_ns, clock.head)
  if not ok then
    error(err, 0)
  end
  -- idle resolution stopped the timers only when clocking out
  if M.state and not shared.timers_running() then
    start_timers()
  end
  return true
end

--- Resolve open clocks in the agenda files and org buffers
--- (org-resolve-clocks). Interactively a count limits this to dangling
--- clocks (not the running one).
---@param only_dangling? boolean
---@param opts? { clocking_in?: boolean, quiet?: boolean }
function M.resolve_clocks(only_dangling, opts)
  if only_dangling == nil and type(opts) ~= "table" then
    only_dangling = vim.v.count > 0
  end
  opts = type(opts) == "table" and opts or {}
  if shared.resolving then
    return true
  end
  local list = M.dangling_clocks(not only_dangling)
  if #list == 0 then
    if not opts.quiet then
      utils.notify("No open clocks to resolve")
    end
    return true
  end
  for _, d in ipairs(list) do
    d.mark = vim.api.nvim_buf_set_extmark(d.bufnr, mark_ns, d.lnum - 1, 0, {})
  end
  for _, d in ipairs(list) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(d.bufnr, mark_ns, d.mark, {})
    vim.api.nvim_buf_del_extmark(d.bufnr, mark_ns, d.mark)
    local line = pos[1] and vim.api.nvim_buf_get_lines(d.bufnr, pos[1], pos[1] + 1, false)[1]
    local c = line and parser.parse_clock_line(line)
    if c and not c["end"] then
      d.lnum = pos[1] + 1
      d.active = d.active and M.state ~= nil
      local ok, err = pcall(M.resolve, d, function(clock)
        return string.format("Dangling clock started %d mins ago", date.elapsed_minutes(clock.start, date.now()))
      end, d.start:minutes(), opts)
      if not ok then
        utils.error(tostring(err))
        return false
      end
    end
  end
  return true
end
