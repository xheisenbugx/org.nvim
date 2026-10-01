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
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "OrgLogBufferSetup",
      data = { bufnr = buf, purpose = what },
      modeline = false,
    })
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

-- The LuaJIT of Neovim 0.11 rounds exact ties away from zero
-- (string.format("%.2f", 0.125) is "0.13"); C printf, and so Emacs,
-- rounds them to even. There, format floats with the C library.
local c_snprintf
if string.format("%.2f", 0.125) ~= "0.12" and jit then
  local ffi = require("ffi")
  pcall(ffi.cdef, "int snprintf(char *str, size_t size, const char *format, ...);")
  c_snprintf = function(spec, x)
    local size = 64
    while true do
      local buf = ffi.new("char[?]", size)
      local n = ffi.C.snprintf(buf, size, spec, ffi.cast("double", x))
      if n < size then
        return ffi.string(buf, n)
      end
      size = n + 1
    end
  end
end

--- `string.format(spec, x)` for one float directive (%f, %e, %g, with
--- flags, width and precision), rounding ties like C printf.
function M.format_float(spec, x)
  if c_snprintf and x == x and x ~= math.huge and x ~= -math.huge then
    return c_snprintf(spec, x)
  end
  return string.format(spec, x)
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

-- stylua: ignore
local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- SHA-256 in Lua, for the strings older sha256() rejects.
local function sha256_lua(s)
  local band, bor, bxor, bnot, ror, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.ror, bit.rshift
  local len = #s
  s = s .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  local tail = {}
  for i = 8, 1, -1 do
    tail[i] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  s = s .. table.concat(tail)
  local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local w = {}
  for chunk = 1, #s, 64 do
    for i = 0, 15 do
      local a, b, c, d = s:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for i = 16, 63 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      w[i] = bit.tobit(w[i - 16] + s0 + w[i - 7] + s1)
    end
    local a, b, c, d, e, f, g, hh = unpack(h)
    for i = 0, 63 do
      local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = hh + s1 + ch + SHA256_K[i + 1] + w[i]
      local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      hh, g, f, e = g, f, e, bit.tobit(d + t1)
      d, c, b, a = c, b, a, bit.tobit(t1 + s0 + maj)
    end
    for i, v in ipairs({ a, b, c, d, e, f, g, hh }) do
      h[i] = bit.tobit(h[i] + v)
    end
  end
  local out = {}
  for i = 1, 8 do
    out[i] = bit.tohex(h[i])
  end
  return table.concat(out)
end
M._sha256_lua = sha256_lua

local sha256_takes_blobs

--- Hex SHA-256 of the bytes of `s` (sha256()). Neovim passes a string with a
--- NUL byte to sha256() as a Blob, which 0.11.0 rejects (E976), 0.12 hashes.
---@param s string
---@return string
function M.sha256(s)
  if s:find("\0", 1, true) then
    if sha256_takes_blobs == nil then
      sha256_takes_blobs = pcall(vim.fn.sha256, "\0")
    end
    if not sha256_takes_blobs then
      return sha256_lua(s)
    end
  end
  return vim.fn.sha256(s)
end

---------------------------------------------------------------------------
-- Paths & files
---------------------------------------------------------------------------

