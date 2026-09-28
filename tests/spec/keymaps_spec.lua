-- End-to-end: drive real buffer-local keymaps with feedkeys.
local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

describe("keymaps e2e", function()
  -- written for this setup rather than the Emacs defaults
  with_config({ todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" }, log_done = "time", log_into_drawer = "LOGBOOK" })
  it("cit cycles TODO keyword", function()
    local buf = org_buffer({ "* Task" }, { 1, 0 })
    keys("cit")
    eq("* TODO Task", buf_lines(buf)[1])
    keys("cit")
    eq("* NEXT Task", buf_lines(buf)[1])
  end)
  it("a count before <C-c><C-t> picks the Nth keyword", function()
    local buf = org_buffer({ "* Task" }, { 1, 0 })
    keys("2<C-c><C-t>")
    eq("* NEXT Task", buf_lines(buf)[1])
  end)
  it("<C-S-Up> shifts both CLOCK timestamps", function()
    local buf = org_buffer({ "* A", "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:30] =>  1:30" }, { 2, 17 })
    keys("<C-S-Up>")
    eq("CLOCK: [2026-09-24 Thu 10:00]--[2026-09-24 Thu 11:30] =>  1:30", buf_lines(buf)[2])
  end)
  it(">> and << promote/demote headings", function()
    local buf = org_buffer({ "* A", "** B" }, { 2, 0 })
    keys(">>")
    eq("*** B", buf_lines(buf)[2])
    keys("<<")
    eq("** B", buf_lines(buf)[2])
  end)
  it(">> falls back to indent on plain text", function()
    local buf = org_buffer({ "text" }, { 1, 0 })
    vim.bo[buf].shiftwidth = 2
    keys(">>")
    eq("  text", buf_lines(buf)[1])
  end)
  it("<C-Space> toggles checkbox", function()
    local buf = org_buffer({ "* H", "- [ ] item" }, { 2, 0 })
    keys("<C-Space>")
    eq("- [X] item", buf_lines(buf)[2])
  end)
  it("<C-a> increments the date under the cursor", function()
    local buf = org_buffer({ "* H", "<2026-09-23 Wed>" }, { 2, 9 })
    keys("<C-a>")
    eq("<2026-09-24 Thu>", buf_lines(buf)[2])
  end)
  it("<C-a> still increments numbers elsewhere", function()
    local buf = org_buffer({ "x 5" }, { 1, 0 })
    keys("<C-a>")
    eq("x 6", buf_lines(buf)[1])
  end)
  it("<S-Down>/<S-Up> removing a priority does not scroll", function()
    local lines = { "* TODO [#C] Low", "* TODO [#A] High" }
    for i = 1, 200 do
      lines[#lines + 1] = "line " .. i
    end
    local buf = org_buffer(lines, { 1, 0 })
    keys("<S-Down>")
    eq("* TODO Low", buf_lines(buf)[1])
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    eq(1, vim.fn.line("w0"))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    keys("<S-Up>")
    eq("* TODO High", buf_lines(buf)[2])
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    eq(1, vim.fn.line("w0"))
  end)
  it("<C-c><C-c> aligns a table", function()
    local buf = org_buffer({ "|a|bb|", "|-", "|ccc|d|" }, { 1, 1 })
    keys("<C-c><C-c>")
    eq({ "| a   | bb |", "|-----+----|", "| ccc | d  |" }, buf_lines(buf))
  end)
  it("<M-CR> on a list item adds an item", function()
    vim.g.org_test = true
    local buf = org_buffer({ "- one" }, { 1, 3 })
    keys("<M-CR>")
    vim.cmd("stopinsert")
    eq("- one", buf_lines(buf)[1])
    eq("- ", buf_lines(buf)[2])
  end)
  it("text typed after Normal-mode <M-CR> goes after the bullet", function()
    local buf = org_buffer({ "- one" }, { 1, 0 })
    keys("<M-CR>two<Esc>")
    eq("- two", buf_lines(buf)[2])
    buf = org_buffer({ "* One" }, { 1, 2 })
    keys("<M-CR>Two<Esc>")
    eq("* Two", buf_lines(buf)[2])
  end)
  it("text typed after Normal-mode <M-S-CR> goes after the checkbox or keyword", function()
    local buf = org_buffer({ "- [ ] one" }, { 1, 0 })
    keys("<M-S-CR>two<Esc>")
    eq("- [ ] two", buf_lines(buf)[2])
    buf = org_buffer({ "* TODO One" }, { 1, 2 })
    keys("<M-S-CR>Two<Esc>")
    eq("* TODO Two", buf_lines(buf)[2])
  end)
  it("<Tab> cycles heading folds", function()
    org_buffer({ "* A", "text", "** B", "more" }, { 1, 0 })
    vim.cmd("normal! zX")
    keys("<Tab>")
    ok(vim.fn.foldclosed(2) == -1 or vim.fn.foldclosed(1) ~= -1)
  end)
end)

describe("alt+arrow keys", function()
  local function keys(k)
    vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
  end
  it("<M-Right>/<M-Left> demote and promote a heading", function()
    local buf = org_buffer({ "* A", "** B :tag:" }, { 2, 0 })
    keys("<M-Right>")
    eq("*** B", buf_lines(buf)[2]:sub(1, 5))
    keys("<M-Left>")
    keys("<M-Left>")
    eq("* B", buf_lines(buf)[2]:sub(1, 3))
    ok(buf_lines(buf)[2]:match(":tag:$"), "tags stay aligned")
  end)
  it("<M-Right> indents a list item", function()
    local buf = org_buffer({ "- one", "- two" }, { 2, 0 })
    keys("<M-Right>")
    eq("  - two", buf_lines(buf)[2])
  end)
  it("<M-Right> moves a table column", function()
    local buf = org_buffer({ "| a | b |" }, { 1, 2 })
    keys("<M-Right>")
    eq("| b | a |", buf_lines(buf)[1])
  end)
  it("<M-Down>/<M-Up> move a table row", function()
    local buf = org_buffer({ "| a |", "| b |", "| c |" }, { 1, 2 })
    keys("<M-Down>")
    eq({ "| b |", "| a |", "| c |" }, buf_lines(buf))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    keys("<M-Up>")
    eq({ "| a |", "| b |", "| c |" }, buf_lines(buf))
  end)
  it("<M-Down> moves a list item", function()
    local buf = org_buffer({ "- one", "- two" }, { 1, 0 })
    keys("<M-Down>")
    eq({ "- two", "- one" }, buf_lines(buf))
  end)
end)

describe("g? help", function()
  local function help_lines()
    require("org.mappings").show_help()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.api.nvim_win_close(0, true)
    return lines
  end
  it("groups org keys by topic, one row per action", function()
    org_buffer({ "* A" }, { 1, 0 })
    local lines = help_lines()
    eq(" Anywhere", lines[1])
    ok(vim.tbl_contains(lines, " Visibility"))
    ok(vim.tbl_contains(lines, " Text objects"))
    local cancel = vim.tbl_filter(function(l)
      return l:match("Cancel clock$")
    end, lines)
    eq(1, #cancel)
    ok(cancel[1]:match("<leader>oxq  <C%-c><C%-x><C%-q>"), cancel[1])
  end)
  it("groups agenda keys", function()
    org_buffer({ "* A" }, { 1, 0 })
    vim.bo.filetype = "orgagenda"
    local lines = help_lines()
    eq(" Agenda buffer", lines[1])
    ok(vim.tbl_contains(lines, " Bulk"))
  end)
end)

describe("default keymaps", function()
  local config = require("org.config")

  --- Pairs where one lhs is a strict prefix of another in the same mode:
  --- the shorter one then only fires after 'timeoutlen', and typing the
  --- longer one quickly never reaches it.
  local function prefix_clashes(entries)
    local clashes = {}
    for _, a in ipairs(entries) do
      for _, b in ipairs(entries) do
        if a.mode == b.mode and #b.key > #a.key and b.key:sub(1, #a.key) == a.key then
          clashes[#clashes + 1] = string.format("%s: %s (%s) < %s (%s)", a.mode, a.lhs, a.name, b.lhs, b.name)
        end
      end
    end
    table.sort(clashes)
    return clashes
  end

  local function section_entries(sections)
    local entries = {}
    for _, sec in ipairs(sections) do
      for name, value in pairs(config.opts.mappings[sec] or {}) do
        for _, lhs in ipairs(config.lhs_list(value)) do
          entries[#entries + 1] = { mode = "n", key = vim.keycode(lhs), lhs = lhs, name = sec .. "." .. name }
        end
      end
    end
    return entries
  end

  --- The org keymaps active in the current buffer (global + buffer-local).
  local function org_buffer_entries()
    local entries = {}
    for _, mode in ipairs({ "n", "x", "o", "i" }) do
      local seen = {}
      local maps = vim.list_extend(vim.api.nvim_buf_get_keymap(0, mode), vim.api.nvim_get_keymap(mode))
      for _, m in ipairs(maps) do
        local key = vim.keycode(m.lhs)
        if m.desc and m.desc:match("^org: ") and not seen[key] then
          seen[key] = true
          entries[#entries + 1] = { mode = mode, key = key, lhs = m.lhs, name = m.desc }
        end
      end
    end
    return entries
  end

  it("no org buffer mapping is a prefix of another", function()
    org_buffer({ "* A" }, { 1, 0 })
    eq({}, prefix_clashes(org_buffer_entries()))
  end)
  it("todo_select and the table keys are both reachable", function()
    org_buffer({ "* A" }, { 1, 0 })
    eq("org: Select TODO state", vim.fn.maparg(config.lhs_list("<prefix>S")[1], "n", false, true).desc)
    eq("", vim.fn.maparg(config.lhs_list("<prefix>T")[1], "n"))
    eq("org: Create table / convert region", vim.fn.maparg(config.lhs_list("<prefix>Tc")[1], "n", false, true).desc)
  end)
  it("no capture buffer mapping is a prefix of another", function()
    org_buffer({ "* A" }, { 1, 0 })
    local entries = section_entries({ "capture" })
    for _, e in ipairs(org_buffer_entries()) do
      if e.mode == "n" then
        entries[#entries + 1] = e
      end
    end
    eq({}, prefix_clashes(entries))
  end)
  it("no agenda or edit_src mapping is a prefix of another", function()
    eq({}, prefix_clashes(section_entries({ "agenda" })))
    eq({}, prefix_clashes(section_entries({ "global", "emacs_global", "edit_src" })))
  end)
end)
