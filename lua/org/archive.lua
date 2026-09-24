---@mod org.archive Archiving
---
--- `archive_subtree` moves a subtree to the archive location, which is
--- taken from (in order) the inherited `ARCHIVE` property, `#+ARCHIVE:` and
--- `archive_location`. The location format is `file::heading`:
---   "%s_archive::"            -> <file>.org_archive, top level
---   "::* Archived Tasks"      -> same file, under that heading
---   "~/org/archive.org::* %s" -> other file (%s = source file name)
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

--- Resolve a location string into { filename, heading, level } for a source file.
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
  local level, title = 0, nil
  if heading ~= "" then
    local stars, rest = heading:match("^(%*+)%s+(.*)$")
    if stars then
      level, title = #stars, vim.trim(rest)
    else
      level, title = 1, heading
    end
  end
  return { filename = filename, heading = title, level = level }
end

local function context_properties(hl)
  local info = config.opts.archive_save_context_info or { "time", "file", "olpath", "category", "todo", "itags" }
  local want = {}
  for _, k in ipairs(info) do
    want[k] = true
  end
  local props = {}
  if want.time then
    props[#props + 1] = { "ARCHIVE_TIME", date.now():clone({ active = false }):to_string() }
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
  return props
end

--- Add properties to the first headline of `lines` using a scratch buffer.
local function add_properties(lines, props)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, p in ipairs(props) do
    edit.set_property(buf, 1, p[1], p[2])
  end
  local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

--- Find or create the archive heading in `bufnr`; returns its line or nil (top level).
local function ensure_heading(bufnr, loc)
  if not loc.heading then
    return nil
  end
  local file = files.get_buffer(bufnr)
  local hl = file:find_headline(function(h)
    return h.level == loc.level and (h.title == loc.heading or h:plain_title() == loc.heading)
  end) or file:find_headline(function(h)
    return h.title == loc.heading or h:plain_title() == loc.heading
  end)
  if hl then
    return hl.line
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local last = vim.api.nvim_buf_get_lines(bufnr, n - 1, n, false)[1]
  local new = { string.rep("*", loc.level) .. " " .. loc.heading }
  if n == 1 and last == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, new)
    return 1
  end
  vim.api.nvim_buf_set_lines(bufnr, n, n, false, new)
  return n + 1
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
  lines = add_properties(lines, context_properties(hl))
  local title = hl:plain_title()

  local same = file.filename and vim.fs.normalize(loc.filename) == file.filename
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
  local hline = ensure_heading(abuf, loc)
  require("org.refile").insert_subtree(lines, { bufnr = abuf, lnum = hline })
  if not same then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
    utils.save_buffer(abuf)
  end
  if bufnr == vim.api.nvim_get_current_buf() then
    local n = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(s, n)), 0 })
  end
  utils.notify(string.format("Subtree \"%s\" archived in %s", title, vim.fn.fnamemodify(loc.filename, ":~")))
  return abuf
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
