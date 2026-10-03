---@mod org.extensions.code.project Per-project org files
---
--- Each git repository gets an org file, `project_file` (default
--- `.org/tasks.org` in the repository; `"<org_directory>/projects/${repo}.org"`
--- keeps them out of it). `project_open`, `project_capture` and
--- `project_agenda` work on the file of the current buffer's repository.

local git = require("org.extensions.code.git")
local utils = require("org.utils")

local M = {}

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

--- The project file of repository `root`.
---@param root string
---@return string|nil
function M.file(root)
  local spec = opts().project_file
  local repo = git.repo_name(root) or "project"
  local path
  if type(spec) == "function" then
    path = spec(root, repo)
  elseif type(spec) == "string" then
    local org_dir = require("org.config").opts.org_directory or "~/org"
    path = spec
      :gsub("<org_directory>", function()
        return utils.expand(org_dir)
      end)
      :gsub("%${repo}", function()
        return repo
      end)
      :gsub("%${root}", function()
        return root
      end)
  end
  if not path or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    path = root .. "/" .. path
  end
  return vim.fs.normalize(path)
end

--- Create the project file (and its directory) when missing.
---@param path string
---@param repo? string
function M.ensure(path, repo)
  if not path or vim.uv.fs_stat(path) then
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local header = opts().project_file_header
  if type(header) == "function" then
    header = header(repo or "")
  end
  local lines = {}
  if header and header ~= "" then
    header = header:gsub("%${repo}", function()
      return repo or ""
    end)
    lines = vim.split(header, "\n", { plain = true })
  end
  vim.fn.writefile(lines, path)
end

--- The repository of the current buffer: its git root, else the last one
--- a code buffer was in, else the working directory's.
---@return string|nil
function M.current_root()
  local root = git.root(0)
  if root then
    return root
  end
  local recent = require("org.extensions.code").recent_roots()[1]
  return recent or git.root(vim.fn.getcwd())
end

local function file_or_warn()
  local root = M.current_root()
  if not root then
    utils.warn("Not in a git repository")
    return nil
  end
  local pf = M.file(root)
  if not pf then
    utils.warn("No project file for " .. root .. " (see project_file)")
    return nil
  end
  M.ensure(pf, git.repo_name(root))
  return pf, root
end

--- `project_open`: visit the project file of the current repository.
function M.open()
  local pf, root = file_or_warn()
  if not pf then
    return
  end
  require("org.extensions.code").remember_root(root)
  utils.open_file(pf)
  return pf
end

--- `project_capture`: capture into the project file with
--- `project_template`.
function M.capture()
  local pf, root = file_or_warn()
  if not pf then
    return
  end
  require("org.extensions.code").remember_root(root)
  local tpl = vim.deepcopy(opts().project_template or {})
  tpl.key = tpl.key or "project"
  tpl.description = tpl.description or ("Project " .. (git.repo_name(root) or ""))
  tpl.target = pf
  if tpl.headline == nil then
    tpl.headline = opts().project_headline
  end
  return require("org.capture").capture(tpl, {})
end

--- The agenda view of a project: `project_agenda_blocks` on the project
--- file, with the code TODOs of the repository.
---@param root string
---@return table view, string|nil project_file
function M.view(root)
  local pf = M.file(root)
  if pf then
    M.ensure(pf, git.repo_name(root))
  end
  local blocks = {}
  for _, b in ipairs(opts().project_agenda_blocks or {}) do
    local nb = vim.deepcopy(b)
    if nb.type == "code_todos" then
      nb.root = nb.root or root
    else
      nb.files = nb.files or { pf }
    end
    blocks[#blocks + 1] = nb
  end
  return { blocks = blocks, description = "Project " .. (git.repo_name(root) or root) }, pf
end

--- `project_agenda`: the agenda of the current repository's project file
--- and its code TODOs.
function M.agenda()
  local pf, root = file_or_warn()
  if not pf then
    return
  end
  require("org.extensions.code").remember_root(root)
  local view = M.view(root)
  if #view.blocks == 0 then
    utils.warn("project_agenda_blocks is empty")
    return
  end
  -- restricted to the project file (which also skips the agenda file check)
  require("org.agenda").open(view, { restrict = { filename = M.file(root) } })
end

return M
