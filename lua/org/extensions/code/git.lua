---@mod org.extensions.code.git Git facts about a file (root, branch, commit)
---
--- The root and branch are read from the `.git` directory (or the `.git`
--- file of a worktree), so BufEnter checks spawn no process; the short
--- commit and remote need `git` and are skipped without it.

local M = {}

local function read(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local s = fh:read("*a")
  fh:close()
  return s
end

--- Directory to start looking from for `path_or_buf` (a path, a buffer
--- number, or nil for the current buffer; the cwd for unnamed buffers).
---@param path_or_buf? string|integer
---@return string
function M.start_dir(path_or_buf)
  local path = path_or_buf
  if path == nil or type(path) == "number" then
    local buf = path or 0
    path = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if path:match("^%a[%w+.-]*://") then
      path = ""
    end
  end
  if path == "" then
    return vim.fn.getcwd()
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if vim.fn.isdirectory(path) == 1 then
    return path
  end
  return vim.fs.dirname(path)
end

--- The work tree root containing `path_or_buf` (see `start_dir`), or nil.
---@param path_or_buf? string|integer
---@return string|nil
function M.root(path_or_buf)
  local dir = M.start_dir(path_or_buf)
  local found = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  if not found then
    return nil
  end
  return vim.fs.dirname(found)
end

--- The git directory of work tree `root` (follows the `gitdir:` file of a
--- worktree or submodule).
---@param root string
---@return string|nil
function M.git_dir(root)
  local dotgit = root .. "/.git"
  if vim.fn.isdirectory(dotgit) == 1 then
    return dotgit
  end
  local s = read(dotgit)
  local dir = s and s:match("gitdir:%s*(%S+)")
  if not dir then
    return nil
  end
  if not dir:match("^/") and not dir:match("^%a:[/\\]") then
    dir = root .. "/" .. dir
  end
  return vim.fs.normalize(dir)
end

--- The checked out branch of `root` (nil when HEAD is detached or there
--- is no repository).
---@param root? string
---@return string|nil
function M.branch(root)
  if not root then
    return nil
  end
  local gd = M.git_dir(root)
  local head = gd and read(gd .. "/HEAD")
  return head and head:match("^ref:%s*refs/heads/(%S+)") or nil
end

--- The repository's name: the last component of its root.
---@param root? string
---@return string|nil
function M.repo_name(root)
  return root and vim.fs.basename(root) or nil
end

--- Run git in `root`; the trimmed stdout, or nil on failure or without git.
---@param root string
---@param args string[]
---@return string|nil
function M.git(root, args)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(3000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

--- The short hash of HEAD, or nil.
---@param root? string
---@return string|nil
function M.commit(root)
  if not root then
    return nil
  end
  local c = M.git(root, { "rev-parse", "--short", "HEAD" })
  return c ~= "" and c or nil
end

--- Facts for a buffer or path: { root, repo, branch, commit, relpath }
--- (fields nil when unknown).
---@param path_or_buf? string|integer
---@return table
function M.info(path_or_buf)
  local root = M.root(path_or_buf)
  local out = { root = root, repo = M.repo_name(root) }
  if root then
    out.branch = M.branch(root)
    out.commit = M.commit(root)
    local path = path_or_buf
    if path == nil or type(path) == "number" then
      path = vim.api.nvim_buf_get_name(path or 0)
    end
    if path ~= "" then
      out.relpath = M.relpath(root, path)
    end
  end
  return out
end

--- `path` relative to `root`, or nil when it is outside.
---@param root string
---@param path string
---@return string|nil
function M.relpath(root, path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  root = vim.fs.normalize(root)
  -- resolve symlinks (/tmp -> /private/tmp on macOS) on both sides
  local rpath = vim.uv.fs_realpath(path) or path
  local rroot = vim.uv.fs_realpath(root) or root
  for _, pair in ipairs({ { root, path }, { rroot, rpath } }) do
    local r, p = pair[1], pair[2]
    if p:sub(1, #r + 1) == r .. "/" then
      return p:sub(#r + 2)
    end
  end
  return nil
end

return M
