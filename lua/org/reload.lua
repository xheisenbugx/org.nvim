---@mod org.reload Reload org buffers whose file another program changed
---
--- With `reload_on_change` (on by default), the directory of every org
--- buffer's file is watched (libuv fs_event; a directory rather than the
--- file, so that saves which write a temporary file and rename it over the
--- original are seen too). When the file changes on disk (a sync tool such
--- as Syncthing, a `git pull`, another editor):
---
--- - an unmodified buffer is reloaded, the way `:checktime` reloads it
---   with 'autoread': the cursor, the view and the closed folds stay, and
---   `u` brings back the text from before the reload;
--- - a modified buffer is never touched: a warning says the file changed.
---   Its timestamp stays the one Vim read, so `:w` still asks before it
---   overwrites the other program's changes (W10/"changed since reading").
---
--- Org's own writes (`:w`, `utils.save_buffer`) record the file's stat
--- through a write hook, and an unmodified buffer is only reloaded when
--- Vim's `:checktime` sees a change, so they never cause a reload.
---
--- Neovim 0.13+ watches 'autoread' buffers itself (runtime nvim/autoread.lua,
--- debounced 100 ms) and may reload first: the views and folds are
--- recorded as soon as an event arrives and put back on any
--- FileChangedShellPost, and a modified buffer is left to its W12 prompt.
local M = {}

local uv = vim.uv
-- milliseconds after the last event of a burst before the file is looked at
M.debounce = 200
-- directories watched at most; the files of others are still checked by
-- Neovim's own 'autoread' (on focus, :checktime)
M.max_watchers = 64

---@class org.reload.Dir
---@field handle uv.uv_fs_event_t
---@field bufs table<integer, string> buffer -> basename of its file

---@type table<string, org.reload.Dir> directory -> watcher
local dirs = {}
---@type table<integer, string> buffer -> watched directory
local buf_dir = {}
---@type table<integer, string> buffer -> stat key of the file as last read or written
local known = {}
---@type table<integer, string> buffer -> stat key already warned about
local warned = {}
---@type table<integer, uv.uv_timer_t>
local timers = {}
---@type table<integer, table[]> buffer -> its windows' views and closed folds before a reload
local snapshots = {}

--- Counters (tests, :checkhealth).
M.stats = { reloads = 0, warnings = 0 }

local fold_case = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

local function enabled()
  return require("org.config").opts.reload_on_change ~= false
end

local function close_handle(h)
  -- lint: allow pcall: the handle may be closed already
  pcall(function()
    h:stop()
    if not h:is_closing() then
      h:close()
    end
  end)
end

local function key_name(name)
  return fold_case and name:lower() or name
end

