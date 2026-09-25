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
--- (org-archive-to-archive-sibling), `archive_all_done` / `archive_all_old`
--- offer to archive every child without open TODOs / with old time stamps
--- (C-u / C-u C-u C-c C-x C-s) and `toggle_archive_tag` toggles the
--- ARCHIVE tag instead.
---
--- User autocmds: `OrgArchive` (org-archive-hook) in the source buffer
--- before the subtree is removed and `OrgArchiveFinalize`
--- (org-archive-finalize-hook) in the archive buffer, both with
--- `data = { bufnr, lnum, title, archive_file }`.

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

--- Resolve a location string into { filename, heading, level, datetree,
--- stars } for a source file. `stars` is the heading with its stars (the
--- line searched for); a date tree location has 3 levels of its own.
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
  if datetree and title then
    -- "datetree/* Sub": the heading goes under the day (level 4)
    level = level + 3
  end
  return {
    filename = filename,
    heading = title,
    level = level,
    datetree = datetree,
    stars = title and (string.rep("*", level) .. " " .. title) or nil,
  }
end

--- ARCHIVE_TIME style timestamp (no brackets, like Emacs).
local function archive_time()
  local s = date.now():clone({ active = false }):to_string()
  return (s:gsub("^%[", ""):gsub("%]$", ""))
end

