---@mod org.babel.jobs Running evaluations: spinner and cancelling
---
--- Every interactive evaluation that runs in the background (C-c C-c,
--- executing the buffer or a subtree) is a job here while it runs. A job
--- shows an animated spinner as virtual text at the end of its block's
--- first line (an extmark: the buffer is never changed for it) and can be
--- cancelled (`:Org babel_cancel`), which kills its process or interrupts
--- its session. Jobs of a buffer are cancelled when the buffer is unloaded,
--- and every job when Neovim exits.
---
--- While a job's process runs, what it prints so far is shown as virtual
--- lines below the block (`babel.live_output`, see `M.stream`): the last
--- lines only, redrawn at most every `M.LIVE_REDRAW_MS`, from at most
--- `M.LIVE_BYTES` of output kept. They go away when the job ends.
---
--- Synchronous evaluations (export, `:var` references, table formulas,
--- org.api callers) never become jobs.

local utils = require("org.utils")

local M = {}

M.ns = vim.api.nvim_create_namespace("org.babel.jobs")
--- the live output below running blocks
M.live_ns = vim.api.nvim_create_namespace("org.babel.jobs.live")

--- Bytes of output kept for the live view (the tail; the result itself
--- keeps everything).
M.LIVE_BYTES = 16384
--- Least milliseconds between two redraws of a live view (20 per second).
M.LIVE_REDRAW_MS = 50
--- Longest line shown in a live view, in characters.
M.LIVE_LINE_CHARS = 300

