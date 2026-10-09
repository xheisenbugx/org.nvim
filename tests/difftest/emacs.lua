-- Emacs Org 9.8.10 workers for the differential test: each one runs
-- scripts/emacs-parity/difftest.el, which answers requests on stdin (see
-- that file). Requests are queued on the least busy worker and answered
-- in the background, so Emacs works while org.nvim computes its side.
--
--   local pool = require("tests.difftest.emacs").start({ jobs = 4 })
--   pool:request("export-html", "/x/d1.org", "/x/d1.export-html.emacs")
--   pool:wait()            -- every request answered
--   pool:stop()
--
-- A request Emacs doesn't answer in `timeout` seconds (Emacs loops
-- forever on some inputs) gets "!error timeout" as its output; its worker
-- is replaced and the requests queued behind it are sent again.
--
-- ORG_EMACS (or EMACS) names the Emacs binary, ORG_LISP_DIR (or ORG_DIR)
-- an Org 9.8.10 lisp directory put first on the load-path.

local M = {}

local root = require("tests.emacs_parity").root

---@class difftest.Request
---@field [1] string oracle
---@field [2] string input
---@field [3] string output

---@class difftest.Worker
---@field job integer
---@field queue difftest.Request[] sent, not answered yet (the first one runs)
---@field since number when the first one started (uv.now())
---@field dead? string

---@class difftest.Pool
---@field workers difftest.Worker[]
---@field stderr string[]
---@field timeout integer ms
---@field timeouts integer requests that timed out
local Pool = {}
Pool.__index = Pool

--- The command line of a worker.
function M.cmd()
  local emacs = vim.env.ORG_EMACS or vim.env.EMACS
  if not emacs or emacs == "" then
    emacs = "emacs"
  end
  local lisp = vim.env.ORG_LISP_DIR or vim.env.ORG_DIR
  local cmd = { emacs, "-Q", "--batch" }
  if lisp and lisp ~= "" then
    vim.list_extend(cmd, { "-L", lisp })
  end
  vim.list_extend(cmd, {
    "-l",
    root .. "/scripts/emacs-parity/common.el",
    "-l",
    root .. "/scripts/emacs-parity/difftest.el",
  })
  return cmd
end

local ENV = { PARITY_ROOT = root, TZ = "UTC0", LC_ALL = "C", LANG = "C" }

local function send(w, r)
  vim.fn.chansend(w.job, table.concat(r, "\t") .. "\n")
end

--- Start worker `i` (again).
function Pool:spawn(i)
  ---@type difftest.Worker
  local w = { job = 0, queue = {}, since = vim.uv.now() }
  local partial = ""
  w.job = vim.fn.jobstart(M.cmd(), {
    env = ENV,
    on_stdout = function(_, data)
      -- a list of lines; the first continues the last partial line
      data[1] = partial .. data[1]
      partial = table.remove(data)
      for _, l in ipairs(data) do
        if l:match("^done ") and #w.queue > 0 then
          table.remove(w.queue, 1)
          w.since = vim.uv.now()
        end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then
          self.stderr[#self.stderr + 1] = ("[emacs %d] %s"):format(i, l)
        end
      end
    end,
    on_exit = function(_, code)
      w.dead = ("exited with %d"):format(code)
    end,
  })
  if w.job <= 0 then
    error("cannot start Emacs: " .. table.concat(M.cmd(), " "))
  end
  self.workers[i] = w
  return w
end

--- Start `opts.jobs` workers; `opts.timeout` (seconds, default 60) per request.
---@param opts { jobs: integer, timeout?: integer }
---@return difftest.Pool
function M.start(opts)
  local self = setmetatable({ workers = {}, stderr = {}, timeout = (opts.timeout or 60) * 1000, timeouts = 0 }, Pool)
  for i = 1, opts.jobs do
    self:spawn(i)
  end
  return self
end

--- Queue a request: Emacs writes `oracle`'s output for `input` to `output`.
function Pool:request(oracle, input, output)
  local best
  for _, w in ipairs(self.workers) do
    if not w.dead and (not best or #w.queue < #best.queue) then
      best = w
    end
  end
  if not best then
    error("every Emacs worker died:\n" .. table.concat(self.stderr, "\n"))
  end
  if #best.queue == 0 then
    best.since = vim.uv.now()
  end
  local r = { oracle, input, output }
  best.queue[#best.queue + 1] = r
  send(best, r)
end

--- Replace worker `i`, which is stuck on its first request or died: that
--- request fails, the others go to the new worker.
function Pool:restart(i, why)
  local old = self.workers[i]
  if not old.dead then
    vim.fn.jobstop(old.job)
  end
  local stuck = table.remove(old.queue, 1)
  if stuck then
    vim.fn.mkdir(vim.fn.fnamemodify(stuck[3], ":h"), "p")
    local f = assert(io.open(stuck[3], "wb"))
    f:write("!error " .. why .. "\n")
    f:close()
  end
  local w = self:spawn(i)
  for _, r in ipairs(old.queue) do
    w.queue[#w.queue + 1] = r
    send(w, r)
  end
end

--- Wait until every request is answered.
function Pool:wait()
  while true do
    local busy = false
    vim.wait(200, function()
      for _, w in ipairs(self.workers) do
        if #w.queue > 0 then
          return false
        end
      end
      return true
    end, 2)
    for i, w in ipairs(self.workers) do
      if #w.queue > 0 then
        busy = true
        if w.dead then
          self.timeouts = self.timeouts + 1
          self:restart(i, "Emacs " .. w.dead)
        elseif vim.uv.now() - w.since > self.timeout then
          self.timeouts = self.timeouts + 1
          self:restart(i, "timeout")
        end
      end
    end
    if not busy then
      return
    end
  end
end

function Pool:stop()
  for _, w in ipairs(self.workers) do
    if not w.dead then
      vim.fn.chanclose(w.job, "stdin")
    end
  end
  vim.wait(5000, function()
    for _, w in ipairs(self.workers) do
      if not w.dead then
        return false
      end
    end
    return true
  end, 10)
  for _, w in ipairs(self.workers) do
    if not w.dead then
      vim.fn.jobstop(w.job)
    end
  end
end

--- Check that Emacs runs and loads Org 9.8.10 (common.el raises an error
--- otherwise): nil, or why not.
function M.check()
  local cmd = M.cmd()
  local okc, r = pcall(function()
    return vim
      .system(vim.list_extend(vim.list_slice(cmd, 1, #cmd - 2), { "--eval", "(princ (org-version))" }), {
        env = ENV,
        text = true,
      })
      :wait()
  end)
  if not okc then
    return tostring(r)
  end
  if r.code ~= 0 then
    return ("%s failed (%d):\n%s"):format(table.concat(cmd, " "), r.code, r.stderr or "")
  end
end

return M
