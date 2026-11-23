---@mod org.utils.buffer Buffer, file navigation, save and selection helpers
---
--- Part of org.utils, which loads it.

local M = require("org.utils")

---------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------

-- bufnr -> { name, norm, real }: a buffer's normalized name and resolved
-- path, so that looking up many files (the agenda) doesn't resolve every
-- buffer's name each time. Entries are checked against the current name.
local buf_paths = {}

local function buf_path(b)
  local name = vim.api.nvim_buf_get_name(b)
  if name == "" then
    return nil
  end
  local c = buf_paths[b]
  if not c or c.name ~= name then
    c = { name = name, norm = vim.fs.normalize(name) }
    buf_paths[b] = c
  end
  return c
end

-- path -> its resolved path, for the files looked up (an agenda looks up
-- every agenda file on each build): resolving a path is a system call per
-- directory in it. Only paths that exist; dropped with buf_paths below.
local real_paths = {}

local function path_realpath(path)
  local real = real_paths[path]
  if not real then
    real = M.realpath(path)
    real_paths[path] = real
  end
  return real
end

local function buf_realpath(c)
  if c.real == nil then
    c.real = M.realpath(c.name) or false
  end
  return c.real
end

vim.api.nvim_create_autocmd({ "BufWipeout", "BufWritePost", "BufFilePost" }, {
  group = M.augroup,
  callback = function(ev)
    buf_paths[ev.buf] = nil
  end,
})
-- a buffer's file may have been created or replaced by a link outside Vim
vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost", "FileChangedShellPost" }, {
  group = M.augroup,
  callback = function()
    buf_paths = {}
    real_paths = {}
  end,
})

--- Loaded buffer for a path, or nil.
function M.find_buffer(path)
  path = vim.fs.normalize(path)
  local bufs = vim.api.nvim_list_bufs()
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_loaded(b) then
      local c = buf_path(b)
      if c and c.norm == path then
        return b
      end
    end
  end
  local real = path_realpath(path)
  if real then
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(b) then
        local c = buf_path(b)
        if c and buf_realpath(c) == real then
          return b
        end
      end
    end
  end
end

-- Buffers load_buffer created unlisted, listed once a normal window shows them.
local background = {}

local function list_when_shown(b)
  background[b] = true
  local group = vim.api.nvim_create_augroup("org_background_buffers", { clear = false })
  if #vim.api.nvim_get_autocmds({ group = group }) > 0 then
    return
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if not background[ev.buf] then
        return
      end
      for _, w in ipairs(vim.fn.win_findbuf(ev.buf)) do
        if vim.api.nvim_win_get_config(w).relative == "" then
          background[ev.buf] = nil
          vim.bo[ev.buf].buflisted = true
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      background[ev.buf] = nil
    end,
  })
end

--- Buffer for a path, loading it (hidden) when needed. A buffer it creates
--- stays unlisted, so background edits (agenda, refile, capture, clock)
--- don't add it to the buffer list or a buffer tabline; it's listed once
--- it's shown in a normal window, like a file opened with :edit.
function M.load_buffer(path)
  local b = M.find_buffer(path)
  if b then
    return b
  end
  b = vim.fn.bufadd(path)
  if not vim.bo[b].buflisted then
    list_when_shown(b)
  end
  -- A hidden load can't show the swap-file dialog; from Lua the ATTENTION
  -- message surfaces as E325. Suppress it ('shortmess' A) and load anyway.
  local shortmess = vim.o.shortmess
  vim.opt.shortmess:append("A")
  local ok, err = pcall(vim.fn.bufload, b)
  vim.o.shortmess = shortmess
  if not ok then
    error(err, 0)
  end
  if vim.bo[b].filetype == "" then
    vim.bo[b].filetype = "org"
  end
  return b
end

