---@mod org.utils.fs Paths, file I/O, JSON, PowerShell and globbing helpers
---
--- Part of org.utils, which loads it.

local M = require("org.utils")

---------------------------------------------------------------------------
-- PowerShell (Windows)
---------------------------------------------------------------------------

--- A PowerShell single-quoted string literal of `s`. Only quotes are
--- special, doubled; PowerShell also takes the curly ones (U+2018 to
--- U+201B) for '.
---@param s string
---@return string
function M.ps_quote(s)
  for _, q in ipairs({ "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) do
    -- lint: allow gsub: quote characters
    s = s:gsub(q, q .. q)
  end
  return "'" .. s .. "'"
end

-- Base64 of `s` (UTF-8) as UTF-16LE, for powershell -EncodedCommand.
local function utf16le_base64(s)
  local out = {}
  for _, c in ipairs(vim.fn.str2list(s)) do
    if c >= 0x10000 then
      c = c - 0x10000
      local hi, lo = 0xD800 + math.floor(c / 0x400), 0xDC00 + c % 0x400
      out[#out + 1] = string.char(hi % 256, math.floor(hi / 256), lo % 256, math.floor(lo / 256))
    else
      out[#out + 1] = string.char(c % 256, math.floor(c / 256))
    end
  end
  return vim.base64.encode(table.concat(out))
end

--- The command running `script` with Windows PowerShell (powershell.exe,
--- part of Windows; also reachable from WSL). The script goes in
--- -EncodedCommand, so no quoting rules of cmd.exe or a shell apply to it.
---@param script string
---@return string[]
function M.powershell(script)
  return {
    "powershell.exe",
    "-NoProfile",
    "-NonInteractive",
    "-WindowStyle",
    "Hidden",
    "-EncodedCommand",
    utf16le_base64(script),
  }
end

---------------------------------------------------------------------------
-- Paths & files
---------------------------------------------------------------------------

--- Whether `path` is absolute: `/x` and, as on Windows, a drive (`C:/x`,
--- `C:\x`), the root of the current drive (`\x`, what expand() makes of
--- `/x` there) or a UNC share (`\\server\share`, `//server/share`).
---@param path string
---@return boolean
function M.is_absolute(path)
  return path:match("^[/\\]") ~= nil or path:match("^%a:[/\\]") ~= nil
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

--- The canonical path of an existing `path` (symlinks resolved) with
--- forward slashes, or nil. vim.uv.fs_realpath gives backslashes on
--- Windows, which don't compare with the normalized paths used elsewhere.
---@param path string
---@return string|nil
function M.realpath(path)
  local real = vim.uv.fs_realpath(path)
  return real and vim.fs.normalize(real) or nil
end

--- `path` with forward slashes and the home directory as `~`, like
--- abbreviate-file-name (fnamemodify ":~" keeps \ on Windows).
---@param path string
---@return string
function M.abbreviate(path)
  path = vim.fs.normalize(path)
  local home = vim.fs.normalize(M.home())
  local p, h = path, home
  if vim.fn.has("win32") == 1 then
    p, h = p:lower(), h:lower()
  end
  if p == h then
    return "~"
  elseif p:sub(1, #h + 1) == h .. "/" then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

--- File name completion (getcompletion() of `kind`, "file" or "dir")
--- with forward slashes, a directory keeping its trailing /. On Windows
--- getcompletion() gives \.
---@param lead string
---@param kind? "file"|"dir"
---@return string[]
function M.complete_path(lead, kind)
  local out = {}
  for _, f in ipairs(vim.fn.getcompletion(lead, kind or "file")) do
    local dir = f:match("[/\\]$") ~= nil
    f = vim.fs.normalize(f)
    out[#out + 1] = (dir and f:sub(-1) ~= "/") and (f .. "/") or f
  end
  return out
end

--- `path` with a leading ~ and $VAR / ${VAR} expanded and nothing else; a
--- relative path stays relative. The safe replacement for vim.fn.expand()
--- on document text, which runs `backticks` as shell commands.
---@param path string
---@return string
function M.expand_vars(path)
  if path == "~" or path:match("^~[/\\]") then
    path = M.home() .. path:sub(2)
  end
  return (
    path
      :gsub("%${([%w_]+)}", function(v)
        return vim.env[v] or ("${" .. v .. "}")
      end)
      :gsub("%$([%w_]+)", function(v)
        return vim.env[v] or ("$" .. v)
      end)
  )
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
  path = M.expand_vars(path)
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

--- The whole contents of file `path` as one string, or nil when it can't
--- be opened or read. `binary` opens it in binary mode (no newline
--- translation on Windows).
---@param path string
---@param binary? boolean
---@return string|nil
function M.read_text(path, binary)
  local fd = io.open(path, binary and "rb" or "r")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

---@return string[]|nil
function M.readfile(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  -- (nil: a directory, which opens but can't be read)
  return content and M.split_content(content) or nil
end

--- The lines of a file's contents, as `readfile` returns them (for
--- contents read some other way, such as asynchronously).
---@param content string
---@return string[]
function M.split_content(content)
  -- in a module a worker thread can load too (the agenda index splits
  -- files there exactly as here)
  return require("org.agenda.index.thread").split_content(content)
end

--- Make directory `dir` and its parents. Another process making the same
--- directory at the same time (parallel `org` commands) makes mkdir() fail
--- with E739 although the directory is there: that isn't an error. Each
--- level of `dir` can lose such a race, so it tries again a few times,
--- and fails only when the directory still isn't there.
---@param dir string
function M.mkdir_p(dir)
  for _ = 1, 4 do
    if vim.fn.isdirectory(dir) == 1 or pcall(vim.fn.mkdir, dir, "p") then
      return
    end
  end
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

function M.writefile(path, lines)
  M.mkdir_p(vim.fn.fnamemodify(path, ":h"))
  local fd, err = io.open(path, "wb")
  if not fd then
    -- (io.open's message starts with the path again)
    local reason = tostring(err)
    if reason:sub(1, #path + 2) == path .. ": " then
      reason = reason:sub(#path + 3)
    end
    error("org: cannot write " .. path .. ": " .. reason, 0)
  end
  fd:write(table.concat(lines, "\n"))
  if #lines > 0 then
    fd:write("\n")
  end
  fd:close()
  -- the cached parse of the file is stale even when its mtime is not
  local files = package.loaded["org.files"]
  if files then
    files.invalidate(vim.fn.fnamemodify(path, ":p"))
  end
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

---------------------------------------------------------------------------
-- Directory scanning & globbing
---------------------------------------------------------------------------

-- The characters that make a path component a wildcard for `glob`.
local GLOB_CHARS = "[%*%?%[{]"
local is_win = vim.fn.has("win32") == 1

-- component -> its compiled regex (false: none), per 'fileignorecase'
local glob_regexes = { [true] = {}, [false] = {} }

--- The regex matching the names `part` (a path component with wildcards)
--- stands for, as Vim's glob matches them: case ignored with
--- 'fileignorecase'. nil for a pattern Vim can't read.
---@param part string
---@return vim.regex|nil
local function glob_regex(part)
  local fic = vim.o.fileignorecase
  local re = glob_regexes[fic][part]
  if re == nil then
    local ok, r = pcall(function()
      return vim.regex((fic and "\\c" or "\\C") .. vim.fn.glob2regpat(part))
    end)
    re = ok and r or false
    glob_regexes[fic][part] = re
  end
  return re or nil
end

--- The entries of directory `dir` as (name, type) pairs, nothing when it
--- can't be read. Unlike vim.fs.dir, `dir` is used as it is (not
--- normalized: no $VAR in it is expanded).
---@param dir string
---@return fun(): string?, string?
function M.scandir(dir)
  local fs = vim.uv.fs_scandir(dir)
  return function()
    if fs then
      return vim.uv.fs_scandir_next(fs)
    end
  end
end

--- The directory a path's leading part names, as a directory to list: ""
--- (what precedes `/x`) is the root, and a drive alone (`C:`, of `C:/x`)
--- its root `C:/`: fs_stat and fs_scandir read `C:` as the current
--- directory of drive C.
---@param dir string
---@return string
function M.dir_path(dir)
  if dir == "" then
    return "/"
  elseif dir:match("^%a:$") then
    return dir .. "/"
  end
  return dir
end

--- `pattern` (with `/` separators) split for `glob`: its components, the
--- index of the first with a wildcard (past the end when none has one)
--- and the directory the components before it name (nil: the current one).
---@param pattern string
---@return string[] parts, integer k, string|nil base
function M._glob_split(pattern)
  local parts = vim.split(pattern, "/", { plain = true })
  local k = 1
  while k <= #parts and not parts[k]:find(GLOB_CHARS) do
    k = k + 1
  end
  local base = k > 1 and M.dir_path(table.concat(parts, "/", 1, k - 1)) or nil
  return parts, k, base
end

--- The paths matching the wildcard `pattern` (`*`, `?`, `[abc]`, `{a,b}`
--- within a path component, `**` for any number of directories), sorted,
--- like Vim's glob() but without its expansion: glob() runs `backticks`
--- as shell commands and expands $VARS, and `globpath()` splits its
--- directory at commas, so neither may see a path that comes from a
--- document, a link or a file name. A path, or a path component, that
--- exists as written is the only match (a file named `plan[1].org`, a
--- directory `[work] notes`). As in Vim, a wildcard
--- matches a name starting with `.` only when it starts with `.` itself,
--- and `**` doesn't enter hidden directories. Relative patterns are
--- relative to the current directory, and so are the paths returned;
--- the matches start with `pattern`'s directory as written.
---@param pattern string
---@return string[]
function M.glob(pattern)
  if pattern == "" then
    return {}
  end
  -- as written (no `..` resolved: callers cut their base off the matches),
  -- with a leading ~ for the home directory like glob()
  if pattern == "~" or pattern:match("^~[/\\]") then
    pattern = M.home() .. pattern:sub(2)
  end
  if is_win then
    pattern = pattern:gsub("\\", "/")
  end
  if vim.uv.fs_stat(pattern) then
    return { pattern }
  end
  -- the leading components without wildcards name the directory to start in
  local parts, k, base = M._glob_split(pattern)
  if k > #parts then
    return {}
  end
  local out = {}
  local function join(dir, name)
    if not dir then
      return name
    end
    return (dir:sub(-1) == "/" and dir or dir .. "/") .. name
  end
  local function is_dir(path, kind)
    if kind == "directory" or kind == "file" then
      return kind == "directory"
    end
    -- a link, or a file system that doesn't tell
    local st = vim.uv.fs_stat(path)
    return st ~= nil and st.type == "directory"
  end
  -- the directories `**` entered, against symlink loops
  local entered = {}
  local function walk(dir, i)
    local part = parts[i]
    if part == nil then
      out[#out + 1] = dir
      return
    end
    if part == "**" then
      -- zero directories, then each directory below (not hidden ones)
      walk(dir, i + 1)
      local real = vim.uv.fs_realpath(dir or ".") or dir or "."
      if entered[real] then
        return
      end
      entered[real] = true
      for name, kind in M.scandir(dir or ".") do
        local path = join(dir, name)
        if name:byte(1) ~= 46 and is_dir(path, kind) then
          walk(path, i)
        end
      end
      return
    end
    -- a component that names an entry as written is that entry (a
    -- directory called `[work] notes`)
    local literal = join(dir, part)
    local exists = vim.uv.fs_stat(literal) ~= nil
    if exists or not part:find(GLOB_CHARS) then
      if exists then
        walk(literal, i + 1)
      end
      return
    end
    local re = glob_regex(part)
    if not re then
      return
    end
    local dot = part:byte(1) == 46
    for name, kind in M.scandir(dir or ".") do
      if (dot or name:byte(1) ~= 46) and re:match_str(name) then
        local path = join(dir, name)
        if i == #parts then
          out[#out + 1] = path
        elseif is_dir(path, kind) then
          walk(path, i + 1)
        end
      end
    end
  end
  if base and not M.is_dir(base) then
    return {}
  end
  walk(base, k)
  table.sort(out)
  return out
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
  --- names matching org-agenda-file-regexp ("^[^.].*\\.org$"). (Listed,
  --- not globbed: a directory's name may hold `[` or `,`.)
  local function add_dir(dir)
    local names = {}
    for name in M.scandir(dir) do
      if name:byte(1) ~= 46 and name:match("%.org$") then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      add(dir .. "/" .. name)
    end
  end
  for _, pattern in ipairs(patterns or {}) do
    local expanded = M.expand(pattern)
    if M.is_dir(expanded) then
      add_dir(expanded)
    elseif expanded:find(GLOB_CHARS) then
      for _, f in ipairs(M.glob(expanded)) do
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