---@class org.babel.Job
---@field id integer
---@field bufnr integer
---@field mark integer extmark of the spinner (at the block's first line)
---@field lang? string
---@field name? string
---@field started integer `vim.uv.now()` at the start
---@field cancelled? boolean
---@field finished? boolean
---@field kill? fun() stops the process or session request, set by the runner
---@field on_cancel? fun(job: org.babel.Job, opts: org.babel.CancelOpts) puts the cancellation in the buffer
---@field live? org.babel.LiveOutput the output so far, when `babel.live_output` is on

---@class org.babel.LiveOutput
---@field mark integer extmark (in `M.live_ns`) on the block's last line
---@field max integer lines shown
---@field tail string the last `M.LIVE_BYTES` of output
---@field cut boolean output was dropped before `tail`
---@field newlines integer newlines in the whole output
---@field open boolean the output does not end with a newline
---@field drawn number `vim.uv.now()` of the last redraw
---@field pending? boolean a redraw is scheduled

---@class org.babel.CancelOpts
---@field quiet? boolean no message
---@field unloading? boolean the job's buffer is being unloaded: don't change it

---@type table<integer, org.babel.Job>
M.running = {}

local next_id = 0
local timer
local frame = 0
local autocmds = false

M.LABEL = "executing…"

local function spinner_frames()
  local s = require("org.config").opts.babel.spinner
  if s == false or type(s) ~= "table" or #s == 0 then
    return nil
  end
  return s
end

local function label(job)
  local frames = spinner_frames()
  local text = M.LABEL
  local secs = math.floor((vim.uv.now() - job.started) / 1000)
  if secs >= 1 then
    text = string.format("%s %ds", text, secs)
  end
  if frames then
    text = frames[frame % #frames + 1] .. " " .. text
  end
  return "  " .. text
end

--- Lines shown in a live view, or nil when it is off.
local function live_max()
  local n = require("org.config").opts.babel.live_output
  if type(n) ~= "number" or n < 1 then
    return nil
  end
  return math.floor(n)
end

--- `line` as plain text for virtual text: after a carriage return only
--- what follows it shows (a progress bar), escape sequences (colours) go,
--- tabs are expanded, other control characters are dropped, and it is
--- cut at `M.LIVE_LINE_CHARS` characters.
local function clean(line)
  if #line > M.LIVE_LINE_CHARS * 4 then
    line = line:sub(1, M.LIVE_LINE_CHARS * 4)
  end
  if line:find("\r", 1, true) then
    local last = ""
    for part in line:gmatch("[^\r]+") do
      last = part
    end
    line = last
  end
  line = line:gsub("\27%[[0-?]*[ -/]*[@-~]", ""):gsub("\27[@-_]", "")
  if line:find("\t", 1, true) then
    local out, width = {}, 0
    for text, tab in line:gmatch("([^\t]*)(\t?)") do
      out[#out + 1] = text
      width = width + vim.fn.strdisplaywidth(text)
      if tab ~= "" then
        local n = 8 - width % 8
        out[#out + 1] = string.rep(" ", n)
        width = width + n
      end
    end
    line = table.concat(out)
  end
  line = line:gsub("[%z\1-\31\127]", "")
  if vim.fn.strchars(line) > M.LIVE_LINE_CHARS then
    line = vim.fn.strcharpart(line, 0, M.LIVE_LINE_CHARS) .. "…"
  end
  return line
end

--- The virtual lines of the live view of `job`: a header (spinner,
--- seconds, how many lines there are when some are hidden) and the last
--- lines of output; nil before any output.
---@param job org.babel.Job
---@return [string, string][][]?
function M.live_lines(job)
  local live = job.live
  if not live or live.tail == "" then
    return nil
  end
  local lines = vim.split(live.tail, "\n", { plain = true })
  if not live.open then
    -- the empty text after the last newline
    lines[#lines] = nil
  end
  if live.cut then
    -- the first line kept is only the end of a line
    table.remove(lines, 1)
  end
  if #lines == 0 then
    return nil
  end
  local first = math.max(1, #lines - live.max + 1)
  local shown = #lines - first + 1
  local total = live.newlines + (live.open and 1 or 0)
  local head = "output"
  local secs = math.floor((vim.uv.now() - job.started) / 1000)
  if secs >= 1 then
    head = string.format("%s %ds", head, secs)
  end
  if total > shown then
    head = string.format("%s, last %d of %d lines", head, shown, total)
  end
  local frames = spinner_frames()
  if frames then
    head = frames[frame % #frames + 1] .. " " .. head
  end
  local out = { { { "  " .. head, "OrgBabelRunning" } } }
  for k = first, #lines do
    out[#out + 1] = { { "  │ ", "OrgBabelRunning" }, { clean(lines[k]), "OrgBabelOutput" } }
  end
  return out
end

--- Redraw the live view of `job` below its block's last line.
---@param job org.babel.Job
local function draw_live(job)
  local live = job.live
  if not live or job.finished or not vim.api.nvim_buf_is_valid(job.bufnr) then
    return
  end
  live.drawn = vim.uv.now()
  local virt = M.live_lines(job)
  if not virt then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(job.bufnr, M.live_ns, live.mark, {})
  if not pos[1] then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, job.bufnr, M.live_ns, pos[1], 0, { id = live.mark, virt_lines = virt })
end

--- Redraw the live view of `job` now, or later when it was redrawn less
--- than `M.LIVE_REDRAW_MS` ago.
---@param job org.babel.Job
local function flush(job)
  local live = job.live
  if not live then
    return
  end
  live.pending = false
  if job.finished then
    return
  end
  local wait = M.LIVE_REDRAW_MS - (vim.uv.now() - live.drawn)
  if wait > 0 then
    live.pending = true
    vim.defer_fn(function()
      flush(job)
    end, math.ceil(wait))
    return
  end
  draw_live(job)
end

--- Add `data` (what the process printed) to the live view of `job`. May
--- be called from a `vim.system` callback (a fast event): the redraw is
--- scheduled.
---@param job? org.babel.Job
---@param data? string
function M.output(job, data)
  local live = job and job.live
  if not job or not live or job.finished or job.cancelled or not data or data == "" then
    return
  end
  local _, nl = data:gsub("\n", "")
  live.newlines = live.newlines + nl
  live.open = data:sub(-1) ~= "\n"
  if #data >= M.LIVE_BYTES then
    live.tail = data:sub(-M.LIVE_BYTES)
    live.cut = true
  else
    live.tail = live.tail .. data
    if #live.tail > M.LIVE_BYTES then
      live.tail = live.tail:sub(-M.LIVE_BYTES)
      live.cut = true
    end
  end
  if not live.pending then
    live.pending = true
    vim.schedule(function()
      flush(job)
    end)
  end
end

--- Have a step of `job` run by `vim.system` with options `sys_opts`
--- stream its output to the job's live view: its stdout and stderr
--- become callbacks. Returns a function that puts the output they
--- collected in the step's result (`vim.system` keeps none when given
--- callbacks), the same as it would have been; nil (`sys_opts` unchanged)
--- when the job has no live view.
---@param job? org.babel.Job
---@param sys_opts vim.SystemOpts
---@return fun(obj: vim.SystemCompleted)?
function M.stream(job, sys_opts)
  if not (job and job.live) then
    return nil
  end
  local buckets = { stdout = {}, stderr = {} }
  for name, bucket in pairs(buckets) do
    sys_opts[name] = function(err, data)
      if err then
        error(err)
      end
      if data then
        if sys_opts.text then
          -- what vim.system does with `text`
          data = data:gsub("\r\n", "\n")
        end
        bucket[#bucket + 1] = data
        M.output(job, data)
      end
    end
  end
  return function(obj)
    obj.stdout = table.concat(buckets.stdout)
    obj.stderr = table.concat(buckets.stderr)
  end
end

--- Redraw the virtual text of `job` at its mark's current line.
local function draw(job)
  if not vim.api.nvim_buf_is_valid(job.bufnr) then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(job.bufnr, M.ns, job.mark, {})
  if not pos[1] then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, job.bufnr, M.ns, pos[1], 0, {
    id = job.mark,
    virt_text = { { label(job), "OrgBabelRunning" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function tick()
  if next(M.running) == nil then
    return stop_timer()
  end
  frame = frame + 1
  local now = vim.uv.now()
  for _, job in pairs(M.running) do
    draw(job)
    -- the live view's header has the spinner and the seconds too
    local live = job.live
    if live and live.drawn > 0 and not live.pending and now - live.drawn >= M.LIVE_REDRAW_MS then
      draw_live(job)
    end
  end
end

local function start_timer()
  if timer or not spinner_frames() then
    return
  end
  local interval = require("org.config").opts.babel.spinner_interval or 100
  timer = vim.uv.new_timer()
  if not timer then
    return
  end
  timer:start(interval, interval, vim.schedule_wrap(tick))
end

local function setup_autocmds()
  if autocmds then
    return
  end
  autocmds = true
  local group = vim.api.nvim_create_augroup("org.babel.jobs", { clear = true })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(ev)
      for _, job in pairs(M.running) do
        if job.bufnr == ev.buf then
          -- the buffer is going away: stop the process, write nothing
          M.cancel(job, { quiet = true, unloading = true })
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.cancel_all({ quiet = true })
    end,
  })
end

--- Register a job for the block whose first line is 0-based `row` (and
--- last line `opts.end_row`, where the live output goes; default `row`).
---@param opts? { lang?: string, name?: string, end_row?: integer }
---@return org.babel.Job
function M.start(bufnr, row, opts)
  opts = opts or {}
  next_id = next_id + 1
  setup_autocmds()
  require("org.highlights").ensure()
  local job = {
    id = next_id,
    bufnr = bufnr,
    lang = opts.lang,
    name = opts.name,
    started = vim.uv.now(),
  }
  job.mark = vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {})
  local max = live_max()
  if max then
    local end_row = math.min(math.max(opts.end_row or row, row), vim.api.nvim_buf_line_count(bufnr) - 1)
    job.live = {
      mark = vim.api.nvim_buf_set_extmark(bufnr, M.live_ns, end_row, 0, {}),
      max = max,
      tail = "",
      cut = false,
      newlines = 0,
      open = false,
      drawn = 0,
    }
  end
  M.running[job.id] = job
  draw(job)
  start_timer()
  return job
end

--- The job ended (its result is in, or it was cancelled): drop the spinner.
---@param job? org.babel.Job
function M.finish(job)
  if not job or job.finished then
    return
  end
  job.finished = true
  M.running[job.id] = nil
  if vim.api.nvim_buf_is_valid(job.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, job.bufnr, M.ns, job.mark)
    if job.live then
      pcall(vim.api.nvim_buf_del_extmark, job.bufnr, M.live_ns, job.live.mark)
    end
  end
  if next(M.running) == nil then
    stop_timer()
  end
end

--- Give the job the function that stops what it runs now. A job
--- cancelled before its process started is stopped at once.
---@param job? org.babel.Job
---@param kill fun()
function M.set_kill(job, kill)
  if not job then
    return
  end
  job.kill = kill
  if job.cancelled then
    pcall(kill)
  end
end

--- Kill the process `obj` (from `vim.system`) with everything it started
--- (a shell running the script, waiting for `sleep`), else a child keeps
--- the output pipe open or finishes the script. Asynchronous runs start
--- `detach`ed, as their own process group: the whole group is killed, so
--- a grandchild forked while cancelling can't escape. Windows kills the
--- process tree.
function M.kill_process(obj)
  local pid = obj.pid
  if pid and vim.fn.has("win32") == 1 then
    pcall(function()
      vim.system({ "taskkill", "/T", "/F", "/PID", tostring(pid) }):wait(1000)
    end)
  elseif pid then
    local ok, res = pcall(vim.uv.kill, -pid, "sigterm")
    if (not ok or res ~= 0) and vim.fn.executable("pkill") == 1 then
      -- not a group leader: its direct children at least
      pcall(function()
        vim.system({ "pkill", "-TERM", "-P", tostring(pid) }):wait(1000)
      end)
    end
  end
  pcall(obj.kill, obj, 15)
end

--- Cancel `job`: stop its process (or interrupt its session request) and
--- show the cancellation. Its result, if one still arrives, is dropped.
---@param job org.babel.Job
---@param opts? org.babel.CancelOpts
function M.cancel(job, opts)
  opts = opts or {}
  if job.cancelled or job.finished then
    return false
  end
  job.cancelled = true
  if job.kill then
    local ok, err = pcall(job.kill)
    if not ok and not opts.quiet then
      utils.warn("babel: " .. tostring(err))
    end
  end
  local on_cancel = job.on_cancel
  M.finish(job)
  if on_cancel then
    on_cancel(job, opts)
  end
  if not opts.quiet then
    utils.notify("Babel evaluation cancelled")
  end
  return true
end

---@param opts? org.babel.CancelOpts
function M.cancel_all(opts)
  local n = 0
  for _, job in pairs(M.running) do
    if M.cancel(job, opts) then
      n = n + 1
    end
  end
  return n
end

--- The current 0-based line of `job`'s block, or nil.
---@param job org.babel.Job
function M.row(job)
  if not vim.api.nvim_buf_is_valid(job.bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(job.bufnr, M.ns, job.mark, {})
  return pos[1]
end

--- Running jobs, oldest first (only those of `bufnr` when given).
---@param bufnr? integer
---@return org.babel.Job[]
function M.list(bufnr)
  local out = {}
  for _, job in pairs(M.running) do
    if not bufnr or job.bufnr == bufnr then
      out[#out + 1] = job
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

--- The running job of the block (or #+CALL / inline element) at 1-based
--- line `lnum` of `bufnr`.
---@return org.babel.Job?
function M.at(bufnr, lnum)
  local rows = { [lnum - 1] = true }
  local ok, b = pcall(require("org.babel").at_block, bufnr, lnum)
  if ok and b then
    rows[b.start - 1] = true
  end
  for _, job in ipairs(M.list(bufnr)) do
    local row = M.row(job)
    if row and rows[row] then
      return job
    end
  end
end

--- A short description of a job, for the list of running jobs.
---@param job org.babel.Job
function M.describe(job)
  local row = M.row(job)
  local name = vim.api.nvim_buf_is_valid(job.bufnr) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(job.bufnr), ":t")
    or ""
  local secs = math.floor((vim.uv.now() - job.started) / 1000)
  return string.format(
    "%s%s %s:%s (%ds)",
    job.lang or "?",
    job.name and (" " .. job.name) or "",
    name ~= "" and name or ("buffer " .. job.bufnr),
    row and tostring(row + 1) or "?",
    secs
  )
end

return M
