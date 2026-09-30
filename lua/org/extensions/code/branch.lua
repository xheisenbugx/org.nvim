---@mod org.extensions.code.branch Branch-aware clocking
---
--- With `branch_clock = true`, switching the git branch of the buffer you
--- work in (noticed on BufEnter, FocusGained and DirChanged) clocks into
--- the heading whose `:BRANCH:` property names the branch, or whose ID,
--- CUSTOM_ID or TICKET property (or title) holds the ticket that
--- `branch_ticket_pattern` extracts from the branch name.

local git = require("org.extensions.code.git")
local utils = require("org.utils")

local M = {}

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

--- Last branch seen per repository root.
---@type table<string, string|false>
M.seen = {}

--- The org files searched for branch headings: the agenda files and the
--- project file of `root`.
---@param root? string
---@return org.File[]
function M.files(root)
  local files = require("org.files")
  local list, seen = {}, {}
  local function add(f)
    if f and f.filename and not seen[f.filename] then
      seen[f.filename] = true
      list[#list + 1] = f
    end
  end
  if root then
    local pf = require("org.extensions.code.project").file(root)
    if pf and vim.uv.fs_stat(pf) then
      add(files.get(pf))
    end
  end
  local ok, agenda = pcall(files.agenda_files)
  if ok then
    for _, f in ipairs(agenda) do
      add(f)
    end
  end
  return list
end

--- The ticket in a branch name (`branch_ticket_pattern`), or nil.
---@param branch string
---@return string|nil
function M.ticket(branch)
  local pat = opts().branch_ticket_pattern
  if not pat or pat == "" then
    return nil
  end
  if type(pat) == "function" then
    return pat(branch)
  end
  return branch:match(pat)
end

--- The heading for `branch`: `:BRANCH:` first, then the ticket.
---@param branch string
---@param root? string
---@return org.Headline|nil
function M.find_heading(branch, root)
  local list = M.files(root)
  for _, f in ipairs(list) do
    for _, hl in ipairs(f.headlines) do
      if hl.properties.BRANCH and vim.trim(hl.properties.BRANCH) == branch then
        return hl
      end
    end
  end
  local ticket = M.ticket(branch)
  if not ticket or ticket == "" then
    return nil
  end
  for _, f in ipairs(list) do
    for _, hl in ipairs(f.headlines) do
      local p = hl.properties
      if p.ID == ticket or p.CUSTOM_ID == ticket or p.TICKET == ticket then
        return hl
      end
    end
  end
  for _, f in ipairs(list) do
    for _, hl in ipairs(f.headlines) do
      if (hl.title or ""):find(ticket, 1, true) then
        return hl
      end
    end
  end
  return nil
end

--- Clock into the heading of `branch` (unless it is already clocked).
---@param branch string
---@param root? string
---@return boolean clocked in
function M.clock_branch(branch, root)
  local hl = M.find_heading(branch, root)
  if not hl then
    return false
  end
  local clock = require("org.clock")
  local bufnr = utils.find_buffer(hl.file.filename) or utils.load_buffer(hl.file.filename)
  if clock.is_clocked_headline(bufnr, hl.line) then
    return false
  end
  local ok, err = pcall(clock.clock_in, { bufnr = bufnr, lnum = hl.line }, { no_count = true })
  if not ok then
    utils.warn("Branch clock: " .. tostring(err))
    return false
  end
  utils.notify(string.format("Branch %s: clocked into %s", branch, hl.title or ""))
  return true
end

--- Check the branch of `buf`'s repository and clock in when it changed.
---@param buf? integer
function M.check(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local root = git.root(buf)
  if not root then
    return
  end
  local branch = git.branch(root) or false
  local prev = M.seen[root]
  M.seen[root] = branch
  if prev == nil and not opts().branch_clock_on_start then
    return
  end
  if branch and branch ~= prev then
    M.clock_branch(branch, root)
  end
end

--- `code_link_branch`: set `:BRANCH:` of the heading at point to the
--- current branch (of the org file's repository, else of the last code
--- buffer's).
function M.link_branch()
  if not utils.ensure_org() then
    return
  end
  local root = require("org.extensions.code.project").current_root()
  local branch = root and git.branch(root)
  if not branch then
    utils.warn("No git branch (not in a repository, or HEAD is detached)")
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local hl = require("org.files").get_buffer(0):headline_at(lnum)
  if not hl then
    utils.warn("Not under a headline")
    return
  end
  require("org.edit").set_property(0, hl.line, "BRANCH", branch)
  M.seen[root] = branch
  utils.notify("Linked branch " .. branch .. " to " .. (hl.title or ""))
  return branch
end

return M
