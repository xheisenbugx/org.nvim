---@mod org.refile Refiling subtrees
---
--- Targets are headlines in the agenda files (plus the current file) up to
--- `refile.max_level`, and the files themselves (top level). With
--- `refile.targets` (like org-refile-targets) they come from specs:
---   { files = "agenda"|"current"|path(s)|function, max_level?, level?,
---     tag?, todo?, regexp? }

local config = require("org.config")
local date = require("org.date")
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

--- Files for a `refile.targets` spec: "agenda", "current", a path/glob or
--- a list of them, or a function returning paths (nil = current file).
local function spec_files(spec_files_value)
  local v = spec_files_value
  if type(v) == "function" then
    v = v()
  end
  if v == nil or v == "current" then
    return utils.is_org() and { files.get_buffer(0) } or {}
  elseif v == "agenda" then
    return files.agenda_files()
  end
  local out = {}
  for _, p in ipairs(utils.glob_org_files(type(v) == "table" and v or { v })) do
    local f = files.get(p)
    if f then
      out[#out + 1] = f
    end
  end
  return out
end

--- Does `hl` satisfy a `refile.targets` spec?
local function spec_matches(spec, hl)
  if spec.level and hl.level ~= spec.level then
    return false
  end
  local max = spec.max_level or spec.maxlevel
  if max and hl.level > max then
    return false
  end
  if spec.tag and not vim.tbl_contains(hl.tags, spec.tag) then
    return false
  end
  if spec.todo and hl.todo ~= spec.todo then
    return false
  end
  if spec.regexp and vim.fn.match(hl.raw, spec.regexp) < 0 then
    return false
  end
  return true
end

--- (file, predicate) pairs describing where targets come from.
local function target_sources()
  local rcfg = config.opts.refile or {}
  local sources = {}
  if rcfg.targets and #rcfg.targets > 0 then
    for _, spec in ipairs(rcfg.targets) do
      for _, f in ipairs(spec_files(spec.files)) do
        sources[#sources + 1] = {
          file = f,
          pred = function(hl)
            return spec_matches(spec, hl)
          end,
        }
      end
    end
    return sources
  end
  local max_level = rcfg.max_level or 3
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
  for _, f in ipairs(list) do
    sources[#sources + 1] = {
      file = f,
      pred = function(hl)
        return hl.level <= max_level
      end,
    }
  end
  return sources
end

--- All refile targets.
---@param opts? { exclude?: { filename: string, s: integer, e: integer } }
---@return org.RefileTarget[]
function M.targets(opts)
  opts = opts or {}
  local rcfg = config.opts.refile or {}
  local style = rcfg.use_outline_path
  if style == nil then
    style = "file"
  end
  local verify = rcfg.verify
  local out = {}
  local seen = {}
  for _, src in ipairs(target_sources()) do
    local f = src.file
    if f.filename then
      local fname = file_label(f.filename)
      if not seen[f.filename] then
        out[#out + 1] = { filename = f.filename, olp = {}, label = fname .. "/" }
      end
      seen[f.filename] = true
      for _, hl in ipairs(f.headlines) do
        local excluded = opts.exclude
          and opts.exclude.filename == f.filename
          and hl.line >= opts.exclude.s
          and hl.line <= opts.exclude.e
        local key = f.filename .. ":" .. hl.line
        if not excluded and not seen[key] and src.pred(hl) and (not verify or verify(hl)) then
          seen[key] = true
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

--- Where the last refile / capture went: { filename|bufnr, lnum, raw }.
M.last_stored = nil

--- Remember the headline at (bufnr, lnum) as the last stored location.
function M.remember(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local name = vim.api.nvim_buf_get_name(bufnr)
  M.last_stored = { bufnr = bufnr, filename = name ~= "" and name or nil, lnum = lnum, raw = line }
end

--- Log a refile note under the moved entry (org-log-refile).
local function log_refile(bufnr, lnum)
  local mode = (config.opts.refile or {}).log
  if not mode then
    return
  end
  local note
  if mode == "note" then
    note = utils.input({ prompt = "Refile note: " })
    if note == nil then
      note = ""
    end
  end
  local ts = date.now():clone({ active = false }):to_string()
  edit.add_log_entry(bufnr, lnum, edit.log_lines("- Refiled on " .. ts, note))
end

local function with_note_order(dest)
  if dest.prepend == nil and (config.opts.refile or {}).reverse_note_order then
    return vim.tbl_extend("force", dest, { prepend = true })
  end
  return dest
end

--- Refile the subtree at target (org-refile).
---@param target? org.Target
---@param opts? { dest?: org.RefileTarget, save?: boolean, copy?: boolean }
function M.refile(target, opts)
  opts = opts or {}
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local verb = opts.copy and "Copy" or "Refile"
  local dest = opts.dest
    or M.pick_target({
      prompt = verb .. ' "' .. hl:plain_title() .. '" to',
      exclude = { filename = file.filename, s = hl.line, e = hl.end_line },
    })
  if not dest then
    return
  end
  dest = with_note_order(dest)
  local title = hl:plain_title()
  local ok, dbuf, dline
  if opts.copy then
    local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.end_line, false)
    while #lines > 1 and vim.trim(lines[#lines]) == "" do
      table.remove(lines)
    end
    ok, dbuf, dline = pcall(M.insert_subtree, lines, dest)
  else
    ok, dbuf, dline = pcall(M.move, { bufnr = bufnr, lnum = hl.line }, dest)
  end
  if not ok then
    utils.error(tostring(dbuf))
    return
  end
  log_refile(dbuf, dline)
  M.remember(dbuf, dline)
  if dbuf ~= bufnr then
    save_if_hidden(dbuf)
  end
  if opts.save then
    utils.save_buffer(bufnr)
  end
  utils.notify((opts.copy and "Copied" or "Refiled") .. ' "' .. title .. '" to ' .. dest.label:gsub("/$", ""))
  return dbuf, dline
end

--- Copy the subtree at target to another location (org-refile-copy).
---@param target? org.Target
---@param opts? { dest?: org.RefileTarget }
function M.refile_copy(target, opts)
  return M.refile(target, vim.tbl_extend("force", opts or {}, { copy = true }))
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

--- Jump to the location of the last refile or capture
--- (org-refile-goto-last-stored, C-u C-u C-c C-w).
function M.goto_last_stored()
  local l = M.last_stored
  if not l then
    utils.warn("No refile or capture location stored yet")
    return
  end
  local bufnr = l.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = l.filename and utils.load_buffer(l.filename) or nil
  end
  if not bufnr then
    utils.warn("The last stored location is gone")
    return
  end
  local lnum = l.lnum
  if vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] ~= l.raw then
    for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line == l.raw then
        lnum = i
        break
      end
    end
  end
  vim.cmd("normal! m'")
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.open_file(vim.api.nvim_buf_get_name(bufnr), lnum)
  else
    vim.api.nvim_set_current_buf(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
end

return M
