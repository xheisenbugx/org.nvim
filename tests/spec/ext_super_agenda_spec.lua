local date = require("org.date")
local utils = require("org.utils")

local today = date.today()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/sa.org"
local work = dir .. "/work.org"

local LINES = {
  "#+CATEGORY: home",
  "* TODO [#A] Pay bills :money:",
  "  DEADLINE: " .. ts(-1),
  "* TODO Standup :work:",
  "  SCHEDULED: " .. ts(0, "09:00"),
  "* NEXT [#B] Groceries :errand:",
  "  SCHEDULED: " .. ts(0),
  "  :PROPERTIES:",
  "  :Effort: 0:30",
  "  :agenda-group: Chores",
  "  :END:",
  "* TODO Someday idea :someday:",
  "  SCHEDULED: " .. ts(0),
  "* Parent",
  "** WAITING [#C] Child task",
  "   DEADLINE: " .. ts(0),
  "** TODO Brush teeth",
  "   SCHEDULED: " .. ts(0, "+1d"),
  "   :PROPERTIES:",
  "   :STYLE: habit",
  "   :END:",
}

local current = LINES

local function write_files()
  utils.writefile(path, current)
  utils.writefile(work, { "#+CATEGORY: job", "* TODO Report :work:", "  DEADLINE: " .. ts(3), "  Mentions budget" })
  for _, p in ipairs({ path, work }) do
    local b = utils.find_buffer(p)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
end

local function setup(ext, extra)
  write_files()
  require("org").setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { path, work },
    todo_keywords = { "TODO NEXT WAITING | DONE" },
    agenda = { time_grid = { enabled = false } },
    extensions = ext and { super_agenda = ext } or nil,
  }, extra or {}))
end

local function view_lines(spec)
  if spec then
    require("org.agenda").open(spec)
  else
    require("org.agenda").open_agenda({ span = "day" })
  end
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- Section name -> item titles, from M.group over the TODO list items.
local function grouped(groups)
  local items = require("org.agenda.items").todo(require("org.files").agenda_files(), nil, {})
  local out = {}
  for _, s in ipairs(require("org.extensions.super_agenda").group(items, groups)) do
    if #s.items > 0 then
      out[#out + 1] = {
        s.name,
        vim.tbl_map(function(it)
          return it.title
        end, s.items),
      }
    end
  end
  return out
end

local function restore()
  current = LINES
  require("org").setup({
    org_directory = vim.fn.getcwd() .. "/tests/fixtures",
    agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
  })
end

