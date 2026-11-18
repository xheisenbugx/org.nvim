---@mod org.version The org.nvim version (org-version)

local M = {}

--- The directory of org.nvim's Lua modules: `lua/` of a checkout, or
--- `share/lua/5.1/` of the LuaRocks tree it was installed into (symlinks
--- resolved: rocks.nvim puts that directory on 'runtimepath' as a link
--- named `lua`).
---@return string
function M.lua_dir()
  local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  return vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
end

--- The directory of the rock in a LuaRocks tree (`plugin/`, `doc/`,
--- `etc/`, `tutor/`), when `lua_dir` is one's `share/lua/5.1/`: the
--- rock's Lua modules go there, its other directories to
--- `lib/luarocks/rocks-5.1/org.nvim/<version>/`.
---@param lua_dir string
---@return string?
function M.rock_dir(lua_dir)
  local tree = lua_dir:match("^(.*)/share/lua/[%d.]+$")
  if not tree then
    return nil
  end
  -- lint: allow glob: the plugin's own install tree, never document text
  local dirs = vim.fn.glob(tree .. "/lib/luarocks/rocks-*/org.nvim/*", false, true)
  table.sort(dirs, function(a, b)
    return vim.version.lt(vim.fs.basename(a):match("^[^-]*"), vim.fs.basename(b):match("^[^-]*"))
  end)
  for i = #dirs, 1, -1 do
    if vim.uv.fs_stat(dirs[i] .. "/plugin/org.lua") then
      return vim.fs.normalize(dirs[i])
    end
  end
end

--- The plugin's root directory: the checkout, or the rock's directory of
--- a LuaRocks install (see `rock_dir`).
---@return string
function M.root()
  local lua_dir = M.lua_dir()
  local parent = vim.fs.dirname(lua_dir)
  if vim.uv.fs_stat(parent .. "/plugin/org.lua") then
    return parent
  end
  return M.rock_dir(lua_dir) or parent
end

--- Output of `git -C dir <args>`, or nil when git fails or isn't installed.
---@param dir string
---@param args string[]
---@return string?
local function git(dir, args)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

--- The release in `dir`: the version of a rock's directory
--- (`.../org.nvim/X.Y.Z-1`), else the checkout's latest vX.Y.Z tag without
--- the "v", or "unreleased" when it has none (or isn't a git checkout).
---@param dir string
---@return string
function M.release_of(dir)
  local rock = vim.fs.normalize(dir):match("/rocks%-[%d.]+/org%.nvim/(%d+%.%d+%.%d+)%-%d+$")
  if rock then
    return rock
  end
  local tag = git(dir, { "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*" })
  return tag and tag:match("^v(%d.*)") or "unreleased"
end

--- `git describe` of the plugin checkout, or "N/A" outside git.
function M.git_version()
  return git(M.root(), { "describe", "--tags", "--always", "--dirty" }) or "N/A"
end

--- The version string: the release, or with `full` the release, git
--- version and install directory (org-version).
---@param full? boolean
---@return string
function M.string(full)
  if not full then
    return M.release
  end
  return string.format("org.nvim version %s (%s @ %s/)", M.release, M.git_version(), M.root())
end

--- Show the version, or insert it at the cursor with a count (C-u).
function M.show()
  local s = M.string(true)
  if vim.v.count > 0 then
    vim.api.nvim_put({ s }, "c", true, true)
  else
    require("org.utils").notify(s)
  end
  return true
end

--- `M.release`: the release of this copy of org.nvim, from its git tag
--- (see `release_of`), looked up on first use.
setmetatable(M, {
  __index = function(t, key)
    if key == "release" then
      rawset(t, "release", M.release_of(M.root()))
      return rawget(t, "release")
    end
  end,
})

return M
