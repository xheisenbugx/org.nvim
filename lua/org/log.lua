---@mod org.log The session log (:Org log)
---
--- Failures org.nvim catches and goes on from (a statistics cookie it
--- couldn't update, a state file it couldn't write, a User autocommand
--- handler that failed) are recorded here, so a bug report can say what
--- went wrong. It keeps the last `M.max` entries of this session, in
--- memory only; the same failure again right after itself counts up the
--- last entry instead of adding one.
---
--- `utils.try(where, fn, ...)` records into it; `:Org log` shows it with
--- the versions a bug report needs. This module loads on the first entry,
--- so a session without failures never loads it.

local M = {}

--- How many entries are kept: the oldest goes when one more comes.
M.max = 200

---@alias org.LogLevel "error"|"warn"|"info"

---@class org.LogEntry
---@field time integer os.time() of the last time it happened
---@field level org.LogLevel
---@field where string what org.nvim was doing ("bookmarks: save", "User OrgTodoChanged")
---@field msg string
---@field trace? string the stack traceback of an error
---@field count integer how many times in a row it happened

--- The entries, oldest first.
---@type org.LogEntry[]
M.entries = {}

--- Entries of each level this session, those dropped from the ring and
--- the repeats included.
---@type table<org.LogLevel, integer>
M.counts = { error = 0, warn = 0, info = 0 }

--- Record an entry.
---@param level org.LogLevel
---@param where string
---@param msg any an error object is shown with tostring()
---@param trace? string
---@return org.LogEntry
function M.add(level, where, msg, trace)
  msg = tostring(msg)
  M.counts[level] = (M.counts[level] or 0) + 1
  local last = M.entries[#M.entries]
  if last and last.level == level and last.where == where and last.msg == msg then
    last.count = last.count + 1
    last.time = os.time()
    return last
  end
  local e = { time = os.time(), level = level, where = where, msg = msg, trace = trace, count = 1 }
  M.entries[#M.entries + 1] = e
  while #M.entries > M.max do
    table.remove(M.entries, 1)
  end
  return e
end

--- Forget every entry and count.
function M.clear()
  M.entries = {}
  M.counts = { error = 0, warn = 0, info = 0 }
end

--- The report `:Org log` shows: the org.nvim, Neovim and OS versions,
--- then the entries, newest last.
---@return string[]
function M.lines()
  local bug_report = require("org.bug_report")
  local lines = {
    "org.nvim log: what org.nvim caught and went on from this session, newest last.",
    "Add it to a bug report (:Org bug_report, :h org-log); q or <Esc> closes it.",
    "",
    "org.nvim : " .. require("org.version").string(true),
    "Neovim   : " .. bug_report.nvim_version(),
    "OS       : " .. bug_report.os_name(),
    string.format(
      "Logged   : %d error(s), %d warning(s) (the last %d entries are kept)",
      M.counts.error,
      M.counts.warn,
      M.max
    ),
    "",
  }
  if #M.entries == 0 then
    lines[#lines + 1] = "Nothing logged this session."
  end
  for _, e in ipairs(M.entries) do
    lines[#lines + 1] = string.format(
      "%s %s %s%s",
      os.date("%Y-%m-%d %H:%M:%S", e.time),
      e.level:upper(),
      e.where,
      e.count > 1 and string.format(" (%d times)", e.count) or ""
    )
    for _, l in ipairs(vim.split(e.msg, "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. l
    end
    -- the traceback, unless the message already ends with one (a
    -- handler's error as Neovim reports it)
    if e.trace and not e.msg:find("stack traceback:", 1, true) then
      for _, l in ipairs(vim.split(e.trace, "\n", { plain = true })) do
        lines[#lines + 1] = "    " .. l:gsub("\t", "    ")
      end
    end
  end
  return lines
end

--- Show the log in a scratch buffer (`:Org log`); q or <Esc> closes it.
---@return integer buf
function M.open()
  local name = "org-log"
  local buf = vim.fn.bufnr("^" .. name .. "$")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines())
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "orglog"
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  -- newest last: show the end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "Close" })
  end
  return buf
end

return M