--- Whether `path` is absolute: `/x` and, as on Windows, a drive (`C:/x`,
--- `C:\x`) or a UNC share (`\\server\share`, `//server/share`).
---@param path string
---@return boolean
function M.is_absolute(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

--- The user's home directory, also where $HOME isn't set (Windows uses
--- %USERPROFILE%), with forward slashes.
---@return string
function M.home()
  local home = vim.env.HOME
  if not home or home == "" then
    home = vim.uv.os_homedir() or "~"
  end
  return (home:gsub("\\", "/"))
end

--- Expand `~`, env vars and make absolute. Relative paths resolve against
--- `base` (default: org_directory).
function M.expand(path, base)
  if not path or path == "" then
    return path
  end
  -- Never vim.fn.expand(): paths often come from document text (INCLUDE,
  -- :dir, :file, scopes), and Vim expansion evaluates `backticks` and
  -- interprets %, # and wildcards. Expand only ~ and environment variables.
  if path == "~" or path:match("^~[/\\]") then
    path = M.home() .. path:sub(2)
  end
  path = path
    :gsub("%${([%w_]+)}", function(v)
      return vim.env[v] or ("${" .. v .. "}")
    end)
    :gsub("%$([%w_]+)", function(v)
      return vim.env[v] or ("$" .. v)
    end)
  if not M.is_absolute(path) then
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
  local fd, err = io.open(path, "wb")
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

local is_mac = vim.fn.has("mac") == 1

--- Whether string `a` sorts before `b` (org-string<), following
--- `sort_function` (org-sort-function): "collate" compares with the
--- collation locale (like string-collate-lessp, see |:language|),
--- "fallback" by character code (org-sort-function-fallback), or a
--- function(a, b, ignore_case) returning a boolean.
---@param a string
---@param b string
---@param ignore_case? boolean
---@return boolean
function M.string_lessp(a, b, ignore_case)
  local f = require("org.config").opts.sort_function or "collate"
  if type(f) == "function" then
    return f(a, b, ignore_case) and true or false
  end
  -- Emacs's string-collate-lessp compares character codes on macOS, whose
  -- wide-character collation for UTF-8 locales is not a real one
  if f == "fallback" or (f == "collate" and is_mac) then
    if ignore_case then
      a, b = a:upper(), b:upper()
    end
    return a < b
  end
  if ignore_case then
    a, b = a:lower(), b:lower()
  end
  if a == b then
    return false
  end
  -- sort() keeps equal items in order: `a` first only when it sorts lower
  local ok, r = pcall(vim.fn.sort, { b, a }, "l")
  if not ok then
    return a < b
  end
  return r[1] == a and r[2] == b
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
  --- Files of a directory like Emacs org-agenda-files: not recursive,
  --- names matching org-agenda-file-regexp ("^[^.].*\\.org$").
  local function add_dir(dir)
    for _, f in ipairs(vim.fn.globpath(dir, "*.org", false, true)) do
      if not vim.fs.basename(f):match("^%.") then
        add(f)
      end
    end
  end
  for _, pattern in ipairs(patterns or {}) do
    local expanded = M.expand(pattern)
    if M.is_dir(expanded) then
      add_dir(expanded)
    elseif expanded:find("[%*%?%[]") then
      for _, f in ipairs(vim.fn.glob(expanded, false, true)) do
        if M.is_dir(f) then
          add_dir(f)
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

local function buf_realpath(c)
  if c.real == nil then
    c.real = vim.uv.fs_realpath(c.name) or false
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
  local real = vim.uv.fs_realpath(path)
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

--- Restore a synchronous edit snapshot without replacing unchanged lines.
--- This keeps unrelated extmarks and cursor locations intact on rollback.
function M.restore_buffer(bufnr, lines, modified)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks =
    vim.diff(table.concat(current, "\n") .. "\n", table.concat(lines, "\n") .. "\n", { result_type = "indices" })
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
---@return boolean ok, string? err
function M.save_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    local ok, err
    local write = function()
      vim.api.nvim_buf_call(bufnr, function()
        ok, err = pcall(vim.cmd, "silent noautocmd keepalt write")
      end)
    end
    -- text the transclusion extension inserted must not reach the file,
    -- and this write skips its BufWritePre
    local transclusion = package.loaded["org.extensions.transclusion"]
    if transclusion and transclusion.without_inserted then
      transclusion.without_inserted(bufnr, write)
    else
      write()
    end
    if not ok then
      err = tostring(err)
      return false, err:match("E%d+:[^\n]*") or err:match("^[^\n]*")
    end
    require("org.files").invalidate(vim.api.nvim_buf_get_name(bufnr))
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

--- Open `path` in the current window (or reuse a window showing it) at `lnum`.
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
      M.set_current_buf(b)
    else
      -- `hide` avoids E37 when the current buffer has unsaved changes; a
      -- modified buffer that can't be hidden (bufhidden=wipe) keeps its
      -- window and the file opens in a split
      local ok, err = pcall(vim.cmd, (cmd == "edit" and "hide " or "") .. cmd .. " " .. vim.fn.fnameescape(path))
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