---@param path string
---@return string|nil
local function stat_key(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return ("%d.%d:%d:%d"):format(st.mtime.sec, st.mtime.nsec or 0, st.size, st.ino or 0)
end

local function file_of(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

--- Remember the file as it is now: what the buffer holds after a read or
--- a write. A later event with the same stat is org's (or Vim's) own.
---@param buf integer
function M.remember(buf)
  local path = file_of(buf)
  known[buf] = path and stat_key(path) or nil
  warned[buf] = nil
end

local function unwatch(buf)
  local d = buf_dir[buf]
  buf_dir[buf] = nil
  local w = d and dirs[d]
  if w then
    w.bufs[buf] = nil
    if next(w.bufs) == nil then
      close_handle(w.handle)
      dirs[d] = nil
    end
  end
end

--- Stop watching for `buf` and forget it (BufWipeout, BufUnload).
---@param buf integer
function M.detach(buf)
  unwatch(buf)
  known[buf], warned[buf], snapshots[buf] = nil, nil, nil
  local t = timers[buf]
  if t then
    timers[buf] = nil
    close_handle(t)
  end
end

local schedule_check

--- Watch the directory of `dir`'s files.
---@param d string
---@return org.reload.Dir|nil
local function watch_dir(d)
  if dirs[d] then
    return dirs[d]
  end
  if vim.tbl_count(dirs) >= M.max_watchers then
    return nil
  end
  local h = uv.new_fs_event()
  if not h then
    return nil
  end
  local entry = { handle = h, bufs = {} }
  local ok = h:start(d, {}, function(err, fname)
    -- a fast callback: no vim.api here
    if err then
      vim.schedule(function()
        if dirs[d] == entry then
          close_handle(h)
          dirs[d] = nil
          for b in pairs(entry.bufs) do
            buf_dir[b] = nil
          end
        end
      end)
      return
    end
    local tail = fname and fname:match("[^/\\]+$")
    tail = tail and key_name(tail)
    for b, name in pairs(entry.bufs) do
      if not tail or tail == name then
        -- the folds as they are now, before anything reloads the buffer
        -- (Neovim's own 'autoread' watcher may, before the debounce ends)
        vim.schedule(function()
          M.snapshot(b)
        end)
        schedule_check(b)
      end
    end
  end)
  if ok ~= 0 then
    close_handle(h)
    return nil
  end
  dirs[d] = entry
  return entry
end

--- Watch the file of `buf` (an org buffer). Called whenever the buffer is
--- set up (FileType, so also after every read) and when its name changes.
---@param buf integer
function M.attach(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not enabled() or not vim.api.nvim_buf_is_loaded(buf) then
    M.detach(buf)
    return
  end
  local path = file_of(buf)
  if not path then
    M.detach(buf)
    return
  end
  M.remember(buf)
  local d = vim.fs.dirname(path)
  if not uv.fs_stat(d) then
    unwatch(buf)
    return
  end
  local real = uv.fs_realpath(d) or d
  if buf_dir[buf] ~= real then
    unwatch(buf)
  end
  local w = watch_dir(real)
  if w then
    w.bufs[buf] = key_name(vim.fs.basename(path))
    buf_dir[buf] = real
  end
end

-- The closed folds of `win`, by start line and its text.
local function closed_folds(win)
  local out = {}
  vim.api.nvim_win_call(win, function()
    local l, last = 1, vim.api.nvim_buf_line_count(0)
    while l <= last do
      local s = vim.fn.foldclosed(l)
      if s == l then
        out[#out + 1] = { l, vim.fn.getline(l) }
        l = vim.fn.foldclosedend(l) + 1
      else
        l = l + 1
      end
    end
  end)
  return out
end

-- Close the folds again, at the same line or at the nearest line with the
-- same text (lines added or removed above move them).
local function restore_folds(win, folds)
  vim.api.nvim_win_call(win, function()
    local last = vim.api.nvim_buf_line_count(0)
    for i = #folds, 1, -1 do
      local lnum, text = folds[i][1], folds[i][2]
      local at
      for off = 0, last do
        local a, b = lnum - off, lnum + off
        if a >= 1 and a <= last and vim.fn.getline(a) == text then
          at = a
        elseif b >= 1 and b <= last and vim.fn.getline(b) == text then
          at = b
        end
        if at or (a < 1 and b > last) then
          break
        end
      end
      if at and vim.fn.foldlevel(at) > 0 and vim.fn.foldclosed(at) == -1 then
        pcall(vim.api.nvim_command, at .. "foldclose")
      end
    end
  end)
end

--- Record the view and closed folds of the windows of unmodified `buf`,
--- to be put back once the buffer is reloaded (by org or by Neovim).
---@param buf integer
function M.snapshot(buf)
  if snapshots[buf] or not enabled() or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified then
    return
  end
  local wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    wins[#wins + 1] = {
      win = win,
      view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      folds = closed_folds(win),
    }
  end
  snapshots[buf] = wins
end

-- After a reload: the views and folds of the snapshot back.
local function restore(buf)
  local wins = snapshots[buf]
  snapshots[buf] = nil
  if not wins or vim.bo[buf].modified then
    return
  end
  M.stats.reloads = M.stats.reloads + 1
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w.win) and vim.api.nvim_win_get_buf(w.win) == buf then
      restore_folds(w.win, w.folds)
      local last = vim.api.nvim_buf_line_count(buf)
      w.view.lnum = math.min(w.view.lnum, last)
      w.view.topline = math.min(w.view.topline, last)
      vim.api.nvim_win_call(w.win, function()
        vim.fn.winrestview(w.view)
      end)
    end
  end
end

-- Whether Neovim watches `buf`'s file itself (Neovim 0.13+: 'autoread'
-- uses file system watchers): it then reloads an unmodified buffer, and
-- asks about a modified one (W12), without org.
local function native_watch(buf)
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "nvim.autoread" })
  if not ok or #cmds == 0 then
    return false
  end
  local l = vim.bo[buf].autoread
  if l == nil then
    return vim.go.autoread
  end
  return l
end

