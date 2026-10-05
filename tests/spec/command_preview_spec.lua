-- Live previews of :Org subcommands while the command line is typed
-- ('inccommand', :h :command-preview).
local commands = require("org.commands")

local ns = vim.api.nvim_create_namespace("org.test.command_preview")

--- Highlights (extmarks) of `ns` in `buf`: { row0, col0, end_col, group }.
local function marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { m[2], m[3], m[4].end_col, m[4].hl_group }
  end
  return out
end

--- The text of each highlight of `ns` in `buf`.
local function marked_text(buf)
  local out = {}
  for _, m in ipairs(marks(buf)) do
    local line = vim.api.nvim_buf_get_lines(buf, m[1], m[1] + 1, false)[1]
    out[#out + 1] = vim.trim(line:sub(m[2] + 1, m[3]))
  end
  return out
end

--- Run the preview of `:Org <args>` as Neovim would.
local function preview(args, pbuf)
  -- Neovim clears the namespace between two previews
  vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
  return commands.preview({ args = args, fargs = vim.split(args, "%s+", { trimempty = true }) }, ns, pbuf)
end

local function clear_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_clear_namespace, b, ns, 0, -1)
    end
  end
end

local TABLE = {
  "| a | b | c |",
  "|---+---+---|",
  "| 1 | 2 |   |",
  "| 3 | 4 |   |",
}

describe(":Org preview dispatch", function()
  after_each(clear_all)

  it("shows nothing for subcommands without a preview, or for none", function()
    org_buffer({ "* A" }, { 1, 0 })
    eq(0, preview(""))
    eq(0, preview("todo_next"))
    eq(0, preview("nonsense foo"))
  end)

  it("shows nothing when the preview function fails", function()
    commands.extra.test_preview = { "org.commands", "run", preview = "missing_fn", raw = true }
    org_buffer({ "* A" }, { 1, 0 })
    eq(0, preview("test_preview x"))
    commands.extra.test_preview = nil
  end)

  it("the :Org command has the preview callback", function()
    require("org.commands").setup()
    local cmd = vim.api.nvim_get_commands({}).Org
    ok(cmd ~= nil)
    -- Neovim reports whether a command has a preview callback since 0.10
    if cmd.preview ~= nil then
      ok(cmd.preview)
    end
  end)
end)

