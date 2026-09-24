---@mod org.utils Helpers
---
--- Async helpers: interactive actions run inside a coroutine (`M.run`) so
--- they can call `M.input`, `M.select`, `M.confirm` linearly even though
--- `vim.ui.*` are callback based (snacks.nvim / dressing replace them).

local M = {}

M.augroup = vim.api.nvim_create_augroup("org.nvim", { clear = false })

---------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------

function M.notify(msg, level, opts)
  vim.notify(msg, level or vim.log.levels.INFO, vim.tbl_extend("force", { title = "org" }, opts or {}))
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
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

--- Prompt for text. Returns nil when cancelled.
---@param opts { prompt: string, default?: string, completion?: string }
function M.input(opts)
  if type(opts) == "string" then
    opts = { prompt = opts }
  end
  if not in_coroutine() then
    local ok, v = pcall(vim.fn.input, opts)
    return ok and v or nil
  end
  return M.await(function(cb)
    vim.ui.input(opts, cb)
  end)
end

--- Prompt for text with a completion function (always uses the cmdline so
--- custom completion works). `complete` receives the typed text.
---@param prompt string
---@param candidates string[]|fun(arglead:string):string[]
---@param default? string
function M.input_complete(prompt, candidates, default)
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

function M._input_complete(arglead, cmdline, _)
  local c = M._complete_candidates
  local list = type(c) == "function" and c(cmdline) or c or {}
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
---@param opts? { prompt?: string, format_item?: fun(item:any):string, kind?: string }
function M.select(items, opts)
  if #items == 0 then
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
  local ok, c = pcall(vim.fn.confirm, msg, "&Yes\n&No", 2)
  return ok and c == 1
end

--- Read one key (synchronous). Returns nil for <Esc>/<C-c>.
function M.getchar(prompt)
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

---------------------------------------------------------------------------
-- Strings
---------------------------------------------------------------------------

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.ends_with(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

function M.escape_pattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

function M.width(s)
  return vim.api.nvim_strwidth(s)
end

--- Pad string to display width.
function M.pad_right(s, width)
  local w = M.width(s)
  if w >= width then
    return s
  end
  return s .. string.rep(" ", width - w)
end

function M.pad_left(s, width)
  local w = M.width(s)
  if w >= width then
    return s
  end
  return string.rep(" ", width - w) .. s
end

--- Truncate to display width, appending an ellipsis if needed.
function M.truncate(s, width)
  if M.width(s) <= width then
    return s
  end
  local out = vim.fn.strcharpart(s, 0, width - 1)
  while M.width(out) > width - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

--- Random v4 UUID.
function M.uuid()
  local bytes = {}
  local ok, rnd = pcall(vim.uv.random, 16)
  for i = 1, 16 do
    bytes[i] = ok and rnd and rnd:byte(i) or math.random(0, 255)
  end
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do
    hex[i] = string.format("%02x", bytes[i])
  end
  local s = table.concat(hex)
  return string.format("%s-%s-%s-%s-%s", s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

---------------------------------------------------------------------------
-- Paths & files
---------------------------------------------------------------------------

--- Expand `~`, env vars and make absolute. Relative paths resolve against
--- `base` (default: org_directory).
function M.expand(path, base)
  if not path or path == "" then
    return path
  end
  if path:find("[%*%?%[]") then
    -- vim.fn.expand() would expand wildcards (joining matches with newlines);
    -- only expand ~ and environment variables for glob patterns
    path = path:gsub("^~", vim.env.HOME or "~"):gsub("%$(%w+)", function(v)
      return vim.env[v] or ("$" .. v)
    end)
  else
    path = vim.fn.expand(path)
  end
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    base = base or M.expand(require("org.config").opts.org_directory, vim.fn.getcwd())
    path = base .. "/" .. path
  end
  return vim.fs.normalize(path)
end

function M.exists(path)
  return path and vim.uv.fs_stat(path) ~= nil
end

function M.is_dir(path)
  local st = path and vim.uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

function M.mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec * 1e9 + st.mtime.nsec) or nil
end

---@return string[]|nil
function M.readfile(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  content = content:gsub("\r\n", "\n")
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.writefile(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    error("org: cannot write " .. path .. ": " .. tostring(err))
  end
  fd:write(table.concat(lines, "\n"))
  if #lines > 0 then
    fd:write("\n")
  end
  fd:close()
end

function M.read_json(path)
  local lines = M.readfile(path)
  if not lines then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok and data or nil
end

function M.write_json(path, data)
  M.writefile(path, { vim.json.encode(data) })
end

--- Expand a list of files/dirs/globs into unique absolute `.org` paths.
---@param patterns string|string[]
---@return string[]
function M.glob_org_files(patterns)
  if type(patterns) == "string" then
    patterns = { patterns }
  end
  local seen, out = {}, {}
  local function add(p)
    p = vim.fs.normalize(p)
    if not seen[p] and (p:match("%.org$") or p:match("%.org_archive$")) and M.exists(p) then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  for _, pattern in ipairs(patterns or {}) do
    local expanded = M.expand(pattern)
    if M.is_dir(expanded) then
      for _, f in ipairs(vim.fn.globpath(expanded, "**/*.org", false, true)) do
        add(f)
      end
    elseif expanded:find("[%*%?%[]") then
      for _, f in ipairs(vim.fn.glob(expanded, false, true)) do
        if M.is_dir(f) then
          for _, g in ipairs(vim.fn.globpath(f, "**/*.org", false, true)) do
            add(g)
          end
        else
          add(f)
        end
      end
    else
      add(expanded)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Buffers
---------------------------------------------------------------------------

--- Loaded buffer for a path, or nil.
function M.find_buffer(path)
  path = vim.fs.normalize(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.fs.normalize(name) == path then
        return b
      end
    end
  end
  local real = vim.uv.fs_realpath(path)
  if real then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and vim.uv.fs_realpath(name) == real then
          return b
        end
      end
    end
  end
end

--- Buffer for a path, loading it (hidden) when needed.
function M.load_buffer(path)
  local b = M.find_buffer(path)
  if b then
    return b
  end
  b = vim.fn.bufadd(path)
  vim.bo[b].buflisted = true
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

--- Write a buffer silently if it has changes.
function M.save_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! noautocmd keepalt write")
    end)
    require("org.files").invalidate(vim.api.nvim_buf_get_name(bufnr))
  end
end

--- Open `path` in the current window (or reuse a window showing it) at `lnum`.
---@param opts? { split?: string, col?: integer, reuse_win?: boolean }
function M.open_file(path, lnum, opts)
  opts = opts or {}
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
      vim.api.nvim_set_current_buf(b)
    else
      -- `hide` avoids E37 when the current buffer has unsaved changes
      vim.cmd((cmd == "edit" and "hide " or "") .. cmd .. " " .. vim.fn.fnameescape(path))
    end
  end
  if lnum then
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(lnum, last)), opts.col or 0 })
    vim.cmd("normal! zv")
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

return M
