-- The output directory of the site builder. A build empties it first, so
-- it must be a directory a build made (it holds MARKER), an empty one or a
-- new one. Anything else is refused before a file is touched: an empty
-- argument, "." or ".." (relative to the checkout: the checkout itself or
-- the directory holding it and its siblings), the checkout or a directory
-- containing it, a directory with a .git, a directory of other files.
local M = {}

--- Written into every site a build makes; only a directory holding it is
--- emptied.
M.MARKER = ".org-nvim-site"

local is_win = vim.fn.has("win32") == 1

--- Forward slashes; case-folded on Windows, whose file names ignore case.
---@param path string
---@return string
local function key(path)
  path = path:gsub("\\", "/")
  return is_win and path:lower() or path
end

--- `path` made absolute against `base`, with its "." and ".." resolved.
---@param path string
---@param base string
---@return string
local function absolute(path, base)
  path = path:gsub("\\", "/")
  if not (path:match("^/") or path:match("^%a:/")) then
    path = base:gsub("\\", "/") .. "/" .. path
  end
  local prefix = path:match("^%a:/") or "/"
  local parts = {}
  for seg in path:sub(#prefix + 1):gmatch("[^/]+") do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return prefix .. table.concat(parts, "/")
end

--- `path` with its symbolic links resolved: the real path of its nearest
--- existing ancestor and the rest of it.
---@param path string
---@return string
local function real(path)
  local rest = {}
  local p = path
  while true do
    local r = vim.uv.fs_realpath(p)
    if r then
      r = r:gsub("\\", "/")
      if #rest == 0 then
        return r
      end
      return (r:sub(-1) == "/" and r or r .. "/") .. table.concat(rest, "/")
    end
    local parent = vim.fs.dirname(p)
    if not parent or parent == p then
      return path
    end
    table.insert(rest, 1, vim.fs.basename(p))
    p = parent
  end
end

--- Whether the directory `dir` has no entries.
---@param dir string
---@return boolean
local function empty(dir)
  for _ in vim.fs.dir(dir) do
    return false
  end
  return true
end

--- The directory to build the site of the checkout `root` into, for the
--- builder's argument `arg` (relative to `root`), or nil and why it can't
--- be. Only looks.
---@param arg string|nil
---@param root string
---@return string|nil dir, string|nil why
function M.check(arg, root)
  if type(arg) ~= "string" or vim.trim(arg) == "" then
    return nil, "no output directory given (pass a directory, or nothing for site/)"
  end
  local dir = real(absolute(arg, root))
  local function refuse(why)
    return nil, ("won't build into %s: %s"):format(dir, why)
  end
  local r = key(real(absolute(root, root)))
  local d = key(dir)
  if d == r then
    return refuse("it is the repository itself")
  end
  -- (a file system root ends with its "/")
  if r:sub(1, #d + 1) == d .. "/" or (d:sub(-1) == "/" and r:sub(1, #d) == d) then
    return refuse("the repository is inside it")
  end
  local st = vim.uv.fs_stat(dir)
  if not st then
    return dir
  end
  if st.type ~= "directory" then
    return refuse("it exists and is not a directory")
  end
  if vim.uv.fs_lstat(dir .. "/.git") then
    return refuse("it holds a .git, like a repository")
  end
  if vim.uv.fs_lstat(dir .. "/" .. M.MARKER) or empty(dir) then
    return dir
  end
  return refuse(
    ("it is not empty and no site build made it (it has no %s): remove it yourself, or pass a new directory"):format(
      M.MARKER
    )
  )
end

--- Make the directory of `arg` (see `check`) ready for a build: created,
--- or emptied when a build made it, with MARKER in it. Returns its path, or
--- nil and why it was refused (then nothing was changed).
---@param arg string|nil
---@param root string
---@return string|nil dir, string|nil why
function M.prepare(arg, root)
  local dir, why = M.check(arg, root)
  if not dir then
    return nil, why
  end
  if vim.uv.fs_stat(dir) then
    local names = {}
    for name in vim.fs.dir(dir) do
      names[#names + 1] = name
    end
    for _, name in ipairs(names) do
      vim.fn.delete(dir .. "/" .. name, "rf")
    end
  else
    vim.fn.mkdir(dir, "p")
  end
  local f = assert(io.open(dir .. "/" .. M.MARKER, "wb"))
  f:write("The org.nvim documentation site (scripts/site/build.lua): a build empties this directory first.\n")
  f:close()
  return dir
end

return M
