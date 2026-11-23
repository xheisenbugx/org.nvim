---@mod org.utils.async Notifications, session log, coroutines and prompts
---
--- Async helpers: interactive actions run inside a coroutine (`M.run`) so
--- they can call `M.input`, `M.select`, `M.confirm` linearly even though
--- `vim.ui.*` are callback based (snacks.nvim / dressing replace them).
---
--- Part of org.utils, which loads it.

local M = require("org.utils")

---------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------

---@param msg string
---@param level? integer
---@param opts? table
function M.notify(msg, level, opts)
  if M._messages then
    -- inside `M.noninteractive`: collected for the caller instead of shown
    table.insert(M._messages, { msg = msg, level = level or vim.log.levels.INFO })
    return
  end
  vim.notify(msg, level or vim.log.levels.INFO, vim.tbl_extend("force", { title = "org" }, opts or {}))
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

---------------------------------------------------------------------------
-- Caught failures (the session log, :Org log)
---------------------------------------------------------------------------

--- The stack traceback of the error `try` caught last, taken by its
--- handler while the stack is still there.
local try_trace

local function try_handler(err)
  try_trace = debug.traceback("", 2):gsub("^\n", "")
  return err
end

local function try_result(where, ok, ...)
  if ok then
    return ok, ...
  end
  local err = ...
  -- an interactive action cancelled (`M.abort`) isn't a failure
  if err ~= "org_abort" then
    require("org.log").add("error", where, err, try_trace)
  end
  try_trace = nil
  return false, err
end

--- Call `fn(...)` like `pcall`, and record a failure in the session log
--- (`:Org log`, `org.log`) under `where`, with its traceback: for a
--- failure org.nvim goes on from, which would otherwise leave no trace.
--- Returns what `pcall` returns. Showing it to the user is the caller's
--- choice (`M.error`, `M.warn`). On success it costs what `xpcall` does.
---@param where string what is being done, for the log ("bookmarks: save")
---@param fn function
---@return boolean ok, any ... the results, or the error
function M.try(where, fn, ...)
  return try_result(where, xpcall(fn, try_handler, ...))
end

