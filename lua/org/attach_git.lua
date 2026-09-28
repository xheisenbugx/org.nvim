---@mod org.attach_git Automatic git commits of attachments (org-attach-git)
---
--- Turned on with `attach.git = true` (Emacs: `(require 'org-attach-git)`).
--- When the attachment root (`attach.dir`, or with `attach.git_dir =
--- "individual-repository"` the entry's own attachment directory) is inside
--- a git work tree, every change made by org-attach (attach, delete, sync)
--- is followed by `git add` / `git rm` of the new, modified and deleted
--- files and a commit "Synchronized attachments". Files of at least
--- `attach.git_annex_cutoff` bytes go to git-annex when the repository has
--- been set up with `git annex init`; opening an attachment whose content
--- is not present runs `git annex get` (`attach.git_annex_auto_get`).

local config = require("org.config")
local utils = require("org.utils")

local M = {}

local function cfg()
  return config.opts.attach or {}
end

--- Is the git integration on (org-attach-git loaded)?
function M.enabled()
  return cfg().git == true
end

--- The directory whose repository is used (org-attach-git-dir): the
--- attachment root, or the entry's attachment directory.
---@param attach_dir string|nil the entry's attachment directory
---@param root string|nil the attachment root (`attach.dir` made absolute)
function M.dir(attach_dir, root)
  if cfg().git_dir == "individual-repository" then
    return attach_dir
  end
  return root
end

--- The top of the git work tree containing `dir` (vc-git-root).
function M.root(dir)
  if not dir or not utils.is_dir(dir) then
    return nil
  end
  local found = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  return found and vim.fs.dirname(found) or nil
end

local function git(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = cwd, text = true }):wait()
  end)
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return res
end

--- Can git-annex be used (org-attach-git-use-annex)?
function M.use_annex(dir)
  local root = M.root(dir)
  if not root or not cfg().git_annex_cutoff then
    return false
  end
  return utils.exists(root .. "/annex") or utils.exists(root .. "/.git/annex")
end

local function split0(s)
  return vim.split(s or "", "\0", { plain = true, trimempty = true })
end

--- Commit the changes in `dir` (org-attach-git-commit): add new and
--- modified files (to git-annex when large), remove deleted ones and commit
--- when anything changed. Returns the number of changed files, or nil when
--- `dir` is not in a git repository.
---@param dir string|nil
---@return integer|nil
function M.commit(dir)
  if not M.root(dir) or vim.fn.executable("git") == 0 then
    return nil
  end
  local annex = M.use_annex(dir)
  local cutoff = cfg().git_annex_cutoff
  local changes = 0
  for _, f in ipairs(split0(git({ "ls-files", "-zmo", "--exclude-standard" }, dir).stdout)) do
    local st = vim.uv.fs_stat(dir .. "/" .. f)
    if annex and st and st.size >= cutoff then
      git({ "annex", "add", f }, dir)
    else
      git({ "add", f }, dir)
    end
    changes = changes + 1
  end
  for _, f in ipairs(split0(git({ "ls-files", "-z", "--deleted" }, dir).stdout)) do
    git({ "rm", f }, dir)
    changes = changes + 1
  end
  if changes > 0 then
    git({ "commit", "-m", "Synchronized attachments" }, dir)
  end
  return changes
end

--- Before opening `path`: fetch its content with `git annex get` when it
--- is in git-annex but not present (org-attach-git-annex-get-maybe).
--- Errors when the content is unavailable and not fetched.
---@param path string
---@param dir string|nil the repository directory (see `M.dir`)
function M.annex_get_maybe(path, dir)
  if not dir or not M.use_annex(dir) then
    return
  end
  local rel = require("org.attach").relative_path(path, dir)
  local found = git({ "annex", "find", "--format=found", "--in=here", rel }, dir).stdout
  if found == "found" then
    return
  end
  local get = cfg().git_annex_auto_get
  if get == nil or get == "ask" then
    get = utils.confirm(string.format("Run git annex get %s?", rel))
  end
  if not get then
    error(string.format("File %s stored in git annex but unavailable", path), 0)
  end
  utils.notify(string.format('Running git annex get "%s".', rel))
  git({ "annex", "get", rel }, dir)
end

return M