-- Reload unmodified `buf` through :checktime, answering its
-- FileChangedShell "reload" (Vim reloads only when its own timestamp of the
-- file differs, so a write of ours is never reloaded).
local function reload(buf)
  M.snapshot(buf)
  local group = vim.api.nvim_create_augroup("org.reload.check", { clear = true })
  -- (not triggered with 'autoread' on: Vim then reloads the unmodified
  -- buffer itself)
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = group,
    buffer = buf,
    callback = function()
      if vim.v.fcs_reason == "changed" and not vim.bo[buf].modified then
        vim.v.fcs_choice = "reload"
      else
        -- deleted (a rename-save half done), only the mode or time, or
        -- modified meanwhile: nothing now
        vim.v.fcs_choice = ""
      end
    end,
  })
  -- (the FileChangedShellPost autocommand below puts the folds back)
  local ok, err = pcall(function()
    vim.cmd("checktime " .. buf)
  end)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  return ok, err
end

-- Not now: Insert or Command-line mode in that buffer, the command-line
-- window, or a pending operator. Try again later.
local function busy(buf)
  local mode = vim.api.nvim_get_mode()
  if mode.blocking or vim.fn.getcmdwintype() ~= "" then
    return true
  end
  local m = mode.mode:sub(1, 1)
  if m == "c" or (m ~= "n" and vim.api.nvim_get_current_buf() == buf) then
    return true
  end
  return mode.mode:sub(1, 2) == "no"
end

--- Look at the file of `buf` now: reload or warn (what an event leads to,
--- after the debounce).
---@param buf integer
---@param tries? integer checks left for a file that is missing (a save
--- that renames over it, not done yet)
function M.check(buf, tries)
  if not enabled() or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local path = file_of(buf)
  if not path then
    return
  end
  local key = stat_key(path)
  if not key then
    if (tries or 3) > 1 then
      schedule_check(buf, (tries or 3) - 1)
    end
    return
  end
  if key == known[buf] then
    -- (reloaded already, by Neovim: the FileChangedShellPost autocommand
    -- used the snapshot, if any)
    snapshots[buf] = nil
    return
  end
  if busy(buf) then
    schedule_check(buf, tries)
    return
  end
  if vim.bo[buf].modified then
    snapshots[buf] = nil
    if warned[buf] ~= key and not native_watch(buf) then
      warned[buf] = key
      M.stats.warnings = M.stats.warnings + 1
      require("org.utils").warn(
        ("%s changed on disk; your unsaved changes are kept (:e! loads the file, :w asks first)"):format(
          vim.fn.fnamemodify(path, ":t")
        )
      )
    end
    return
  end
  local ok = reload(buf)
  -- (nothing reloaded, a snapshot left: Vim saw no change)
  snapshots[buf] = nil
  if ok then
    known[buf] = key
  end
end

--- Check `buf` once `M.debounce` ms have passed without another event.
--- Safe from a fast (libuv) callback.
---@param buf integer
---@param tries? integer
function schedule_check(buf, tries)
  local t = timers[buf] ---@type uv.uv_timer_t?
  if not t then
    t = uv.new_timer()
    if not t then
      return
    end
    timers[buf] = t
  end
  t:stop()
  t:start(M.debounce, 0, function()
    vim.schedule(function()
      if timers[buf] == t then
        timers[buf] = nil
        close_handle(t)
      end
      M.check(buf, tries)
    end)
  end)
end

--- Directories watched (tests, :checkhealth).
---@return integer
function M.watch_count()
  return vim.tbl_count(dirs)
end

--- Stop every watcher (reload_on_change turned off, tests).
function M.stop()
  for b in pairs(buf_dir) do
    M.detach(b)
  end
  for _, w in pairs(dirs) do
    close_handle(w.handle)
  end
  dirs, buf_dir = {}, {}
end

local group = vim.api.nvim_create_augroup("org.reload", { clear = true })
vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
  group = group,
  callback = function(ev)
    if buf_dir[ev.buf] or known[ev.buf] or timers[ev.buf] or snapshots[ev.buf] then
      M.detach(ev.buf)
    end
  end,
})
-- :file, :saveas: the buffer's file is another one now
vim.api.nvim_create_autocmd("BufFilePost", {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].filetype == "org" then
      M.attach(ev.buf)
    end
  end,
})
-- The buffer was reloaded (by org, or by Neovim: 'autoread', a W11/W12
-- dialog): what it holds is the file now; the folds go back
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = group,
  callback = function(ev)
    if buf_dir[ev.buf] then
      M.remember(ev.buf)
    end
    if snapshots[ev.buf] then
      restore(ev.buf)
    end
  end,
})
require("org.write_hooks").register("reload", {
  order = 90,
  filetype = "org",
  post = function(bufnr, ctx)
    if ctx.ok and enabled() then
      -- (also the first write of a new file: its directory is watched now)
      M.attach(bufnr)
    end
  end,
})

return M
