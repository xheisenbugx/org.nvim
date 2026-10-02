---@mod org.extensions.code Code <-> notes bridge
---
--- Enable with `setup({ extensions = { code = {} } })` (see
--- `:h org-extensions-code`): capture code with its context, `code:` links
--- to symbols, an org file per git repository, clocking by git branch and
--- the repository's TODO comments in the agenda.

local M = {}

local C = "org.extensions.code"

M.defaults = {
  --- Template of `code_capture` (a capture template table). Its `target`
  --- "project" (or nil) captures into the repository's project file under
  --- `project_headline`, or `fallback_target` outside a repository.
  capture_template = {
    description = "Code note",
    type = "entry",
    template = "* %?\n  %U  %(code-link)\n  %(git-info)\n%(code-block)",
    target = "project",
  },
  --- Key of a template with `capture_template` added to
  --- `capture.templates` (when that key is free), so the capture menu
  --- offers it in code buffers too; false for none.
  template_key = "k",
  --- Filetype -> Babel language of the captured src block, over the
  --- built-in table (`{ javascript = "js", cpp = "C++", ... }`).
  languages = {},
  --- Link paths: "absolute" (with `~`) or "relative" (to the git root).
  link_path = "absolute",
  --- `store_link` in a code buffer stores a `code:` link.
  store_links = true,
  --- Link to the symbol around the cursor (LSP, else treesitter) rather
  --- than the line.
  store_symbol = true,
  --- Milliseconds to wait for a language server (to attach, then to
  --- answer); 0 skips LSP.
  lsp_timeout = 1000,
  --- Filetypes that are not code buffers for links and captures.
  exclude_filetypes = { "help", "qf", "netrw", "oil", "orgagenda", "gitcommit" },
  --- The org file of a repository: a path relative to its root, or with
  --- `<org_directory>`, `${repo}` and `${root}` replaced (e.g.
  --- "<org_directory>/projects/${repo}.org"), or `fun(root, repo): path`.
  project_file = ".org/tasks.org",
  --- First lines of a new project file (`${repo}` is replaced).
  project_file_header = "#+title: ${repo}\n",
  --- Headline project captures go under (nil: the end of the file).
  project_headline = "Tasks",
  --- Where "project" code captures go outside a repository (nil: the
  --- `default_notes_file`), and under which headline (nil: the end of it).
  fallback_target = nil,
  fallback_headline = nil,
  --- Template of `project_capture` (its target is the project file).
  project_template = { description = "Project task", type = "entry", template = "* TODO %?\n  %U\n  %a" },
  --- Blocks of `project_agenda`, on the project file; a `code_todos` block
  --- lists the repository's TODO comments.
  project_agenda_blocks = {
    { type = "agenda", span = "week" },
    { type = "todo" },
    { type = "code_todos" },
  },
  --- Clock into the heading of a git branch when you switch to it.
  branch_clock = false,
  --- Also clock in for the branch found when Neovim starts.
  branch_clock_on_start = false,
  --- Lua pattern (or `fun(branch)`) whose capture is the ticket in a
  --- branch name, matched against headings' ID, CUSTOM_ID, TICKET and title.
  branch_ticket_pattern = "(%u+%-%d+)",
  --- Comment keywords of the code TODOs.
  todo_keywords = { "TODO", "FIXME", "HACK", "XXX", "BUG" },
  --- Lua pattern on the text in parentheses after the keyword whose
  --- capture is the ID of a heading: `TODO(org:ID)`.
  todo_link_pattern = "^org:%s*(.-)%s*$",
  --- Only count keywords after a comment marker (or at the start of a line).
  todo_require_comment = true,
  --- Lua patterns of repository-relative paths to skip.
  todo_exclude = { "%.org$", "%.min%.js$", "^vendor/", "^node_modules/" },
  --- "auto" (git grep, else rg, else Lua), "git", "rg" or "lua".
  todo_scanner = "auto",
  --- Files the Lua scanner reads at most.
  todo_max_files = 2000,
  --- Items shown at most.
  todo_max_items = 500,
  --- Put before the category of a code TODO listed under its heading.
  todo_group_prefix = "↳ ",
}

local function a(fn, desc, modes)
  local mod, name = fn:match("^(.-)%.([%w_]+)$")
  return { C .. "." .. mod, name, desc = desc, modes = modes, global = true }
end

M.actions = {
  code_capture = a("context.capture", "Capture code with a src block, a link back and git info", { "n", "x" }),
  code_store_link = { C, "store_link", desc = "Store a code: link to the symbol at the cursor", global = true },
  project_open = a("project.open", "Open the org file of this git repository"),
  project_capture = a("project.capture", "Capture into the org file of this git repository"),
  project_agenda = a("project.agenda", "Agenda of this repository's org file and code TODOs"),
  code_todos = a("todos.open", "Show this repository's TODO comments in an agenda"),
  code_link_branch = a("branch.link_branch", "Set the heading's BRANCH property to the current git branch"),
}

