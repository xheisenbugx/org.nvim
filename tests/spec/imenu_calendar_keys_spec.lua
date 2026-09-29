-- org-imenu-depth (the imenu index in the location list, gO), the Org keys
-- of the calendar (org-calendar-to-agenda-key,
-- org-calendar-insert-diary-entry-key, org-calendar-goto-agenda) and the
-- citation key under the mouse (org-cite-basic-mouse-over-key-face).
local config = require("org.config")
local date = require("org.date")

local function stub(tbl, name, value)
  local old = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = old
  end
end

describe("imenu (org-imenu-depth)", function()
  after_each(function()
    config.opts.ui.imenu_depth = 2
    pcall(vim.cmd, "lclose")
  end)

  local lines = {
    "* TODO [#A] One :tag:",
    "** Two [[https://x.org][link]] [1/2]",
    "*** Three",
    "** COMMENT Four",
    "* Five",
    "** ",
  }

  it("lists the headlines down to imenu_depth levels", function()
    -- Emacs 9.8.10 (org-imenu-get-tree, probes/13-menus-mouse/p4.el):
    -- depth 2: One, Two link [1/2], Four, Five; depth 3 adds Three
    org_buffer(lines)
    local function texts()
      return vim.tbl_map(function(e)
        return e.text
      end, require("org.goto").imenu_index(0))
    end
    eq({ "One", "Two link [1/2]", "Four", "Five" }, texts())
    config.opts.ui.imenu_depth = 3
    eq({ "One", "Two link [1/2]", "Three", "Four", "Five" }, texts())
  end)

  it("uses reduced levels with odd levels only", function()
    -- Emacs 9.8.10: A, B (level 3 = 2)
    org_buffer({ "#+STARTUP: odd", "* A", "*** B", "***** C" })
    eq(
      { "A", "B" },
      vim.tbl_map(function(e)
        return e.text
      end, require("org.goto").imenu_index(0))
    )
  end)

  it("opens the location list (gO)", function()
    local buf = org_buffer(lines)
    eq("gO", config.opts.mappings.org.imenu)
    require("org.actions").run("imenu")
    local list = vim.fn.getloclist(0)
    if #list == 0 then
      vim.cmd("wincmd p")
      list = vim.fn.getloclist(0)
    end
    eq({ "One", "  Two link [1/2]", "  Four", "Five" }, vim.tbl_map(function(e)
      return e.text
    end, list))
    eq({ 1, 2, 4, 5 }, vim.tbl_map(function(e)
      return e.lnum
    end, list))
    eq(buf, list[1].bufnr)
  end)
end)

describe("calendar keys", function()
  local function with_keys(keys, fn)
    local restore = stub(vim.fn, "getcharstr", function()
      return table.remove(keys, 1) or "\27"
    end)
    local ok, res = pcall(fn)
    restore()
    assert(ok, res)
    return res
  end

  after_each(function()
    config.opts.calendar_to_agenda_key = "default"
    config.opts.agenda.diary_entry_file = config.defaults.agenda.diary_entry_file
    pcall(function()
      require("org.agenda.view").quit(true)
    end)
  end)

  it("shows the agenda of the calendar's date with c (org-calendar-goto-agenda)", function()
    -- Emacs 9.8.10: c on 2026-10-07 shows the week from Monday 5 October
    local opened
    local restore = stub(require("org.agenda"), "open_agenda", function(opts)
      opened = opts
    end)
    org_buffer({ "<2026-10-07 Wed>" }, { 1, 3 })
    with_keys({ "c" }, function()
      require("org.timestamps").goto_calendar()
    end)
    restore()
    eq(date.parse("<2026-10-05 Mon>"):days(), opened.anchor)
  end)

  it("uses calendar_to_agenda_key, or none", function()
    eq({ agenda = "c" }, require("org.calendar").calendar_keys())
    config.opts.calendar_to_agenda_key = "<C-a>"
    eq(vim.keycode("<C-a>"), require("org.calendar").calendar_keys().agenda)
    config.opts.calendar_to_agenda_key = false
    eq(nil, require("org.calendar").calendar_keys().agenda)
    -- date prompts don't have the keys
    config.opts.calendar_to_agenda_key = "default"
    local called = false
    local restore = stub(require("org.calendar"), "goto_agenda", function()
      called = true
    end)
    local picked = with_keys({ "c", "\r" }, function()
      return require("org.calendar").pick({ default = date.parse("<2026-10-07 Wed>") })
    end)
    restore()
    eq(false, called)
    eq("2026-10-07", picked:to_date_string())
  end)

  it("adds a diary entry for the date with i when the diary is an Org file", function()
    local path = vim.fn.tempname() .. ".org"
    config.opts.agenda.diary_entry_file = path
    eq("i", require("org.calendar").calendar_keys().diary)
    org_buffer({ "<2026-10-07 Wed>" }, { 1, 3 })
    local r1 = stub(require("org.utils"), "getchar", function()
      return "d"
    end)
    local r2 = stub(require("org.utils"), "input", function()
      return "Dentist"
    end)
    with_keys({ "i" }, function()
      require("org.timestamps").goto_calendar()
    end)
    r1()
    r2()
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false), "\n")
    ok(text:find("Dentist", 1, true), text)
    ok(text:find("<2026-10-07 Wed>", 1, true), text)
    pcall(vim.cmd, "bwipeout! " .. vim.fn.bufnr(path))
    vim.fn.delete(path)
  end)
end)

describe("citation key under the mouse", function()
  local getmousepos = vim.fn.getmousepos
  after_each(function()
    vim.fn.getmousepos = getmousepos
    config.opts.export.cite.basic_mouse_over_key_face = "highlight"
  end)

  local function marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, require("org.cite_mouse").ns, 0, -1, { details = true })
  end

  it("highlights the key under the mouse (org-cite-basic-mouse-over-key-face)", function()
    eq("highlight", config.defaults.export.cite.basic_mouse_over_key_face)
    local buf = org_buffer({ "See [cite:@doe2020; @roe] here." })
    local win = vim.api.nvim_get_current_win()
    local cm = require("org.cite_mouse")
    vim.fn.getmousepos = function()
      return { winid = win, line = 1, column = 13 }
    end
    cm.on_move()
    local m = marks(buf)
    eq(1, #m)
    -- the "@" included, like org-cite-key-boundaries
    eq({ 0, 10 }, { m[1][2], m[1][3] })
    eq(18, m[1][4].end_col)
    eq("OrgCiteMouseOver", m[1][4].hl_group)
    -- off the key: cleared
    vim.fn.getmousepos = function()
      return { winid = win, line = 1, column = 2 }
    end
    cm.on_move()
    eq(0, #marks(buf))
    -- off with false
    config.opts.export.cite.basic_mouse_over_key_face = false
    vim.fn.getmousepos = function()
      return { winid = win, line = 1, column = 13 }
    end
    cm.on_move()
    eq(0, #marks(buf))
  end)

  it("maps <MouseMove> and turns mousemoveevent on", function()
    local buf = org_buffer({ "x" })
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      found = found or m.lhs == "<MouseMove>"
    end
    ok(found)
    eq(true, vim.o.mousemoveevent)
  end)
end)
