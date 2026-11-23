---@mod org.tutor Interactive tutorial (:Org tutor)
---
--- A vimtutor-style guided lesson in a real org buffer, so every org key
--- works in it. `:Org tutor [lesson] [reset]` copies the lesson text from
--- `tutor/org/<lesson>.org` (on 'runtimepath') to
--- `stdpath("data")/org/tutor/<lesson>.org` and opens the copy: the
--- shipped file is never edited, and the copy is an ordinary file, so
--- saving, the agenda, capture and clocking work in it as in any notes
--- file. Running it again opens the same copy (the progress you saved);
--- `reset` starts the lesson over from a fresh copy.
---
--- `{{section.action}}` in the lesson text is replaced, when the copy is
--- made, by the first key of `mappings.<section>.<action>` (`:Org action`
--- when it has none), so the lesson shows the keys of your config.
---
--- Exercises are the headlines whose title starts with a number like
--- `1.2`. Their checks live in `lua/org/tutor/lessons/<lesson>.lua`
--- (`{ checks = ..., hints = ... }`), keyed by that number: a condition,
--- or a list of conditions that must all hold, evaluated on the parse of
--- the buffer (`org.files`) within the exercise's subtree. A ✓ or ✗
--- (`ui.tutor_marks`) at the end of the exercise's headline shows the
--- result, updated as the buffer changes; once all are ✓ the next lesson
--- is named under the last line. A hint (`:Org tutor_hint`) gives the keys
--- that solve the exercise at the cursor.
---
--- The `#+TUTOR_ORDER:`, `#+TUTOR_LEVEL:` and `#+TUTOR_TOPICS:` keywords of
--- a lesson (`M.meta`) give its place in the course, its level and what it
--- teaches: `:Org tutor` without a lesson lists them in that order with
--- the progress of each, and the website's playground groups them so.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

--- Milliseconds of quiet after a change before the checks run again.
M.debounce_ms = 150

M.ns = vim.api.nvim_create_namespace("org.tutor")

--- Lesson used when `:Org tutor` gets none.
M.default_lesson = "basics"

---@class org.tutor.Condition
---@field heading? string plain title of a headline in the exercise's subtree the other fields test (default: the exercise headline)
---@field todo? string|false its TODO keyword (false: none)
---@field priority? string its priority
---@field tags? string[] tags it has (own tags)
---@field parent? string plain title of its parent
---@field depth? integer levels below the exercise headline
---@field children? string[] plain titles of its children, in order
---@field scheduled? boolean has a SCHEDULED date
---@field deadline? boolean has a DEADLINE
---@field clocked? boolean has a closed CLOCK line
---@field min_headings? integer at least this many headlines in its subtree, itself excluded
---@field item? string a list item with this text in the exercise
---@field checked? string a checked list item with this text in the exercise
---@field table_aligned? boolean the first table in the exercise is aligned
---@field table_row? string a table row in the exercise whose first field is this
---@field contains? string text (plain) found in the exercise
---@field folded? boolean its subtree is folded in a window (view: see below)
---@field cursor? string a window has the cursor on the headline with this plain title, anywhere in the file (view: see below)
---@field buffer? string a buffer whose name has this text exists, such as an export or a file opened from the lesson (view: see below)
---@field fn? fun(ctx: org.tutor.Context): boolean
---
--- `folded`, `cursor` and `buffer` test the view, not the text: once an
--- exercise with such a condition has passed it stays done (remembered
--- in `M.seen_path()`, until the lesson is reset), as there is nothing in
--- the file to show it.

---@class org.tutor.Context
---@field buf integer
---@field file org.File
---@field exercise org.Headline
---@field lines string[] the exercise's subtree lines

---@alias org.tutor.Checks table<string, org.tutor.Condition|org.tutor.Condition[]>

---------------------------------------------------------------------------
-- Lessons
---------------------------------------------------------------------------

