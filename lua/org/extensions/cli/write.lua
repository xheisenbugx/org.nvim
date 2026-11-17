---@mod org.extensions.cli.write Commands of `org` that change headings
---
--- `set todo|tags|priority|property|scheduled|deadline`, `note`, `refile`,
--- `archive` and `id`. Each finds one heading (`run.resolve_target`),
--- refuses to write a file a running Neovim has unsaved changes in
--- (`run.guard`), edits it with org.nvim's own commands, saves through
--- `utils.save_buffer` and returns the changed heading.

local run = require("org.extensions.cli.run")
local data = require("org.extensions.cli.data")

local M = {}

local fail = run.fail

--- Fail with a usage message unless there are `n` words.
local function need(words, n, usage)
  if #words < n then
    fail("usage: " .. usage, "usage")
  end
end

--- Is `tag` a valid tag name (org-tag-re: letters and digits of any
--- script, `_ @ # %`; see `tags.valid`)?
local function valid_tag(tag)
  return require("org.tags").valid(tag)
end

--- Fail with `bad_value` unless a property value is one line (a drawer
--- holds one line per property).
local function one_line_value(name, value)
  if value:find("[\r\n]") then
    fail("the value of " .. name .. " must be one line", "bad_value", { name = name, value = value })
  end
end

--- The heading of words[1], and its buffer target.
local function open(words, flags)
  local hl = run.resolve_target(words[1], flags)
  local bufnr, lnum = run.open_target(hl, flags)
  run.mark_messages()
  return hl, bufnr, lnum
end

--- Save, and the result of a change of `field` of the heading at
--- (bufnr, lnum).
local function changed(flags, bufnr, lnum, field, old, new, extra)
  run.check_prompted()
  run.save_all(flags)
  local hl = run.headline_at(bufnr, lnum)
  local d = { headline = data.headline(hl), field = field, old = data.nn(old), new = data.nn(new) }
  for k, v in pairs(extra or {}) do
    d[k] = v
  end
  return { data = d, text = { run.headline_line(hl) } }
end

function M.cmd_set_todo(words, flags)
  need(words, 2, "org set todo TARGET STATE")
  local new = words[2]
  if new == "none" then
    new = ""
  end
  local hl = run.resolve_target(words[1], flags)
  local todo_cfg = hl.file.settings.todo
  if new ~= "" and not todo_cfg:is_keyword(new) then
    fail("unknown TODO keyword " .. new, "bad_value", { keyword = new, keywords = todo_cfg:names() })
  end
  local old = hl.todo
  local bufnr, lnum = run.open_target(hl, flags)
  run.mark_messages()
  local res = require("org.todo").change_state({ bufnr = bufnr, lnum = lnum }, new, { note = flags.note })
  if not res then
    run.fail_with_messages("could not change the TODO state of " .. hl:plain_title())
  end
  ---@cast res -nil
  local now = run.headline_at(bufnr, lnum)
  return changed(flags, bufnr, lnum, "todo", old, now and now.todo or nil, { repeated = res.repeated or false })
end

