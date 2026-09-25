---@mod org.archive Archiving
---
--- `archive_subtree` moves a subtree to the archive location, which is
--- taken from (in order) the inherited `ARCHIVE` property, `#+ARCHIVE:` and
--- `archive_location`. The location format is `file::heading`:
---   "%s_archive::"            -> <file>.org_archive, top level
---   "::* Archived Tasks"      -> same file, under that heading
---   "~/org/archive.org::* %s" -> other file (%s = source file name)
---   "archive.org::datetree/"  -> other file, in a date tree (CLOSED date)
--- `archive_to_sibling` moves the subtree under an "Archive" sibling
--- (org-archive-to-archive-sibling), `archive_all_done` offers to archive
--- every child without open TODOs (C-u C-c C-x C-s) and
--- `toggle_archive_tag` toggles the ARCHIVE tag instead.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

--- The raw archive location for a headline.
function M.location_for(hl)
  local h = hl
  while h do
    if h.properties.ARCHIVE and h.properties.ARCHIVE ~= "" then
      return h.properties.ARCHIVE
    end
    h = h.parent
  end
  if hl.file.settings.archive and hl.file.settings.archive ~= "" then
    return hl.file.settings.archive
  end
  return config.opts.archive_location or "%s_archive::"
end

--- Resolve a location string into { filename, heading, level, datetree }
--- for a source file.
---@param location string
---@param source_file string|nil absolute path of the source file
function M.parse_location(location, source_file)
  local file_part, heading = location:match("^(.-)::(.*)$")
  if not file_part then
    file_part, heading = location, ""
  end
  local filename
  if file_part == "" then
    filename = source_file
  else
    local src = source_file or ""
    file_part = file_part:gsub("%%s", function()
      return src
    end)
    if src ~= "" then
      -- when %s already produced an absolute path this is a no-op
      if not file_part:match("^[/~]") and not file_part:match("^%a:[/\\]") then
        file_part = vim.fn.fnamemodify(src, ":h") .. "/" .. file_part
      end
    end
    filename = vim.fs.normalize(vim.fn.expand(file_part))
  end
  heading = vim.trim(heading or ""):gsub("%%s", vim.fn.fnamemodify(source_file or "", ":t"))
  local datetree = false
  local dt_rest = heading:match("^datetree/(.*)$")
  if dt_rest then
    datetree = true
    heading = vim.trim(dt_rest)
  end
  local level, title = 0, nil
  if heading ~= "" then
    local stars, rest = heading:match("^(%*+)%s+(.*)$")
    if stars then
      level, title = #stars, vim.trim(rest)
    else
      level, title = 1, heading
    end
  end
  return { filename = filename, heading = title, level = level, datetree = datetree }
end

--- ARCHIVE_TIME style timestamp (no brackets, like Emacs).
local function archive_time()
  local s = date.now():clone({ active = false }):to_string()
  return (s:gsub("^%[", ""):gsub("%]$", ""))
end