--- The hunks between texts `a` and `b`, as `{ start_a, count_a, start_b,
--- count_b }` lists: Neovim's xdiff with `result_type = "indices"`
--- (`vim.text.diff` on Neovim 0.12+, `vim.diff` before it).
---@param a string
---@param b string
---@return integer[][]
function M.diff_indices(a, b)
  -- the deprecated `vim.diff` is only reached on Neovim 0.11, which has no `vim.text.diff`
  ---@diagnostic disable-next-line: deprecated
  local xdiff = (vim.text and vim.text.diff) or vim.diff
  return xdiff(a, b, { result_type = "indices" }) --[[@as integer[][] ]]
end

--- Lines `first`..`last` (1-based, `last` included; default the whole
--- buffer) of buffer `bufnr` as its file holds them: text that is in the
--- buffer only to be shown (what the transclusion extension inserted) and
--- never reaches the file is left out. Anything that copies buffer text
--- somewhere else (refile, archive, a kill) takes it from here, or the
--- shown text would become real text there.
---@param bufnr integer
---@param first? integer
---@param last? integer
---@return string[]
function M.file_lines(bufnr, first, last)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  first = first or 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last or -1, false)
  -- only when the extension is loaded: core never loads it
  local tr = package.loaded["org.extensions.transclusion"]
  local inside = tr and tr.inserted_rows and tr.inserted_rows(bufnr)
  if not inside then
    return lines
  end
  local out = {}
  for i, l in ipairs(lines) do
    if not inside[first + i - 1] then
      out[#out + 1] = l
    end
  end
  return out
end

--- Restore a synchronous edit snapshot without replacing unchanged lines.
--- This keeps unrelated extmarks and cursor locations intact on rollback.
function M.restore_buffer(bufnr, lines, modified)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = M.diff_indices(table.concat(current, "\n") .. "\n", table.concat(lines, "\n") .. "\n")
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start = h[2] == 0 and h[1] or h[1] - 1
    vim.api.nvim_buf_set_lines(bufnr, start, start + h[2], false, vim.list_slice(lines, h[3], h[3] + h[4] - 1))
  end
  vim.bo[bufnr].modified = modified
end

--- Write a buffer silently if it has changes. Returns false and a one-line
--- error when the write fails: moving data must never continue after a
--- failed destination save, so callers check the result.
---
--- The write skips autocommands (user formatters and the like don't run on
--- org's background saves), but the `org.write_hooks` pre/post hooks run
--- exactly as they do for `:w` (crypt's encrypt_on_save, transclusion,
--- ...). A hook that vetoes makes this return false and its message.
---
--- A file whose directory doesn't exist asks to create it, as
--- basic-save-buffer does in Emacs; no (and every prompt inside
--- `M.noninteractive`) returns false and "Canceled".
---@return boolean ok, string? err
function M.save_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local dir = vim.fn.fnamemodify(name, ":p:h")
    -- (a URL like scp://host/f.org isn't a local directory to create)
    if not name:match("^%a[%w+.-]+://") and not vim.uv.fs_stat(dir) then
      if not M.confirm(("Directory `%s/' does not exist; create? "):format(vim.fs.normalize(dir))) then
        return false, "Canceled"
      end
      local made, merr = pcall(M.mkdir_p, dir)
      if not made then
        merr = tostring(merr)
        return false, merr:match("E%d+:[^\n]*") or merr:match("^[^\n]*")
      end
    end
    local hooks = require("org.write_hooks")
    local hok, herr, run = hooks.run_pre(bufnr, "save_buffer")
    if not hok then
      return false, herr
    end
    local ok, err
    vim.api.nvim_buf_call(bufnr, function()
      ok, err = pcall(vim.cmd --[[@as fun(command: string)]], "silent noautocmd keepalt write")
    end)
    if ok then
      require("org.files").invalidate(vim.api.nvim_buf_get_name(bufnr))
    end
    hooks.run_post(run, ok)
    if not ok then
      err = tostring(err)
      return false, err:match("E%d+:[^\n]*") or err:match("^[^\n]*")
    end
  end
  return true
end

--- Save a buffer and warn when the write fails. Returns whether it saved.
function M.save_buffer_or_warn(bufnr)
  local ok, err = M.save_buffer(bufnr)
  if not ok then
    M.warn(("Could not save %s: %s"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."), err))
  end
  return ok
end

--- Show buffer `b` in the current window. A modified buffer there that
--- can't be hidden (bufhidden=wipe, E37) keeps its window, and `b` opens
--- in a split.
function M.set_current_buf(b)
  local ok, err = pcall(vim.api.nvim_set_current_buf, b)
  if not ok then
    if not tostring(err):find("E37", 1, true) then
      error(err, 0)
    end
    vim.cmd("split")
    vim.api.nvim_set_current_buf(b)
  end
end

--- Open `path` in the current window (or reuse a window showing it) at `lnum`.
--- `opts.reveal` false leaves the folds as they are (the caller shows the
--- context), instead of opening those around the line.
---@param opts? { split?: string, col?: integer, reuse_win?: boolean, reveal?: boolean }
function M.open_file(path, lnum, opts)
  opts = opts or {}
  ---@type string?
  local cmd = ({ split = "split", vsplit = "vsplit", tab = "tabedit" })[opts.split or ""] or "edit"
  if opts.reuse_win then
    local b = M.find_buffer(path)
    if b then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == b then
          vim.api.nvim_set_current_win(w)
          cmd = nil
          break
        end
      end
    end
  end
  if cmd then
    local b = M.find_buffer(path)
    if b and cmd == "edit" then
      M.set_current_buf(b)
    else
      -- `hide` avoids E37 when the current buffer has unsaved changes; a
      -- modified buffer that can't be hidden (bufhidden=wipe) keeps its
      -- window and the file opens in a split
      local ok, err = pcall(
        vim.cmd --[[@as fun(command: string)]],
        (cmd == "edit" and "hide " or "") .. cmd .. " " .. vim.fn.fnameescape(path)
      )
      if not ok then
        if cmd == "edit" and tostring(err):find("E37", 1, true) then
          vim.cmd("split " .. vim.fn.fnameescape(path))
        else
          error(err, 0)
        end
      end
    end
  end
  if lnum then
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(lnum, last)), opts.col or 0 })
    if opts.reveal ~= false then
      vim.cmd("normal! zv")
    end
  end
end

function M.get_lines(bufnr, s, e)
  return vim.api.nvim_buf_get_lines(bufnr or 0, s - 1, e, false)
end

--- Replace lines s..e (1-based, inclusive) with `lines`. e = s-1 inserts.
function M.set_lines(bufnr, s, e, lines)
  vim.api.nvim_buf_set_lines(bufnr or 0, s - 1, e, false, lines)
end

function M.cursor()
  local c = vim.api.nvim_win_get_cursor(0)
  return c[1], c[2] + 1 -- 1-based column
end

--- Visual selection range {srow, scol, erow, ecol} (1-based, inclusive).
function M.visual_range()
  local mode = vim.fn.mode()
  local s, e
  if mode == "v" or mode == "V" or mode == "\22" then
    s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
  else
    s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  end
  local srow, scol, erow, ecol = s[2], s[3], e[2], e[3]
  if srow > erow or (srow == erow and scol > ecol) then
    srow, scol, erow, ecol = erow, ecol, srow, scol
  end
  return srow, scol, erow, ecol, mode
end

--- Byte index (1-based) of the last byte of the character starting at
--- byte `col` of `line`, at most `#line`. A charwise Visual selection's end
--- column (`visual_range`) is the first byte of its last character: slice
--- with this, or a multibyte last character is cut in half.
---@param line string
---@param col integer
---@return integer
function M.char_end(line, col)
  if col < 1 or col >= #line then
    return math.min(col, #line)
  end
  return col + vim.str_utf_end(line, col)
end

--- Leave Visual mode, setting the '< and '> marks, when it is active.
--- Unlike feedkeys() with the "x" flag, this does not run the keys typed
--- ahead (a key already typed for the prompt that follows, or the rest of
--- a macro), which would then run as Visual-mode commands.
function M.exit_visual()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \27")
  end
end

--- Is the current buffer an org buffer?
function M.is_org(bufnr)
  return vim.bo[bufnr or 0].filetype == "org"
end

function M.ensure_org()
  if not M.is_org() then
    M.warn("Not an org buffer")
    return false
  end
  return true
end
