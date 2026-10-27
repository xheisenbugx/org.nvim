-- The sticky headline context (org.ui.context): a float over the top rows
-- of an org window listing the headlines its first line is under.
local context = require("org.ui.context")

--- A document whose entries are long enough to scroll past:
--- 1 "* One", 2 "** Two", 3 "*** Three", 4.. body, 40 "** Sibling", 41.. body,
--- 80 "* Four", 81.. body.
local function doc()
  local lines = { "* TODO [#A] One :work:", "** Two", "*** Three" }
  for i = 4, 39 do
    lines[i] = "Body " .. i
  end
  lines[40] = "** Sibling"
  for i = 41, 79 do
    lines[i] = "Text " .. i
  end
  lines[80] = "* Four"
  for i = 81, 120 do
    lines[i] = "More " .. i
  end
  return lines
end

--- Scroll the current window so `top` is its first line, cursor on
--- `cursor` (default a few lines below), and update the context.
local function scroll(top, cursor)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { cursor or (top + 5), 0 })
  vim.fn.winrestview({ topline = top })
  context.update(win, true)
  return win
end

local function float_lines(win)
  local f = context.float(win)
  if not f then
    return {}
  end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f), 0, -1, false)
end

describe("sticky headline context", function()
  local saved
  before_each(function()
    local ui = require("org.config").opts.ui
    saved = vim.deepcopy(ui.context)
    ui.context.line_numbers = false
    vim.cmd("silent! only")
  end)
  after_each(function()
    context.disable()
    require("org.config").opts.ui.context = saved
    vim.cmd("silent! only")
  end)

  it("is off by default", function()
    eq(false, require("org.config").opts.ui.context.enabled)
    org_buffer(doc(), { 1, 0 })
    scroll(10)
    eq(nil, context.float())
    eq({}, context.lines())
  end)

  it("shows the headlines above the first line on screen", function()
    org_buffer(doc(), { 1, 0 })
    context.enable()
    local win = scroll(10)
    eq({ 1, 2, 3 }, context.lines(win))
    eq({ "* TODO [#A] One :work:", "** Two", "*** Three" }, float_lines(win))
    local cfg = vim.api.nvim_win_get_config(context.float(win))
    eq("win", cfg.relative)
    eq(win, cfg.win)
    eq(3, cfg.height)
    eq(vim.api.nvim_win_get_width(win), cfg.width)
    eq(false, cfg.focusable)
  end)

  it("shows nothing while the top headline is on screen", function()
    org_buffer(doc(), { 1, 0 })
    context.enable()
    local win = scroll(1, 1)
    eq({}, context.lines(win))
    eq(nil, context.float(win))
    -- the headline on the first line goes into the context when the
    -- lines under the float are in its entry
    scroll(2, 10)
    eq({ 1, 2, 3 }, context.lines(win))
  end)

  it("goes by the line under the float: a sibling ends the context", function()
    org_buffer(doc(), { 1, 0 })
    context.enable()
    -- line 38 on top: 39 and 40 ("** Sibling") are under the float rows
    local win = scroll(37)
    eq({ 1 }, context.lines(win))
    scroll(42)
    eq({ 1, 40 }, context.lines(win))
    scroll(81)
    eq({ 80 }, context.lines(win))
  end)

  it("takes the headlines of the line under a full float", function()
    local lines = { "* A", "** B", "*** C" }
    for i = 4, 8 do
      lines[i] = "c" .. i
    end
    lines[9] = "**** D"
    for i = 10, 60 do
      lines[i] = "d" .. i
    end
    org_buffer(lines, { 1, 0 })
    context.enable()
    -- top line 7 is under A, B, C; the line under three rows (10) is
    -- also under D: the outermost goes
    local win = scroll(7, 20)
    eq({ 2, 3, 9 }, context.lines(win))
  end)

  it("drops the outermost headlines past max_lines, or the innermost", function()
    local o = require("org.config").opts.ui.context
    o.max_lines = 2
    org_buffer(doc(), { 1, 0 })
    context.enable()
    local win = scroll(10)
    eq({ 2, 3 }, context.lines(win))
    o.trim_scope = "inner"
    scroll(11)
    eq({ 1, 2 }, context.lines(win))
  end)

  it("counts a closed fold as one line", function()
    local lines = { "* A", "** B", "b1", "b2", "b3", "b4", "* D" }
    for i = 8, 60 do
      lines[i] = "d" .. i
    end
    org_buffer(lines, { 1, 0 })
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].foldenable = false
    context.enable()
    local function at_top()
      vim.api.nvim_win_set_cursor(win, { 20, 0 })
      vim.fn.winrestview({ topline = 3 })
      context.update(win, true)
      return context.lines(win)
    end
    -- under two rows of context: "b3", still in B
    eq({ 1, 2 }, at_top())
    -- with b2..b4 folded, the second row is the fold and "* D" comes next
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldenable = true
    vim.cmd("normal! zE")
    vim.cmd("4,6fold")
    eq({}, at_top())
  end)

  it("counts the screen lines of a wrapped line", function()
    local lines = { "* A", "** B", "b1", string.rep("word ", 40), "b2", "** C" }
    for i = 7, 60 do
      lines[i] = "c" .. i
    end
    org_buffer(lines, { 1, 0 })
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].foldenable = false
    vim.wo[win].wrap = true
    context.enable()
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.fn.winrestview({ topline = 4 })
    eq(4, vim.fn.line("w0"))
    ok(vim.api.nvim_win_text_height(win, { start_row = 3, end_row = 3 }).all >= 2)
    context.update(win, true)
    -- the wrapped line takes the rows under the float: still in B (one
    -- line a row, "** C" would come under two rows and end B)
    eq({ 1, 2 }, context.lines(win))
  end)

  it("gives each window its own context and closes it in other buffers", function()
    org_buffer(doc(), { 1, 0 })
    context.enable()
    local left = scroll(10)
    vim.cmd("vsplit")
    local right = scroll(85)
    eq({ 80 }, context.lines(right))
    eq({ 1, 2, 3 }, context.lines(left))
    ok(context.float(left) ~= context.float(right))
    vim.cmd("enew")
    context.update(right, true)
    eq(nil, context.float(right))
    eq({ 1, 2, 3 }, context.lines(left))
    vim.cmd("close")
    context.update_all(true)
    eq({ 1, 2, 3 }, context.lines(left))
  end)

  it("closes the float with its window", function()
    org_buffer(doc(), { 1, 0 })
    context.enable()
    scroll(10)
    vim.cmd("split")
    local win = scroll(12)
    local f = context.float(win)
    ok(f)
    vim.cmd("close")
    eq(false, vim.api.nvim_win_is_valid(f))
  end)

  it("follows edits of the context headlines", function()
    local buf = org_buffer(doc(), { 1, 0 })
    context.enable()
    local win = scroll(10)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "** Renamed" })
    context.update(win, true)
    eq({ "* TODO [#A] One :work:", "** Renamed", "*** Three" }, float_lines(win))
  end)

  it("puts the line numbers in the gutter", function()
    require("org.config").opts.ui.context.line_numbers = true
    org_buffer(doc(), { 1, 0 })
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].number = true
    vim.wo[win].numberwidth = 4
    context.enable()
    scroll(10)
    eq({ "  1 * TODO [#A] One :work:", "  2 ** Two", "  3 *** Three" }, float_lines(win))
    vim.wo[win].number = false
  end)

  it("copies the buffer's highlighting", function()
    org_buffer(doc(), { 1, 0 })
    context.enable()
    local win = scroll(10)
    local fbuf = vim.api.nvim_win_get_buf(context.float(win))
    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, -1, { 0, 0 }, { 0, -1 }, { details = true })) do
      if m[4].hl_group then
        groups[m[4].hl_group] = true
      end
    end
    ok(groups.OrgTodo, vim.inspect(groups))
    ok(groups.OrgTags, vim.inspect(groups))
    ok(groups.OrgPriorityA, vim.inspect(groups))
  end)

  it("copies bullets and concealed link markup", function()
    local ui = require("org.config").opts.ui
    local bullets = ui.bullets
    ui.bullets = { "◉", "○" }
    local okc, err = pcall(function()
      local lines = doc()
      lines[2] = "** See [[https://orgmode.org][docs]]"
      local buf = org_buffer(lines, { 1, 0 })
      require("org.ui.decorations").render(buf)
      require("org.ui.decorations").attach(buf)
      local win = vim.api.nvim_get_current_win()
      vim.wo[win].conceallevel = 2
      context.enable()
      scroll(10)
      local fbuf = vim.api.nvim_win_get_buf(context.float(win))
      local virt, conceal = {}, 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, -1, 0, -1, { details = true })) do
        if m[4].virt_text then
          virt[#virt + 1] = m[4].virt_text[#m[4].virt_text][1]
        end
        if m[4].conceal then
          conceal = conceal + 1
        end
      end
      ok(vim.tbl_contains(virt, "◉") and vim.tbl_contains(virt, "○"), vim.inspect(virt))
      ok(conceal >= 2, "conceal marks: " .. conceal)
      eq(2, vim.wo[context.float(win)].conceallevel)
    end)
    ui.bullets = bullets
    if not okc then
      error(err, 0)
    end
  end)

  it("leaves a buffer whose parse is out of date to a later parse", function()
    local buf = org_buffer(doc(), { 1, 0 })
    context.enable()
    local win = scroll(10)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "** Later" })
    context.update(win)
    eq("** Two", float_lines(win)[2])
    vim.wait(1000, function()
      return float_lines(win)[2] == "** Later"
    end)
    eq("** Later", float_lines(win)[2])
  end)

  it("toggles with context_toggle and goes to a headline with context_goto", function()
    org_buffer(doc(), { 1, 0 })
    local actions = require("org.actions").list
    eq(true, actions.context_toggle.global)
    eq(true, context.toggle())
    local win = scroll(10)
    eq({ 1, 2, 3 }, context.lines(win))
    context.goto_context()
    eq(3, vim.api.nvim_win_get_cursor(win)[1])
    eq(false, context.toggle())
    eq(nil, context.float(win))
    eq(false, context.goto_context())
  end)

  it("turns on from setup with ui.context.enabled", function()
    require("org.config").opts.ui.context.enabled = true
    context.setup()
    eq(true, context.enabled())
    require("org.config").opts.ui.context.enabled = false
    context.setup()
    eq(false, context.enabled())
  end)

  it("leaves org buffers to nvim-treesitter-context when it has an org parser", function()
    org_buffer(doc(), { 1, 0 })
    local add = vim.treesitter.language.add
    package.loaded["treesitter-context"] = {
      enabled = function()
        return true
      end,
    }
    vim.treesitter.language.add = function(lang)
      if lang == "org" then
        return true
      end
      return add(lang)
    end
    local okc, err = pcall(function()
      context.enable()
      local win = scroll(10)
      eq(nil, context.float(win))
      -- a buffer can still ask for org's
      vim.b.org_context = true
      context.update(win, true)
      eq({ 1, 2, 3 }, context.lines(win))
    end)
    vim.treesitter.language.add = add
    package.loaded["treesitter-context"] = nil
    vim.b.org_context = nil
    if not okc then
      error(err, 0)
    end
  end)
end)
