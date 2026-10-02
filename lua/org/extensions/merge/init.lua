---@mod org.extensions.merge Structural git merge driver for Org files
---
--- Enable with `extensions = { merge = true }` (see
--- `:h org-extensions-merge`). The driver itself is a script,
--- `lua/org/extensions/merge/driver.lua` (or `bin/org-merge`), that git
--- runs for `*.org` files once `.gitattributes` and the git config name it;
--- `:Org merge_install` sets both up for the repository of the current file.
--- The merge is in `org.extensions.merge.merge`.

local MOD = "org.extensions.merge"

local M = {}

M.defaults = {
  --- Name of the driver in git (`merge=<name>` and `merge.<name>.driver`).
  driver_name = "org",
  --- Patterns given the driver in the attributes file.
  patterns = { "*.org" },
  --- Side taken when both changed the same TODO keyword, priority,
  --- planning keyword or property, or moved the same entry to different
  --- parents: "ours", "theirs", or nil for conflict markers around that
  --- entry's headline (or that property, or the moved entry).
  prefer = nil,
  --- Sort LOGBOOK items newest first when both sides added some.
  sort_logbook = true,
  --- Pass `todo_keywords` to the driver, so custom keywords (NEXT, WAIT...)
  --- are read as keywords and not as part of titles.
  pass_todo_keywords = true,
  --- Drawers merged item by item like LOGBOOK (besides LOGBOOK and the
  --- `log_into_drawer` / `clock.into_drawer` names): `{ "NOTES" }`.
  set_drawers = {},
  --- How alike (0..1, share of equal lines) an entry renamed and edited on
  --- one side must stay to be matched with the original; false: only an
  --- entry whose text did not change is matched after a rename.
  rename_similarity = 0.6,
  --- A Lua file the driver runs first, for other settings it should see.
  config_file = nil,
}

M.actions = {
  merge_install = { MOD, "install", desc = "Use the Org merge driver in this git repository" },
  merge_uninstall = { MOD, "uninstall", desc = "Stop using the Org merge driver in this git repository" },
}

M.commands = {
  merge_install = {
    MOD,
    "install_command",
    desc = "Use the Org merge driver here: :Org merge_install [gitattributes|info]",
    complete = function()
      return { "gitattributes", "info" }
    end,
  },
}

local function opts()
  return require("org.extensions").opts("merge") or M.defaults
end

local function utils()
  return require("org.utils")
end

--- Directory of the driver script.
function M.dir()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
end

--- The driver script.
function M.driver_path()
  return M.dir() .. "/driver.lua"
end

--- `bin/org-merge` of this checkout (nil when missing).
function M.wrapper_path()
  local p = vim.fn.fnamemodify(M.dir(), ":h:h:h:h") .. "/bin/org-merge"
  return vim.fn.filereadable(p) == 1 and p or nil
end

