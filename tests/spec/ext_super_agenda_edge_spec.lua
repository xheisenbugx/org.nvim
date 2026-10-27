-- Edge cases of the super_agenda extension: empty agendas, no agenda
-- files, unicode, many groups, malformed groups and options, narrow
-- windows.
local date = require("org.date")
local utils = require("org.utils")
local sa = require("org.extensions.super_agenda")

local today = date.today()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/edge.org"

local LINES = {
  "#+CATEGORY: 日本",
  "* TODO [#A] Réunion équipe :Équipe:",
  "  SCHEDULED: " .. ts(0, "09:00"),
  "* TODO 買い物 🛒 :家事:",
  "  SCHEDULED: " .. ts(0),
  "* NEXT Plain task",
  "  DEADLINE: " .. ts(0),
}

local function wipe_agendas()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "orgagenda" then
      local win = vim.fn.bufwinid(b)
      if win ~= -1 then
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
      end
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
end

local function write(lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  require("org.files").invalidate(path)
  utils.writefile(path, lines or LINES)
end

local function setup(ext, files)
  require("org").setup({
    org_directory = dir,
    agenda_files = files or { path },
    todo_keywords = { "TODO NEXT | DONE" },
    agenda = { time_grid = { enabled = false } },
    extensions = { super_agenda = ext },
  })
end

local function view_lines(spec)
  require("org.agenda").open(spec or { type = "todo" })
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function has(lines, s)
  for _, l in ipairs(lines) do
    if l:find(s, 1, true) then
      return true
    end
  end
  return false
end

--- Section name -> item titles of M.group over the TODO list.
local function grouped(groups)
  local items = require("org.agenda.items").todo(require("org.files").agenda_files(), nil, {})
  local out = {}
  for _, s in ipairs(sa.group(items, groups)) do
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
  wipe_agendas()
  require("org").setup({
    org_directory = vim.fn.getcwd() .. "/tests/fixtures",
    agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
  })
end

describe("super_agenda edge cases", function()
  before_each(function()
    write()
  end)
  after_each(restore)

  it("leaves an empty agenda as it is", function()
    write({ "* Nothing to do here" })
    setup({ groups = { { name = "Work", tag = "work" } } })
    local grouped_lines = view_lines()
    setup({})
    eq(view_lines(), grouped_lines)
    ok(not has(grouped_lines, "Other items"))
  end)

  it("draws the agenda without agenda files", function()
    setup({ groups = { { name = "Work", tag = "work" } } }, {})
    local lines = view_lines()
    ok(#lines > 0)
    ok(not has(lines, "Work"))
    ok(not has(lines, "super_agenda:"))
    eq({}, sa.group({}, { { name = "Work", tag = "work" } })[1].items)
  end)

  it("groups an empty list of items", function()
    setup({})
    local secs = sa.group({}, { { name = "A", todo = true }, { auto_category = true } })
    -- the plain group and the unmatched one, both empty; no auto sections
    eq(
      { "A", "Other items" },
      vim.tbl_map(function(s)
        return s.name
      end, secs)
    )
    for _, s in ipairs(secs) do
      eq({}, s.items)
    end
  end)

  it("matches tags with unicode letters in any case", function()
    setup({})
    -- org-super-agenda compares tags with cl-equalp: case-insensitive
    eq(
      { { "Team", { "Réunion équipe" } }, { "Other items", { "買い物 🛒", "Plain task" } } },
      grouped({
        { name = "Team", tag = "équipe" },
      })
    )
    eq(
      { { "Chores", { "買い物 🛒" } }, { "Other items", { "Réunion équipe", "Plain task" } } },
      grouped({
        { name = "Chores", tag = "家事" },
      })
    )
  end)

  it("matches unicode headings and categories and names auto groups after them", function()
    setup({})
    eq(
      { { "Cart", { "買い物 🛒" } }, { "Other items", { "Réunion équipe", "Plain task" } } },
      grouped({
        { name = "Cart", heading_regexp = "🛒" },
      })
    )
    eq(
      { { "Category: 日本", { "Réunion équipe", "買い物 🛒", "Plain task" } } },
      grouped({
        { auto_category = true },
      })
    )
  end)

  it("renders unicode group names and folds them", function()
    setup({ groups = { { name = "Équipe ✓ 日本", tag = "Équipe" } } })
    local lines = view_lines()
    local row
    for i, l in ipairs(lines) do
      if l == " Équipe ✓ 日本" then
        row = i
      end
    end
    ok(row, table.concat(lines, "\n"))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    eq(true, sa.toggle_group())
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    ok(has(lines, " Équipe ✓ 日本 … (1)"), table.concat(lines, "\n"))
    ok(not has(lines, "Réunion équipe"))
    eq(true, sa.toggle_group())
  end)

  it("handles many groups, one item each and most of them empty", function()
    local groups = {}
    for i = 1, 300 do
      groups[#groups + 1] = { name = ("G%03d"):format(i), heading_regexp = "no match " .. i }
    end
    groups[#groups + 1] = { name = "Plain", heading_regexp = "Plain" }
    setup({ groups = groups })
    local secs = grouped(groups)
    eq({ { "Plain", { "Plain task" } }, { "Other items", { "Réunion équipe", "買い物 🛒" } } }, secs)
    local lines = view_lines()
    ok(has(lines, " Plain"))
    ok(not has(lines, "G001"))
  end)

  it("keeps the order of groups with equal orders by name, and a stable order otherwise", function()
    setup({})
    eq(
      { "a", "b", "c" },
      vim.tbl_map(
        function(s)
          return s[1]
        end,
        grouped({
          { name = "c", heading_regexp = "Réunion", order = 1 },
          { name = "b", heading_regexp = "買い物", order = 1 },
          { name = "a", todo = "NEXT", order = 1 },
        })
      )
    )
  end)

  it("treats an order that is not a number as 0", function()
    setup({})
    local items = {}
    for i = 1, 30 do
      items[i] = { title = "t" .. i, todo = i % 2 == 0 and "TODO" or nil, tags = {}, priority = nil }
    end
    -- a string order among numbers must not break the sort
    local secs = sa.group(items, {
      { name = "Two", todo = "TODO", order = 2 },
      { name = "Str", todo = true, order = "x" },
      { name = "One", anything = true, order = 1 },
    })
    eq(
      { "Str", "One", "Two", "Other items" },
      vim.tbl_map(function(s)
        return s.name
      end, secs)
    )
  end)

  it("reports a malformed group in the agenda instead of failing", function()
    for _, groups in ipairs({
      { "Work" },
      { { name = "Bad", nonsense = true } },
      { { name = "Bad date", deadline = { "before", "not a date" } } },
      { { name = "Bad effort", effort_lt = "lots" } },
      { { take = "x" } },
      { { name = "Bad date sel", date = "tomorrow" } },
    }) do
      setup({ groups = groups })
      local lines = view_lines()
      ok(has(lines, "super_agenda:"), vim.inspect(groups) .. "\n" .. table.concat(lines, "\n"))
      -- the items are still listed, ungrouped
      ok(has(lines, "Plain task"), table.concat(lines, "\n"))
      wipe_agendas()
    end
  end)

  it("reports an invalid group through :checkhealth", function()
    local res = {}
    local h = {
      ok = function(m)
        res[#res + 1] = "ok " .. m
      end,
      error = function(m)
        res[#res + 1] = "error " .. m
      end,
    }
    sa.health(h, { groups = { { nonsense = 1 } } })
    sa.health(h, {})
    sa.health(h, { groups = "not a list" })
    eq("error super_agenda groups: super_agenda: unknown selector nonsense", res[1])
    eq("ok super_agenda: 0 group(s)", res[2])
    eq('error super_agenda: groups must be a list of groups, not "not a list"', res[3])
  end)

  it("ignores groups given as a single table instead of a list", function()
    setup({ groups = { name = "Work", tag = "work" } })
    local lines = view_lines()
    ok(has(lines, "Plain task"))
    ok(not has(lines, "super_agenda:"))
  end)

  it("accepts a group name that is not a string", function()
    setup({ groups = { { name = 42, todo = "NEXT" }, { name = { "list" }, todo = "TODO" } } })
    local lines = view_lines()
    ok(has(lines, " 42"), table.concat(lines, "\n"))
    ok(has(lines, "Plain task"))
    ok(has(lines, "買い物"))
  end)

  it("draws a group without a header for name false, none or empty", function()
    setup({
      groups = {
        { name = false, todo = "NEXT", order = 1 },
        { name = "none", heading_regexp = "Réunion", order = 2 },
        { name = "", heading_regexp = "買い物", order = 3 },
      },
    })
    local lines = view_lines()
    ok(not has(lines, "Other items"))
    ok(has(lines, "Plain task") and has(lines, "Réunion équipe") and has(lines, "買い物"))
    ok(not has(lines, " none"))
  end)

  it("takes the first or last n items with odd counts", function()
    setup({})
    -- the items the group takes beyond n are dropped, as upstream
    eq({}, grouped({ { take = { 0, { todo = true } } } }))
    eq(
      { { "Last 9 Any TODO keyword", { "Réunion équipe", "買い物 🛒", "Plain task" } } },
      grouped({ { take = { -9, { todo = true } } } })
    )
    eq(
      { { "First 1 TODO items", { "Réunion équipe" } }, { "Other items", { "Plain task" } } },
      grouped({ { take = { "1", { todo = "TODO" } } } })
    )
  end)

  it("fills a narrow agenda window with the separator and no more", function()
    setup({ groups = { { name = "Équipe", tag = "Équipe" } }, header_separator = "─" })
    view_lines()
    local agenda_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vnew")
    vim.api.nvim_win_set_width(agenda_win, 12)
    require("org.agenda.view").refresh()
    vim.api.nvim_set_current_win(agenda_win)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local sep
    for _, l in ipairs(lines) do
      if l ~= "" and l:gsub("─", "") == "" then
        sep = l
      end
    end
    ok(sep, table.concat(lines, "\n"))
    -- at least 10 characters even in a tiny window
    ok(vim.fn.strchars(sep) >= 10)
    ok(vim.fn.strchars(sep) <= math.max(vim.api.nvim_win_get_width(0), 10))
    vim.cmd("silent! only")
  end)

  it("takes odd header options without failing", function()
    setup({
      groups = { { name = "Équipe", tag = "Équipe" } },
      header_separator = "",
      header_prefix = "",
      final_group_separator = "== end ==\n",
      unmatched_name = "Ünmatched ✓",
    })
    local lines = view_lines()
    ok(has(lines, "Équipe"))
    ok(has(lines, "Ünmatched ✓"))
    ok(has(lines, "== end =="))
  end)

  it("leaves the agenda keys alone with header_keys = false", function()
    setup({ groups = { { name = "Équipe", tag = "Équipe" } }, header_keys = false })
    view_lines()
    eq(nil, vim.b.org_super_agenda_keys)
  end)

  it("moves between headers at the ends of the buffer without failing", function()
    setup({ groups = { { name = "Équipe", tag = "Équipe" } } })
    view_lines()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    sa.goto_header(-1)
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { last, 0 })
    sa.goto_header(1)
    eq(last, vim.api.nvim_win_get_cursor(0)[1])
    -- not on a header: toggle says so, so the key falls back
    eq(false, sa.toggle_group())
  end)

  it("survives a transformer that errors or returns something else", function()
    setup({
      groups = {
        {
          name = "T",
          todo = "TODO",
          transformer = function(line)
            if line:find("Réunion", 1, true) then
              error("boom")
            end
            return 42
          end,
        },
        {
          name = "U",
          todo = "NEXT",
          transformer = function(line)
            return "→ " .. line .. " ✓"
          end,
        },
      },
    })
    local lines = view_lines()
    ok(has(lines, "Réunion équipe"))
    ok(has(lines, "買い物"))
    ok(has(lines, "→ "), table.concat(lines, "\n"))
    ok(has(lines, "Plain task ✓"))
  end)

  it("puts items whose auto key is missing under the unmatched group", function()
    setup({})
    eq(
      { { "Other items", { "Réunion équipe", "買い物 🛒", "Plain task" } } },
      grouped({
        { auto_property = "nope" },
        { auto_group = true },
        {
          auto_map = function()
            error("boom")
          end,
        },
      })
    )
  end)
end)
