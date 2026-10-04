---@mod org.export.process External commands of exports
---
--- Runs the shell commands that turn an export into its final file
--- (org-latex-pdf-process, org-texinfo-info-process, org-man-pdf-process,
--- org-odt-convert-process): one after another, like org-compile-file,
--- whatever the exit code of the previous one. Without a callback each
--- command is waited for; with one, the commands run in the background
--- with |vim.system()| callbacks and the run can be cancelled, which kills
--- the running command with the processes it started (its process group;
--- its process tree on Windows). Output goes, as it arrives, to a log
--- buffer such as "*Org PDF LaTeX Output*" (the buffer Emacs gives
--- `shell-command`).

local M = {}

local is_win = vim.fn.has("win32") == 1

--- Asynchronous runs that have not finished yet.
---@type table<org.export.Process, true>
M.running = {}

--- Output of the last run that finished (read by the Neovim of
--- asynchronous exports, which sends it back with its result).
---@type { name: string?, text: string }?
M.last_output = nil

--- Log buffer names held by a running process.
---@type table<string, true>
local busy = {}

---@class org.export.Process
---@field cmds (string|string[])[] the commands
---@field output string[] what the commands printed (stdout and stderr), in order
---@field running boolean
---@field cancelled boolean
---@field code? integer exit code of the last command that ran
---@field log_buf? integer the log buffer
---@field log_name? string its name
---@field _obj? vim.SystemObj the command running now
local Process = {}
Process.__index = Process

--- Everything the commands printed so far.
---@return string
function Process:text()
  return table.concat(self.output)
end

local function kill_tree(obj, signal)
  local pid = obj.pid
  if not pid then
    return
  end
  if is_win then
    pcall(vim.system, { "taskkill", "/T", "/F", "/PID", tostring(pid) })
    return
  end
  -- the command is a process group leader (`detach`): kill the group, so
  -- that latexmk's pdflatex or soffice's workers stop too
  local ok, res = pcall(vim.uv.kill, -pid, signal)
  if not ok or res ~= 0 then
    pcall(obj.kill, obj, signal)
  end
end

--- Stop the run: kill the command running now with its children; the
--- commands after it don't start. The run's callback is still called,
--- with `cancelled` set.
---@return boolean cancelled false when the run had already finished
function Process:cancel()
  if not self.running or self.cancelled then
    return false
  end
  self.cancelled = true
  local obj = self._obj
  if obj then
    kill_tree(obj, "sigterm")
    -- a command that ignores SIGTERM gets SIGKILL a little later
    vim.defer_fn(function()
      if self._obj == obj then
        kill_tree(obj, "sigkill")
      end
    end, 3000)
  end
  return true
end

local function find_buffer(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == name then
      return b
    end
  end
end

--- An empty log buffer called `name` (`name<2>`, ... while a running
--- process writes to `name`). Not listed, kept when hidden.
---@param name string
---@return integer buf, string name
function M.log_buffer(name)
  local n, k = name, 1
  while busy[n] do
    k = k + 1
    n = name .. "<" .. k .. ">"
  end
  local buf = find_buffer(n)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    pcall(vim.api.nvim_buf_set_name, buf, n)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  return buf, n
end

--- Append `text` to the end of `buf` (a partial last line is continued).
---@param buf integer
---@param text string
function M.append(buf, text)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) or text == "" then
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local tail = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  local lines = vim.split(tail .. text:gsub("\r\n", "\n"), "\n", { plain = true })
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, last - 1, last, false, lines)
  vim.bo[buf].modifiable = was
  vim.bo[buf].modified = false
end