local function context_properties(hl)
  local info = config.opts.archive_save_context_info or { "time", "file", "olpath", "category", "todo", "itags" }
  local props = {}
  for _, k in ipairs(info) do
    local name, value = "ARCHIVE_" .. k:upper(), nil
    if k == "time" then
      value = archive_time()
    elseif k == "file" then
      value = hl.file.filename and vim.fn.fnamemodify(hl.file.filename, ":~")
    elseif k == "olpath" then
      value = table.concat(hl:outline_path(), "/")
    elseif k == "olid" then
      value = hl.parent and hl.parent:id()
    elseif k == "category" then
      value = hl:get_category()
    elseif k == "todo" then
      value = hl.todo
    elseif k == "itags" then
      value = table.concat(hl:get_inherited_tags(), " ")
    elseif k == "ltags" then
      value = table.concat(hl.tags, " ")
    end
    if value and value ~= "" then
      props[#props + 1] = { name, value }
    end
  end
  return props
end

local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
end

local function get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
end

local function is_blank(l)
  return l ~= nil and l:match("^%s*$") ~= nil
end

local function line_count(bufnr)
  local n = vim.api.nvim_buf_line_count(bufnr)
  if n == 1 and get_line(bufnr, 1) == "" then
    return 0
  end
  return n
end

--- Insert lines after line `at`; an empty buffer is replaced.
local function put(bufnr, at, lines)
  if line_count(bufnr) == 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    return 0
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  return at
end

--- Text lines of `s` (which is inserted at a line start). Returns the
--- lines and whether the text ended in the middle of a line.
local function text_lines(s)
  local lines = vim.split(s, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
    return lines, false
  end
  return lines, true
end

--- Replace the blank lines after line `last` (up to `limit`) by `n` blank
--- lines (Emacs replaces the whitespace after the subtree by "\n\n").
local function normalize_blanks_after(bufnr, last, limit, n)
  local e = last
  while e < limit and is_blank(get_line(bufnr, e + 1)) do
    e = e + 1
  end
  local blanks = {}
  for _ = 1, n do
    blanks[#blanks + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, last, e, false, blanks)
  return last + n
end

--- Where the archived subtree goes in `abuf`: returns the insertion point
--- (insert after that line) and the level. Creates the heading (and the
--- date tree) of the location when needed.
local function archive_point(abuf, loc, d, open_line)
  local reversed = config.opts.archive_reversed_order
  local s, e = 1, line_count(abuf)
  if loc.datetree then
    local day = require("org.capture").ensure_datetree(abuf, nil, d, "day")
    local hl = files.get_buffer(abuf):headline_at(day)
    s, e = hl.line, hl.end_line
    if not loc.stars then
      return reversed and hl.body_end or e, hl.level + 1
    end
  end
  if loc.stars then
    local hline
    local pat = "^" .. vim.pesc(loc.stars) .. "%s*$"
    local pat_tags = "^" .. vim.pesc(loc.stars) .. "%s+:[%w_@#%%:]+:%s*$"
    for i = s, e do
      local l = get_line(abuf, i)
      if l and (l:match(pat) or l:match(pat_tags)) then
        hline = i
        break
      end
    end
    if not hline then
      local new = loc.datetree and { loc.stars } or { "", loc.stars }
      local at = put(abuf, e, new)
      hline = at + #new
      e = e + #new
    end
    local file = files.get_buffer(abuf)
    local hl = file:headline_at(hline)
    local limit = loc.datetree and e or line_count(abuf)
    local n = loc.datetree and 0 or 1
    local last
    if reversed then
      last = hl.body_end
    else
      last = hl.end_line
    end
    -- back over the whitespace before the insertion point
    while last > hl.line and is_blank(get_line(abuf, last)) do
      last = last - 1
    end
    return normalize_blanks_after(abuf, last, limit, n), loc.level + 1
  end
  if reversed then
    local file = files.get_buffer(abuf)
    return file.headlines[1] and file.preamble_end or line_count(abuf), 1
  end
  -- point-max, then a newline
  return line_count(abuf), 1, not open_line
end

--- Mark the archived entry done (org-archive-mark-done), without logging.
local function mark_done(abuf, lnum, todo_cfg)
  local want = config.opts.archive_mark_done
  if not want then
    return
  end
  local line = get_line(abuf, lnum)
  local p = require("org.parser").parse_headline_line(line, todo_cfg)
  if not p or (p.todo and todo_cfg:is_done(p.todo)) then
    return
  end
  local done = todo_cfg:done_names()
  local kw = type(want) == "string" and vim.tbl_contains(done, want) and want or done[1] or "DONE"
  p.todo = kw
  vim.api.nvim_buf_set_lines(abuf, lnum - 1, lnum, false, { edit.build_headline(p) })
end

--- With `attach.archive_delete` (org-attach-archive-delete), delete the
--- attachments of an archived entry.
local function delete_attachments(bufnr, lnum)
  local mode = (config.opts.attach or {}).archive_delete
  if not mode then
    return
  end
  local ok, attach = pcall(require, "org.attach")
  if not ok then
    return
  end
  attach.delete_all({ bufnr = bufnr, lnum = lnum }, mode == true)
end

--- Archive the subtree at target. A count works like Emacs's prefix
--- argument: 4 (C-u) runs `archive_all_done`, 16 (C-u C-u)
--- `archive_all_old`.
---@param target? org.Target
function M.archive_subtree(target)
  if target == nil then
    if vim.v.count == 4 then
      return M.archive_all_done()
    elseif vim.v.count == 16 then
      return M.archive_all_old()
    end
  end
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local loc = M.parse_location(M.location_for(hl), file.filename)
  if not loc.filename then
    utils.warn("No file associated to buffer")
    return
  end
  local s, e = hl.line, hl.end_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local same = file.filename and vim.fs.normalize(loc.filename) == file.filename
  local title = hl:plain_title()
  local closed = hl.planning.closed
  local props = context_properties(hl)
  local all_tags = hl:get_tags()
  local itags = hl:get_inherited_tags()

  local abuf, open_line
  local before = vim.api.nvim_buf_line_count(bufnr)
  if same then
    abuf = bufnr
  else
    local new_file = not utils.exists(loc.filename)
    abuf = utils.load_buffer(loc.filename)
    if new_file and line_count(abuf) == 0 then
      local header = {}
      if not loc.filename:match("%.org$") then
        -- Emacs puts Org mode in the mode line of a new non-.org file
        header = { "#    -*- mode: org -*-", "" }
      end
      local fmt = config.opts.archive_file_header_format
      if fmt then
        local text = fmt:gsub("%%s", function()
          return file.filename
        end)
        local tl
        tl, open_line = text_lines(text)
        vim.list_extend(header, tl)
      end
      if #header > 0 then
        vim.api.nvim_buf_set_lines(abuf, 0, -1, false, header)
      end
    end
  end
  local at, level, blank = archive_point(abuf, loc, closed or date.today(), open_line)
  local new = edit.relevel(lines, level)
  if blank then
    table.insert(new, 1, "")
  end
  at = put(abuf, at, new)
  local lnum = at + 1 + (blank and 1 or 0)
  -- org-archive-subtree-add-inherited-tags: "infile" (default) | true | false
  local add_itags = config.opts.archive_subtree_add_inherited_tags
  if add_itags == nil then
    add_itags = "infile"
  end
  if #itags > 0 and (add_itags == true or (add_itags == "infile" and same)) then
    edit.update_headline(abuf, lnum, { tags = all_tags })
  end
  mark_done(abuf, lnum, file.settings.todo)
  require("org.id").register_lines(new, vim.fs.normalize(loc.filename))
  for _, p in ipairs(props) do
    edit.set_property(abuf, lnum, p[1], p[2])
  end
  local data = { bufnr = bufnr, lnum = s, title = title, archive_file = loc.filename }
  fire("OrgArchiveFinalize", vim.tbl_extend("force", data, { bufnr = abuf, lnum = lnum }))
  if not same then
    utils.save_buffer(abuf)
  end
  -- back in the source: the subtree moved when archiving above it
  if same and lnum <= s then
    local delta = vim.api.nvim_buf_line_count(bufnr) - before
    s, e = s + delta, e + delta
  end
  fire("OrgArchive", data)
  delete_attachments(bufnr, s)
  local parent = hl.parent and hl.parent.line
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
  if parent then
    pcall(require("org.lists").update_statistics_for, bufnr, parent)
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
    if c ~= hl and c.level == hl.level and c.title == name and c:is_archived() then
      sib = c
      break
    end
  end
  local s, e = hl.line, hl.end_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local before = vim.api.nvim_buf_line_count(bufnr)
  local sib_line
  if sib then
    sib_line = sib.line
  else
    -- created at the end of the parent's subtree (after the source)
    local at = hl.parent and hl.parent.end_line or before
    local heading = edit.align_tags_line(string.rep("*", hl.level) .. " " .. name .. " :ARCHIVE:", file.settings.todo)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, { heading })
    sib_line = at + 1
    before = before + 1
  end
  local shl = files.get_buffer(bufnr):headline_at(sib_line)
  local at = config.opts.archive_reversed_order and shl.body_end or shl.end_line
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, edit.relevel(lines, hl.level + 1))
  edit.set_property(bufnr, at + 1, "ARCHIVE_TIME", archive_time())
  if at < s then
    local delta = vim.api.nvim_buf_line_count(bufnr) - before
    s, e = s + delta, e + delta
  end
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
  if sib_line > e then
    sib_line = sib_line - (e - s + 1)
  end
  if hl.parent then
    pcall(require("org.lists").update_statistics_for, bufnr, hl.parent.line)
  end
  if bufnr == vim.api.nvim_get_current_buf() then
    local n = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(s, n)), 0 })
    pcall(vim.cmd, sib_line .. "foldclose")
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