describe("super_agenda extension", function()
  after_each(restore)

  it("leaves the agenda unchanged when off or without groups", function()
    setup(nil)
    local plain_day = view_lines()
    local plain_todo = view_lines({ type = "todo" })
    setup({})
    eq(plain_day, view_lines())
    eq(plain_todo, view_lines({ type = "todo" }))
    setup({ groups = { { name = "X", anything = true } } })
    setup(false)
    eq(plain_day, view_lines())
    setup({ enabled = false, groups = { { name = "X", anything = true } } })
    eq(plain_todo, view_lines({ type = "todo" }))
  end)

  describe("selectors", function()
    before_each(function()
      setup({})
    end)
    it("puts each item in the first group it matches, then Other items", function()
      eq({
        { "Important", { "Pay bills" } },
        { "Work", { "Standup", "Report" } },
        { "Other items", { "Groceries", "Someday idea", "Child task", "Brush teeth" } },
      }, grouped({
        { name = "Important", priority = "A" },
        { name = "Work", tag = "work", priority = "A" },
      }))
    end)
    it("todo, tag, category, priority comparisons", function()
      eq({ { "Waiting", { "Child task" } } }, vim.list_slice(grouped({ { name = "Waiting", todo = "WAITING" } }), 1, 1))
      eq({ "Groceries", "Child task" }, grouped({ { name = "P", ["priority<="] = "B" } })[1][2])
      eq({ "Pay bills" }, grouped({ { name = "P", ["priority>"] = "B" } })[1][2])
      eq({ "Pay bills", "Groceries" }, grouped({ { name = "P", priority_ge = "B" } })[1][2])
      eq({ "Child task" }, grouped({ { name = "P", ["priority<"] = "B" } })[1][2])
      eq({ "Report" }, grouped({ { name = "C", category = "job" } })[1][2])
      -- selectors of a group are ORed; tags match case-insensitively
      local g = grouped({ { name = "T", tag = { "errand", "WORK" }, todo = "NEXT" } })
      eq({ "Standup", "Groceries", "Report" }, g[1][2])
      eq("Items categorized as: job", grouped({ { category = "job" } })[1][1])
      eq("Tags: work", grouped({ { tag = "work" } })[1][1])
    end)
    it("planning dates", function()
      eq({ "Pay bills" }, grouped({ { name = "D", deadline = "past" } })[1][2])
      eq({ "Child task" }, grouped({ { name = "D", deadline = "today" } })[1][2])
      eq({ "Report" }, grouped({ { name = "D", deadline = "future" } })[1][2])
      eq({ "Pay bills", "Child task", "Report" }, grouped({ { name = "D", deadline = true } })[1][2])
      eq({ "Report" }, grouped({ { name = "D", deadline = { "after", today:add(1, "d"):to_date_string() } } })[1][2])
      local s = grouped({ { name = "S", scheduled = "today" } })
      eq({ "Standup", "Groceries", "Someday idea", "Brush teeth" }, s[1][2])
      eq("Past due", grouped({ { deadline = "past" } })[1][1])
      eq({ "Pay bills", "Child task", "Report" }, grouped({ { name = "N", scheduled = false } })[1][2])
    end)
    it("effort, property, regexp, habit, children and pred", function()
      eq({ "Groceries" }, grouped({ { name = "E", ["effort<"] = "1:00" } })[1][2])
      eq({ "Groceries" }, grouped({ { name = "E", effort_gt = "0:30" } })[1][2])
      eq("Other items", grouped({ { name = "E", effort_gt = "1:00" } })[1][1])
      eq({ "Groceries" }, grouped({ { name = "P", property = "agenda-group" } })[1][2])
      eq({ "Groceries" }, grouped({ { name = "P", property = { "Effort", "0:30" } } })[1][2])
      eq({ "Report" }, grouped({ { name = "R", regexp = "budget" } })[1][2])
      eq({ "Standup" }, grouped({ { name = "H", heading_regexp = "^stand" } })[1][2])
      eq({ "Report" }, grouped({ { name = "F", file_path = "work\\.org$" } })[1][2])
      eq({ "Brush teeth" }, grouped({ { name = "H", habit = true } })[1][2])
      eq({ "Report" }, grouped({ {
        name = "P",
        pred = function(it)
          return it.title == "Report"
        end,
      } })[1][2])
    end)
    it(":and, :not, :discard, :take and :anything", function()
      eq({ "Report" }, grouped({ { name = "A", ["and"] = { tag = "work", deadline = true } } })[1][2])
      eq({ "Pay bills", "Groceries", "Someday idea", "Child task", "Brush teeth" }, grouped({
        { name = "N", ["not"] = { tag = "work" } },
      })[1][2])
      eq({
        { "All", { "Pay bills", "Standup", "Groceries", "Child task", "Brush teeth", "Report" } },
      }, grouped({ { discard = { tag = "someday" } }, { name = "All", anything = true } }))
      eq({ "Standup" }, grouped({ { name = "One", take = { 1, { tag = "work" } } } })[1][2])
      eq({ "Report" }, grouped({ { take = { -1, { tag = "work" } } } })[1][2])
      eq("Last 1 Tags: work", grouped({ { take = { -1, { tag = "work" } } } })[1][1])
    end)
    it("orders groups by :order, then by name among equal non-zero orders", function()
      eq({ "A", "B", "Other items", "Z" }, vim.tbl_map(function(s)
        return s[1]
      end, grouped({
        { name = "Z", tag = "work", order = 100 },
        { name = "B", priority = "A", order = 1 },
        { name = "A", priority = "B", order = 1 },
      })))
    end)
    it("accepts Emacs-style plists", function()
      eq({ "Pay bills" }, grouped({ { ":name", "Imp", ":priority", "A" } })[1][2])
      eq({ "Groceries" }, grouped({ { ":name", "E", ":effort<", "1:00" } })[1][2])
    end)
  end)

  describe("auto groups", function()
    before_each(function()
      setup({})
    end)
    local function names(groups)
      return vim.tbl_map(function(s)
        return s[1]
      end, grouped(groups))
    end
    it("groups by category, todo, priority, tags and properties", function()
      eq({ "Category: home", "Category: job" }, names({ { auto_category = true } }))
      eq({ "To-do: NEXT", "To-do: TODO", "To-do: WAITING" }, names({ { auto_todo = true } }))
      eq({ "Priority: A", "Priority: B", "Priority: C", "Other items" }, names({ { auto_priority = true } }))
      eq(
        { "Tags: errand", "Tags: money", "Tags: someday", "Tags: work", "Other items" },
        names({ { auto_tags = true } })
      )
      eq({ "Effort: 0:30", "Other items" }, names({ { auto_property = "Effort" } }))
      eq({ "Group: Chores", "Other items" }, names({ { auto_group = true } }))
      eq({ "Parent", "Other items" }, names({ { auto_parent = true } }))
      eq({ "Parent", "Top-level headings" }, names({ { auto_outline_path = true } }))
      eq({ "Directory: " .. vim.fn.fnamemodify(dir, ":t") }, names({ { auto_dir_name = true } }))
      eq({ "long", "short" }, names({ {
        auto_map = function(it)
          return #it.title > 9 and "long" or "short"
        end,
      } }))
    end)
    it("groups by planning date in date order", function()
      local g = grouped({ { auto_planning = true } })
      eq(vim.trim(today:add(-1, "d"):strftime("%e %B %Y")), g[1][1])
      eq({ "Pay bills" }, g[1][2])
      eq(vim.trim(today:strftime("%e %B %Y")), g[2][1])
      eq(vim.trim(today:add(3, "d"):strftime("%e %B %Y")), g[3][1])
    end)
    it("keeps earlier groups first and leaves unmatched items", function()
      eq({
        { "Urgent", { "Pay bills" } },
        { "Category: home", { "Standup", "Groceries", "Someday idea", "Child task", "Brush teeth" } },
        { "Category: job", { "Report" } },
      }, grouped({ { name = "Urgent", priority = "A" }, { auto_category = true } }))
    end)
    it("groups by an ancestor with a keyword", function()
      current = vim.deepcopy(LINES)
      current[14] = "* PROJ Parent"
      setup({}, { todo_keywords = { "TODO NEXT WAITING PROJ | DONE" } })
      local g = grouped({ { ancestor_with_todo = "PROJ" } })
      eq({ "Ancestor PROJ: Parent", { "Child task", "Brush teeth" } }, g[1])
      eq("Nearest PROJ: Parent", grouped({ { ancestor_with_todo = { "PROJ", nearest = true } } })[1][1])
    end)
  end)

  describe("rendering", function()
    it("renders group headers inside each agenda day", function()
      setup({
        groups = {
          { name = "Timed", time_grid = true },
          { name = "Due", deadline = true },
          { discard = { tag = "someday" } },
        },
      })
      local lines = view_lines()
      -- group headers and item titles, in buffer order
      local body = {}
      local view = require("org.agenda.view")
      for i, l in ipairs(lines) do
        local it = view.state.line_items[i]
        if it then
          body[#body + 1] = it.title
        elseif l:match("^ %S") then
          body[#body + 1] = l:sub(2)
        end
      end
      -- Report's deadline warning shows today; items keep the agenda's order
      eq(
        { "Timed", "Standup", "Due", "Pay bills", "Report", "Child task", "Other items", "Groceries", "Brush teeth" },
        body
      )
      local blank_before = {}
      for i, l in ipairs(lines) do
        if l == " Timed" or l == " Due" then
          blank_before[#blank_before + 1] = lines[i - 1]
        end
      end
      eq({ "", "" }, blank_before)
    end)
    it("puts time grid lines in the :time_grid group", function()
      setup(
        { groups = { { name = "Timed", time_grid = true } } },
        { agenda = { time_grid = { enabled = true, type = { "daily" }, times = { 1200 } } } }
      )
      local lines = view_lines()
      local timed, grid, other
      for i, l in ipairs(lines) do
        if l == " Timed" then
          timed = i
        elseif l == " Other items" then
          other = i
        elseif l:find("12:00", 1, true) then
          grid = i
        end
      end
      ok(timed and grid and other, table.concat(lines, "\n"))
      ok(timed < grid and grid < other, table.concat(lines, "\n"))
    end)
    it("keeps agenda keys working on grouped items", function()
      setup({ groups = { { name = "Due", deadline = true } } })
      view_lines()
      local view = require("org.agenda.view")
      local target
      for l, it in pairs(view.state.line_items) do
        if it.title == "Pay bills" then
          target = l
        end
      end
      ok(target)
      vim.api.nvim_win_set_cursor(0, { target, 0 })
      view.actions.todo_next()
      local src = vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
      ok(src[2]:find("^%* NEXT %[#A%] Pay bills"), src[2])
    end)
    it("uses a block's super_groups, a separator character, face and transformer", function()
      setup({ header_separator = "=", groups = { { name = "never", anything = true } } })
      local lines = view_lines({
        type = "todo",
        super_groups = {
          {
            name = "Work",
            tag = "work",
            face = "ErrorMsg",
            transformer = function(line)
              return line .. " !"
            end,
          },
          { name = "none", anything = true },
        },
      })
      local text = table.concat(lines, "\n")
      ok(not text:find("never", 1, true))
      ok(text:find("\n===+\n Work\n", 1, false), text)
      ok(text:find("Standup[^\n]* !\n"), text)
      ok(not text:find(" none", 1, true))
      local view = require("org.agenda.view")
      local buf = vim.api.nvim_get_current_buf()
      local found = false
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "ErrorMsg" then
          found = true
        end
      end
      ok(found)
      local _ = view
    end)
    it("groups org-ql views too", function()
      setup({}, { extensions = { ql = {} } })
      local lines = view_lines({ type = "ql", query = "(todo)", super_groups = { { auto_category = true } } })
      local text = table.concat(lines, "\n")
      ok(text:find(" Category: home", 1, true))
      ok(text:find(" Category: job", 1, true))
    end)
  end)
end)