--- Lessons on 'runtimepath', by name: `tutor/org/<name>.org`.
---@return table<string, string> name -> path
function M.lessons()
  local out = {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file("tutor/org/*.org", true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    out[name] = out[name] or path
  end
  return out
end

--- The levels a lesson can be at (`#+TUTOR_LEVEL:`), easiest first.
M.levels = { "Beginner", "Daily workflow", "Power user" }

---@class org.tutor.Meta
---@field name string lesson name (the file name without `.org`)
---@field path string the shipped lesson file
---@field title string its `#+TITLE:` ("" when it has none)
---@field order? integer its place in the course (`#+TUTOR_ORDER:`)
---@field level? string one of `M.levels` (`#+TUTOR_LEVEL:`)
---@field topics string[] what it teaches (`#+TUTOR_TOPICS:`, comma-separated)

--- A lesson's metadata: the `#+TITLE:` and the `#+TUTOR_ORDER:`,
--- `#+TUTOR_LEVEL:` and `#+TUTOR_TOPICS:` keywords of its file, read up
--- to the first headline. nil when there is no such lesson.
---@param name string
---@return org.tutor.Meta|nil
function M.meta(name)
  local path = M.lessons()[name]
  return path and M.file_meta(path) or nil
end

--- The metadata of the lesson file at `path` (see `M.meta`).
---@param path string
---@return org.tutor.Meta
function M.file_meta(path)
  ---@type org.tutor.Meta
  local meta = { name = vim.fn.fnamemodify(path, ":t:r"), path = path, title = "", topics = {} }
  for _, line in ipairs(vim.fn.readfile(path, "", 40)) do
    if line:match("^%*+%s") then
      break
    end
    local key, value = line:match("^#%+([%w_]+):%s*(.-)%s*$")
    key = key and key:lower()
    if key == "title" then
      meta.title = value
    elseif key == "tutor_order" then
      meta.order = tonumber(value)
    elseif key == "tutor_level" then
      meta.level = value
    elseif key == "tutor_topics" then
      for topic in value:gmatch("[^,]+") do
        meta.topics[#meta.topics + 1] = vim.trim(topic)
      end
    end
  end
  return meta
end

--- Lesson names in course order: by `#+TUTOR_ORDER:`, then by name (a
--- lesson without one comes after those that have one).
---@return string[]
function M.lesson_names()
  local names = vim.tbl_keys(M.lessons())
  local order = {}
  for _, name in ipairs(names) do
    order[name] = (M.meta(name) or {}).order or math.huge
  end
  table.sort(names, function(a, b)
    if order[a] ~= order[b] then
      return order[a] < order[b]
    end
    return a < b
  end)
  return names
end

--- The lesson after `name` in course order, or nil after the last one.
---@param name string
---@return string|nil
function M.next_lesson(name)
  local names = M.lesson_names()
  for i, n in ipairs(names) do
    if n == name then
      return names[i + 1]
    end
  end
  return nil
end

--- The module of a lesson's checks and hints (`org.tutor.lessons.<name>`):
--- `{ checks = {...}, hints = {...} }`, or (the older form) the checks
--- table alone.
---@param name string
---@return { checks: org.tutor.Checks, hints: table<string, string> }
local function lesson_module(name)
  local ok, mod = pcall(require, "org.tutor.lessons." .. name)
  if not ok or type(mod) ~= "table" then
    return { checks = {}, hints = {} }
  end
  if type(mod.checks) == "table" or type(mod.hints) == "table" then
    return { checks = mod.checks or {}, hints = mod.hints or {} }
  end
  return { checks = mod, hints = {} }
end

--- The checks of a lesson, by exercise number; {} when it has none.
---@param name string
---@return org.tutor.Checks
function M.checks(name)
  return lesson_module(name).checks
end

--- The hints of a lesson, by exercise number: what solves the exercise,
--- with `{{section.action}}` placeholders (`M.render_line`).
---@param name string
---@return table<string, string>
function M.hints(name)
  return lesson_module(name).hints
end

--- Where the working copy of a lesson lives.
---@param name string
---@return string
function M.copy_path(name)
  return vim.fs.normalize(vim.fn.stdpath("data") .. "/org/tutor/" .. name .. ".org")
end

--- The key shown for `mappings.<section>.<name>`: its first lhs, or
--- `:Org <name>` when it has none (`mappings.org` / `mappings.global`).
---@param section string
---@param name string
---@return string|nil
function M.key(section, name)
  local maps = config.opts.mappings
  local s = maps[section]
  if type(s) ~= "table" then
    return nil
  end
  local lhs = maps.disable_all and {} or config.lhs_list(s[name])
  if lhs[1] then
    return lhs[1]
  end
  if (section == "org" or section == "global") and require("org.actions").list[name] then
    return ":Org " .. name
  end
  return "(no key: mappings." .. section .. "." .. name .. ")"
end

--- The leader key as shown in the lesson.
local function leader()
  local l = vim.g.mapleader
  if l == nil or l == "" then
    return "\\"
  end
  return vim.fn.keytrans(l)
end

--- The examples directory shipped with the plugin, as a link.
local function examples()
  local index = vim.api.nvim_get_runtime_file("examples/00-index.org", false)[1]
  if index then
    return "[[file:" .. vim.fs.normalize(index) .. "][examples/00-index.org]]"
  end
  return "=examples/00-index.org= in the org.nvim directory"
end

--- Replace the `{{...}}` placeholders of the lesson text. The
--- `#+TUTOR_...:` metadata lines (`M.meta`) are left out.
---@param lines string[]
---@return string[]
function M.render(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if not line:match("^#%+[Tt][Uu][Tt][Oo][Rr]_[%w_]*:") then
      out[#out + 1] = M.render_line(line)
    end
  end
  return out
end

--- Replace the `{{...}}` placeholders of one line of text.
---@param line string
---@return string
function M.render_line(line)
  return (
    line:gsub("{{([%w_%.]+)}}", function(ref)
      if ref == "leader" then
        return leader()
      elseif ref == "done" or ref == "todo" then
        local marks = config.opts.ui.tutor_marks or {}
        return marks[ref] or (ref == "done" and "✓" or "✗")
      elseif ref == "examples" then
        return examples()
      end
      local section, name = ref:match("^([%w_]+)%.([%w_]+)$")
      return section and M.key(section, name) or nil
    end)
  )
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

--- The headlines of `ex`'s subtree, `ex` excluded.
---@param file org.File
---@param ex org.Headline
---@return org.Headline[]
local function descendants(file, ex)
  local out = {}
  for i = ex.index + 1, #file.headlines do
    local hl = file.headlines[i]
    if hl.line > ex.end_line then
      break
    end
    out[#out + 1] = hl
  end
  return out
end

local function list_items(ctx)
  if not ctx.items then
    local _, all = require("org.lists").parse_region(ctx.lines, 1, #ctx.lines)
    ctx.items = all
  end
  return ctx.items
end

--- The first table of the exercise: its lines.
local function first_table(ctx)
  local tbl = {}
  for _, line in ipairs(ctx.lines) do
    if line:match("^%s*|") then
      tbl[#tbl + 1] = line
    elseif #tbl > 0 then
      break
    end
  end
  return tbl
end

---@param ctx org.tutor.Context
---@param c org.tutor.Condition
---@return boolean
local function check_one(ctx, c)
  local hl = ctx.exercise
  if c.heading then
    local found
    for _, h in ipairs(descendants(ctx.file, ctx.exercise)) do
      if h:plain_title() == c.heading then
        found = h
        break
      end
    end
    if not found then
      return false
    end
    hl = found
  end
  if c.todo ~= nil and (hl.todo or false) ~= c.todo then
    return false
  end
  if c.priority ~= nil and hl.priority ~= c.priority then
    return false
  end
  for _, tag in ipairs(c.tags or {}) do
    if not vim.tbl_contains(hl.tags, tag) then
      return false
    end
  end
  if c.parent ~= nil and not (hl.parent and hl.parent:plain_title() == c.parent) then
    return false
  end
  if c.depth ~= nil and hl.level - ctx.exercise.level ~= c.depth then
    return false
  end
  if c.children ~= nil then
    local titles = {}
    for _, child in ipairs(hl.children) do
      titles[#titles + 1] = child:plain_title()
    end
    if not vim.deep_equal(titles, c.children) then
      return false
    end
  end
  if c.scheduled ~= nil and (hl.planning.scheduled ~= nil) ~= c.scheduled then
    return false
  end
  if c.deadline ~= nil and (hl.planning.deadline ~= nil) ~= c.deadline then
    return false
  end
  if c.clocked ~= nil then
    local closed = false
    for _, clock in ipairs(hl.clocks or {}) do
      closed = closed or clock["end"] ~= nil
    end
    if closed ~= c.clocked then
      return false
    end
  end
  if c.min_headings ~= nil and #descendants(ctx.file, hl) < c.min_headings then
    return false
  end
  if c.item ~= nil or c.checked ~= nil then
    local want, found = c.checked or c.item, false
    for _, item in ipairs(list_items(ctx)) do
      if vim.trim(item.text) == want and (c.checked == nil or item.checkbox == "X") then
        found = true
        break
      end
    end
    if not found then
      return false
    end
  end
  if c.table_aligned ~= nil then
    local lines = first_table(ctx)
    local aligned = false
    if #lines > 0 then
      local tbl = require("org.table")
      local rendered
      vim.api.nvim_buf_call(ctx.buf, function()
        rendered = tbl.render(tbl.parse(lines))
      end)
      aligned = vim.deep_equal(rendered, lines)
    end
    if aligned ~= c.table_aligned then
      return false
    end
  end
  if c.table_row ~= nil then
    local found = false
    for _, line in ipairs(ctx.lines) do
      local first = line:match("^%s*|([^|]*)|")
      if first and vim.trim(first) == c.table_row then
        found = true
        break
      end
    end
    if not found then
      return false
    end
  end
  if c.contains ~= nil and not table.concat(ctx.lines, "\n"):find(c.contains, 1, true) then
    return false
  end
  if c.buffer ~= nil then
    local found = false
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      found = found or (vim.fn.buflisted(b) == 1 and vim.api.nvim_buf_get_name(b):find(c.buffer, 1, true) ~= nil)
    end
    if not found then
      return false
    end
  end
  if c.folded ~= nil or c.cursor ~= nil then
    local wins = vim.api.nvim_buf_is_valid(ctx.buf) and vim.fn.win_findbuf(ctx.buf) or {}
    if c.folded ~= nil then
      local folded = false
      for _, win in ipairs(wins) do
        folded = folded
          or vim.api.nvim_win_call(win, function()
            return vim.fn.foldclosed(hl.line) == hl.line
          end)
      end
      if folded ~= c.folded then
        return false
      end
    end
    if c.cursor ~= nil then
      local at = false
      for _, win in ipairs(wins) do
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        for _, h in ipairs(ctx.file.headlines) do
          at = at or (h.line == lnum and h:plain_title() == c.cursor)
        end
      end
      if not at then
        return false
      end
    end
  end
  if c.fn ~= nil and not c.fn(ctx) then
    return false
  end
  return true
end

--- Whether the conditions of an exercise hold.
---@param buf integer
---@param file org.File
---@param ex org.Headline the exercise headline
---@param conds org.tutor.Condition|org.tutor.Condition[]
---@return boolean
function M.check(buf, file, ex, conds)
  local ctx = { buf = buf, file = file, exercise = ex, lines = vim.list_slice(file.lines, ex.line, ex.end_line) }
  local list = vim.islist(conds) and conds or { conds }
  for _, c in ipairs(list) do
    local ok, res = pcall(check_one, ctx, c)
    if not ok or not res then
      return false
    end
  end
  return true
end

--- The exercise number of a headline ("1.2"), or nil.
---@param hl org.Headline
---@return string|nil
function M.exercise_id(hl)
  return hl:plain_title():match("^(%d+%.%d+)%s")
end

--- Attached buffers: bufnr -> { name, checks, seen, timer, results, all_done }
local state = {}

---------------------------------------------------------------------------
-- Exercises done in a window's view
---------------------------------------------------------------------------

--- Where the exercises passed by a view condition (`folded`, `cursor`, `buffer`)
--- are remembered: { [lesson] = { [exercise] = true } }.
---@return string
function M.seen_path()
  return vim.fs.normalize(vim.fn.stdpath("data") .. "/org/tutor/seen.json")
end

---@return table<string, table<string, boolean>>
local function read_seen()
  local f = io.open(M.seen_path(), "r")
  if not f then
    return {}
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, text)
  return ok and type(data) == "table" and data or {}
end

---@param data table<string, table<string, boolean>>
local function write_seen(data)
  local path = M.seen_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(data) }, path)
end

--- The exercises of lesson `name` passed by a view condition.
---@param name string
---@return table<string, boolean>
function M.seen(name)
  local seen = read_seen()[name]
  local out = {}
  if type(seen) == "table" then
    for id, v in pairs(seen) do
      out[tostring(id)] = v == true or nil
    end
  end
  return out
end

---@param name string
---@param id string
local function remember(name, id)
  local data = read_seen()
  data[name] = type(data[name]) == "table" and data[name] or {}
  data[name][id] = true
  write_seen(data)
end

---@param name string
local function forget(name)
  local data = read_seen()
  if data[name] ~= nil then
    data[name] = nil
    write_seen(data)
  end
end

--- Whether conditions test the view (`folded`, `cursor`, `buffer`) rather than the text.
---@param conds org.tutor.Condition|org.tutor.Condition[]
---@return boolean
local function is_view(conds)
  for _, c in ipairs(vim.islist(conds) and conds or { conds }) do
    if c.folded ~= nil or c.cursor ~= nil or c.buffer ~= nil then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Lesson titles and progress
---------------------------------------------------------------------------

--- A lesson's title as the list shows it: its `#+TITLE:` without the
--- "org.nvim tutor N:" prefix, capitalized ("Capture, agenda and
--- clocking"); the lesson name when it has no title.
---@param name string
---@return string
function M.title(name)
  local meta = M.meta(name)
  local title = meta and meta.title ~= "" and meta.title or name
  title = title:gsub("^[Oo]rg%.nvim tutor%s*%d*:%s*", "")
  return (title:gsub("^%l", string.upper))
end

--- How far the saved copy of lesson `name` is: exercises done (by their
--- checks on the copy as saved, or as loaded in a buffer) and exercises
--- with a check. nil when the lesson was never opened.
---@param name string
---@return integer|nil passed
---@return integer|nil total
function M.progress(name)
  local path = M.copy_path(name)
  local loaded = utils.find_buffer(path)
  if not loaded and vim.fn.filereadable(path) == 0 then
    return nil, nil
  end
  local file = require("org.files").get(path)
  if not file then
    return nil, nil
  end
  local checks, seen = M.checks(name), M.seen(name)
  local passed, total, counted = 0, 0, {}
  for _, hl in ipairs(file.headlines) do
    local id = M.exercise_id(hl)
    local conds = id and checks[id]
    if id and conds and not counted[id] then
      counted[id] = true
      total = total + 1
      local pass
      if is_view(conds) then
        pass = seen[id] or (loaded ~= nil and M.check(loaded, file, hl, conds))
      else
        pass = M.check(loaded or vim.api.nvim_get_current_buf(), file, hl, conds)
      end
      passed = passed + (pass and 1 or 0)
    end
  end
  return passed, total
end

---------------------------------------------------------------------------
-- Marks
---------------------------------------------------------------------------

--- The line shown when every exercise of lesson `name` is done.
---@param name? string
---@return string
local function finished_text(name)
  local nxt = name and M.next_lesson(name)
  if nxt then
    local meta = M.meta(nxt) or {}
    return ("Next lesson: %s%s (:Org tutor %s)"):format(meta.order and (meta.order .. ". ") or "", M.title(nxt), nxt)
  end
  return "That was the last lesson. :Org tutor lists them all"
end

--- Run the checks of a tutor buffer now and redraw its marks.
---@param buf integer
---@return table<string, boolean> results exercise number -> passed
function M.refresh(buf)
  local st = state[buf]
  local results = {}
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return results
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local file = require("org.files").get_buffer(buf)
  local marks = config.opts.ui.tutor_marks or {}
  local done_mark, todo_mark = marks.done or "✓", marks.todo or "✗"
  local total, passed = 0, 0
  for _, hl in ipairs(file.headlines) do
    local id = M.exercise_id(hl)
    local conds = id and st.checks[id]
    if id and conds and results[id] == nil then
      local pass = M.check(buf, file, hl, conds)
      if is_view(conds) then
        -- done once is done: nothing in the text shows it
        if pass and st.name and not st.seen[id] then
          st.seen[id] = true
          remember(st.name, id)
        end
        pass = pass or st.seen[id] == true
      end
      results[id] = pass
      total = total + 1
      passed = passed + (pass and 1 or 0)
      vim.api.nvim_buf_set_extmark(buf, M.ns, hl.line - 1, 0, {
        virt_text = { { " " .. (pass and done_mark or todo_mark), pass and "OrgTutorDone" or "OrgTutorTodo" } },
        virt_text_pos = "eol",
        priority = 200,
      })
    end
  end
  if total > 0 then
    vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, {
      virt_text = {
        { (" %s %d/%d"):format(done_mark, passed, total), passed == total and "OrgTutorDone" or "OrgTutorProgress" },
      },
      virt_text_pos = "eol",
      priority = 200,
    })
  end
  local all = total > 0 and passed == total
  if all then
    -- under the last line: where to go next
    local text = finished_text(st.name)
    vim.api.nvim_buf_set_extmark(buf, M.ns, vim.api.nvim_buf_line_count(buf) - 1, 0, {
      virt_lines = { { { "" } }, { { done_mark .. " " .. text, "OrgTutorDone" } } },
      priority = 200,
    })
    if st.all_done == false then
      utils.notify(("Tutor %q done! %s"):format(st.name or "", text))
    end
  end
  st.all_done = all
  st.results = results
  return results
end

--- Run the checks after `M.debounce_ms` of quiet.
---@param buf integer
local function schedule(buf)
  local st = state[buf]
  if not st then
    return
  end
  st.timer = st.timer or vim.uv.new_timer()
  st.timer:stop()
  st.timer:start(
    M.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if state[buf] and vim.api.nvim_buf_is_valid(buf) then
        M.refresh(buf)
      end
    end)
  )
end

local function detach(buf)
  local st = state[buf]
  if st and st.timer then
    st.timer:stop()
    st.timer:close()
  end
  state[buf] = nil
end

--- Show the ✓ / ✗ marks of `checks` in `buf` and keep them up to date.
---@param buf integer
---@param checks org.tutor.Checks
---@param name? string the lesson (default `b:org_tutor`): remembers the exercises done in the view, and names the next lesson
function M.attach(buf, checks, name)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  require("org.highlights").ensure()
  detach(buf)
  name = name or vim.b[buf].org_tutor
  local st = { name = name, checks = checks, seen = name and M.seen(name) or {} }
  state[buf] = st
  -- every change, also the ones made while another buffer is current
  -- (from the agenda, capture or a clock out)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if state[buf] ~= st then
        return true -- detach
      end
      schedule(buf)
    end,
    on_reload = function()
      if state[buf] == st then
        schedule(buf)
      end
    end,
  })
  local group = vim.api.nvim_create_augroup("org.tutor", { clear = false })
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      detach(buf)
    end,
  })
  local view = false
  for _, conds in pairs(checks) do
    view = view or is_view(conds)
  end
  if view then
    -- folding and moving change no text: check again when the cursor
    -- moves or rests
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
      group = group,
      buffer = buf,
      callback = function()
        schedule(buf)
      end,
    })
  end
  M.refresh(buf)