local function context_properties(hl)
  local info = config.opts.archive_save_context_info or { "time", "file", "olpath", "category", "todo", "itags" }
  local want = {}
  for _, k in ipairs(info) do
    want[k] = true
  end
  local props = {}
  if want.time then
    props[#props + 1] = { "ARCHIVE_TIME", archive_time() }
  end
  if want.file and hl.file.filename then
    props[#props + 1] = { "ARCHIVE_FILE", vim.fn.fnamemodify(hl.file.filename, ":~") }
  end
  if want.olpath then
    local olp = hl:outline_path()
    if #olp > 0 then
      props[#props + 1] = { "ARCHIVE_OLPATH", table.concat(olp, "/") }
    end
  end
  if want.olid and hl.parent and hl.parent:id() then
    props[#props + 1] = { "ARCHIVE_OLID", hl.parent:id() }
  end
  if want.category then
    props[#props + 1] = { "ARCHIVE_CATEGORY", hl:get_category() }
  end
  if want.todo and hl.todo then
    props[#props + 1] = { "ARCHIVE_TODO", hl.todo }
  end
  if want.itags then
    local itags = hl:get_inherited_tags()
    if #itags > 0 then
      props[#props + 1] = { "ARCHIVE_ITAGS", table.concat(itags, " ") }
    end
  end
  if want.ltags and #hl.tags > 0 then
    props[#props + 1] = { "ARCHIVE_LTAGS", table.concat(hl.tags, " ") }
  end
  return props
end

--- Apply `fn(buf)` to `lines` in a scratch buffer and return the result.
local function with_scratch(lines, fn)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  fn(buf)
  local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

--- Add properties to the first headline of `lines`.
local function add_properties(lines, props)
  return with_scratch(lines, function(buf)
    for _, p in ipairs(props) do
      edit.set_property(buf, 1, p[1], p[2])
    end
  end)
end

--- Give the first headline of `lines` all of `tags` (local + inherited).
local function set_tags(lines, tags)
  return with_scratch(lines, function(buf)
    edit.update_headline(buf, 1, { tags = tags })
  end)
end

--- Find or create the archive heading in `bufnr` (under `parent_lnum`
--- when given); returns its line or nil (top level).
local function ensure_heading(bufnr, loc, parent_lnum)
  if not loc.heading then
    return parent_lnum
  end
  local file = files.get_buffer(bufnr)
  local parent = parent_lnum and file:headline_at(parent_lnum) or nil
  local function matches(h)
    return h.title == loc.heading or h:plain_title() == loc.heading
  end
  local hl
  if parent then
    for _, c in ipairs(parent.children) do
      if matches(c) then
        hl = c
      end
    end
  else
    hl = file:find_headline(function(h)
      return h.level == loc.level and matches(h)
    end) or file:find_headline(matches)
  end
  if hl then
    return hl.line
  end
  local level = parent and parent.level + 1 or loc.level
  local new = { string.rep("*", level) .. " " .. loc.heading }
  local at = parent and parent.end_line or vim.api.nvim_buf_line_count(bufnr)
  local last = vim.api.nvim_buf_get_lines(bufnr, at - 1, at, false)[1]
  if not parent and at == 1 and last == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, new)
    return 1
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, new)
  return at + 1
end

--- Archive the subtree at target.
---@param target? org.Target
function M.archive_subtree(target)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local loc = M.parse_location(M.location_for(hl), file.filename)
  if not loc.filename then
    utils.warn("Cannot archive: buffer has no file name")
    return
  end
  local s, e = hl.line, hl.end_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  while #lines > 1 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  local same = file.filename and vim.fs.normalize(loc.filename) == file.filename
  -- org-archive-subtree-add-inherited-tags: 'infile (default) | true | false
  local add_itags = config.opts.archive_subtree_add_inherited_tags
  if add_itags == nil then
    add_itags = "infile"
  end
  local itags = hl:get_inherited_tags()
  if #itags > 0 and (add_itags == true or (add_itags == "infile" and same)) then
    lines = set_tags(lines, hl:get_tags())
  end
  lines = add_properties(lines, context_properties(hl))
  local title = hl:plain_title()
  local closed = hl.planning.closed

  local abuf
  if same then
    abuf = bufnr
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
  else
    abuf = utils.load_buffer(loc.filename)
    local alines = vim.api.nvim_buf_get_lines(abuf, 0, -1, false)
    if #alines == 0 or (#alines == 1 and alines[1] == "") then
      vim.api.nvim_buf_set_lines(abuf, 0, -1, false, {
        "#    -*- mode: org -*-",
        "",
        "",
        "Archived entries from file " .. file.filename,
        "",
      })
    end
  end
  local parent
  if loc.datetree then
    local d = closed or date.today()
    parent = require("org.capture").ensure_datetree(abuf, nil, d, "day")
  end
  local hline = ensure_heading(abuf, loc, parent)
  require("org.refile").insert_subtree(lines, { bufnr = abuf, lnum = hline })
  if not same then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
    utils.save_buffer(abuf)
  end
  if bufnr == vim.api.nvim_get_current_buf() then
    local n = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(s, n)), 0 })
  end
  utils.notify(string.format('Subtree "%s" archived in %s', title, vim.fn.fnamemodify(loc.filename, ":~")))
  return abuf
end

--- Move the subtree at target under its "Archive" sibling
--- (org-archive-to-archive-sibling). The sibling gets the ARCHIVE tag and
--- is created at the end of the parent's subtree when missing.
---@param target? org.Target
function M.archive_to_sibling(target)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local name = config.opts.archive_sibling_heading or "Archive"
  if hl:plain_title() == name and hl:is_archived() then
    utils.warn("This is the archive sibling")
    return
  end
  local siblings = hl.parent and hl.parent.children or file.children
  local sib
  for _, c in ipairs(siblings) do
    if c ~= hl and c.level == hl.level and c:plain_title() == name and c:is_archived() then
      sib = c
    end
  end
  local s, e = hl.line, hl.end_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  while #lines > 1 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  lines = add_properties(lines, { { "ARCHIVE_TIME", archive_time() } })
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
  local removed = e - s + 1
  local sib_line
  if sib then
    sib_line = sib.line > e and sib.line - removed or sib.line
  else
    local at = hl.parent and hl.parent.end_line - removed or vim.api.nvim_buf_line_count(bufnr)
    local min = hl.parent and hl.parent.line or 0
    while at > min and vim.trim(vim.api.nvim_buf_get_lines(bufnr, at - 1, at, false)[1] or "x") == "" do
      at = at - 1
    end
    local heading = edit.align_tags_line(string.rep("*", hl.level) .. " " .. name .. " :ARCHIVE:", file.settings.todo)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, { heading })
    sib_line = at + 1
  end
  require("org.refile").insert_subtree(lines, { bufnr = bufnr, lnum = sib_line })
  if bufnr == vim.api.nvim_get_current_buf() then
    local n = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(s, n)), 0 })
    local sl = sib_line
    pcall(vim.cmd, sl .. "foldclose")
  end
  utils.notify(string.format('Subtree "%s" moved to archive sibling', hl:plain_title()))
  return sib_line
