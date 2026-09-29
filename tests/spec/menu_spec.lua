-- The Org menus (org-org-menu, org-tbl-menu, org-agenda-menu,
-- org-columns-menu, org-table-fedit-menu, orgtbl-mode-menu, org-clock-menu):
-- Neovim menus with Emacs's entries, added and removed with the buffer.
local config = require("org.config")
local menu = require("org.menu")

--- The menu `path` ({} when there is none).
local function get(path)
  local ok, m = pcall(vim.fn.menu_get, path)
  return ok and m or {}
end

local function names(path)
  local m = get(path)[1]
  return vim.tbl_map(function(s)
    return s.name
  end, m and m.submenus or {})
end

local function emenu(...)
  vim.cmd("emenu " .. table.concat(vim.tbl_map(menu.escape, { ... }), "."))
end

describe("menus", function()
  after_each(function()
    config.opts.ui.menus = true
    require("org.customize").menu_expanded = false
  end)

  it("adds the Org and Table menus in org buffers only", function()
    org_buffer({ "* H" })
    eq(1, #get("Org"))
    eq(1, #get("Table"))
    vim.cmd("enew!")
    eq(0, #get("Org"))
    eq(0, #get("Table"))
  end)

  it("has Emacs's entries in Emacs's order", function()
    org_buffer({ "* H" })
    -- org-org-menu (org.el)
    eq(
      {
        "Show/Hide",
        "-sep",
        "New Heading",
        "Navigate Headings",
        "Edit Structure",
        "Editing",
        "Archive",
        "-sep",
        "Hyperlinks",
        "-sep",
        "TODO Lists",
        "Tags and Properties",
        "Dates and Scheduling",
        "Logging work",
        "-sep",
        "Agenda Command...",
        "Set Restriction Lock",
        "File List for Agenda",
        "Special Views Current File",
        "-sep",
        "Export/Publish...",
        "LaTeX",
        "-sep",
        "Documentation",
        "Customize",
        "Send Bug Report",
        "-sep",
        "Restart/Reload",
      },
      vim.tbl_map(function(n)
        return n:match("^%-sep%d+%-$") and "-sep" or n
      end, names("Org"))
    )
    eq(
      { "Up", "Next", "Previous", "Next Same Level", "Previous Same Level", "-sep", "Jump" },
      vim.tbl_map(function(n)
        return n:match("^%-sep") and "-sep" or n
      end, names("Org.Navigate Headings"))
    )
    -- org-tbl-menu
    local tbl = vim.tbl_filter(function(n)
      return not n:match("^%-sep")
    end, names("Table"))
    eq({
      "Align",
      "Next Field",
      "Previous Field",
      "Next Row",
      "Blank Field",
      "Edit Field",
      "Copy Field from Above",
      "Column",
      "Row",
      "Rectangle",
      "Calculate",
      "Debug Formulas",
      "Show Column/Row Numbers",
      "Create",
      "Convert Region",
      "Import from File",
      "Export to File",
      "Create/Convert 'table.el' Table",
      "Plot",
    }, tbl)
  end)

  it("shows the keys of the actions", function()
    org_buffer({ "* H" })
    local items = vim.fn.menu_get("Org.Navigate Headings")[1].submenus
    eq("Up", items[1].name)
    eq(config.lhs_list(config.opts.mappings.org.goto_parent)[1], items[1].actext)
  end)

  it("runs the action of an entry", function()
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    emenu("Org", "Edit Structure", "Demote Heading")
    eq({ "** A", "* B" }, buf_lines(buf))
    emenu("Org", "Navigate Headings", "Next")
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("gives entries their prefix argument", function()
    -- C-u C-c *: the whole table, not only the row at the cursor
    local buf = org_buffer({ "| 1 |   |", "| 2 |   |", "#+TBLFM: $2=$1*3" }, { 1, 2 })
    emenu("Table", "Calculate", "Recalculate Line")
    eq({ "| 1 | 3 |", "| 2 |   |" }, vim.list_slice(buf_lines(buf), 1, 2))
    emenu("Table", "Calculate", "Recalculate All")
    eq({ "| 1 | 3 |", "| 2 | 6 |" }, vim.list_slice(buf_lines(buf), 1, 2))
  end)

  it("refuses an entry greyed out at the cursor", function()
    local buf = org_buffer({ "text", "* A" }, { 1, 0 })
    local warned
    local notify = vim.notify
    vim.notify = function(msg)
      warned = msg
    end
    emenu("Org", "Edit Structure", "Move Subtree Down")
    vim.notify = notify
    eq({ "text", "* A" }, buf_lines(buf))
    ok(warned and warned:find("not available"), warned)
    -- and disables it before a popup
    local shown
    local popup = menu._popup
    menu._popup = function(root)
      shown = root
    end
    menu.popup("Org")
    menu._popup = popup
    eq("Org", shown)
    eq(false, vim.fn.menu_info("Org.Edit Structure.Move Subtree Down", "n").enabled)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    menu.update("Org")
    eq(true, vim.fn.menu_info("Org.Edit Structure.Move Subtree Down", "n").enabled)
  end)

  it("lists the agenda files in File List for Agenda", function()
    local path = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "* T" }, path)
    local saved = config.opts.agenda_files
    config.opts.agenda_files = { path }
    org_buffer({ "* H" })
    menu.sync(true)
    local files = names("Org.File List for Agenda")
    config.opts.agenda_files = saved
    eq("Edit File List", files[1])
    local label = vim.fn.fnamemodify(vim.fs.normalize(vim.fn.resolve(path)), ":~")
    ok(vim.tbl_contains(files, label) or vim.tbl_contains(files, vim.fn.fnamemodify(path, ":~")), vim.inspect(files))
    emenu("Org", "File List for Agenda", files[#files])
    eq("* T", vim.api.nvim_get_current_line())
    vim.fn.delete(path)
  end)

  it("is off with ui.menus = false", function()
    config.opts.ui.menus = false
    org_buffer({ "* H" })
    eq(0, #get("Org"))
    config.opts.ui.menus = true
    menu.sync()
    eq(1, #get("Org"))
  end)

  it("adds OrgTbl where orgtbl-mode is on", function()
    vim.cmd("enew!")
    vim.bo.bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "| a | b |" })
    require("org.table.orgtbl").enable(0)
    menu.sync()
    eq(1, #get("OrgTbl"))
    eq("Create or convert", names("OrgTbl")[1])
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    emenu("OrgTbl", "Row", "Insert Row")
    -- org-shiftmetadown: org-table-insert-row, above the row
    eq({ "|   |   |", "| a | b |" }, buf_lines(0))
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    emenu("OrgTbl", "Column", "Delete Column")
    eq({ "|   |", "| b |" }, buf_lines(0))
    require("org.table.orgtbl").disable(0)
    menu.sync()
    eq(0, #get("OrgTbl"))
  end)

  it("adds Edit-Formulas in the formula editor", function()
    org_buffer({ "| 1 | 2 |", "#+TBLFM: $2=$1*2" }, { 1, 2 })
    require("org.table").edit_formulas()
    eq("orgformulas", vim.bo.filetype)
    menu.sync()
    eq(1, #get("Edit-Formulas"))
    eq({ "Finish and Install", "Finish, Install, and Apply", "Abort" }, vim.list_slice(names("Edit-Formulas"), 1, 3))
    emenu("Edit-Formulas", "Abort")
    vim.api.nvim_feedkeys("", "x", false)
    ok(vim.bo.filetype ~= "orgformulas")
  end)

  it("adds Column with the overlay column view", function()
    org_buffer({ "* A", ":PROPERTIES:", ":X: 1", ":END:" }, { 1, 0 })
    require("org.columns").open()
    eq(1, #get("Column"))
    eq("Edit property", names("Column")[1])
    emenu("Column", "Quit")
    vim.api.nvim_feedkeys("", "x", false)
    vim.wait(50, function()
      return #get("Column") == 0
    end)
    eq(0, #get("Column"))
  end)

  it("adds the Agenda menu in the agenda", function()
    require("org.agenda").command("a")
    eq("orgagenda", vim.bo.filetype)
    menu.sync()
    eq("Agenda Files", names("Agenda")[1])
    local views = names("Agenda.View")
    eq("Day View", views[1])
    emenu("Agenda", "View", "Day View")
    eq("day", require("org.agenda.view").state.span)
    require("org.agenda.view").quit(true)
  end)

  it("pops up the clock menu (org-clock-menu)", function()
    local shown
    local popup = menu._popup
    menu._popup = function(root)
      shown = root
    end
    require("org.actions").run("clock_menu")
    menu._popup = popup
    eq("]OrgClock", shown)
    eq({ "Clock out", "Change effort estimate", "Go to clock entry", "Switch task" }, names("]OrgClock"))
  end)

  it("expands the Customize menu (org-create-customize-menu)", function()
    org_buffer({ "* H" })
    local sub = names("Org.Customize")
    eq({ "Browse Org Group", "Expand This Menu" }, { sub[1], sub[3] })
    require("org.actions").run("customize_menu")
    sub = names("Org.Customize")
    eq("Browse Org group", sub[1])
    eq("Org", sub[3])
    ok(vim.tbl_contains(names("Org.Customize.Org"), "deadline_warning_days"))
    ok(vim.tbl_contains(names("Org.Customize.Org.agenda"), "span"))
  end)
end)
