--- Pre/post-write hooks: code that must run around every write of a
--- buffer, whichever way it is written.
---
--- A buffer is written either by the user (`:w`, `:wq`, ...: the
--- BufWritePre/BufWritePost autocommands run) or by org itself
--- (`utils.save_buffer`, used by refile, archive, capture, agenda edits,
--- mobile, ...), which writes with `:noautocmd` so that unrelated user
--- autocommands (formatters, linters) don't run on background saves. Hooks
--- registered here run in both cases, so the bytes on disk are the same.
---
---   require("org.write_hooks").register("my-ext", {
---     order = 50, -- lower runs first (pre); post runs in reverse
---     filetype = "org", -- optional filter (string or list)
---     pre = function(bufnr, ctx)
---       -- change the buffer before it is written; `ctx.state` is a table
---       -- kept for this write and handed to `post`. Return false (and a
---       -- message), or throw, to veto: nothing is written, `:w` fails
---       -- with that message and `utils.save_buffer` returns false, msg.
---     end,
---     post = function(bufnr, ctx)
---       -- `ctx.ok` tells whether the file was written. Runs for every
---       -- hook whose `pre` ran (also after a veto or a failed write), so
---       -- it can put back what `pre` took out.
---     end,
---   })
---
--- `ctx.source` is "write" (a Vim write command) or "save_buffer".
local M = {}

---@class OrgWriteHook
---@field pre? fun(bufnr: integer, ctx: table): (boolean|nil, string|nil)
---@field post? fun(bufnr: integer, ctx: table)
---@field order? integer
---@field filetype? string|string[]

---@type table<string, OrgWriteHook>
local hooks = {}
---@type { name: string, hook: OrgWriteHook }[]|nil
local sorted
local define_autocmds

--- Register (or replace) the hook `name`.
---@param name string
---@param hook OrgWriteHook
function M.register(name, hook)
  vim.validate("name", name, "string")
  vim.validate("hook", hook, "table")
  hooks[name] = hook
  sorted = nil
  define_autocmds()
end

--- Remove the hook `name` (no-op when absent).
---@param name string
function M.unregister(name)
  hooks[name] = nil
  sorted = nil
end

--- Registered hook names, in run order.
---@return string[]
function M.list()
  local out = {}
  for _, e in ipairs(M._sorted()) do
    out[#out + 1] = e.name
  end
  return out
end

function M._sorted()
  if not sorted then
    sorted = {}
    for name, hook in pairs(hooks) do
      sorted[#sorted + 1] = { name = name, hook = hook }
    end
    table.sort(sorted, function(a, b)
      local oa, ob = a.hook.order or 50, b.hook.order or 50
      if oa ~= ob then
        return oa < ob
      end
      return a.name < b.name
    end)
  end
  return sorted
end

local function applies(hook, bufnr)
  local ft = hook.filetype
  if not ft then
    return true
  end
  local bft = vim.bo[bufnr].filetype
  if type(ft) == "string" then
    return ft == bft
  end
  return vim.tbl_contains(ft, bft)
end

--- Run the post hooks of `run` (from `run_pre`), latest first.
---@param run table
---@param ok boolean whether the file was written
function M.run_post(run, ok)
  if not run or run.done then
    return
  end
  run.done = true
  local bufnr = run.bufnr
  for i = #run.ran, 1, -1 do
    local e = run.ran[i]
    if e.hook.post and vim.api.nvim_buf_is_valid(bufnr) then
      e.ctx.ok = ok
      local pok, err = pcall(e.hook.post, bufnr, e.ctx)
      if not pok then
        require("org.utils").error(("write hook %s: %s"):format(e.name, tostring(err)))
      end
    end
  end
end

--- Run every applicable pre hook on `bufnr`. On a veto the post hooks of
--- the hooks that already ran are run (with ok = false) and the write must
--- not happen.
---@param bufnr integer
---@param source "write"|"save_buffer"
---@return boolean ok, string|nil err, table run (hand it to `run_post`)
function M.run_pre(bufnr, source)
  local run = { bufnr = bufnr, ran = {} }
  for _, e in ipairs(M._sorted()) do
    if applies(e.hook, bufnr) then
      local ctx = { bufnr = bufnr, source = source, state = {} }
      run.ran[#run.ran + 1] = { name = e.name, hook = e.hook, ctx = ctx }
      local pok, res, msg = true, nil, nil
      if e.hook.pre then
        pok, res, msg = pcall(e.hook.pre, bufnr, ctx)
      end
      if not pok or res == false then
        local err = not pok and ("%s: %s"):format(e.name, tostring(res)) or msg or ("%s: write vetoed"):format(e.name)
        M.run_post(run, false)
        return false, err, run
      end
    end
  end
  return true, nil, run
end

---------------------------------------------------------------------------
-- The Vim write commands
---------------------------------------------------------------------------

---@type table<integer, table> pre hooks run, waiting for BufWritePost
local pending = {}
local last_err = "org: write vetoed"

--- BufWritePre: returns 0 (and the autocmd throws, aborting the write)
--- when a hook vetoed.
---@param bufnr integer
---@return integer
function M._on_write_pre(bufnr)
  if next(hooks) == nil then
    return 1
  end
  local ok, err, run = M.run_pre(bufnr, "write")
  if not ok then
    last_err = err or "write vetoed"
    return 0
  end
  if #run.ran == 0 then
    return 1
  end
  -- a stale run (its write never finished) is closed first
  if pending[bufnr] then
    M.run_post(pending[bufnr], false)
  end
  pending[bufnr] = run
  -- A write that fails (or that another autocommand stops) has no
  -- BufWritePost: run the post hooks once the write command is over.
  -- A callback can run while autocommands still do (vim.wait in a
  -- formatter): wait until none does.
  local function fallback()
    if pending[bufnr] ~= run then
      return
    end
    if vim.fn.state():find("x") then
      vim.defer_fn(fallback, 20)
      return
    end
    pending[bufnr] = nil
    M.run_post(run, false)
  end
  vim.schedule(fallback)
  return 1
end

function M._veto_message()
  return last_err
end

local function on_write_post(bufnr)
  local run = pending[bufnr]
  if run then
    pending[bufnr] = nil
    M.run_post(run, true)
  end
end

--- (Re)create the autocommands. Each registration moves them after the
--- BufWritePre handlers defined so far (formatters and the like), so the
--- hooks see the text that is about to be written.
define_autocmds = function()
  local group = vim.api.nvim_create_augroup("org.write_hooks", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    -- A Vimscript exception (unlike a Lua error) aborts the write.
    command = [[if !v:lua.require'org.write_hooks'._on_write_pre(str2nr(expand('<abuf>')))]]
      .. [[ | throw v:lua.require'org.write_hooks'._veto_message() | endif]],
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      on_write_post(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      pending[ev.buf] = nil
    end,
  })
end

define_autocmds()

return M
