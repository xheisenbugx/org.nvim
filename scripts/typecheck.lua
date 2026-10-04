-- The type check behind `make typecheck`. Run it from the repository root
-- with
--
--   nvim --headless --clean -l scripts/typecheck.lua
--
-- It runs `lua-language-server --check=.` once with the settings of
-- .luarc.json, except that the diagnostics .luarc.json demotes to hints
-- (need-check-nil, param-type-mismatch, ...) are reported as warnings. Then
-- it keeps:
--
--   * every warning and error in a file listed in scripts/typecheck_strict.txt
--     (a file, or a directory and everything under it), and
--   * in any other file, the warnings and errors that aren't of a demoted
--     kind: what a plain `lua-language-server --check` with .luarc.json
--     reports.
--
-- It prints them as `file:line:col: [Severity] message (code)` and exits
-- non-zero when there is one. One pass over the whole workspace, so a
-- listed file is checked with every module it requires loaded, and only
-- the listed file's own diagnostics count, not those of what it requires.
--
-- lua-language-server must be on PATH (CI pins the version). The type
-- annotations of the Neovim runtime come from $VIMRUNTIME, which `nvim -l`
-- sets.

local M = {}

local SEVERITY = { "Error", "Warning", "Information", "Hint" }

--- Diagnostic codes that .luarc.json sets below Warning: the strict set.
---@param luarc table decoded .luarc.json
---@return string[]
function M.demoted(luarc)
  local codes = {}
  for code, level in pairs(luarc["diagnostics.severity"] or {}) do
    local name = tostring(level):gsub("[!+]$", "")
    if name == "Hint" or name == "Information" then
      codes[#codes + 1] = code
    end
  end
  table.sort(codes)
  return codes
end

--- The strict list: one repo-relative path per line; `#` starts a comment.
---@param text string
---@return string[]
function M.parse_list(text)
  local paths = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local path = vim.trim((line:gsub("#.*$", "")))
    if path ~= "" then
      paths[#paths + 1] = (path:gsub("/+$", ""))
    end
  end
  return paths
end

--- Whether `file` (repo-relative) is one of `paths` or under one of them.
---@param file string
---@param paths string[]
---@return boolean
function M.is_strict(file, paths)
  for _, p in ipairs(paths) do
    if file == p or file:sub(1, #p + 1) == p .. "/" then
      return true
    end
  end
  return false
end

---@class org.typecheck.Hit
---@field file string repo-relative path
---@field line integer 1-based
---@field col integer 1-based
---@field severity string
---@field code string
---@field message string

--- The diagnostics to report out of lua-language-server's JSON output
--- (`{ [file uri] = lsp.Diagnostic[] }`), sorted by file and position.
---@param report table<string, table[]>
---@param root string absolute path of the workspace, without a trailing slash
---@param demoted string[] codes reported only in strict files
---@param strict string[] the strict list
---@return org.typecheck.Hit[]
function M.filter(report, root, demoted, strict)
  local is_demoted = {}
  for _, c in ipairs(demoted) do
    is_demoted[c] = true
  end
  local hits = {}
  for uri, diags in pairs(report) do
    local path = vim.fs.normalize(vim.uri_to_fname(uri))
    local file = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or path
    local strict_file = M.is_strict(file, strict)
    for _, d in ipairs(diags) do
      local severity = d.severity or 1
      if severity <= 2 and (strict_file or not is_demoted[d.code]) then
        hits[#hits + 1] = {
          file = file,
          line = d.range.start.line + 1,
          col = d.range.start.character + 1,
          severity = SEVERITY[severity],
          code = tostring(d.code or "?"),
          message = d.message,
        }
      end
    end
  end
  table.sort(hits, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col < b.col
  end)
  return hits
end

---@param path string
---@return string
local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

---@param path string
---@param s string
local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

--- Run the check from the repository root; returns the exit status.
---@return integer
function M.main()
  local root = vim.fs.normalize(vim.fn.getcwd())
  local luarc = vim.json.decode(read(root .. "/.luarc.json"))
  local demoted = M.demoted(luarc)
  local strict = M.parse_list(read(root .. "/scripts/typecheck_strict.txt"))
  for _, p in ipairs(strict) do
    if not vim.uv.fs_stat(root .. "/" .. p) then
      io.stdout:write("scripts/typecheck_strict.txt: no such file or directory: ", p, "\n")
      return 1
    end
  end

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  -- --configpath is merged over .luarc.json, its keys winning: raise the
  -- demoted diagnostics to warnings and sort them out afterwards.
  local severity = {}
  for _, c in ipairs(demoted) do
    severity[c] = "Warning!"
  end
  write(tmp .. "/strict.json", vim.json.encode({ ["diagnostics.severity"] = severity }))
  local out = tmp .. "/check.json"
  if vim.fn.executable("lua-language-server") ~= 1 then
    io.stdout:write("typecheck: lua-language-server is not on PATH\n")
    return 1
  end
  io.stdout:write("typecheck: lua-language-server --check over the repository...\n")
  local res = vim
    .system({
      "lua-language-server",
      "--check=" .. root,
      "--configpath=" .. tmp .. "/strict.json",
      "--checklevel=Warning",
      "--check_format=json",
      "--check_out_path=" .. out,
      "--logpath=" .. tmp,
    }, { text = true })
    :wait()
  local ok, report = pcall(function()
    return vim.json.decode(read(out))
  end)
  vim.fn.delete(tmp, "rf")
  -- it exits 1 when it found anything (demoted ones included), so only a
  -- missing or unreadable report is a failure of the check itself
  if not ok or type(report) ~= "table" then
    io.stdout:write(res.stdout or "", res.stderr or "", "\nlua-language-server failed (exit ", res.code, ")\n")
    return 1
  end

  local hits = M.filter(report, root, demoted, strict)
  for _, h in ipairs(hits) do
    io.stdout:write(string.format("%s:%d:%d: [%s] %s (%s)\n", h.file, h.line, h.col, h.severity, h.message, h.code))
  end
  if #hits > 0 then
    io.stdout:write(#hits, " problem(s); files in scripts/typecheck_strict.txt also get: ")
    io.stdout:write(table.concat(demoted, ", "), "\n")
    return 1
  end
  io.stdout:write("typecheck: no problems (strict: ", table.concat(strict, ", "), ")\n")
  return 0
end

if arg and arg[0] and arg[0]:match("typecheck%.lua$") then
  os.exit(M.main())
end

return M