end

local function has_open_todo(hl)
  if hl:is_todo() then
    return true
  end
  for _, c in ipairs(hl.children) do
    if has_open_todo(c) then
      return true
    end
  end
  return false
end

--- Offer to archive every child of the headline at the cursor (every
--- top-level tree when not on a headline) that has no open TODO entries
--- (org-archive-all-done).
---@param opts? { tag?: boolean, confirm?: fun(hl: org.Headline): boolean }
---@return integer count of archived entries
function M.archive_all_done(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local file = files.get_buffer(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local on = file:headline_at(lnum)
  local list = (on and on.line == lnum) and on.children or file.children
  local candidates = {}
  for _, c in ipairs(list) do
    if not has_open_todo(c) and not c:is_archived() then
      candidates[#candidates + 1] = { line = c.line, raw = c.raw }
    end
  end
  --- Current line of a candidate (archiving may shift lines).
  local function find(c)
    local f = files.get_buffer(bufnr)
    local hl = f:headline_at(c.line)
    if hl and hl.line == c.line and hl.raw == c.raw then
      return hl
    end
    return f:find_headline(function(h)
      return h.raw == c.raw
    end)
  end
  local confirm = opts.confirm
    or function(hl)
      local q = opts.tag and "Set ARCHIVE tag? " or "Move subtree to archive? "
      return utils.confirm(q .. "(no open TODO items) " .. hl:plain_title())
    end
  local n = 0
  -- bottom-up so earlier line numbers stay valid
  for i = #candidates, 1, -1 do
    local hl = find(candidates[i])
    if hl and confirm(hl) then
      if opts.tag then
        M.toggle_archive_tag({ bufnr = bufnr, lnum = hl.line })
      else
        M.archive_subtree({ bufnr = bufnr, lnum = hl.line })
      end
      n = n + 1
    end
  end
  utils.notify(n == 0 and "No entries archived" or string.format("%d entries archived", n))
  return n
end

--- Toggle the ARCHIVE tag of the headline at target.
---@param target? org.Target
function M.toggle_archive_tag(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local tags = vim.deepcopy(hl.tags)
  local idx
  for i, t in ipairs(tags) do
    if t == "ARCHIVE" then
      idx = i
    end
  end
  if idx then
    table.remove(tags, idx)
  else
    tags[#tags + 1] = "ARCHIVE"
  end
  edit.update_headline(bufnr, hl.line, { tags = tags })
  if not idx and bufnr == vim.api.nvim_get_current_buf() then
    pcall(vim.cmd, hl.line .. "foldclose")
  end
  if not target then
    utils.notify(idx and "ARCHIVE tag removed" or "Entry archived (ARCHIVE tag)")
  end
  return not idx
end

return M
