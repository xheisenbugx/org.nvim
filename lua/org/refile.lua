---@mod org.refile Refiling subtrees
---
--- Targets are headlines in the agenda files (plus the current file) up to
--- `refile.max_level`, and the files themselves (top level).

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

---@class org.RefileTarget
---@field filename string
---@field lnum integer|nil headline line; nil = file top level
---@field olp string[] outline path including the target itself
---@field level integer|nil
---@field label string

local function file_label(path)
  return vim.fn.fnamemodify(path, ":t")
end

--- All refile targets.
---@param opts? { exclude?: { filename: string, s: integer, e: integer } }
---@return org.RefileTarget[]
function M.targets(opts)
  opts = opts or {}
  local rcfg = config.opts.refile or {}
  local max_level = rcfg.max_level or 3
  local style = rcfg.use_outline_path
  if style == nil then
    style = "file"
  end
  local list = files.agenda_files()
  if rcfg.include_current_file ~= false and utils.is_org() then
    local cur = files.get_buffer(0)
    local found = false
    for i, f in ipairs(list) do
      if f.filename and cur.filename and f.filename == cur.filename then
        list[i] = cur
        found = true
      end
    end
    if not found and cur.filename then
      table.insert(list, 1, cur)
    end
  end
  local out = {}
  for _, f in ipairs(list) do
    if f.filename then
      local fname = file_label(f.filename)
      out[#out + 1] = { filename = f.filename, olp = {}, label = fname .. "/" }
      for _, hl in ipairs(f.headlines) do
        local excluded = opts.exclude
          and opts.exclude.filename == f.filename
          and hl.line >= opts.exclude.s
          and hl.line <= opts.exclude.e
        if hl.level <= max_level and not excluded then
          local olp = hl:outline_path()
          olp[#olp + 1] = hl:plain_title()
          local label
          if style == "file" or style == "full-file-path" then
            label = fname .. "/" .. table.concat(olp, "/")
          elseif style then
            label = table.concat(olp, "/")
          else
            label = hl:plain_title() .. "  (" .. fname .. ")"
          end
          out[#out + 1] = { filename = f.filename, lnum = hl.line, olp = olp, level = hl.level, label = label }
        end
      end
    end
  end
  return out
end

--- Ask for a refile target.
---@param opts? { prompt?: string, exclude?: table }
---@return org.RefileTarget|nil
function M.pick_target(opts)
  opts = opts or {}
  local targets = M.targets(opts)
  if #targets == 0 then
    utils.warn("No refile targets (check `agenda_files`)")
    return nil
  end
  local prompt = opts.prompt or "Refile to"
  if (config.opts.refile or {}).allow_creating_parent_nodes then
    local labels = vim.tbl_map(function(t)
      return t.label
    end, targets)
    local value = utils.input_complete(prompt .. ": ", function(cmdline)
      local out = {}
      for _, l in ipairs(labels) do
        if l:lower():find(cmdline:lower(), 1, true) then
          out[#out + 1] = l
        end
      end
      return out
    end)
    if not value or vim.trim(value) == "" then
      return nil
    end
    value = vim.trim(value)
    for _, t in ipairs(targets) do
      if t.label == value then
        return t
      end
    end
    -- longest existing prefix + new nodes
    local best
    for _, t in ipairs(targets) do
      local l = t.label:gsub("/$", "")
      if value:sub(1, #l + 1) == l .. "/" and (not best or #t.label > #best.label) then
        best = t
      end
    end
    if not best then
      utils.warn("No refile target matches: " .. value)
      return nil
    end
    local rest = value:sub(#best.label:gsub("/$", "") + 2)
    local new_nodes = vim.split(rest, "/", { trimempty = true })
    if #new_nodes == 0 then
      return best
    end
    if not utils.confirm("Create new node(s) " .. table.concat(new_nodes, "/") .. "?") then
      return nil
    end
    return M.create_nodes(best, new_nodes)
  end
  return utils.select(targets, {
    prompt = prompt,
    format_item = function(t)
      return t.label
    end,
    kind = "org_refile",
  })
end

--- Create headline(s) `names` under `parent` target; returns the new target.
function M.create_nodes(parent, names)
  local bufnr = utils.load_buffer(parent.filename)
  local file = files.get_buffer(bufnr)
  local level, at
  if parent.lnum then
    local hl = file:headline_at(parent.lnum)
    level = hl.level + 1
    at = hl.end_line
  else
    level = 1
    at = #file.lines
  end
  local lines = {}
  for i, name in ipairs(names) do
    lines[#lines + 1] = string.rep("*", level + i - 1) .. " " .. name
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  local olp = vim.deepcopy(parent.olp)
  vim.list_extend(olp, names)
  return {
    filename = parent.filename,
    lnum = at + #lines,
    olp = olp,
    level = level + #names - 1,
    label = parent.label .. table.concat(names, "/"),
  }
end

--- Insert `lines` (a subtree) under `dest`. Returns (bufnr, first line).
---@param lines string[]
---@param dest org.RefileTarget|{ filename?: string, bufnr?: integer, lnum?: integer, prepend?: boolean }
function M.insert_subtree(lines, dest)
  local bufnr = dest.bufnr or utils.load_buffer(dest.filename)
  local file = files.get_buffer(bufnr)
  local level, at
  if dest.lnum then
    local hl = file:headline_at(dest.lnum)
    level = hl.level + 1
    if dest.prepend then
      at = hl.body_end
      -- keep the headline's own section body before the new child
    else
      at = hl.end_line
    end
  else
    level = 1
    if dest.prepend then
      at = file.preamble_end
    else
      at = #file.lines
    end
  end
  -- drop trailing blank lines at the insertion point so the tree stays tidy
  while at > 0 and not dest.prepend and vim.trim(file.lines[at] or "x") == "" and at > (dest.lnum or 0) and at > (dest.min_at or 0) do
    at = at - 1
  end
  local new = edit.relevel(vim.deepcopy(lines), level)
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, new)
  return bufnr, at + 1
end

--- Move a subtree (or given lines) to `dest`.
---@param src { bufnr?: integer, lnum?: integer, lines?: string[] }
---@param dest org.RefileTarget
---@return integer bufnr, integer lnum of the moved headline
function M.move(src, dest)
  if src.lines then
    local b, l = M.insert_subtree(src.lines, dest)
    return b, l
  end
  local sbuf = src.bufnr or vim.api.nvim_get_current_buf()
  local sfile = files.get_buffer(sbuf)
  local hl = sfile:headline_at(src.lnum or vim.api.nvim_win_get_cursor(0)[1])
  if not hl then
    error("org: nothing to refile here")
  end
  local s, e = hl.line, hl.end_line
  local lines = vim.api.nvim_buf_get_lines(sbuf, s - 1, e, false)
  -- trailing blank lines stay behind? keep them with the subtree but trim
  while #lines > 1 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  local dbuf = dest.bufnr or utils.load_buffer(dest.filename)
  if dbuf == sbuf then
    if dest.lnum and dest.lnum >= s and dest.lnum <= e then
      error("org: cannot refile a subtree into itself")
    end
    local dfile = files.get_buffer(dbuf)
    local dhl = dest.lnum and dfile:headline_at(dest.lnum) or nil
    local insert_after
    if dest.prepend then
      insert_after = dhl and dhl.body_end or dfile.preamble_end
    else
      insert_after = dhl and dhl.end_line or #dfile.lines
    end
    if insert_after >= e then
      local b, l = M.insert_subtree(lines, { bufnr = dbuf, lnum = dest.lnum, prepend = dest.prepend, min_at = e })
      vim.api.nvim_buf_set_lines(sbuf, s - 1, e, false, {})
      return b, l - (e - s + 1)
    else
      vim.api.nvim_buf_set_lines(sbuf, s - 1, e, false, {})
      return M.insert_subtree(lines, { bufnr = dbuf, lnum = dest.lnum, prepend = dest.prepend })
    end
  end
  local b, l = M.insert_subtree(lines, { bufnr = dbuf, lnum = dest.lnum, prepend = dest.prepend })
  vim.api.nvim_buf_set_lines(sbuf, s - 1, e, false, {})
  return b, l
end

--- Save a buffer that is not shown in any window (hidden target files).
local function save_if_hidden(bufnr)
  if vim.fn.bufwinid(bufnr) == -1 then
    utils.save_buffer(bufnr)
  end
end

--- Refile the subtree at target (org-refile).
---@param target? org.Target
---@param opts? { dest?: org.RefileTarget, save?: boolean }
function M.refile(target, opts)
  opts = opts or {}
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local dest = opts.dest
    or M.pick_target({
      prompt = "Refile \"" .. hl:plain_title() .. "\" to",
      exclude = { filename = file.filename, s = hl.line, e = hl.end_line },
    })
  if not dest then
    return
  end
  local title = hl:plain_title()
  local ok, dbuf, dline = pcall(M.move, { bufnr = bufnr, lnum = hl.line }, dest)
  if not ok then
    utils.error(tostring(dbuf))
    return
  end
  if dbuf ~= bufnr then
    save_if_hidden(dbuf)
  end
  if opts.save then
    utils.save_buffer(bufnr)
  end
  utils.notify("Refiled \"" .. title .. "\" to " .. dest.label:gsub("/$", ""))
  return dbuf, dline
end

--- Jump to a refile target (C-u C-c C-w in Emacs).
function M.goto()
  local dest = M.pick_target({ prompt = "Go to" })
  if not dest then
    return
  end
  vim.cmd("normal! m'")
  utils.open_file(dest.filename, dest.lnum or 1)
end

return M