-- <prefix>j: "jump" between code and notes
M.mappings = {
  global = {
    code_capture = "<prefix>jc",
    code_store_link = "<prefix>jl",
    project_open = "<prefix>jp",
    project_capture = "<prefix>jn",
    project_agenda = "<prefix>ja",
    code_todos = "<prefix>jt",
  },
  org = {
    code_link_branch = "<prefix>jb",
  },
}

M.groups = { { "j", "code" } }

local augroup = vim.api.nvim_create_augroup("org.code", { clear = true })

-- repository roots of recent code buffers, most recent first
local roots = {}

--- Remember `root` as the most recent repository.
---@param root? string
function M.remember_root(root)
  if not root then
    return
  end
  for i, r in ipairs(roots) do
    if r == root then
      table.remove(roots, i)
      break
    end
  end
  table.insert(roots, 1, root)
  while #roots > 10 do
    table.remove(roots)
  end
end

--- Repository roots of recent code buffers, most recent first.
---@return string[]
function M.recent_roots()
  return roots
end

--- The resolved options.
---@return table
function M.opts()
  return require("org.extensions").opts("code") or M.defaults
end

--- `code_store_link`: store a `code:` link from a code buffer.
function M.store_link()
  local l = require(C .. ".link").store()
  if not l then
    require("org.utils").warn("Not a code buffer")
    return
  end
  require("org.links").store(l.link, l.desc)
  require("org.utils").notify("Stored: " .. l.link)
  return l
end

-- the template we added to capture.templates, to remove it again
local added_template

function M.setup(opts)
  vim.api.nvim_clear_autocmds({ group = augroup })
  local config = require("org.config")
  local types = config.opts.links.types
  if types.code == nil then
    types.code = require(C .. ".link").type
  end
  require(C .. ".context").register()
  require("org.lazy").on_load("org.agenda.render", "code", function(render)
    render.sources.code_todos = require(C .. ".todos").source
  end)
  local key = opts.template_key
  local templates = config.opts.capture.templates
  if key and templates and templates[key] == nil then
    if vim.tbl_isempty(templates) then
      -- keep the default template the empty table stands for
      for k, t in pairs(require("org.capture").DEFAULT_TEMPLATES) do
        templates[k] = vim.deepcopy(t)
      end
      added_template = { key = key, defaults = true }
    else
      added_template = { key = key }
    end
    local tpl = vim.deepcopy(opts.capture_template)
    if tpl.target == "project" or tpl.target == nil then
      -- resolved when the capture starts (the target, then the headline):
      -- the project file, or fallback_target outside a repository
      local own, headline = tpl.headline, nil
      tpl.target = function()
        local target
        target, headline = require(C .. ".context").project_target(require(C .. ".git").root(0), own)
        return target
      end
      tpl.headline = function()
        return headline
      end
    end
    templates[key] = tpl
    added_template.tpl = tpl
  end
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(ev)
      if require(C .. ".link").is_code_buffer(ev.buf) then
        M.remember_root(require(C .. ".git").root(ev.buf))
      end
    end,
  })
  if opts.branch_clock then
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "DirChanged" }, {
      group = augroup,
      callback = function(ev)
        local buf = ev.event == "DirChanged" and vim.api.nvim_get_current_buf() or ev.buf
        vim.schedule(function()
          require(C .. ".branch").check(buf)
        end)
      end,
    })
  end
end

function M.teardown()
  vim.api.nvim_clear_autocmds({ group = augroup })
  local config = require("org.config")
  local types = config.opts.links.types
  if types.code == require(C .. ".link").type then
    types.code = nil
  end
  require(C .. ".context").unregister()
  require("org.lazy").if_loaded("org.agenda.render", "code", function(render)
    if render.sources.code_todos == require(C .. ".todos").source then
      render.sources.code_todos = nil
    end
  end)
  if added_template then
    local templates = config.opts.capture.templates
    if templates[added_template.key] == added_template.tpl then
      templates[added_template.key] = nil
      if added_template.defaults then
        for k in pairs(require("org.capture").DEFAULT_TEMPLATES) do
          templates[k] = nil
        end
      end
    end
    added_template = nil
  end
  require(C .. ".branch").seen = {}
  require(C .. ".branch").warned = {}
  require(C .. ".todos").cache = {}
end

function M.health(h, opts)
  if vim.fn.executable("git") == 1 then
    h.ok("git found: commits in captures, git grep for code TODOs")
  else
    h.warn("git not found: captures have no commit, code TODOs use rg or a slow scan")
  end
  if vim.fn.executable("rg") == 1 then
    h.ok("rg found")
  end
  local root = require(C .. ".git").root(vim.fn.getcwd())
  if root then
    h.info("project file of the working directory: " .. tostring(require(C .. ".project").file(root)))
  end
  if opts.branch_clock then
    h.info("branch clocking is on")
  end
  if (opts.lsp_timeout or 0) <= 0 then
    h.info("lsp_timeout is 0: code: links use treesitter and text search")
  end
end

return M
