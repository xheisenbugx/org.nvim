---@mod org.mobile.edit Pull: edits
---
--- Moving the captured entries into the inbox, finding an entry from
--- its link and applying one edit to it (org-mobile-edit).
--- Part of org.mobile, which loads it.

local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.mobile.shared")

local M = require("org.mobile")

local cfg = shared.cfg
local delete_all = shared.delete_all
local inbox_path = shared.inbox_path
local org_dir = shared.org_dir
local stage_read = shared.stage_read
local stage_write = shared.stage_write
local staging_dir = shared.staging_dir
local text_of = shared.text_of
local write_raw = shared.write_raw

---------------------------------------------------------------------------
-- Pull
---------------------------------------------------------------------------

--- Set the checksum of mobileorg.org in checksums.dat to that of `content`
--- (org-mobile-update-checksum-for-capture-file).
local function update_capture_checksum(content)
  local path = staging_dir() .. "/checksums.dat"
  local lines = utils.readfile(path)
  if not lines then
    return
  end
  for i, l in ipairs(lines) do
    local pre, hex, rest = l:match("^(.-)(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+)(.*)$")
    if hex and vim.trim(rest):sub(-#M.capture_file) == M.capture_file then
      lines[i] = pre .. M.md5(content) .. rest
      write_raw(path, text_of(lines))
      return
    end
  end
end

--- Move the contents of mobileorg.org to the end of the inbox
--- (org-mobile-move-capture). Returns the inbox buffer and the first new
--- line, or nil when there was nothing new.
function M.move_capture()
  local capture = staging_dir() .. "/" .. M.capture_file
  local content = stage_read(capture) or ""
  content = content:gsub("\r\n", "\n")
  if not content:match("%S") then
    return nil
  end
  local bufnr = utils.load_buffer(inbox_path())
  local new = vim.split(content, "\n", { plain = true })
  if new[#new] == "" then
    table.remove(new)
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  local was_modified = vim.bo[bufnr].modified
  local start
  if n == 1 and first == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, new)
    start = 1
  else
    vim.api.nvim_buf_set_lines(bufnr, n, n, false, new)
    start = n + 1
  end
  -- like Emacs's save-buffer, a failed save stops the pull before the
  -- capture file is emptied, so the entries are not lost
  local saved, err = utils.save_buffer(bufnr)
  if not saved then
    -- take the entries out again, or the next pull would add them twice
    vim.api.nvim_buf_set_lines(bufnr, start - 1, start - 1 + #new, false, {})
    vim.bo[bufnr].modified = was_modified
    error(("Could not save %s: %s"):format(inbox_path(), err), 0)
  end
  stage_write(capture, "")
  update_capture_checksum("")
  return bufnr, start
end

--- Is `s` nil or blank?
local function blank(s)
  return s == nil or not s:match("%S")
end

--- Are two tag lists the same set (org-mobile-tags-same-p)?
function M.tags_same(a, b)
  a, b = a or {}, b or {}
  return #delete_all(a, b) == 0 and #delete_all(b, a) == 0
end

local function normalize_body(s)
  local out = {}
  for _, l in ipairs(vim.split(vim.trim(s), "\n", { plain = true })) do
    l = vim.trim(l)
    if l ~= "" then
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n")
end

--- Are two bodies visually equal (org-mobile-bodies-same-p)?
function M.bodies_same(a, b)
  if a == nil and b == nil then
    return true
  elseif a == nil or b == nil then
    return false
  end
  return normalize_body(a) == normalize_body(b)
end

local function forced(kind)
  local f = cfg().force_mobile_change
  return f == true or (type(f) == "table" and vim.tbl_contains(f, kind))
end

local function split_lines(s)
  local lines = vim.split(s, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- The headline at target, only when target is on the headline line.
local function heading_at(target)
  local f = files.get_buffer(target.bufnr)
  local hl = f:headline_at(target.lnum)
  if hl and hl.line == target.lnum then
    return hl, f
  end
  return nil, f
end

--- End (exclusive) of the subtree starting at `lnum` of `lines`, trailing
--- blank lines included (org-end-of-subtree t t).
local function subtree_end(lines, lnum)
  local level = #(lines[lnum]:match("^(%*+)") or "*")
  for i = lnum + 1, #lines do
    local stars = lines[i]:match("^(%*+)%s")
    if stars and #stars <= level then
      return i
    end
  end
  return #lines + 1
end

--- Find the entry of a link from the mobile application
--- (org-mobile-locate-entry): `id:ID`, `olp:FILE:PATH/TO/HEADING` or
--- `olp:FILE` (a new line at the end of the file, for top-level additions).
--- Returns a target `{ bufnr, lnum }` or nil; errors when an outline path
--- does not exist.
---@param link string
---@return { bufnr: integer, lnum: integer }|nil
function M.locate_entry(link)
  local decode = require("org.protocol").decode
  local id = link:match("^id:(.*)$")
  if id then
    local r = require("org.id").find(id)
    if not r then
      return nil
    end
    local bufnr = r.bufnr or utils.load_buffer(r.filename)
    local hl = files.get_buffer(bufnr):find_by_id(id)
    return hl and { bufnr = bufnr, lnum = hl.line } or nil
  end
  local file, path = link:match("^olp:(.-):(.*)$")
  if not file then
    file = link:match("^olp:(.*)$")
    if not file then
      return nil
    end
    local bufnr = utils.load_buffer(utils.expand(decode(file), org_dir()))
    local n = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, n, n, false, { "" })
    return { bufnr = bufnr, lnum = n + 1 }
  end
  local fpath = utils.expand(decode(file), org_dir())
  if not utils.exists(fpath) then
    error("File not found: " .. fpath, 0)
  end
  local bufnr = utils.load_buffer(fpath)
  local nodes = files.get_buffer(bufnr).children
  local found
  local level = 0
  for part in path:gmatch("[^/]+") do
    part = decode(part)
    level = level + 1
    found = nil
    for _, hl in ipairs(nodes) do
      if vim.trim(hl.title or "") == vim.trim(part) then
        found = hl
        break
      end
    end
    if not found then
      error(string.format("Heading not found on level %d: %s", level, part), 0)
    end
    nodes = found.children
  end
  return found and { bufnr = bufnr, lnum = found.line } or nil
end

--- Apply an edit from the mobile application to the entry at target
--- (org-mobile-edit). `what` is "todo", "tags", "priority", "heading",
--- "body", "addheading", "refile", "delete", "archive" or
--- "archive-sibling". Errors (with a message) when the entry changed on
--- the computer too, unless `mobile.force_mobile_change` says otherwise.
---@param what string
---@param old string|nil
---@param new string|nil
---@param target { bufnr: integer, lnum: integer }
function M.edit(what, old, new, target)
  local hl = heading_at(target)
  local bufnr = target.bufnr
  if what == "todo" or what == "todostate" then
    local current = hl and hl.todo
    if new == "DONEARCHIVE" then
      local todo_cfg = files.get_buffer(bufnr).settings.todo
      require("org.todo").change_state(target, todo_cfg:first_done(current), { inhibit_note = true })
      require("org.archive").archive_subtree(target)
    elseif new == current then
      return true
    elseif current == old or forced("todo") then
      require("org.todo").change_state(target, new, { inhibit_note = true })
      return true
    else
      error(string.format('State before change was expected as "%s", but is "%s"', old or "nil", current or "nil"), 0)
    end
  elseif what == "tags" then
    local current = hl and hl.tags or {}
    local new1 = new and vim.split(new, ":+", { trimempty = true }) or {}
    local old1 = old and vim.split(old, ":+", { trimempty = true }) or {}
    if M.tags_same(current, new1) then
      return true
    elseif M.tags_same(current, old1) or forced("tags") then
      require("org.edit").update_headline(bufnr, target.lnum, { tags = new1 })
      return true
    else
      local msg = 'Tags before change were expected as "%s", but are "%s"'
      error(string.format(msg, old or "", table.concat(current, ":")), 0)
    end
  elseif what == "priority" then
    if not hl then
      return nil
    end
    local current = hl.priority
    if current == new then
      return true
    elseif current == old or forced("priority") then
      require("org.priority").set(target, new or " ")
      return true
    else
      error(string.format("Priority was expected to be %s, but is %s", old or "nil", current or "nil"), 0)
    end
  elseif what == "heading" then
    if not hl then
      return nil
    end
    local current = hl.title
    if current == new then
      return true
    elseif current == old or forced("heading") then
      require("org.edit").update_headline(bufnr, target.lnum, { title = new })
      return true
    else
      error("Heading changed in the mobile device and on the computer", 0)
    end
  elseif what == "addheading" then
    local new_lines = split_lines(new or "")
    if #new_lines == 0 then
      new_lines = { "" }
    end
    if hl then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local e = subtree_end(lines, hl.line)
      while e - 1 > hl.line and not lines[e - 1]:match("%S") do
        e = e - 1
      end
      new_lines[1] = string.rep("*", hl.level + 1) .. " " .. new_lines[1]
      vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, new_lines)
    else
      new_lines[1] = "* " .. new_lines[1]
      vim.api.nvim_buf_set_lines(bufnr, target.lnum - 1, target.lnum, false, new_lines)
    end
    return true
  elseif what == "refile" then
    if not hl then
      error("Not at a heading", 0)
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local s, e = hl.line, subtree_end(lines, hl.line)
    local sub = vim.list_slice(lines, s, e - 1)
    local dest = M.locate_entry(new or "")
    if not dest then
      error("Refile target not found: " .. tostring(new), 0)
    end
    local edit = require("org.edit")
    local dhl = heading_at(dest)
    local at
    if dhl then
      local dlines = vim.api.nvim_buf_get_lines(dest.bufnr, 0, -1, false)
      at = subtree_end(dlines, dhl.line)
      sub = edit.relevel(sub, dhl.level + 1)
      vim.api.nvim_buf_set_lines(dest.bufnr, at - 1, at - 1, false, sub)
    else
      at = dest.lnum
      sub = edit.relevel(sub, 1)
      vim.api.nvim_buf_set_lines(dest.bufnr, at - 1, at, false, sub)
      at = at + 1
    end
    if dest.bufnr == bufnr and at <= s then
      local shift = dhl and #sub or #sub - 1
      s, e = s + shift, e + shift
    end
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e - 1, false, {})
    return true
  elseif what == "delete" then
    if not hl then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, subtree_end(lines, hl.line) - 1, false, {})
    return true
  elseif what == "archive" then
    require("org.archive").archive_subtree(target)
    return true
  elseif what == "archive-sibling" then
    require("org.archive").archive_to_sibling(target)
    return true
  elseif what == "body" then
    if not hl then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local nxt = #lines + 1
    for i = hl.line + 1, #lines do
      if lines[i]:match("^%*+%s") then
        nxt = i
        break
      end
    end
    local current = text_of(vim.list_slice(lines, hl.line + 1, nxt - 1))
    if blank(current) then
      current = nil
    end
    if M.bodies_same(current, new) then
      return true
    elseif M.bodies_same(current, old) or forced("body") then
      vim.api.nvim_buf_set_lines(bufnr, hl.line, nxt - 1, false, split_lines(new or ""))
      return true
    else
      error("Body was changed in the mobile device and on the computer", 0)
    end
  end
end

shared.blank = blank
shared.heading_at = heading_at
shared.subtree_end = subtree_end
