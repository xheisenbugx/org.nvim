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
  local now = run.headline_at(bufnr, lnum)
  return changed(flags, bufnr, lnum, "todo", old, now.todo, { repeated = res.repeated or false })
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
    if not t:match("^[%w_@#%%]+$") then
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
  else
    need(words, 3, "org set property TARGET NAME VALUE")
  end
  local props = require("org.properties")
  local name = words[2]
  if name:find("%s") or name == "" then
    fail("invalid property name " .. name, "bad_value", { name = name })
  end
  local hl, bufnr, lnum = open(words, flags)
  local old = hl:get_property(name:upper(), false)
  local target = { bufnr = bufnr, lnum = lnum }
  if flags.delete then
    props.delete_property(target, name)
  elseif props.set_property(target, name, words[3]) == nil then
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
  return d:clone({ active = true, range_end = vim.NIL })
end

local function set_planning(kind)
  return function(words, flags)
    need(words, 2, "org set " .. kind .. " TARGET DATE")
    local d = read_planning_date(words[2])
    local hl, bufnr, lnum = open(words, flags)
    local old = hl.planning[kind]
    require("org.timestamps").set_date({ bufnr = bufnr, lnum = lnum }, kind, d)
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
  local hl = run.resolve_target(words[1], flags)
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
