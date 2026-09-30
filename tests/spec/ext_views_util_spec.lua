local views = require("org.extensions.views_util")

describe("views_util canvas", function()
  it("tracks byte offsets of highlighted segments", function()
    local cv = views.Canvas.new()
    cv:add({ { "◆ ", "A" }, { "done", "B" } })
    cv:put(" x")
    cv:add("plain")
    eq({ "◆ done x", "plain" }, cv:strings())
    eq({ { 0, 4, "A" }, { 4, 8, "B" } }, cv.lines[1].hls)
  end)

  it("draws into a buffer with layered highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace("views_util_spec")
    local cv = views.Canvas.new()
    cv:add({ { "ab", { "Low", "High" } } })
    cv:draw(buf, ns)
    eq({ "ab" }, buf_lines(buf))
    eq(false, vim.bo[buf].modifiable)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(2, #marks)
    ok(marks[2][4].priority > marks[1][4].priority)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("views_util sources", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" } })

  it("follows a subtree and filters its headlines", function()
    local buf = org_buffer({
      "* TODO Before",
      "* Parent :p:",
      "** TODO One :x:",
      "** NEXT Two",
      "* TODO After",
    }, { 2, 0 })
    local src = views.resolve_source("subtree")
    eq("subtree", src.kind)
    local function titles(hls)
      return vim.tbl_map(function(h)
        return h.title
      end, hls)
    end
    eq({ "Parent", "One", "Two" }, titles(views.collect(src)))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Inserted" })
    eq({ "Parent", "One", "Two" }, titles(views.collect(src)))
    eq({ "One" }, titles(views.collect(src, { tag = "x" })))
    -- inherited tags count
    eq({ "Parent", "One", "Two" }, titles(views.collect(src, { tag = "p" })))
    eq({ "Two" }, titles(views.collect(src, { filter = '(todo "NEXT")' })))
    eq({ "One" }, titles(views.collect(src, { filter = "x" })))
    eq({ "Two" }, titles(views.collect(src, { query = "todo:NEXT" })))
    local hls, err = views.collect(src, { filter = "(nosuch" })
    eq({}, hls)
    ok(err)
    ok(views.source_label(src):find("Parent", 1, true))
  end)

  it("refuses buffer sources outside org buffers", function()
    vim.cmd("enew!")
    local src, err = views.resolve_source("buffer")
    eq(nil, src)
    ok(err)
  end)

  it("finds a headline that moved", function()
    local buf = org_buffer({ "* TODO A", "* TODO B" })
    local ref = { bufnr = buf, lnum = 2, raw = "* TODO B" }
    eq({ bufnr = buf, lnum = 2 }, views.target(ref))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* New" })
    eq({ bufnr = buf, lnum = 3 }, views.target(ref))
  end)
end)

describe("views_util formatting", function()
  it("formats durations and day offsets", function()
    eq("45m", views.short_duration(45))
    eq("2h", views.short_duration(120))
    eq("1h30m", views.short_duration(90))
    eq("160h", views.short_duration(160 * 60 + 12))
    eq("today", views.relative_days(0))
    eq("tomorrow", views.relative_days(1))
    eq("in 3d", views.relative_days(3))
    eq("2d ago", views.relative_days(-2))
  end)

  it("fits and centers text", function()
    eq("ab  ", views.fit("ab", 4))
    eq("abc…", views.fit("abcdef", 4))
    eq(" ab ", views.center("ab", 4))
  end)

  it("blends colours", function()
    eq("#000000", views.blend(0x000000, 0xffffff, 0))
    eq("#808080", views.blend(0x000000, 0xffffff, 0.5))
    eq("#ffffff", views.blend(0x000000, 0xffffff, 1))
  end)

  it("picks TODO, priority and tag faces", function()
    eq("OrgTodo", views.todo_group("TODO"))
    eq("OrgDone", views.todo_group("DONE"))
    eq("OrgPriorityA", views.priority_group("A"))
    eq("OrgPriority", views.priority_group("D"))
    eq("OrgTags", views.tag_group("x"))
  end)
end)

describe("views_util canvas merging", function()
  it("merges adjacent segments of the same highlight", function()
    local cv = views.Canvas.new()
    cv:put("ab", "A")
    cv:put("cd", "A")
    cv:put("ef", { "X", "Y" })
    cv:put("gh", { "X", "Y" })
    cv:put("ij")
    cv:put("kl", "A")
    eq({ { 0, 4, "A" }, { 4, 8, { "X", "Y" } }, { 10, 12, "A" } }, cv.lines[1].hls)
    eq({ "abcdefghijkl" }, cv:strings())
  end)
end)

describe("views_util targets", function()
  it("picks the copy of a moved headline nearest its old line", function()
    local buf = org_buffer({ "* TODO Same", "* Other", "* TODO Same", "* More", "* TODO Same" })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* New" })
    eq({ bufnr = buf, lnum = 6 }, views.target({ bufnr = buf, lnum = 5, raw = "* TODO Same" }))
  end)
end)

describe("views_util arguments", function()
  it("tells file names from tags matches", function()
    eq(true, views.is_path("~/x.org"))
    eq(true, views.is_path("notes/x.org"))
    eq(true, views.is_path("./notes"))
    eq(true, views.is_path("/abs/dir"))
    eq(true, views.is_path("~/org/*.org"))
    eq(false, views.is_path("work/NEXT"))
    eq(false, views.is_path("work+urgent/!TODO"))
    eq(false, views.is_path("(todo)"))
  end)

  it("completes sources", function()
    local c = views.complete_sources("")
    ok(vim.tbl_contains(c, "agenda"))
    ok(vim.tbl_contains(c, "buffer"))
    ok(vim.tbl_contains(c, "subtree"))
  end)
end)

describe("views_util windows", function()
  local columns, lines
  before_each(function()
    columns, lines = vim.o.columns, vim.o.lines
  end)
  after_each(function()
    vim.o.columns, vim.o.lines = columns, lines
    vim.cmd("silent! only")
  end)

  it("opens a float that fits a tiny editor", function()
    vim.o.columns, vim.o.lines = 20, 6
    local buf = views.scratch("org://views-tiny", "text")
    local win, how = views.open(buf, "float", { width = 0.9, height = 0.9, title = "A long title" })
    local cfg = vim.api.nvim_win_get_config(win)
    ok(cfg.width <= 18, cfg.width)
    ok(cfg.height <= 4, cfg.height)
    views.close(how)
  end)

  it("resizes a float with the editor", function()
    vim.o.columns, vim.o.lines = 100, 40
    local buf = views.scratch("org://views-resize", "text")
    local win, how = views.open(buf, "float", { width = 0.5, height = 0.5 })
    eq(50, vim.api.nvim_win_get_width(win))
    vim.o.columns = 60
    views.relayout(how)
    eq(30, vim.api.nvim_win_get_width(win))
    views.close(how)
  end)
end)

describe("views_util watch", function()
  local group
  after_each(function()
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end
  end)

  it("debounces a burst of changes into one call", function()
    local calls = 0
    group = views.watch("OrgViewsSpecWatch", function()
      calls = calls + 1
    end, { delay = 30 })
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("User", { pattern = "OrgTodoStateChange" })
      vim.wait(10)
    end
    vim.wait(200, function()
      return calls > 0
    end)
    vim.wait(60)
    eq(1, calls)
  end)

  it("ignores changes of buffers the view does not show", function()
    local calls = 0
    local mine = org_buffer({ "* A" })
    vim.bo[mine].bufhidden = "hide"
    local other = org_buffer({ "* B" })
    group = views.watch("OrgViewsSpecWatch", function()
      calls = calls + 1
    end, {
      delay = 10,
      relevant = function(b)
        return b == mine
      end,
    })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = other })
    vim.wait(60)
    eq(0, calls)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = mine })
    ok(vim.wait(500, function()
      return calls == 1
    end))
  end)

  it("watches unnamed org buffers too", function()
    local calls = 0
    -- org_buffer() buffers have no name
    local mine = org_buffer({ "* A" })
    group = views.watch("OrgViewsSpecWatch", function()
      calls = calls + 1
    end, { delay = 10 })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = mine })
    ok(vim.wait(500, function()
      return calls == 1
    end))
  end)

  it("reports an error of the callback once", function()
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local calls = 0
    group = views.watch("OrgViewsSpecWatch", function()
      calls = calls + 1
      error("boom")
    end, { delay = 5 })
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("User", { pattern = "OrgClockIn" })
      vim.wait(200, function()
        return false
      end)
    end
    vim.notify = notify
    eq(3, calls)
    eq(1, #msgs)
    ok(msgs[1]:find("boom", 1, true))
  end)
end)
