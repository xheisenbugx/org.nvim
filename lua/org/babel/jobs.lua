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
--- Synchronous evaluations (export, `:var` references, table formulas,
--- org.api callers) never become jobs.

local utils = require("org.utils")

local M = {}

M.ns = vim.api.nvim_create_namespace("org.babel.jobs")

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
  for _, job in pairs(M.running) do
    draw(job)
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

--- Register a job for the block whose first line is 0-based `row`.
---@param opts? { lang?: string, name?: string }
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