describe(":Org table_formula", function()
  after_each(clear_all)

  it("previews the column filled by a formula and the #+TBLFM line", function()
    local buf = org_buffer(TABLE, { 3, 10 })
    eq(1, preview("table_formula $1*$2"))
    eq({ "| a | b |  c |", "|---+---+----|", "| 1 | 2 |  2 |", "| 3 | 4 | 12 |", "#+TBLFM: $3=$1*$2" }, buf_lines(buf))
    eq({ "2", "12", "$3=$1*$2" }, marked_text(buf))
  end)

  it("fills the preview window's buffer with the new table (inccommand=split)", function()
    org_buffer(TABLE, { 3, 10 })
    local pbuf = vim.api.nvim_create_buf(false, true)
    eq(2, preview("table_formula $1+$2", pbuf))
    eq({ "| a | b | c |", "|---+---+---|", "| 1 | 2 | 3 |", "| 3 | 4 | 7 |", "#+TBLFM: $3=$1+$2" }, buf_lines(pbuf))
    eq({ "3", "7", "$3=$1+$2" }, marked_text(pbuf))
  end)

  it("shows nothing for a half-typed formula, a huge table or outside a table", function()
    local buf = org_buffer(TABLE, { 3, 10 })
    eq(0, preview("table_formula $1*"))
    eq(0, preview("table_formula "))
    eq(TABLE, buf_lines(buf))
    local table_mod = require("org.table")
    local max = table_mod.preview_max_fields
    table_mod.preview_max_fields = 5
    eq(0, preview("table_formula $1*$2"))
    table_mod.preview_max_fields = max
    org_buffer({ "* A", "text" }, { 2, 0 })
    eq(0, preview("table_formula $1*$2"))
  end)

  it("takes an explicit target: $N= and @R$C=", function()
    local buf = org_buffer(TABLE, { 3, 2 })
    eq(1, preview("table_formula @3$3=$1-$2"))
    eq({ "| 3 | 4 | -1 |", "#+TBLFM: @3$3=$1-$2" }, { buf_lines(buf)[4], buf_lines(buf)[5] })
  end)

  it("running it stores the formula and fills the column", function()
    local buf = org_buffer(TABLE, { 3, 10 })
    vim.cmd("Org table_formula $1*$2")
    eq({ "| a | b |  c |", "|---+---+----|", "| 1 | 2 |  2 |", "| 3 | 4 | 12 |", "#+TBLFM: $3=$1*$2" }, buf_lines(buf))
    -- an existing formula is replaced, an empty one removed
    vim.cmd("Org table_formula $1+$2")
    eq({ "| 3 | 4 | 7 |", "#+TBLFM: $3=$1+$2" }, { buf_lines(buf)[4], buf_lines(buf)[5] })
    vim.cmd("Org table_formula $3=")
    eq("#+TBLFM:", vim.trim(buf_lines(buf)[5]))
  end)

  it("without a formula asks for it like C-c =", function()
    local buf = org_buffer(TABLE, { 3, 10 })
    local utils = require("org.utils")
    local input = utils.input
    utils.input = function()
      return "$1*$2"
    end
    local okc, err = pcall(vim.cmd, "Org table_formula")
    utils.input = input
    ok(okc, err)
    -- C-c = computes the current field only
    eq({ "| 1 | 2 | 2 |", "| 3 | 4 |   |", "#+TBLFM: $3=$1*$2" }, vim.list_slice(buf_lines(buf), 3, 5))
  end)
end)

local DOC = {
  "* TODO Alpha :work:",
  "Some text about pears.",
  "* Beta :home:",
  "Apples and pears.",
  "* TODO Gamma :work:urgent:",
}