--- Fire the User autocommand `pattern` with `data` (modeline off) for the
--- handlers users and other plugins register, without letting their
--- failure stop the org command that fires it. An error in a handler is
--- shown by Neovim (with the event's name) and recorded in the session
--- log too; not being able to fire it at all (from a fast event, say) is
--- org.nvim's own failure: logged and shown as a warning.
---@param pattern string
---@param data? any
function M.user_event(pattern, data)
  local where = "User " .. pattern
  local fast = vim.in_fast_event()
  local errmsg
  if not fast then
    errmsg = vim.v.errmsg
    vim.v.errmsg = ""
  end
  local ok, err = M.try(where, vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
  if not fast then
    local handler_err = vim.v.errmsg
    if handler_err ~= "" then
      require("org.log").add("error", where .. " (a handler)", handler_err)
    else
      vim.v.errmsg = errmsg
    end
  end
  if not ok then
    local msg = string.format("Could not run the User %s autocommands: %s (see :Org log)", pattern, tostring(err))
    if fast then
      vim.schedule(function()
        M.warn(msg)
      end)
    else
      M.warn(msg)
    end
  end
end

---------------------------------------------------------------------------
-- Non-interactive calls (org.api)
---------------------------------------------------------------------------

--- Depth of `M.noninteractive` calls: while positive, prompts (`input`,
--- `input_note`, `input_complete`, `select`, `confirm`, `getchar`, the
--- date picker) answer as if cancelled instead of waiting for the user.
M._noninteractive = 0
--- Messages collected by `M.noninteractive` (nil outside of it).
M._messages = nil

--- Is a prompt to be answered as cancelled (inside `M.noninteractive`)?
function M.is_noninteractive()
  return M._noninteractive > 0
end

--- Call `fn(...)` without prompting and without showing messages: prompts
--- answer as if cancelled and `notify` / `warn` / `error` messages are
--- collected. Returns `ok, messages, results...` (`results` is the error
--- when `ok` is false).
---@return boolean ok, { msg: string, level: integer }[] messages, any ...
function M.noninteractive(fn, ...)
  local saved = M._messages
  local msgs = {}
  M._messages = msgs
  M._noninteractive = M._noninteractive + 1
  local res = { pcall(fn, ...) }
  M._noninteractive = M._noninteractive - 1
  M._messages = saved
  return res[1], msgs, unpack(res, 2, table.maxn(res))
end

---------------------------------------------------------------------------
-- Coroutines
---------------------------------------------------------------------------

--- Resume a coroutine and report errors.
local function resume(co, ...)
  local res = { coroutine.resume(co, ...) }
  if not res[1] then
    local err = res[2]
    if type(err) == "string" and err:find("org_abort", 1, true) then
      return false
    end
    -- an error of a key the action ran with `:normal!` (`p` from an empty
    -- register: E353) is the user's, shown like Vim shows it
    local vim_err = type(err) == "string" and err:match("Vim%(normal%):(E%d+: .*)$")
    if vim_err then
      M.error(vim_err)
      return false
    end
    M.error(debug.traceback(co, tostring(err)))
    return false
  end
  return true, unpack(res, 2)
end

--- Run `fn` in a coroutine. Returns (finished, results...) where
--- `finished` is true when fn completed without yielding.
function M.run(fn, ...)
  local co = coroutine.create(fn)
  local res = { resume(co, ...) }
  local finished = coroutine.status(co) == "dead"
  return finished, unpack(res, 2)
end

--- Wrap `fn` so calling it runs in a coroutine.
function M.async(fn)
  return function(...)
    return M.run(fn, ...)
  end
end

--- Abort the running interactive action silently.
function M.abort()
  error("org_abort", 0)
end

local function in_coroutine()
  local co, main = coroutine.running()
  return co and not main and co or nil
end

--- Yield until `register(callback)` calls the callback.
function M.await(register)
  local co = in_coroutine()
  if not co then
    error("org.utils.await called outside of a coroutine (wrap with org.utils.run)")
  end
  local done, result = false, nil
  register(function(...)
    local args = { ... }
    vim.schedule(function()
      if done then
        return
      end
      done = true
      result = args
      resume(co, unpack(args))
    end)
  end)
  return coroutine.yield()
end

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------

--- Prompt for text. Returns nil when cancelled.
---@param opts { prompt: string, default?: string, completion?: string }
function M.input(opts)
  if type(opts) == "string" then
    opts = { prompt = opts }
  end
  if M._noninteractive > 0 then
    return nil
  end
  if not in_coroutine() then
    local ok, v = pcall(vim.fn.input, opts)
    return ok and v or nil
  end
  return M.await(function(cb)
    vim.ui.input(opts, cb)
  end)
end

--- Read a log note like Emacs' `*Org Note*` buffer: a small split where the
--- note is typed over several lines, <C-c><C-c> stores it and <C-c><C-k>
--- cancels (returns nil). Lines starting with "# " at the top are dropped.
--- Falls back to a one-line `M.input` outside an interactive action or
--- with `note_buffer = false`.
---@param opts { prompt: string, purpose?: string }
---@return string|nil
function M.input_note(opts)
  if type(opts) == "string" then
    opts = { prompt = opts }
  end
  if M._noninteractive > 0 then
    return nil
  end
  local ok_cfg, config = pcall(require, "org.config")
  local use_buffer = not (ok_cfg and config.opts.note_buffer == false)
  if not use_buffer or not in_coroutine() or #vim.api.nvim_list_uis() == 0 then
    return M.input(opts)
  end
  local what = (opts.purpose or opts.prompt or "note"):gsub("[:%s]+$", "")
  return M.await(function(cb)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# Insert note for " .. what .. ".",
      "# Finish with C-c C-c, or cancel with C-c C-k.",
      "",
    })
    vim.cmd("botright 8split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].filetype = "org"
    pcall(vim.api.nvim_buf_set_name, buf, "*Org Note*")
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    vim.cmd("startinsert")
    local done = false
    local function finish(text)
      if done then
        return
      end
      done = true
      vim.cmd("stopinsert")
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      cb(text)
    end
    local function store()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      while lines[1] and lines[1]:match("^# ") do
        table.remove(lines, 1)
      end
      finish((vim.trim(table.concat(lines, "\n"))))
    end
    for _, mode in ipairs({ "n", "i" }) do
      vim.keymap.set(mode, "<C-c><C-c>", store, { buffer = buf, desc = "org: store note" })
      vim.keymap.set(mode, "<C-c><C-k>", function()
        finish(nil)
      end, { buffer = buf, desc = "org: cancel note" })
    end
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        finish(nil)
      end,
    })
    -- org-log-buffer-setup-hook
    M.user_event("OrgLogBufferSetup", { bufnr = buf, purpose = what })
  end)