--- Lines of LaTeX's output that report an error ("! ..." and the "l.NN"
--- line after it), at most `max` of them: what a failure notification
--- shows of the log.
---@param text string
---@param max? integer
---@return string[]
function M.error_excerpt(text, max)
  max = max or 6
  local out = {}
  local lines = vim.split(text or "", "\n", { plain = true })
  for i, l in ipairs(lines) do
    if #out >= max then
      break
    end
    if l:match("^! ") or l:match("^[^:%s]+:%d+: ") then
      out[#out + 1] = l
      for j = i + 1, math.min(i + 8, #lines) do
        if lines[j]:match("^l%.%d+") then
          out[#out + 1] = lines[j]
          break
        end
      end
    end
  end
  return out
end

--- Run `cmds`, shell command lines (run with `opts.shell`, by default
--- 'shell' and 'shellcmdflag') or argument lists, one after another in
--- `opts.cwd`.
---
--- Without `on_done` each command is waited for (at most `opts.timeout`
--- ms, 10 minutes by default) and the finished run is returned. With
--- `on_done`, the commands run in the background and on_done(run) is
--- called on the main loop when the last one has exited or the run was
--- cancelled; the running process is returned at once.
---
--- `opts.log_buffer` names the buffer the output goes to (emptied first;
--- asynchronous runs always have one, "*Org Export Process*" by default).
--- `opts.on_output(text)` is called with output as it arrives.
---@param cmds (string|string[])[]
---@param opts? { cwd?: string, shell?: string[], timeout?: integer, log_buffer?: string, on_output?: fun(text: string) }
---@param on_done? fun(run: org.export.Process)
---@return org.export.Process
function M.run(cmds, opts, on_done)
  opts = opts or {}
  local shell = opts.shell or { vim.o.shell, vim.o.shellcmdflag }
  local function argv(c)
    if type(c) == "table" then
      return c
    end
    local a = vim.deepcopy(shell)
    a[#a + 1] = c
    return a
  end
  local proc = setmetatable({ cmds = cmds, output = {}, running = true, cancelled = false }, Process)
  local name = opts.log_buffer or (on_done and "*Org Export Process*" or nil)
  if name then
    proc.log_buf, proc.log_name = M.log_buffer(name)
  end
  local function done()
    proc.running = false
    proc._obj = nil
    M.running[proc] = nil
    if proc.log_name then
      busy[proc.log_name] = nil
    end
    M.last_output = { name = proc.log_name, text = proc:text() }
  end

  if not on_done then
    for _, c in ipairs(cmds) do
      local ok, res = pcall(function()
        return vim.system(argv(c), { cwd = opts.cwd, text = true }):wait(opts.timeout or 600000)
      end)
      if not ok then
        res = { code = -1, signal = 0, stdout = "", stderr = tostring(res) .. "\n" }
      end
      local text = (res.stdout or "") .. (res.stderr or "")
      proc.output[#proc.output + 1] = text
      proc.code = res.code
      if proc.log_buf then
        M.append(proc.log_buf, text)
      end
    end
    done()
    return proc
  end

  M.running[proc] = true
  if proc.log_name then
    busy[proc.log_name] = true
  end
  local function on_data(_, data)
    if not data then
      return
    end
    -- a fast event: the buffer and the callback wait for the main loop
    proc.output[#proc.output + 1] = data
    vim.schedule(function()
      M.append(proc.log_buf, data)
      if opts.on_output then
        opts.on_output(data)
      end
    end)
  end
  local i = 0
  local function step()
    i = i + 1
    if proc.cancelled or i > #cmds then
      done()
      return on_done(proc)
    end
    local sysopts = { cwd = opts.cwd, text = true, stdout = on_data, stderr = on_data, detach = not is_win }
    local ok, obj = pcall(vim.system, argv(cmds[i]), sysopts, function(res)
      proc.code = res.code
      proc._obj = nil
      -- the exit callback is a fast event, where options (the next step
      -- reads 'shell') and most of the API are off limits
      vim.schedule(step)
    end)
    if ok then
      proc._obj = obj
    else
      on_data(nil, tostring(obj) .. "\n")
      proc.code = -1
      vim.schedule(step)
    end
  end
  -- on the next turn of the loop, so on_done never runs before run() returns
  vim.schedule(step)
  return proc
end

--- Cancel every running process.
function M.cancel_all()
  for p in pairs(M.running) do
    p:cancel()
  end
end

-- The commands are process group leaders, which outlive Neovim: stop them
-- when it quits, as Emacs kills its export processes.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("org.export.process", { clear = true }),
  callback = M.cancel_all,
})

return M