function M.cmd_set_tags(words, flags)
  need(words, 1, "org set tags TARGET [TAGS] [--add TAG] [--remove TAG]")
  if words[2] == nil and #flags.add == 0 and #flags.remove == 0 then
    fail('usage: org set tags TARGET TAGS (or --add / --remove; "" clears)', "usage")
  end
  local tags = require("org.tags")
  local hl, bufnr, lnum = open(words, flags)
  local old = vim.deepcopy(hl.tags)
  local new = words[2] ~= nil and tags.parse_input(words[2]) or vim.deepcopy(old)
  for _, t in ipairs(flags.add) do
    if not vim.tbl_contains(new, t) then
      new[#new + 1] = t
    end
  end
  new = vim.tbl_filter(function(t)
    return not vim.tbl_contains(flags.remove, t)
  end, new)
  for _, t in ipairs(new) do
    if not valid_tag(t) then
      fail("invalid tag " .. t .. " (letters, digits, _ @ # %)", "bad_value", { tag = t })
    end
  end
  local res = tags.set_tags({ bufnr = bufnr, lnum = lnum }, new, true)
  if not res then
    run.fail_with_messages("could not set the tags")
  end
  return changed(flags, bufnr, lnum, "tags", old, run.headline_at(bufnr, lnum).tags)
end

function M.cmd_set_priority(words, flags)
  need(words, 2, "org set priority TARGET PRIORITY")
  local priority = require("org.priority")
  local hl, bufnr, lnum = open(words, flags)
  if not priority.enabled() then
    run.fail_with_messages("priority commands are disabled")
  end
  local old = hl.priority
  local value = words[2]
  if value == "none" or value == "" then
    priority.set({ bufnr = bufnr, lnum = lnum }, " ")
  elseif not priority.set({ bufnr = bufnr, lnum = lnum }, value) then
    run.fail_with_messages("invalid priority " .. value, "bad_value")
  end
  return changed(flags, bufnr, lnum, "priority", old, run.headline_at(bufnr, lnum).priority)
end

function M.cmd_set_property(words, flags)
  if flags.delete then
    need(words, 2, "org set property TARGET NAME --delete")
    if #words > 2 then
      fail("set property --delete takes TARGET NAME, not also a value", "usage")
    end
  else
    need(words, 3, "org set property TARGET NAME VALUE")
  end
  local props = require("org.properties")
  local name = words[2]
  if name:find("%s") or name == "" then
    fail("invalid property name " .. name, "bad_value", { name = name })
  end
  -- the VALUE: the remaining words
  local value = table.concat(words, " ", 3)
  one_line_value(name, value)
  local hl, bufnr, lnum = open(words, flags)
  local old = hl:get_property(name:upper(), false)
  local target = { bufnr = bufnr, lnum = lnum }
  if flags.delete then
    props.delete_property(target, name)
  elseif props.set_property(target, name, value) == nil then
    run.fail_with_messages("could not set " .. name, "bad_value")
  end
  local new = run.headline_at(bufnr, lnum):get_property(name:upper(), false)
  return changed(flags, bufnr, lnum, "property", old, new, { name = name:upper() })
end

--- A date of `set scheduled` / `set deadline`: nil for "" or none.
local function read_planning_date(s)
  local date = require("org.date")
  s = vim.trim(s)
  if s == "" or s == "none" then
    return nil
  end
  local d
  if s:match("^[<%[]") then
    d = date.parse(s)
  else
    d = date.read_date(s, date.today())
  end
  if not d then
    fail("cannot read date " .. s, "bad_value", { date = s })
  end
  ---@cast d -nil
  return d:clone({ active = true, range_end = vim.NIL })
end

local function set_planning(kind)
  return function(words, flags)
    need(words, 2, "org set " .. kind .. " TARGET DATE")
    -- the DATE: the remaining words (2030-02-03 09:15)
    local d = read_planning_date(table.concat(words, " ", 2))
    local hl, bufnr, lnum = open(words, flags)
    local old = hl.planning[kind]
    -- like org-schedule / org-deadline: a repeater and warning period stay,
    -- CLOSED goes, and the change is logged (log_reschedule, log_redeadline)
    -- with the --note text, or without one
    local target = { bufnr = bufnr, lnum = lnum }
    if (d or old) and not require("org.timestamps").plan_date(target, kind, d, { note = flags.note or false }) then
      run.fail_with_messages("could not set the " .. kind .. " date", "failed")
    end
    local now = run.headline_at(bufnr, lnum).planning[kind]
    return changed(flags, bufnr, lnum, kind, data.timestamp(old), data.timestamp(now))
  end
end

M.cmd_set_scheduled = set_planning("scheduled")
M.cmd_set_deadline = set_planning("deadline")

function M.cmd_note(words, flags)
  need(words, 2, "org note TARGET TEXT")
  local text = table.concat(words, " ", 2)
  if text == "-" then
    text = run.read_stdin()
  end
  text = vim.trim(text)
  if text == "" then
    fail("the note is empty", "usage")
  end
  local edit = require("org.edit")
  local hl, bufnr, lnum = open(words, flags)
  local entry = edit.log_entry("note", text, nil, nil, require("org.date").effective_now(hl))
  if entry then
    edit.add_log_entry(bufnr, lnum, entry)
  end
  return changed(flags, bufnr, lnum, "note", nil, text)
end

---------------------------------------------------------------------------
-- add, append, set title
---------------------------------------------------------------------------

local function blank(line)
  return line == nil or not line:match("%S")
end

--- The lines of `text` as body lines of a heading of `level`: split at
--- newlines, without the blank lines around them, indented as planning
--- lines are (adapt_indentation). A line that would read as a heading
--- (`* ...` at column 0) gets one space: a plain list item with a `*`
--- bullet has to be indented.
---@param text string
---@param level integer
---@return string[]
local function body_lines(text, level)
  local lines = vim.split((text:gsub("\r\n?", "\n")), "\n", { plain = true })
  while #lines > 0 and blank(lines[1]) do
    table.remove(lines, 1)
  end
  while #lines > 0 and blank(lines[#lines]) do
    table.remove(lines)
  end
  local indent = require("org.edit").body_indent(level)
  return vim.tbl_map(function(l)
    if blank(l) then
      return ""
    end
    l = indent .. l:gsub("%s+$", "")
    if l:match("^%*+%s") or l:match("^%*+$") then
      l = " " .. l
    end
    return l
  end, lines)
end

--- One line of text: no newline in it.
local function one_line(s, what)
  s = vim.trim(s)
  if s:find("[\r\n]") then
    fail(what .. " must be one line", "bad_value", { [what] = s })
  end
  if s == "" then
    fail(what .. " is empty", "usage")
  end
  return s
end

--- blank_before_new_entry.heading (org-blank-before-new-entry): is the
--- new heading preceded by a blank line? "auto": when `ref` (a sibling,
--- or the parent) is.
local function blank_before(lines, ref)
  local b = require("org.config").opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  if v ~= "auto" then
    return v == true
  end
  return ref ~= nil and ref > 1 and blank(lines[ref - 1])
end

--- The org file PARENT names when it is a file: a readable path, or an
--- agenda file by name (not FILE::TITLE nor FILE:LINE).
---@return string|nil
local function parent_file(spec)
  if spec:find("::", 1, true) or spec:match(":%d+$") or spec:match("^id:") then
    return nil
  end
  local found = run.files_named(spec, require("org.files").agenda_files())
  if #found > 1 then
    fail("several agenda files are named " .. spec, "bad_value", {
      file = spec,
      candidates = vim.tbl_map(function(f)
        return data.path(f.filename)
      end, found),
    })
  end
  return found[1] and found[1].filename or nil
end

function M.cmd_add(words, flags)
  need(words, 2, "org add PARENT TITLE")
  local title = one_line(table.concat(words, " ", 2), "title")
  local todo_kw = flags.todo or {}
  if #todo_kw > 1 then
    fail("--todo takes one keyword", "usage")
  end
  local kw = todo_kw[1]
  for _, t in ipairs(flags.tag) do
    if not valid_tag(t) then
      fail("invalid tag " .. t .. " (letters, digits, _ @ # %)", "bad_value", { tag = t })
    end
  end
  local props = {}
  for _, p in ipairs(flags.property) do
    local name, value = p:match("^([^=%s]+)=(.*)$")
    if not name then
      fail("--property needs NAME=VALUE, not " .. p, "bad_value", { property = p })
    end
    one_line_value(name, value)
    props[#props + 1] = { name, value }
  end
  local dates = {}
  for _, kind in ipairs({ "deadline", "scheduled" }) do
    if flags[kind] and vim.trim(flags[kind]) ~= "" then
      dates[kind] = read_planning_date(flags[kind])
    end
  end

  -- where: under a heading, or at the end of a file
  local spec = words[1]
  local path = parent_file(spec)
  local parent, bufnr, plnum
  if path then
    run.guard(path, flags)
    bufnr = run.load_buffer(path)
  else
    parent = run.resolve_target(spec, flags)
    bufnr, plnum = run.open_target(parent, flags)
  end
  local file = require("org.files").get_buffer(bufnr)
  local todo_cfg = file.settings.todo
  if kw and not todo_cfg:is_keyword(kw) then
    fail("unknown TODO keyword " .. kw, "bad_value", { keyword = kw, keywords = todo_cfg:names() })
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local step = require("org.structure").odd_levels_only(bufnr) and 2 or 1
  local level, at, ref, floor
  local following = false
  if parent then
    local ph = run.headline_at(bufnr, plnum)
    level = ph.level + step
    floor = ph.line
    local kids = ph.children or {}
    if flags.first and #kids > 0 then
      at, ref, following = kids[1].line, kids[1].line, true
    else
      at = ph.end_line + 1
      ref = #kids > 0 and kids[#kids].line or ph.line
    end
  else
    level, floor = 1, 0
    at = #lines + 1
    local tops = file.children or {}
    ref = #tops > 0 and tops[#tops].line or nil
  end
  if not following then
    -- after the last text of the subtree, before the blank lines that
    -- separate it from what follows
    while at - 1 > floor and blank(lines[at - 1]) do
      at = at - 1
    end
  end
  local sep = blank_before(lines, ref)
  local new = {}
  if sep and at > 1 and not blank(lines[at - 1]) then
    new[#new + 1] = ""
  end
  local edit = require("org.edit")
  local done = kw and todo_cfg:is_done(kw)
  local heading = edit.build_headline({
    level = level,
    todo = not done and kw or nil,
    title = title,
    tags = #flags.tag > 0 and require("org.tags").sort(vim.deepcopy(flags.tag)) or nil,
  })
  new[#new + 1] = heading
  local lnum = at + #new - 1
  if flags.body and vim.trim(flags.body) ~= "" then
    vim.list_extend(new, body_lines(flags.body, level))
  end
  if following and sep then
    new[#new + 1] = ""
  end
  run.mark_messages()
  if #lines == 1 and lines[1] == "" then
    -- an empty file
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new)
  else
    vim.api.nvim_buf_set_lines(bufnr, at - 1, at - 1, false, new)
  end
  local target = { bufnr = bufnr, lnum = lnum }
  if flags.priority then
    local priority = require("org.priority")
    if not priority.enabled() then
      run.fail_with_messages("priority commands are disabled")
    end
    if not priority.set(target, flags.priority) then
      run.fail_with_messages("invalid priority " .. flags.priority, "bad_value")
    end
  end
  if done then
    if not require("org.todo").change_state(target, kw) then
      run.fail_with_messages("could not set the TODO state to " .. kw)
    end
  end
  for _, kind in ipairs({ "deadline", "scheduled" }) do
    if dates[kind] and not require("org.timestamps").plan_date(target, kind, dates[kind], { note = false }) then
      run.fail_with_messages("could not set the " .. kind .. " date", "failed")
    end
  end
  for _, p in ipairs(props) do
    if require("org.properties").set_property(target, p[1], p[2]) == nil then
      run.fail_with_messages("could not set " .. p[1], "bad_value")
    end
  end
  run.check_prompted()
  run.save_all(flags)
  local hl = run.headline_at(bufnr, lnum)
  local ph = plnum and run.headline_at(bufnr, plnum)
  return {
    data = { headline = data.headline(hl), parent = ph and data.headline(ph) or vim.NIL },
    text = { "Added " .. run.headline_line(hl) },
  }
end

function M.cmd_append(words, flags)
  need(words, 2, "org append TARGET TEXT")
  local text = table.concat(words, " ", 2)
  if vim.trim(text) == "-" then
    text = run.read_stdin()
  end
  if vim.trim(text) == "" then
    fail("the text is empty", "usage")
  end
  local hl, bufnr, lnum = open(words, flags)
  local h = run.headline_at(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kids = h.children or {}
  -- the end of the heading's own text: before its first child, without
  -- the blank lines before that
  local at = (#kids > 0 and kids[1].line or h.end_line + 1)
  local floor = require("org.edit").meta_end(h)
  while at - 1 > floor and blank(lines[at - 1]) do
    at = at - 1
  end
  local new = body_lines(text, h.level)
  -- a new paragraph after text already there (planning and the property
  -- drawer are not text)
  if at - 1 > floor then
    table.insert(new, 1, "")
  end
  vim.api.nvim_buf_set_lines(bufnr, at - 1, at - 1, false, new)
  run.check_prompted()
  run.save_all(flags)
  local now = run.headline_at(bufnr, lnum)
  return {
    data = { headline = data.headline(now), text = vim.trim(text) },
    text = { "Appended to " .. run.headline_line(now or hl) },
  }
end

function M.cmd_set_title(words, flags)
  need(words, 2, "org set title TARGET TITLE")
  local title = one_line(table.concat(words, " ", 2), "title")
  local hl, bufnr, lnum = open(words, flags)
  local old = hl:plain_title()
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  require("org.structure").edit_headline(title)
  local now = run.headline_at(bufnr, lnum)
  return changed(flags, bufnr, lnum, "title", old, now and now:plain_title() or nil)
end

function M.cmd_refile(words, flags)
  need(words, 2, "org refile TARGET DESTINATION")
  local spec = words[2]
  local hl = run.resolve_target(words[1], flags)
  local from = { file = data.path(hl.file.filename), line = hl.line }
  local path = run.arg_path(spec)
  local dest
  if not spec:find("::", 1, true) and not spec:match(":%d+$") and vim.fn.filereadable(path) == 1 then
    local name = vim.fn.fnamemodify(path, ":t")
    dest = { filename = path, olp = {}, label = name, path = name .. "/" }
  else
    local dh = run.resolve_target(spec, { file = {} })
    local olp = dh:outline_path()
    olp[#olp + 1] = dh:plain_title()
    dest = {
      filename = dh.file.filename,
      lnum = dh.line,
      olp = olp,
      label = dh:plain_title(),
      path = table.concat(olp, "/") .. "/",
    }
  end
  run.guard(dest.filename, flags)
  local bufnr, lnum = run.open_target(hl, flags)
  dest.bufnr = run.load_buffer(dest.filename)
  run.mark_messages()
  local dbuf, dline = require("org.refile").refile({ bufnr = bufnr, lnum = lnum }, { dest = dest, count = 0 })
  if not dbuf then
    run.fail_with_messages("could not refile " .. hl:plain_title())
  end
  run.check_prompted()
  run.save_all(flags)
  local moved = run.headline_at(dbuf, dline)
  return {
    data = { headline = data.headline(moved), from = from },
    text = { "Refiled to " .. run.headline_line(moved) },
  }
end

function M.cmd_archive(words, flags)
  need(words, 1, "org archive TARGET")
  local archive = require("org.archive")
  -- the TARGET is the only argument: all the words
  local hl = run.resolve_target(table.concat(words, " "), flags)
  local from = { file = data.path(hl.file.filename), line = hl.line }
  local title = hl:plain_title()
  local cmd = require("org.config").opts.archive_default_command or "archive_subtree"
  if cmd == "archive_subtree" then
    local ok, loc = pcall(archive.parse_location, archive.location_for(hl), hl.file.filename)
    if ok and loc and loc.filename then
      run.guard(loc.filename, flags)
    end
  end
  local bufnr, lnum = run.open_target(hl, flags)
  run.mark_messages()
  local finalized
  local au = vim.api.nvim_create_autocmd("User", {
    pattern = "OrgArchiveFinalize",
    callback = function(ev)
      -- the source subtree is deleted after this: follow the entry
      finalized = { data = ev.data, mark = require("org.marks").set(ev.data.bufnr, ev.data.lnum) }
    end,
  })
  local ok, res = pcall(archive.archive_subtree_default, { bufnr = bufnr, lnum = lnum }, {})
  pcall(vim.api.nvim_del_autocmd, au)
  if not ok then
    error(res, 0)
  end
  if res == nil then
    run.fail_with_messages("could not archive " .. title)
  end
  run.check_prompted()
  ---@type table|vim.NIL, string|vim.NIL
  local hl_after, archive_file = vim.NIL, vim.NIL
  local dbuf, dline
  local marks = require("org.marks")
  if finalized then
    dbuf = finalized.data.bufnr
    dline = finalized.mark and finalized.mark:lnum() or finalized.data.lnum
    marks.del(finalized.mark)
    archive_file = data.path(finalized.data.archive_file or vim.api.nvim_buf_get_name(dbuf))
  elseif cmd == "archive_to_sibling" and type(res) == "number" then
    -- the archive sibling: its last child is the entry
    local sib = run.headline_at(bufnr, res)
    local last = sib and sib.children[#sib.children]
    if last then
      dbuf, dline = bufnr, last.line
    end
  elseif cmd == "set_tag" then
    dbuf, dline = bufnr, lnum
  end
  -- the archive file may be written before the source: lines move
  local mark = dbuf and marks.set(dbuf, dline)
  run.save_all(flags)
  if mark then
    dline = mark:lnum() or dline
    marks.del(mark)
    local h = run.headline_at(dbuf, dline)
    hl_after = h and data.headline(h) or vim.NIL
  end
  return {
    data = { title = title, from = from, archive_file = archive_file, headline = hl_after },
    text = {
      "Archived: " .. title .. (archive_file ~= vim.NIL and (" -> " .. run.short_path(archive_file)) or ""),
    },
  }
end

function M.cmd_id(words, flags)
  need(words, 1, "org id TARGET [--create]")
  local hl = run.resolve_target(table.concat(words, " "), flags)
  local id = hl.properties.ID
  local created = false
  if not id and flags.create then
    local bufnr, lnum = run.open_target(hl, flags)
    id = require("org.id").get_create({ bufnr = bufnr, lnum = lnum })
    created = true
    run.save_all(flags)
    hl = run.headline_at(bufnr, lnum)
  end
  return {
    data = { id = data.nn(id), created = created, headline = data.headline(hl) },
    text = id and { id } or {},
    code = id and 0 or 1,
  }
end

return M