--- The first active time stamp in the subtree, when it (and the end of a
--- range) lies before today (org-archive-all-old's test).
local function old_timestamp(hl)
  local today = date.today_days()
  for _, l in ipairs(hl:subtree_lines()) do
    local a, b = l:match("(<%d%d%d%d%-%d%d%-%d%d[^>]*>)%-%-(<%d%d%d%d%-%d%d%-%d%d[^>]*>)")
    local ts = a or l:match("<%d%d%d%d%-%d%d%-%d%d[^>]*>")
    if ts then
      local d = date.parse(ts)
      if not d or d:days() >= today then
        return nil
      end
      if b then
        local d2 = date.parse(b)
        if not d2 or d2:days() >= today then
          return nil
        end
        return "old timestamp " .. a .. "--" .. b
      end
      return "old timestamp " .. ts
    end
  end
end

--- Offer to archive (or tag) every child of the headline at the cursor
--- (every top-level tree when not on a headline) for which `predicate`
--- returns a reason (org-archive-all-matches).
local function archive_all_matches(predicate, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local file = files.get_buffer(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local on = file:headline_at(lnum)
  local list = (on and on.line == lnum) and on.children or file.children
  local candidates = {}
  for _, c in ipairs(list) do
    local reason = predicate(c)
    if reason and not (opts.tag and c:is_archived()) then
      candidates[#candidates + 1] = { line = c.line, raw = c.raw, reason = reason }
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
    or function(hl, reason)
      local q = opts.tag and "Set ARCHIVE tag? " or "Move subtree to archive? "
      return utils.confirm(q .. "(" .. reason .. ") " .. hl:plain_title())
    end
  local n = 0
  -- bottom-up so earlier line numbers stay valid
  for i = #candidates, 1, -1 do
    local hl = find(candidates[i])
    if hl and confirm(hl, candidates[i].reason) then
      if opts.tag then
        if not hl:is_archived() then
          M.toggle_archive_tag({ bufnr = bufnr, lnum = hl.line })
        end
      else
        M.archive_subtree({ bufnr = bufnr, lnum = hl.line })
      end
      n = n + 1
    end
  end
  utils.notify(string.format("%d trees archived", n))
  return n
end

--- Offer to archive every child of the headline at the cursor (every
--- top-level tree when not on a headline) that has no open TODO entries
--- (org-archive-all-done, C-u C-c C-x C-s). With `opts.tag`, set the
--- ARCHIVE tag instead (C-u C-c C-x a).
---@param opts? { tag?: boolean, confirm?: fun(hl: org.Headline, reason: string): boolean }
---@return integer count of archived entries
function M.archive_all_done(opts)
  return archive_all_matches(function(hl)
    return not has_open_todo(hl) and "no open TODO items" or nil
  end, opts)
end

--- Offer to archive every child of the headline at the cursor (every
--- top-level tree when not on a headline) whose first active time stamp
--- lies before today (org-archive-all-old, C-u C-u C-c C-x C-s).
---@param opts? { tag?: boolean, confirm?: fun(hl: org.Headline, reason: string): boolean }
---@return integer count of archived entries
function M.archive_all_old(opts)
  return archive_all_matches(old_timestamp, opts)
end

--- Toggle the ARCHIVE tag of the headline at target. With a count (C-u
--- C-c C-x a), offer to tag every child without open TODOs instead.
---@param target? org.Target
function M.toggle_archive_tag(target)
  if target == nil and vim.v.count > 0 then
    return M.archive_all_done({ tag = true })
  end
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
    utils.notify(idx and "Subtree unarchived" or "Subtree archived")
  end
  return not idx
end

return M