describe(":Org occur and :Org tags_sparse_tree", function()
  after_each(clear_all)

  it("previews regexp matches as they are typed", function()
    local buf = org_buffer(DOC, { 1, 0 })
    eq(1, preview("occur pe"))
    eq({ "pe", "pe" }, marked_text(buf))
    eq(1, preview("occur pears\\."))
    eq({ "pears.", "pears." }, marked_text(buf))
    eq(DOC, buf_lines(buf))
  end)

  it("keeps the spaces of the regexp", function()
    local buf = org_buffer(DOC, { 1, 0 })
    eq(0, preview("occur and  pears"))
    eq({}, marked_text(buf))
    eq(1, preview("occur and pears"))
    eq({ "and pears" }, marked_text(buf))
  end)

  it("shows nothing for an invalid regexp and lists matches in the split", function()
    local buf = org_buffer(DOC, { 1, 0 })
    eq(0, preview("occur \\("))
    eq({}, marks(buf))
    local pbuf = vim.api.nvim_create_buf(false, true)
    eq(2, preview("occur pears", pbuf))
    eq({ "|2| Some text about pears.", "|4| Apples and pears." }, buf_lines(pbuf))
    eq({ "pears", "pears" }, marked_text(pbuf))
  end)

  it("previews the headlines of a tags/property match", function()
    local buf = org_buffer(DOC, { 1, 0 })
    eq(1, preview("tags_sparse_tree work"))
    eq({ "* TODO Alpha :work:", "* TODO Gamma :work:urgent:" }, marked_text(buf))
    eq(1, preview("tags_sparse_tree work+urgent"))
    eq({ "* TODO Gamma :work:urgent:" }, marked_text(buf))
    -- half typed: nothing
    eq(0, preview('tags_sparse_tree work+PRIO="'))
    eq({}, marks(buf))
  end)

  it("running them builds the sparse tree", function()
    org_buffer(DOC, { 1, 0 })
    vim.cmd("Org occur Apples")
    local loc = vim.fn.getloclist(0)
    eq(1, #loc)
    eq(4, loc[1].lnum)
    vim.cmd("Org tags_sparse_tree home")
    loc = vim.fn.getloclist(0)
    eq(1, #loc)
    eq(3, loc[1].lnum)
  end)
end)

-- Neovim draws the preview and undoes it at once, so the buffer never
-- shows it to the API: these tests read the screen of a child Neovim.
describe(":Org previews typed on the command line", function()
  local Screen = require("tests.screen")
  local screen

  after_each(function()
    if screen then
      screen:close()
      screen = nil
    end
  end)

  local LINES = "return vim.api.nvim_buf_get_lines(0, 0, -1, false)"

  --- The screen's rows as plain text, trailing blanks dropped.
  local function rows()
    -- a round trip lets the child's pending redraw arrive
    screen:request("nvim_eval", "1")
    local out = {}
    for line in screen:render():gmatch("[^\n]+") do
      local row = line:match("^|(.*)|$")
      if row then
        out[#out + 1] = (row:gsub("{%d+:(.-)}", "%1"):gsub("%s+$", ""))
      end
    end
    return out
  end

  --- Wait until `pred(rows)` holds; fail with the screen otherwise.
  local function wait_screen(pred)
    local r
    vim.wait(5000, function()
      r = rows()
      return pred(r)
    end, 20)
    ok(pred(r), table.concat(r, "\n"))
    return r
  end

  local function has(text)
    return function(r)
      return vim.tbl_contains(r, text)
    end
  end

  local function lacks(text)
    return function(r)
      return not vim.tbl_contains(r, text)
    end
  end

  local FILLED = { "| a | b |  c |", "|---+---+----|", "| 1 | 2 |  2 |", "| 3 | 4 | 12 |", "#+TBLFM: $3=$1*$2" }
  local UNDO = "local u = vim.fn.undotree() return { u.seq_last, u.seq_cur }"

  it("previews a table formula per keystroke; <Esc> leaves nothing behind", function()
    screen = Screen.new({ width = 60, height = 10 })
    screen:org(TABLE, { cursor = { 3, 10 } })
    screen:cmd("set inccommand=nosplit")
    local undo = screen:lua(UNDO)
    screen:input(":Org table_formula $1+")
    -- half typed: nothing changes
    wait_screen(has(":Org table_formula $1+"))
    wait_screen(has("| 1 | 2 |   |"))
    screen:input("$2")
    wait_screen(has("| 3 | 4 | 7 |"))
    wait_screen(has("#+TBLFM: $3=$1+$2"))
    screen:input("<BS><BS><BS>*$2")
    wait_screen(has("| 3 | 4 | 12 |"))
    eq(TABLE, screen:lua(LINES))
    screen:input("<Esc>")
    wait_screen(lacks("#+TBLFM: $3=$1*$2"))
    eq(TABLE, screen:lua(LINES))
    eq(false, screen:lua("return vim.bo.modified"))
    eq(undo, screen:lua(UNDO))
    -- running it gives the real result, which one undo takes back
    screen:input(":Org table_formula $1*$2<CR>")
    vim.wait(5000, function()
      return vim.deep_equal(FILLED, screen:lua(LINES))
    end, 10)
    eq(FILLED, screen:lua(LINES))
    screen:input("u")
    vim.wait(5000, function()
      return vim.deep_equal(TABLE, screen:lua(LINES))
    end, 10)
    eq(TABLE, screen:lua(LINES))
  end)

  it("lists the matches in the preview window with inccommand=split", function()
    screen = Screen.new({ width = 60, height = 16 })
    screen:org(DOC, { cursor = { 1, 0 } })
    screen:cmd("set inccommand=split")
    screen:input(":Org occur pears")
    wait_screen(has("|2| Some text about pears."))
    wait_screen(has("|4| Apples and pears."))
    screen:input("<Esc>")
    wait_screen(lacks("|4| Apples and pears."))
    eq(1, #screen:lua("return vim.api.nvim_list_wins()"))
    eq(DOC, screen:lua(LINES))
  end)

  it("shows nothing with inccommand off", function()
    screen = Screen.new({ width = 60, height = 10 })
    screen:org(TABLE, { cursor = { 3, 10 } })
    screen:cmd("set inccommand=")
    screen:input(":Org table_formula $1*$2")
    local r = wait_screen(has(":Org table_formula $1*$2"))
    ok(not vim.tbl_contains(r, "#+TBLFM: $3=$1*$2"))
    screen:input("<Esc>")
  end)
end)

describe(":Org agenda_filter_regexp", function()
  local config = require("org.config")
  local utils = require("org.utils")
  local view = require("org.agenda.view")
  local agenda = require("org.agenda")
  local date = require("org.date")

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/f.org"
  local stamp = "<" .. date.today():to_string({ brackets = false }) .. ">"

  local function open()
    utils.writefile(path, {
      "* TODO Alpha :work:",
      "  SCHEDULED: " .. stamp,
      "* TODO Beta plot :home:",
      "  SCHEDULED: " .. stamp,
      "* TODO Gamma plot twist",
      "  SCHEDULED: " .. stamp,
    })
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({ agenda_files = { path }, org_directory = dir })
    config.opts.clock.persist = false
    agenda.open_agenda({ span = "day" })
  end

  local function shown()
    local out = {}
    for _, it in pairs(view.state.line_items) do
      out[#out + 1] = it.title
    end
    table.sort(out)
    return out
  end

  --- Titles of the agenda items whose line the preview dims.
  local function dimmed()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
      if m[4].hl_group == "OrgAgendaDimmed" then
        out[#out + 1] = view.state.line_items[m[2] + 1].title
      end
    end
    table.sort(out)
    return out
  end

  after_each(function()
    clear_all()
    pcall(view.quit, true)
  end)

  it("previews the entries a regexp filter hides, or with - keeps", function()
    open()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    eq(1, preview("agenda_filter_regexp plot"))
    eq({ "Alpha" }, dimmed())
    -- the match is highlighted in the entries that stay
    eq(2, #vim.tbl_filter(function(m)
      return m[4] == "OrgCommandPreview"
    end, marks(0)))
    eq(1, preview("agenda_filter_regexp pl\\(o\\|a\\)t tw"))
    eq({ "Alpha", "Beta plot" }, dimmed())
    eq(1, preview("agenda_filter_regexp -plot"))
    eq({ "Beta plot", "Gamma plot twist" }, dimmed())
    -- half typed or invalid: nothing
    eq(0, preview("agenda_filter_regexp \\("))
    eq(0, preview("agenda_filter_regexp -"))
    eq(lines, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    eq({ "Alpha", "Beta plot", "Gamma plot twist" }, shown())
  end)

  it("lists the entries that stay in the preview window", function()
    open()
    local pbuf = vim.api.nvim_create_buf(false, true)
    eq(2, preview("agenda_filter_regexp twist", pbuf))
    local out = buf_lines(pbuf)
    eq(1, #out)
    ok(out[1]:find("Gamma plot twist", 1, true))
  end)

  it("running it filters the agenda; outside an agenda it reports an error", function()
    open()
    vim.cmd("Org agenda_filter_regexp plot")
    eq({ "Beta plot", "Gamma plot twist" }, shown())
    vim.cmd("Org agenda_filter_regexp -twist")
    eq({ "Beta plot" }, shown())
    pcall(view.quit, true)
    org_buffer({ "* A" }, { 1, 0 })
    eq(0, preview("agenda_filter_regexp plot"))
  end)
end)
