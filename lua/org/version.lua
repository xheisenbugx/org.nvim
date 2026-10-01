---@mod org.version The org.nvim version (org-version)

local M = {}

--- The plugin's root directory.
function M.root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(src, ":p:h:h:h"))
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

--- The release of the checkout in `dir`: its latest vX.Y.Z tag without
--- the "v", or "unreleased" when it has none (or isn't a git checkout).
---@param dir string
---@return string
function M.release_of(dir)
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