end

--- Prompt for text with a completion function (always uses the cmdline so
--- custom completion works). `complete` receives the typed text.
---@param prompt string
---@param candidates string[]|fun(arglead:string):string[]
---@param default? string
---@return string?
function M.input_complete(prompt, candidates, default)
  if M._noninteractive > 0 then
    return nil
  end
  M._complete_candidates = candidates
  local ok, value = pcall(vim.fn.input, {
    prompt = prompt,
    default = default or "",
    completion = "customlist,v:lua.require'org.utils'._input_complete",
    cancelreturn = vim.NIL,
  })
  M._complete_candidates = nil
  if not ok or value == vim.NIL then
    return nil
  end
  return value
end

---@param arglead string
---@param cmdline string
---@return string[]
function M._input_complete(arglead, cmdline, _)
  local c = M._complete_candidates
  ---@type string[]
  local list
  if type(c) == "function" then
    list = c(cmdline) or {}
  else
    list = c or {}
  end
  -- complete only the last word (after ':' or space) for tag-like inputs
  local lead = cmdline:match("([^:%s]*)$") or ""
  local prefix = cmdline:sub(1, #cmdline - #lead)
  local out = {}
  for _, item in ipairs(list) do
    if item:lower():find(lead:lower(), 1, true) == 1 then
      out[#out + 1] = prefix .. item
    end
  end
  return out
end

--- Choose from a list. Returns item, index (nil when cancelled).
---@param items any[]
---@param opts? { prompt?: string, format_item?: (fun(item:any):string), kind?: string }
function M.select(items, opts)
  if #items == 0 or M._noninteractive > 0 then
    return nil
  end
  if not in_coroutine() then
    error("org.utils.select must run inside org.utils.run")
  end
  return M.await(function(cb)
    vim.ui.select(items, opts or {}, cb)
  end)
end

--- Yes/no confirmation (synchronous).
function M.confirm(msg)
  if M._noninteractive > 0 then
    return false
  end
  local ok, c = pcall(vim.fn.confirm, msg, "&Yes\n&No", 2)
  return ok and c == 1
end

--- Start Insert mode at the cursor, or after the end of the line when the
--- cursor is past it or on its trailing space. Normal mode keeps the cursor
--- on the last character, so on a new "- " or "** " line a plain
--- `startinsert` would put the typed text before that space.
function M.start_insert()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_get_current_line()
  if col >= #line or (col == #line - 1 and line:sub(-1) == " ") then
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
  end
end

--- Read one key (synchronous). Returns nil for <Esc>/<C-c>.
function M.getchar(prompt)
  if M._noninteractive > 0 then
    return nil
  end
  if prompt then
    vim.api.nvim_echo({ { prompt, "Question" } }, false, {})
  end
  local ok, ch = pcall(vim.fn.getcharstr)
  vim.api.nvim_echo({ { "" } }, false, {})
  if not ok or ch == "\27" or ch == "\3" then
    return nil
  end
  return ch
end
