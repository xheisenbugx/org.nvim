---@mod org.pickers.sources What the pickers list
---
--- Builders turning org data into `org.PickerItem`s (no UI), and the
--- `pick_*` actions that open them with `org.pickers.pick`. The actions
--- take an optional `{ backend = name, backend_opts = table }` overriding
--- the `picker` option and adding to `picker_opts`.

local config = require("org.config")
local files = require("org.files")
local pickers = require("org.pickers")
local utils = require("org.utils")

local M = {}

-- on_choice of the pickers going to a place: several can be chosen, and
-- their picker_keys open it in a split, vertical split or tab page, or
-- put them in the quickfix list (pick() makes it pickers.go())
local function jump() end

---@param opts? { backend?: string, backend_opts?: table }
---@param spec org.PickerSpec
local function pick(opts, spec)
  opts = type(opts) == "table" and opts or {}
  if spec.on_choice == jump then
    spec.split, spec.multi = true, true
    spec.on_choice = function(items, _, how)
      pickers.go(items, how, spec.title)
    end
  end
  return pickers.pick(spec, opts.backend, opts.backend_opts)
end

---------------------------------------------------------------------------
-- Display helpers
---------------------------------------------------------------------------

--- Highlight group of a TODO keyword: its `ui.todo_keyword_faces` face,
--- else OrgDone / OrgTodo.
---@param kw string
---@param done boolean
---@return string
function M.todo_group(kw, done)
  local faces = (config.opts.ui or {}).todo_keyword_faces or {}
  if faces[kw] then
    return "orgTodoKw_" .. kw:gsub("[^%w_]", "_")
  end
  return done and "OrgDone" or "OrgTodo"
end

--- Highlight group of a priority cookie (`ui.priority_faces`, else
--- OrgPriority).
---@param p string
---@return string
function M.priority_group(p)
  local faces = (config.opts.ui or {}).priority_faces or {}
  if faces[p] then
    return require("org.highlights").face_group("orgPriorityFace_", p)
  end
  return "OrgPriority"
end