local function git(args, cwd)
  local cmd = vim.list_extend({ "git" }, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return res.code == 0, vim.trim(res.stdout or ""), vim.trim(res.stderr or "")
end

--- Top of the git work tree holding `path` (a file or directory), or nil.
---@param path? string default: the current buffer's file, else the cwd
function M.repo_root(path)
  path = path or vim.api.nvim_buf_get_name(0)
  local dir = path ~= "" and vim.fn.fnamemodify(path, ":p") or vim.fn.getcwd()
  if vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  if vim.fn.executable("git") == 0 or vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  local ok, out = git({ "rev-parse", "--show-toplevel" }, dir)
  return ok and out ~= "" and out or nil
end

--- The `merge.<name>.driver` command. The options are not in it: the
--- driver reads them from the repository's `merge.<name>.*` git config at
--- merge time (see |M.config_values|), so `git config merge.org.prefer
--- theirs` takes effect without installing again.
---@param o? table the extension's options
---@return string
function M.driver_command(o)
  o = o or opts()
  return table.concat({
    vim.fn.shellescape(vim.v.progpath),
    "--headless -u NONE -i NONE -l",
    vim.fn.shellescape(M.driver_path()),
    vim.fn.shellescape("--name=" .. o.driver_name),
    "--marker-size=%L --base-label=%S --ours-label=%X --theirs-label=%Y %O %A %B %P",
  }, " ")
end

--- The `merge.<name>.*` git config the driver reads, from the options:
--- `{ key, values }` pairs (an empty list unsets the key).
---@param o? table the extension's options
---@return { [1]: string, [2]: string[] }[]
function M.config_values(o)
  o = o or opts()
  local todo = {}
  if o.pass_todo_keywords ~= false then
    local kw = require("org.config").opts.todo_keywords
    kw = type(kw) == "string" and { kw } or kw or {}
    if not (#kw == 1 and kw[1] == "TODO | DONE") then
      for _, seq in ipairs(kw) do
        if type(seq) == "string" then
          todo[#todo + 1] = seq
        end
      end
    end
  end
  local drawers = {}
  for _, d in ipairs(o.set_drawers or {}) do
    drawers[#drawers + 1] = tostring(d)
  end
  local sim = o.rename_similarity
  return {
    { "prefer", (o.prefer == "ours" or o.prefer == "theirs") and { o.prefer } or {} },
    { "sortLogbook", o.sort_logbook == false and { "false" } or {} },
    { "todo", todo },
    { "setDrawers", drawers },
    { "renameSimilarity", sim == false and { "2" } or (tonumber(sim) and { tostring(sim) } or {}) },
    { "config", o.config_file and { vim.fn.expand(o.config_file) } or {} },
  }
end

local function read_lines(path)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end
  return {}
end

-- Attributes file lines with `pattern merge=name` added (or removed).
local function edit_attributes(lines, o, remove)
  local want = {}
  for _, p in ipairs(o.patterns) do
    want[p .. " merge=" .. o.driver_name] = true
  end
  local out, have = {}, {}
  for _, l in ipairs(lines) do
    local key = vim.trim(l)
    if want[key] then
      have[key] = true
      if not remove then
        out[#out + 1] = l
      end
    else
      out[#out + 1] = l
    end
  end
  if not remove then
    for _, p in ipairs(o.patterns) do
      local line = p .. " merge=" .. o.driver_name
      if not have[line] then
        out[#out + 1] = line
      end
    end
  end
  return out, vim.tbl_count(have)
end

--- Set up the driver in the repository at `root`.
---@param root string
---@param where "gitattributes"|"info" `.gitattributes` (committed) or `.git/info/attributes` (this clone only)
---@param o? table the extension's options
---@return boolean ok
---@return string message
function M.install_at(root, where, o)
  o = o or opts()
  local attr
  if where == "info" then
    local ok, p = git({ "rev-parse", "--git-path", "info/attributes" }, root)
    if not ok then
      return false, "git rev-parse failed"
    end
    attr = vim.fn.fnamemodify(root .. "/" .. p, ":p")
    if utils().is_absolute(p) then
      attr = p
    end
    vim.fn.mkdir(vim.fn.fnamemodify(attr, ":h"), "p")
  else
    attr = root .. "/.gitattributes"
  end
  local lines = edit_attributes(read_lines(attr), o, false)
  vim.fn.writefile(lines, attr)
  local name = "merge." .. o.driver_name
  local ok1, _, err1 = git({ "config", "--local", name .. ".name", "Org structural merge (org.nvim)" }, root)
  local ok2, _, err2 = git({ "config", "--local", name .. ".driver", M.driver_command(o) }, root)
  if not (ok1 and ok2) then
    return false, "git config failed: " .. (err1 ~= "" and err1 or err2)
  end
  for _, kv in ipairs(M.config_values(o)) do
    local key = name .. "." .. kv[1]
    git({ "config", "--local", "--unset-all", key }, root)
    for _, v in ipairs(kv[2]) do
      local ok3, _, err3 = git({ "config", "--local", "--add", key, v }, root)
      if not ok3 then
        return false, "git config failed: " .. err3
      end
    end
  end
  return true, string.format("Org merge driver installed (%s, %s.driver)", vim.fn.fnamemodify(attr, ":~:."), name)
end

--- Remove the driver from the repository at `root`: the attribute lines
--- from `.gitattributes` and `.git/info/attributes` and the git config.
---@param root string
---@param o? table
---@return boolean ok
---@return string message
function M.uninstall_at(root, o)
  o = o or opts()
  local files = { root .. "/.gitattributes" }
  local ok, p = git({ "rev-parse", "--git-path", "info/attributes" }, root)
  if ok then
    files[#files + 1] = utils().is_absolute(p) and p or (root .. "/" .. p)
  end
  local removed = 0
  for _, f in ipairs(files) do
    if vim.fn.filereadable(f) == 1 then
      local lines, n = edit_attributes(read_lines(f), o, true)
      if n > 0 then
        vim.fn.writefile(lines, f)
        removed = removed + n
      end
    end
  end
  git({ "config", "--local", "--remove-section", "merge." .. o.driver_name }, root)
  return true, string.format("Org merge driver removed (%d attribute line%s)", removed, removed == 1 and "" or "s")
end

local CHOICES = {
  { id = "gitattributes", label = ".gitattributes (committed, for everyone) + .git/config" },
  { id = "info", label = ".git/info/attributes (this clone only) + .git/config" },
}

--- `merge_install`: ask where, then set up the driver for the repository
--- of the current file.
function M.install()
  local root = M.repo_root()
  if not root then
    utils().warn("merge_install: not in a git repository")
    return
  end
  vim.ui.select(CHOICES, {
    prompt = "Org merge driver for " .. require("org.utils").abbreviate(root) .. ":",
    format_item = function(c)
      return c.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, msg = M.install_at(root, choice.id)
    if ok then
      utils().notify(msg)
    else
      utils().error(msg)
    end
  end)
end

--- `:Org merge_install [gitattributes|info]`: without an argument, ask.
function M.install_command(args)
  local where = vim.trim(args or "")
  if where == "" then
    return M.install()
  end
  if where ~= "gitattributes" and where ~= "info" then
    utils().warn("merge_install: gitattributes or info, not " .. where)
    return
  end
  local root = M.repo_root()
  if not root then
    utils().warn("merge_install: not in a git repository")
    return
  end
  local ok, msg = M.install_at(root, where)
  if ok then
    utils().notify(msg)
  else
    utils().error(msg)
  end
end

--- `merge_uninstall`: remove the driver from the current repository.
function M.uninstall()
  local root = M.repo_root()
  if not root then
    utils().warn("merge_uninstall: not in a git repository")
    return
  end
  local _, msg = M.uninstall_at(root)
  utils().notify(msg)
end

function M.health(h)
  if vim.fn.executable("git") == 1 then
    h.ok("merge: git found")
  else
    h.warn("merge: git not found; the driver is only used by git")
  end
  local root = M.repo_root(vim.fn.getcwd())
  if root then
    local o = opts()
    local ok, drv = git({ "config", "--get", "merge." .. o.driver_name .. ".driver" }, root)
    local _, attr = git({ "check-attr", "merge", "--", "x.org" }, root)
    if ok and drv ~= "" and attr:match("merge: " .. vim.pesc(o.driver_name) .. "$") then
      h.ok("merge: driver installed in " .. root)
    else
      h.info("merge: not installed in " .. root .. " (:Org merge_install)")
    end
  end
  h.info("merge: driver command: " .. M.driver_command())
end

return M
