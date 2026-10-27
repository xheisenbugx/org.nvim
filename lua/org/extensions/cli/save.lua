---@mod org.extensions.cli.save Guarding files and saving them
---
--- A file a running Neovim has unsaved changes in is refused (`guard`),
--- modified buffers are saved through the write hooks (`save_all`) and a
--- running Neovim is told, and org.nvim's own messages become failures.
--- Part of org.extensions.cli.run, which loads it.

local shared = require("org.extensions.cli.shared")

local M = require("org.extensions.cli.run")

local fail = M.fail
local state = shared.state
local arg_path = M.arg_path
local short_path = M.short_path

-- Tell a running Neovim (with the cli extension on) that files changed:
-- it watches this file, rereads changed files and the clock
-- (org.clock.sync).
local function touch_stamp()
  pcall(function()
    local path = require("org.extensions.cli").stamp_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fh = io.open(path, "wb")
    if fh then
      fh:write(tostring(vim.uv.hrtime()) .. "\n")
      fh:close()
    end
  end)
end

--- Swap files a Neovim editing `path` would have ('directory').
local function swap_files(path)
  local full = arg_path(path)
  local tail = vim.fn.fnamemodify(full, ":t")
  local head = vim.fn.fnamemodify(full, ":h")
  local win = vim.fn.has("win32") == 1
  local out = {}
  for _, d in ipairs(vim.split(vim.o.directory, ",", { trimempty = true })) do
    local percent = d:match("//$") or d:match("\\\\$")
    local dir = d:gsub("[/\\]+$", "")
    local base
    if dir == "." or dir == "" then
      dir, base = head, "." .. tail
    elseif percent then
      base = full:gsub(win and "[/\\:]" or "/", "%%")
    else
      base = tail
    end
    for _, ext in ipairs({ ".swp", ".swo", ".swn" }) do
      out[#out + 1] = dir .. "/" .. base .. ext
    end
  end
  return out
end

--- Fail with `file_busy` when a running Neovim has unsaved changes in
--- `path` (its swap file says so), unless --force.
---@param path string
---@param flags table
function M.guard(path, flags)
  if not path or flags.force then
    return
  end
  local me = vim.fn.getpid()
  for _, sw in ipairs(swap_files(path)) do
    if vim.uv.fs_stat(sw) then
      local ok, info = pcall(vim.fn.swapinfo, sw)
      if ok and type(info) == "table" and not info.error and info.dirty == 1 and info.pid ~= me then
        local alive = info.pid and info.pid > 0 and vim.uv.kill(info.pid, 0) == 0
        if alive then
          fail(
            string.format(
              "%s has unsaved changes in a running Neovim (pid %d); save it there or use --force",
              path,
              info.pid
            ),
            "file_busy",
            { file = arg_path(path), pid = info.pid, swap = sw }
          )
        end
      end
    end
  end
end

--- Save every modified buffer (through utils.save_buffer: the write hooks
--- run) and tell a running Neovim. None is written unless all can be:
--- no file has unsaved changes in a running Neovim, and no write hook
--- refuses one (org-crypt without the passphrase it would ask for).
function M.save_all(flags)
  local utils = require("org.utils")
  local hooks = require("org.write_hooks")
  local bufs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified and vim.api.nvim_buf_get_name(b) ~= "" then
      if state.dirty_before[b] then
        -- the session's user has unsaved changes there: the change is in
        -- the buffer, saved when they save it
        vim.notify(
          short_path(vim.api.nvim_buf_get_name(b)) .. " has unsaved changes in Neovim; the change is not saved yet",
          vim.log.levels.WARN
        )
      else
        bufs[#bufs + 1] = b
      end
    end
  end
  local function failed(b, e)
    -- a prompt a hook couldn't ask (a passphrase), or a change on disk,
    -- is the reason
    M.check_prompted()
    M.check_disk_changed()
    local name = vim.api.nvim_buf_get_name(b)
    fail("could not save " .. name .. ": " .. tostring(e), "failed", { file = name })
  end
  for _, b in ipairs(bufs) do
    M.guard(vim.api.nvim_buf_get_name(b), flags or {})
  end
  -- The pre-write hooks of every buffer run before any file is written.
  -- What they change (entries org-crypt encrypts) stays for the write;
  -- the post hooks undo the rest, as after a failed write.
  for _, b in ipairs(bufs) do
    local ok, e, run = hooks.run_pre(b, "save_buffer")
    if not ok then
      failed(b, e)
    end
    hooks.run_post(run, false)
  end
  for _, b in ipairs(bufs) do
    local ok, e = utils.save_buffer(b)
    if not ok then
      failed(b, e)
    end
    state.touched = true
  end
  if state.touched then
    touch_stamp()
  end
end

---------------------------------------------------------------------------
-- Writes that run at the same time
---------------------------------------------------------------------------

--- The lock file write commands run under (outside the session server),
--- so that two `org` processes never edit the same file at once.
function M.lock_path()
  return vim.fn.stdpath("state") .. "/org/cli-write.lock"
end

local function pid_alive(pid)
  local r, e = vim.uv.kill(pid, 0)
  return r == 0 or tostring(e or ""):find("EPERM", 1, true) ~= nil
end

local function lock_owner(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local s = fh:read("*a") or ""
  fh:close()
  return tonumber(s:match("^%s*(%d+)"))
end

--- Take the write lock, waiting up to `extensions.cli.lock_timeout`
--- seconds for the `org` that holds it; a lock left by a process that is
--- gone is taken over. Fails with `file_busy` when the wait ends.
function M.lock_writes()
  if state.lock then
    return
  end
  local path = M.lock_path()
  require("org.utils").mkdir_p(vim.fs.dirname(path))
  local me = vim.fn.getpid()
  local timeout = tonumber(shared.cli_opts().lock_timeout) or 10
  local deadline = vim.uv.hrtime() + timeout * 1e9
  local owner
  while true do
    local fd = vim.uv.fs_open(path, "wx", tonumber("644", 8))
    if fd then
      vim.uv.fs_write(fd, tostring(me) .. "\n")
      vim.uv.fs_close(fd)
      state.lock = path
      return
    end
    owner = lock_owner(path)
    local st = vim.uv.fs_stat(path)
    -- a lock whose process is gone (or, without a pid yet, one older than
    -- the time it takes to write it)
    local stale = (owner and owner ~= me and not pid_alive(owner))
      or (not owner and st and os.time() - st.mtime.sec > 5)
    if stale and lock_owner(path) == owner then
      os.remove(path)
    elseif vim.uv.hrtime() > deadline then
      fail(
        string.format(
          "another org command (pid %s) is writing; try again (the lock is %s)",
          owner and tostring(owner) or "?",
          path
        ),
        "file_busy",
        { lock = path, pid = owner or vim.NIL }
      )
    else
      vim.uv.sleep(20)
    end
  end
end

--- Give the write lock back.
function M.unlock_writes()
  if state.lock then
    if lock_owner(state.lock) == vim.fn.getpid() then
      os.remove(state.lock)
    end
    state.lock = nil
  end
end

--- What a file on disk is now: false when there is none.
local function disk_key(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    return false
  end
  return table.concat({ st.mtime.sec, st.mtime.nsec, st.size, st.ino or 0 }, ":")
end

--- Remember each file as the command reads it, and make `utils.save_buffer`
--- refuse a file that changed on disk since (another program wrote it):
--- Vim would ask whether to write it anyway, a prompt the command line
--- can't answer, and leave the file unwritten. Returns the function that
--- puts things back.
---@return fun()
function M.watch_disk()
  local utils = require("org.utils")
  local known = {}
  local group = vim.api.nvim_create_augroup("org_cli_disk", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name ~= "" then
        known[ev.buf] = disk_key(name)
      end
    end,
  })
  local function changed(name)
    state.disk_changed = state.disk_changed or name
    state.disk_reason = short_path(name) .. " changed on disk while org was changing it; it was not written"
    return false, state.disk_reason
  end
  local save = rawget(utils, "save_buffer")
  rawset(utils, "save_buffer", function(bufnr)
    local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
    local writes = name ~= "" and vim.bo[bufnr].modified
    local before = writes and disk_key(name)
    if writes and known[bufnr] ~= nil and known[bufnr] ~= before then
      return changed(name)
    end
    local ok, e = save(bufnr)
    if ok and writes then
      -- Vim asked whether to write over a change on disk and got no
      -- answer: nothing was written
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified and disk_key(name) == before then
        return changed(name)
      end
      known[bufnr] = disk_key(name)
    end
    return ok, e
  end)
  return function()
    rawset(utils, "save_buffer", save)
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

--- Fail with `file_changed` when a file changed on disk under the command
--- (see `watch_disk`).
function M.check_disk_changed()
  local name = state.disk_changed
  if name then
    fail(
      short_path(name) .. " changed on disk while org was changing it (another program wrote it); run the command again",
      "file_changed",
      { file = name }
    )
  end
end

--- Fail with `input_needed` when a prompt was refused during the command.
function M.check_prompted()
  if state.prompted then
    fail(
      "interactive input needed (" .. state.prompted .. "); not available in the CLI",
      "input_needed",
      { prompt = state.prompted }
    )
  end
end

--- Fail with org.nvim's own warnings and errors as the message.
function M.fail_with_messages(default, ecode)
  M.check_prompted()
  M.check_disk_changed()
  local msgs = {}
  for _, m in ipairs(state.messages) do
    if m.level >= vim.log.levels.WARN then
      msgs[#msgs + 1] = m.msg
    end
  end
  fail(#msgs > 0 and msgs[#msgs] or default, ecode or "failed", { messages = msgs })
end

--- Forget the messages so far (fail_with_messages reports the ones a
--- step adds).
function M.mark_messages()
  state.messages = {}
end

shared.touch_stamp = touch_stamp