--- Append the chunks of a TODO keyword, priority, title and tags.
---@param out table chunks
---@param e { todo?: string, done?: boolean, priority?: string, title: string, tags?: string[] }
local function entry_chunks(out, e)
  if e.todo then
    out[#out + 1] = { e.todo, M.todo_group(e.todo, e.done) }
    out[#out + 1] = { " " }
  end
  if e.priority then
    out[#out + 1] = { "[#" .. e.priority .. "]", M.priority_group(e.priority) }
    out[#out + 1] = { " " }
  end
  out[#out + 1] = { e.title, e.done and "OrgHeadlineDone" or nil }
  if e.tags and #e.tags > 0 then
    out[#out + 1] = { "  :" .. table.concat(e.tags, ":") .. ":", "OrgTags" }
  end
  return out
end

--- Display name of a file: its path relative to the working directory or
--- home.
---@param file org.File
---@return string
local function file_name(file)
  if not file.filename then
    return "[buffer " .. tostring(file.bufnr) .. "]"
  end
  return vim.fn.fnamemodify(file.filename, ":~:.")
end

---------------------------------------------------------------------------
-- Headlines
---------------------------------------------------------------------------

--- An item for a headline: `[file ]outline › path › TODO [#A] Title  :tags:`.
---@param hl org.Headline
---@param opts? { file?: boolean } show the file name first
---@return org.PickerItem
function M.headline_item(hl, opts)
  opts = opts or {}
  local file = hl.file
  local display = {}
  if opts.file then
    display[#display + 1] = { vim.fn.fnamemodify(file_name(file), ":t"), "Directory" }
    display[#display + 1] = { " " }
  end
  local path = hl:outline_path()
  if #path > 0 then
    display[#display + 1] = { table.concat(path, " › ") .. " › ", "Comment" }
  end
  entry_chunks(display, {
    todo = hl.todo,
    done = hl.todo ~= nil and hl:is_done(),
    priority = hl.priority,
    title = hl:plain_title(),
    tags = hl.tags,
  })
  return {
    display = display,
    filename = file.filename,
    bufnr = not file.filename and file.bufnr or nil,
    lnum = hl.line,
    value = hl,
  }
end

--- Items for the headlines of `file_list`, filtered by `filter`.
---@param file_list org.File[]
---@param opts? { file?: boolean, filter?: fun(hl: org.Headline): boolean }
---@return org.PickerItem[]
function M.headline_items(file_list, opts)
  opts = opts or {}
  local out = {}
  for _, f in ipairs(file_list) do
    for _, hl in ipairs(f.headlines) do
      if not opts.filter or opts.filter(hl) then
        out[#out + 1] = M.headline_item(hl, opts)
      end
    end
  end
  return out
end

--- Pick a headline of the current file and jump to it.
function M.headlines(opts)
  if not utils.ensure_org() then
    return false
  end
  pick(opts, {
    title = "Headlines",
    items = M.headline_items({ files.get_buffer(0) }),
    on_choice = jump,
  })
end

--- Pick a headline of the agenda files (and the current file) and jump
--- to it.
function M.headlines_all(opts)
  pick(opts, {
    title = "Agenda headlines",
    items = M.headline_items(files.agenda_files_with_current(), { file = true }),
    on_choice = jump,
  })
end

---------------------------------------------------------------------------
-- Tags
---------------------------------------------------------------------------

--- Tags of `file_list` (definitions, `#+FILETAGS` and headline tags) with
--- the number of headlines carrying each, sorted by name.
---@param file_list org.File[]
---@return { name: string, count: integer }[]
function M.tag_list(file_list)
  local count, order = {}, {}
  local function add(t, n)
    if t and t ~= "" and not t:match("^{.*}$") then
      if not count[t] then
        count[t] = 0
        order[#order + 1] = t
      end
      count[t] = count[t] + (n or 0)
    end
  end
  for _, f in ipairs(file_list) do
    for _, d in ipairs(f:tag_definitions()) do
      add(d.name)
    end
    for _, t in ipairs(f.settings and f.settings.filetags or {}) do
      add(t)
    end
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        add(t, 1)
      end
    end
  end
  table.sort(order, function(a, b)
    return a:lower() < b:lower()
  end)
  local out = {}
  for i, t in ipairs(order) do
    out[i] = { name = t, count = count[t] }
  end
  return out
end

--- Items for tags: `name  (count)`, a mark before the ones in `current`.
---@param tags { name: string, count?: integer }[]
---@param current? table<string, boolean>
---@return org.PickerItem[]
function M.tag_items(tags, current)
  local out = {}
  for i, t in ipairs(tags) do
    local display = {}
    if current then
      display[1] = current[t.name] and { "✓ ", "OrgDone" } or { "  " }
    end
    display[#display + 1] = { t.name, "OrgTags" }
    if t.count then
      display[#display + 1] = { "  (" .. t.count .. ")", "Comment" }
    end
    out[i] = { display = display, value = t.name }
  end
  return out
end

--- Pick a tag, then a headline of the agenda files with that tag (own or
--- inherited), and jump to it.
function M.tag(opts)
  local file_list = files.agenda_files_with_current()
  pick(opts, {
    title = "Tags",
    items = M.tag_items(M.tag_list(file_list)),
    on_choice = function(items)
      local tag = items[1].value
      pick(opts, {
        title = "Tagged :" .. tag .. ":",
        items = M.headline_items(file_list, {
          file = true,
          filter = function(hl)
            return vim.tbl_contains(hl:get_tags(), tag)
          end,
        }),
        on_choice = jump,
      })
    end,
  })
end

--- The tags of the headline at `target` after toggling `chosen` (and
--- adding the tags typed in `query`, `a:b` or `a b`).
---@param current string[]
---@param chosen string[]
---@param query? string
---@return string[]
function M.toggle_tags(current, chosen, query)
  local out, has = {}, {}
  for _, t in ipairs(current) do
    has[t] = true
  end
  local flip = {}
  for _, t in ipairs(chosen) do
    flip[t] = true
  end
  for _, t in ipairs(current) do
    if not flip[t] then
      out[#out + 1] = t
    end
  end
  for _, t in ipairs(chosen) do
    if not has[t] then
      out[#out + 1] = t
      has[t] = true
    end
  end
  if #chosen == 0 and query and query ~= "" then
    for _, t in ipairs(require("org.tags").parse_input(query)) do
      if not has[t] then
        out[#out + 1] = t
        has[t] = true
      end
    end
  end
  return out
end

--- Set the tags of the headline at the cursor: the chosen tags (several
--- with multi-select) are toggled; text matching no tag adds it as a new
--- tag.
function M.set_tags(opts)
  if not utils.ensure_org() then
    return false
  end
  local edit = require("org.edit")
  local bufnr, _, hl = edit.resolve_headline()
  if not bufnr or not hl then
    return
  end
  local lnum = hl.line
  local current, cur_set = vim.deepcopy(hl.tags), {}
  for _, t in ipairs(current) do
    cur_set[t] = true
  end
  local tags, seen = {}, {}
  for _, t in ipairs(require("org.tags").all_tags(bufnr)) do
    seen[t] = true
    tags[#tags + 1] = { name = t }
  end
  for _, t in ipairs(current) do
    if not seen[t] then
      tags[#tags + 1] = { name = t }
    end
  end
  pick(opts, {
    title = "Toggle tags",
    items = M.tag_items(tags, cur_set),
    multi = true,
    allow_query = true,
    create_label = "+ New tags…",
    on_choice = function(items, query)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local chosen = vim.tbl_map(function(it)
        return it.value
      end, items)
      local f = files.get_buffer(bufnr)
      local h = f:headline_at(lnum)
      local new = M.toggle_tags(h and h.tags or current, chosen, query)
      require("org.tags").set_tags({ bufnr = bufnr, lnum = lnum }, new)
    end,
  })
end

---------------------------------------------------------------------------
-- Agenda
---------------------------------------------------------------------------

local function hhmm(min)
  return string.format("%02d:%02d", math.floor(min / 60), min % 60)
end

--- An item for an agenda entry: `[day ]time|leader category: TODO title`.
---@param it org.AgendaItem
---@param day? integer show this day number first
---@return org.PickerItem
function M.agenda_item(it, day)
  local display = {}
  if day then
    local d = require("org.date").from_days(day)
    display[#display + 1] = { d:strftime("%a %d %b") .. " ", "OrgAgendaDate" }
  end
  if it.time then
    local t = hhmm(it.time) .. (it.end_time and ("-" .. hhmm(it.end_time)) or "")
    display[#display + 1] = { t .. " ", "Special" }
  end
  if it.extra and it.extra ~= "" then
    display[#display + 1] = { it.extra, "Comment" }
  end
  if it.category and it.category ~= "" then
    display[#display + 1] = { it.category .. ": ", "Identifier" }
  end
  entry_chunks(display, {
    todo = it.todo,
    done = it.done,
    priority = it.priority,
    title = vim.trim(it.display_title or it.title or ""),
    tags = it.headline and it.headline.tags or nil,
  })
  return {
    display = display,
    filename = it.filename,
    bufnr = not it.filename and it.bufnr or nil,
    lnum = it.lnum,
    value = it,
  }
end

--- Sort agenda items with an `agenda.sorting` strategy, like the views.
--- A strategy that fails (an unknown one, user-defined-up without
--- agenda.cmp_user_defined), which the views report, is warned about and
--- leaves the order. Returns whether it sorted.
---@param list org.AgendaItem[]
---@param sorting string[]
---@return boolean
local function sort(list, sorting)
  local ok, err = pcall(require("org.agenda.items").sort, list, sorting)
  if not ok then
    utils.warn(tostring(err))
  end
  return ok
end

--- Items of the agenda from day `from` to `to` (day numbers), sorted like
--- the agenda view.
---@param from integer
---@param to integer
---@param file_list? org.File[]
---@return org.PickerItem[]
function M.agenda_items(from, to, file_list)
  local date = require("org.date")
  local items_mod = require("org.agenda.items")
  require("org.agenda.highlights").setup()
  local today = date.today_days()
  local by_day = items_mod.agenda(file_list or files.agenda_files(), from, to, { today = today })
  local sorting = require("org.agenda.render").sorting_for({}, "agenda")
  local out = {}
  for d = from, to do
    local list = by_day[d] or {}
    if #list > 0 and sorting and not sort(list, sorting) then
      sorting = nil -- warned once
    end
    for _, it in ipairs(list) do
      if (it.filename or it.bufnr) and it.lnum then
        out[#out + 1] = M.agenda_item(it, from ~= to and d or nil)
      end
    end
  end
  return out
end

--- Pick an entry of today's agenda and jump to it.
function M.agenda_day(opts)
  local today = require("org.date").today_days()
  pick(opts, { title = "Agenda: today", items = M.agenda_items(today, today), on_choice = jump })
end

--- Pick an entry of the agenda of the next 7 days (today first).
function M.agenda_week(opts)
  local today = require("org.date").today_days()
  pick(opts, { title = "Agenda: 7 days", items = M.agenda_items(today, today + 6), on_choice = jump })
end

--- Items of the global TODO list (open entries), sorted like the TODO view.
---@param file_list? org.File[]
---@return org.PickerItem[]
function M.todo_items(file_list)
  require("org.agenda.highlights").setup()
  local items_mod = require("org.agenda.items")
  local list = items_mod.todo(file_list or files.agenda_files())
  local sorting = require("org.agenda.render").sorting_for({}, "todo")
  -- the timestamp the timestamp-*, scheduled-*, deadline-*, ts-* and
  -- tsia-* strategies compare, as the TODO view takes it
  local kind = items_mod.list_timestamp_kind(sorting) or false
  for _, it in ipairs(list) do
    items_mod.set_list_timestamp(it, sorting, kind)
  end
  sort(list, sorting)
  local out = {}
  for _, it in ipairs(list) do
    out[#out + 1] = M.agenda_item(it)
  end
  return out
end

--- Pick an open TODO entry of the agenda files and jump to it.
function M.todo(opts)
  pick(opts, { title = "TODO", items = M.todo_items(), on_choice = jump })
end

---------------------------------------------------------------------------
-- Files and capture templates
---------------------------------------------------------------------------

--- Pick an agenda file and open it.
function M.agenda_file(opts)
  local items = {}
  for _, path in ipairs(files.agenda_file_paths()) do
    items[#items + 1] = {
      display = {
        { vim.fn.fnamemodify(path, ":t"), "Directory" },
        { "  " .. vim.fn.fnamemodify(path, ":~:h"), "Comment" },
      },
      filename = path,
      lnum = 1,
      value = path,
    }
  end
  pick(opts, { title = "Agenda files", items = items, on_choice = jump })
end

--- Items for the capture templates: `key  description`.
---@return org.PickerItem[]
function M.capture_template_items()
  local capture = require("org.capture")
  local keys = vim.tbl_keys(capture.templates())
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    local tpl = capture.get_template(key)
    if tpl then
      out[#out + 1] = {
        display = { { key, "Special" }, { "  " .. (tpl.description or key) } },
        value = tpl,
      }
    end
  end
  return out
end

--- Pick a capture template and capture with it. From the agenda with
--- `capture.use_agenda_date`, the capture takes the date at the cursor,
--- like the capture menu (org-capture-use-agenda-date).
function M.capture_template(opts)
  -- the date now: the picker takes the focus
  local copts = {}
  if config.opts.capture.use_agenda_date and vim.bo.filetype == "orgagenda" then
    copts.date = require("org.agenda.view").cursor_date()
  end
  pick(opts, {
    title = "Capture template",
    items = M.capture_template_items(),
    preview = false,
    on_choice = function(items)
      require("org.capture").capture(items[1].value, copts)
    end,
  })
end

return M
