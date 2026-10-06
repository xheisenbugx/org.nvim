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
--- `1.2`. Their checks live in `lua/org/tutor/lessons/<lesson>.lua`, keyed
--- by that number: a condition, or a list of conditions that must all
--- hold, evaluated on the parse of the buffer (`org.files`) within the
--- exercise's subtree. A ✓ or ✗ (`ui.tutor_marks`) at the end of the
--- exercise's headline shows the result, updated as the buffer changes.

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
---@field fn? fun(ctx: org.tutor.Context): boolean

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

--- Lesson names, sorted.
---@return string[]
function M.lesson_names()
  local names = vim.tbl_keys(M.lessons())
  table.sort(names)
  return names
end

--- The checks of a lesson (`org.tutor.lessons.<name>`), {} when it has none.
---@param name string
---@return org.tutor.Checks
function M.checks(name)
  local ok, checks = pcall(require, "org.tutor.lessons." .. name)
  return ok and type(checks) == "table" and checks or {}
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

--- Replace the `{{...}}` placeholders of the lesson text.
---@param lines string[]
---@return string[]
function M.render(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:gsub("{{([%w_%.]+)}}", function(ref)
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
  end
  return out
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
    hl = nil
    for _, h in ipairs(descendants(ctx.file, ctx.exercise)) do
      if h:plain_title() == c.heading then
        hl = h
        break
      end
    end
    if not hl then
      return false
    end
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

---------------------------------------------------------------------------
-- Marks
---------------------------------------------------------------------------

--- Attached buffers: bufnr -> { checks, timer }
local state = {}

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
    if conds and results[id] == nil then
      local pass = M.check(buf, file, hl, conds)
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
function M.attach(buf, checks)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  require("org.highlights").ensure()
  detach(buf)
  local st = { checks = checks }
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
  M.refresh(buf)
end

--- Whether `buf` shows marks.
---@param buf integer
---@return boolean
function M.attached(buf)
  return state[buf] ~= nil
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
  M.attach(buf, M.checks(name))
  if not fresh then
    utils.notify(("Tutor %q resumed; `:Org tutor %s reset` starts it over"):format(name, name))
  end
  return buf
end

--- `:Org tutor [lesson] [reset]`.
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
