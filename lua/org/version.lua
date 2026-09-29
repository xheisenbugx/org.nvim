---@mod org.version The org.nvim version (org-version)

local M = {}

--- Release of this copy of org.nvim; "unreleased" between releases.
M.release = "unreleased"

--- The plugin's root directory.
function M.root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(src, ":p:h:h:h"))
end

--- `git describe` of the plugin checkout, or "N/A" outside git.
function M.git_version()
  if vim.fn.executable("git") ~= 1 then
    return "N/A"
  end
  local ok, res = pcall(function()
    return vim.system({ "git", "-C", M.root(), "describe", "--tags", "--always", "--dirty" }, { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return "N/A"
  end
  return vim.trim(res.stdout or "")
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

return M
