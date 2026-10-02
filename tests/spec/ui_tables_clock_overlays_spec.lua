-- UI sweep: tables, clock overlays, custom times and special windows.

--- Screen text of row `r` (1-based), trailing blanks trimmed.
local function screen_row(r)
  local s = {}
  for c = 1, vim.o.columns do
    s[#s + 1] = vim.fn.screenstring(r, c)
  end
  return (table.concat(s):gsub("%s+$", ""))
end

--- Display column (1-based) where `needle` starts on screen row `r`.
local function screen_col(r, needle)
  local row = screen_row(r)
  local b = row:find(needle, 1, true)
  return b and vim.fn.strdisplaywidth(row:sub(1, b - 1)) + 1 or nil
end

--- Run `fn` with the editor resized to `cols` x `lines`, then restore it.
local function with_size(cols, lines, fn)
  local c, l = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = cols, lines
  local ok_, err = pcall(fn)
  vim.o.columns, vim.o.lines = c, l
  if not ok_ then
    error(err, 0)
  end
end

describe("special window float", function()
  it("is refitted and recentred on VimResized", function()
    with_size(80, 30, function()
      org_buffer({ "* A", "#+begin_src text", "x = 1", "#+end_src" }, { 3, 0 })
      require("org.context").edit_special()
      local win = vim.api.nvim_get_current_win()
      eq("editor", vim.api.nvim_win_get_config(win).relative)
      vim.o.columns, vim.o.lines = 50, 20
      vim.cmd("doautocmd VimResized")
      eq(40, vim.api.nvim_win_get_width(win))
      eq(14, vim.api.nvim_win_get_height(win))
      local cfg = vim.api.nvim_win_get_config(win)
      eq(5, cfg.col)
      vim.o.columns, vim.o.lines = 160, 40
      vim.cmd("doautocmd VimResized")
      eq(128, vim.api.nvim_win_get_width(win))
      eq(16, vim.api.nvim_win_get_config(win).col)
      vim.api.nvim_win_close(win, true)
    end)
  end)
end)

describe("table alignment on the displayed width", function()
  local function align(lines)
    local buf = org_buffer(lines, { 1, 2 })
    require("org.table").align()
    return buf_lines(buf)
  end

  describe("with hidden emphasis markers", function()
    with_config({ ui = vim.tbl_extend("force", require("org.config").opts.ui, { hide_emphasis_markers = true }) })

    -- Emacs 9.8.10, org-hide-emphasis-markers t: org-table-align measures
    -- with org-string-width, which skips the invisible markers
    it("doesn't count the markers", function()
      eq({ "| *bold* | x |", "| ab   | y |" }, align({ "| *bold* | x |", "| ab | y |" }))
    end)

    it("lines the bars up on screen", function()
      align({ "| *bold* | x |", "| ab | y |", "" })
      vim.wo.foldenable = false
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.cmd("redraw!")
      eq(screen_row(2):find("|", 2, true), screen_row(1):find("|", 2, true))
    end)
  end)

  describe("with pretty entities", function()
    with_config({ ui = vim.tbl_extend("force", require("org.config").opts.ui, { pretty_entities = true }) })

    -- Emacs 9.8.10, org-pretty-entities t: "\alpha x" displays as "α x"
    it("counts an entity as its character", function()
      eq({ "| \\alpha x | z |", "| ab  | y |" }, align({ "| \\alpha x | z |", "| ab | y |" }))
    end)

    it("doesn't count the script marks and braces", function()
      eq({ "| a_{ij} | z |", "| ab  | y |" }, align({ "| a_{ij} | z |", "| ab | y |" }))
    end)
  end)

  it("counts markers and entities when they are shown", function()
    eq({ "| *bold* | x |", "| ab     | y |" }, align({ "| *bold* | x |", "| ab | y |" }))
    eq({ "| \\alpha x | z |", "| ab       | y |" }, align({ "| \\alpha x | z |", "| ab | y |" }))
  end)

  -- Emacs 9.8.10: org-toggle-link-display, then org-table-align
  it("counts the whole link after toggle_link_display", function()
    local buf = org_buffer({ "| [[https://example.com][ex]] | z |", "| ab | y |" }, { 1, 2 })
    require("org.links").toggle_link_display()
    require("org.table").align()
    eq("| ab                          | y |", buf_lines(buf)[2])
    require("org.links").toggle_link_display()
    require("org.table").align()
    eq("| ab | y |", buf_lines(buf)[2])
  end)

  it("puts the C-c } column labels over the displayed fields", function()
    with_size(60, 10, function()
      org_buffer({ "text", "| [[https://example.com][Ex]] | b | c |", "| x | yyy | z |" }, { 3, 2 })
      require("org.table").align()
      require("org.table").toggle_coordinate_overlays()
      vim.wo.foldenable = false
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("redraw!")
      local labels, first = screen_row(2), screen_row(3)
      local n = 0
      for p in first:gmatch("()|") do
        n = n + 1
        if n <= 3 then
          eq("$" .. n, labels:sub(p + 2, p + 3), first .. " / " .. labels)
        end
      end
      require("org.table").toggle_coordinate_overlays()
    end)
  end)
end)

describe("clock display (C-c C-x C-d)", function()
  local CLOCK = "CLOCK: [2026-03-01 Sun 10:00]--[2026-03-01 Sun 11:30] =>  1:30"

  local function display()
    local utils = require("org.utils")
    local notify = utils.notify
    utils.notify = function() end
    local ok_, err = pcall(require("org.clock").toggle_display, 0, "untilnow")
    utils.notify = notify
    assert(ok_, err)
  end

  -- org-clock-put-overlay puts the overlay on the heading line, which stays
  -- visible when the subtree is folded
  it("shows the sums on folded headlines, before the ellipsis", function()
    with_size(80, 12, function()
      org_buffer({
        "* Project",
        CLOCK,
        "* Other",
        "CLOCK: [2026-03-01 Sun 12:00]--[2026-03-01 Sun 12:45] =>  0:45",
      })
      require("org.fold").overview()
      display()
      vim.cmd("redraw!")
      eq(1, vim.fn.foldclosed(1))
      eq("* Project" .. string.rep("·", 51) .. "      1:30 ...", screen_row(1))
      eq("* Other" .. string.rep("·", 53) .. "      0:45 ...", screen_row(2))
      vim.cmd("normal! zR")
      vim.cmd("redraw!")
      eq("* Project" .. string.rep("·", 51) .. "      1:30", screen_row(1))
      require("org.clock").remove_overlays(0)
    end)
  end)

  -- the dots fill up to column 60 measured on the displayed title
  -- (org-string-width), and the overlay hides the tags
  it("lines the sums up on headlines with links and tags", function()
    with_size(80, 12, function()
      org_buffer({
        "* Plain task",
        CLOCK,
        "* Read [[https://example.com/a/very/long/path/to/doc][doc]]",
        CLOCK,
        "* TODO Tagged                                                 :work:home:",
        CLOCK,
      })
      vim.wo.conceallevel = 2
      vim.wo.foldenable = false
      display()
      vim.cmd("redraw!")
      eq(64, screen_col(1, "   1:30"))
      eq(64, screen_col(3, "   1:30"))
      eq(64, screen_col(5, "   1:30"), screen_row(5))
      eq("* TODO Tagged" .. string.rep("·", 47) .. "      1:30", screen_row(5))
      require("org.clock").remove_overlays(0)
      vim.cmd("redraw!")
      ok(screen_row(5):find(":work:home:$"), screen_row(5))
    end)
  end)
end)

describe("shrunk table columns", function()
  -- Emacs 9.8.10 org-table-shrink: the field is cut at its visible width,
  -- so a link shows as its description
  it("show a link as its description", function()
    with_size(60, 10, function()
      org_buffer({
        "| <4>                     | x |",
        "| [[https://a.com][Link]]  | y |",
        "| [[https://a.com][L]]     | z |",
        "",
        "text",
      }, { 5, 0 })
      require("org.table").shrink(0, 1)
      vim.cmd("redraw!")
      ok(vim.startswith(screen_row(2), "| Link…| y |"), screen_row(2))
      ok(vim.startswith(screen_row(3), "| L   …| z |"), screen_row(3))
    end)
  end)

  it("aren't drawn twice on the cursor line in Visual mode", function()
    with_size(60, 10, function()
      org_buffer({ "| <3>   | x |", "| abcdef | y |", "| ab     | z |" }, { 2, 2 })
      require("org.table").shrink(0, 1)
      vim.cmd("normal! v")
      vim.cmd("redraw!")
      local visual = screen_row(2)
      vim.cmd("normal! \27")
      vim.cmd("redraw!")
      -- the revealed line shows its field once, in full
      eq("| abcdef | y |", visual)
      eq("| abc…| y |", screen_row(2))
      eq("| ab …| z |", screen_row(3))
    end)
  end)
end)
