---@mod org.clock.persist Keeping the clock across restarts
---
--- Restore a persisted or open clock after a restart, and follow a
--- clock started or stopped outside this Neovim.
---
--- Part of org.clock, which loads it.

local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local clock_cfg = shared.clock_cfg
local hook_exit = shared.hook_exit
local hook_rename = shared.hook_rename
local mode_line_heading = shared.mode_line_heading
local persist = shared.persist
local start_timers = shared.start_timers
local stop_timers = shared.stop_timers
local total_before = shared.total_before

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

--- Ask whether to resume a clock found after a restart
--- (org-clock-persist-query-resume).
local function query_resume(title)
  return not clock_cfg().persist_query_resume or utils.confirm("Resume clock (" .. title .. ")?")
end

--- Follow a clock started or stopped outside this Neovim (by the `org`
--- command line, see `:h org-extensions-cli`): reread changed files, drop
--- the running clock when its open CLOCK line is gone, or take up an open
--- CLOCK line found in the agenda files. Nothing calls it unless the cli
--- extension is enabled.
---@return "in"|"out"|nil what changed
---@return org.ClockState|nil state the clock that started or stopped
function M.sync()
  pcall(vim.cmd, "silent! checktime")
  if M.state then
    if M.find_open_clock() then
      return nil
    end
    local st = M.state
    M.state = nil
    stop_timers()
    pcall(vim.cmd, "redrawstatus")
    return "out", st
  end
  for _, f in ipairs(files.agenda_files()) do
    for _, hl in ipairs(f.headlines) do
      for _, c in ipairs(hl.clocks) do
        if not c["end"] then
          M.state = {
            path = f.filename,
            start = c.start:clone({ active = false }):to_string({ range = false }),
            title = mode_line_heading(hl),
            effort = require("org.properties").effort_minutes(hl),
            total = (total_before(hl)),
          }
          start_timers()
          hook_rename()
          pcall(vim.cmd, "redrawstatus")
          return "in", M.state
        end
      end
    end
  end
  return nil
end

--- Restore the running clock after a restart (from `clock.persist_file`).
--- Called by `setup()` when `clock.persist` is set: `true` restores the
--- clock and the history, `"clock"` / `"history"` only one of them.
---@return org.ClockState|nil state the running clock, if any
function M.restore()
  hook_exit()
  hook_rename()
  if M.state then
    return M.state
  end
  local cfg = clock_cfg()
  local want_clock = cfg.persist ~= "history"
  if cfg.persist and cfg.persist_file then
    local data = utils.read_json(cfg.persist_file)
    if type(data) == "table" then
      if cfg.persist == true or cfg.persist == "history" then
        if type(data.last) == "table" then
          M.last = data.last
        end
        if type(data.history) == "table" and vim.islist(data.history) then
          M.history = data.history
        end
      end
      -- a clock in a buffer without a file did not survive the restart
      if
        want_clock
        and type(data.state) == "table"
        and data.state.path
        and data.state.path ~= ""
        and data.state.start
      then
        M.state = data.state
        if M.find_open_clock() then
          if not query_resume(M.state.title) then
            -- the open CLOCK line stays, as a dangling clock to resolve
            M.state = nil
            return nil
          end
          start_timers()
          return M.state
        end
        M.state = nil
      end
    end
  end
  if not want_clock then
    return nil
  end
  for _, f in ipairs(files.agenda_files()) do
    for _, hl in ipairs(f.headlines) do
      for _, c in ipairs(hl.clocks) do
        if not c["end"] then
          if not query_resume(mode_line_heading(hl)) then
            return nil
          end
          M.state = {
            path = f.filename,
            start = c.start:clone({ active = false }):to_string({ range = false }),
            title = mode_line_heading(hl),
            effort = require("org.properties").effort_minutes(hl),
            total = (total_before(hl)),
          }
          start_timers()
          return M.state
        end
      end
    end
  end
  return nil
end