end

--- Whether `buf` shows marks.
---@param buf integer
---@return boolean
function M.attached(buf)
  return state[buf] ~= nil
end

---------------------------------------------------------------------------
-- Hints
---------------------------------------------------------------------------

--- The exercise headline whose subtree has line `lnum`, or nil.
---@param file org.File
---@param lnum integer
---@return org.Headline|nil
local function exercise_at(file, lnum)
  local found
  for _, hl in ipairs(file.headlines) do
    if hl.line > lnum then
      break
    end
    if M.exercise_id(hl) and hl.end_line >= lnum then
      found = hl
    end
  end
  return found
end

--- `:Org tutor_hint`: show the keys that solve the exercise at the
--- cursor (the lesson's `hints`).
---@return boolean|nil
function M.hint()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.b[buf].org_tutor
  if not name then
    utils.warn("Not a tutor lesson: open one with :Org tutor")
    return
  end
  local hl = exercise_at(require("org.files").get_buffer(buf), vim.api.nvim_win_get_cursor(0)[1])
  if not hl then
    utils.notify("Put the cursor in an exercise (a headline such as 1.2 and its text) for its hint")
    return
  end
  local id = M.exercise_id(hl)
  local hint = M.hints(name)[id]
  if not hint then
    utils.notify(("No hint for %s"):format(hl:plain_title()))
    return
  end
  local text = ("Hint for %s: %s"):format(hl:plain_title(), M.render_line(hint))
  utils.notify(text)
  return true
end

---------------------------------------------------------------------------
-- Opening a lesson
---------------------------------------------------------------------------

--- Open a lesson's working copy: resumes the copy when there is one,
--- else (or with `reset`) makes a fresh one from the shipped lesson.
---@param name? string lesson (default `M.default_lesson`)
---@param reset? boolean start over
---@return integer|nil bufnr
function M.open(name, reset)
  name = name or M.default_lesson
  local src = M.lessons()[name]
  if not src then
    utils.error(("No org tutor lesson %q (lessons: %s)"):format(name, table.concat(M.lesson_names(), ", ")))
    return nil
  end
  local path = M.copy_path(name)
  local existing = utils.find_buffer(path)
  local fresh = reset or (not existing and vim.fn.filereadable(path) == 0)
  if fresh then
    forget(name)
    if existing and state[existing] then
      state[existing].seen = {}
    end
    local lines = M.render(vim.fn.readfile(src))
    if existing then
      -- keep the buffer (and its undo history: u brings the old copy back)
      vim.api.nvim_buf_set_lines(existing, 0, -1, false, lines)
      utils.save_buffer_or_warn(existing)
    else
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      if vim.fn.writefile(lines, path) ~= 0 then
        utils.error("Could not write " .. path)
        return nil
      end
    end
  end
  vim.cmd("drop " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  if fresh then
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end
  vim.b[buf].org_tutor = name
  M.attach(buf, M.checks(name), name)
  if not fresh then
    utils.notify(("Tutor %q resumed; `:Org tutor %s reset` starts it over"):format(name, name))
  end
  return buf
end

--- The lesson list: each lesson's number, title, level and progress, in
--- course order. Returns the lesson picked, or nil.
---@return string|nil
function M.pick()
  local items = {}
  for _, name in ipairs(M.lesson_names()) do
    local meta = M.meta(name) or {}
    local passed, total = M.progress(name)
    local progress
    if passed and total and total > 0 then
      progress = passed == total and ("done %d/%d"):format(passed, total) or ("%d/%d"):format(passed, total)
    else
      progress = "not started"
    end
    local parts = {}
    if meta.order then
      parts[#parts + 1] = "lesson " .. meta.order
    end
    if meta.level then
      parts[#parts + 1] = meta.level
    end
    parts[#parts + 1] = progress
    parts[#parts + 1] = ":Org tutor " .. name
    items[#items + 1] = {
      value = name,
      label = M.title(name),
      desc = table.concat(parts, " · "),
    }
  end
  return require("org.ui").choose({ prompt = "Lesson: ", title = "org.nvim tutor", items = items })
end

--- `:Org tutor` without a lesson: pick one from the list, then open it.
---@param reset? boolean start the lesson picked over
---@return integer|nil bufnr
function M.start(reset)
  local name = M.pick()
  if not name then
    return nil
  end
  return M.open(name, reset)
end

--- `:Org tutor [lesson] [reset]`: without a lesson, the lesson list.
---@param args? string
function M.command(args)
  local name, reset
  for _, word in ipairs(vim.split(vim.trim(args or ""), "%s+", { trimempty = true })) do
    if word == "reset" then
      reset = true
    else
      name = word
    end
  end
  if not name then
    return M.start(reset)
  end
  return M.open(name, reset)
end

--- Completion of `:Org tutor`: the lessons, and `reset`.
---@return string[]
function M.complete()
  local out = M.lesson_names()
  out[#out + 1] = "reset"
  return out
end

return M
