-- Time budgets on pathological input (tests/helpers/gen.lua): very long
-- lines, deep nesting, 10,000 headlines, big tables, a 100,000-line file.
--
-- Budgets are about 10x what a laptop takes, so they hold on slow shared CI
-- runners; ORG_PERF_SCALE=3 multiplies them (and ORG_PERF_SCALE=0.2 makes
-- them strict when hunting a regression). Growth checks time the same work
-- at size N and 2N: twice the input may take at most 3x the time, which a
-- linear algorithm passes on any machine and a quadratic one (4x) fails.
-- "perf: memory" checks that repeated exports leave the heap flat.
-- ORG_PERF_REPORT=1 prints every measurement. See CONTRIBUTING.md
-- "Performance budgets".
local gen = require("tests.helpers.gen")
local config = require("org.config")
local fold = require("org.fold")

local SCALE = tonumber(vim.env.ORG_PERF_SCALE or "") or 1
local REPORT = vim.env.ORG_PERF_REPORT == "1"

local function now()
  return vim.uv.hrtime() / 1e6
end

--- Milliseconds `fn` takes: the best of `runs` (default 1).
local function time(fn, runs)
  local best = math.huge
  for _ = 1, runs or 1 do
    collectgarbage()
    local t = now()
    fn()
    best = math.min(best, now() - t)
  end
  return best
end

local function report(label, value, extra, unit)
  if REPORT then
    io.stderr:write(("  perf %-52s %9.1f %s%s\n"):format(label, value, unit or "ms", extra or ""))
  end
end

-- `make coverage` runs the specs with the JIT off and a line hook: the
-- work still runs (and is counted), the time limits don't apply
local TIMED = not under_coverage()

--- `fn` must finish within `ms` milliseconds (times ORG_PERF_SCALE).
local function budget(label, ms, fn)
  local dt = time(fn)
  report(label, dt, (" (budget %d)"):format(ms * SCALE))
  ok(
    dt <= ms * SCALE or not TIMED,
    ("%s took %.0f ms, budget %d ms (ORG_PERF_SCALE=%s)"):format(label, dt, ms * SCALE, SCALE)
  )
  return dt
end

--- `fn(n)` at 2n may take at most 3x its time at n (plus `slack` ms, 10 by
--- default, for timer noise on fast operations). `setup(n)` (optional)
--- prepares untimed state and returns the argument for `fn`.
local function linear(label, n, fn, setup, slack)
  local function run(size)
    return time(function()
      fn(setup and setup(size) or size)
    end, 1)
  end
  if not TIMED then
    -- (once, for the lines it runs)
    run(n)
    return
  end
  -- (setup outside the timing: run separately and keep the best of two)
  local function best(size)
    local a = run(size)
    local b = run(size)
    return math.min(a, b)
  end
  local t1 = best(n)
  local t2 = best(2 * n)
  local limit = 3 * t1 + (slack or 10) * SCALE
  report(label, t2, (" (n: %.1f ms, 2n: %.1f ms, limit %.1f)"):format(t1, t2, limit))
  ok(t2 <= limit, ("%s: %.1f ms at n=%d, %.1f ms at 2n: grows faster than linear"):format(label, t1, n, t2))
end

local function messages()
  return vim.api.nvim_exec2("messages", { output = true }).output
end

--- Open `lines` as an org file the way a user does (:edit runs the
--- ftplugin, the syntax and the fold setup), compute its folds and draw it.
local function open(lines)
  local path = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.bufhidden = "wipe"
  vim.fn.foldlevel(vim.api.nvim_buf_line_count(0))
  vim.cmd("redraw!")
  return vim.api.nvim_get_current_buf()
end

local function syn(l, c)
  return vim.fn.synIDattr(vim.fn.synID(l, c, 1), "name")
end

--- Inside a describe: no messages before a test, no buffers after it.
local function setup()
  before_each(function()
    vim.cmd("messages clear")
  end)
  after_each(function()
    vim.cmd("silent! %bwipeout!")
  end)
end

describe("perf: long lines", function()
  setup()
  --- A file with one `kind` of long line between two headlines.
  local function file(kind, n)
    local line = ({
      prose = gen.prose,
      marked = gen.marked,
      markers = gen.markers,
      list = function(k)
        return "- " .. gen.prose(k) .. " :: term"
      end,
      table = function(k)
        return "| " .. gen.marked(k) .. " |"
      end,
      headline = function(k)
        return "** TODO " .. gen.marked(k) .. " :tag:"
      end,
    })[kind](n)
    return { "* Before", line, "* After *bold*" }
  end

  --- Draw the buffer again from scratch (the syntax state of every line
  --- recomputed).
  local function redraw_fresh()
    vim.cmd("syntax clear")
    vim.b.current_syntax = nil
    vim.cmd("runtime! syntax/org.lua")
    vim.cmd("redraw!")
  end

  for _, kind in ipairs({ "prose", "marked", "markers", "list", "table", "headline" }) do
    it(kind .. ": 30,000 characters draw in budget, syntax stays on", function()
      open(file(kind, 30000))
      vim.cmd("messages clear")
      budget("draw a 30,000-character " .. kind .. " line", 1000, redraw_fresh)
      local m = messages()
      ok(not m:find("redrawtime"), m)
      ok(not m:find("E363"), m)
      -- highlighting goes on past the long line (no region leaks into it)
      eq("OrgHeadlineLevel1", syn(3, 1))
      eq("OrgBold", syn(3, 11))
    end)
  end

  for _, kind in ipairs({ "prose", "marked", "list", "table", "headline" }) do
    it(kind .. ": drawing time grows linearly with the line", function()
      local buf = open(file(kind, 100))
      vim.cmd("messages clear")
      linear("draw a " .. kind .. " line", 20000, redraw_fresh, function(n)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, file(kind, n))
      end)
      -- ('redrawtime' caps a drawing that turns syntax off)
      local m = messages()
      ok(not m:find("redrawtime"), m)
    end)
  end

  it("typing in a 10,000-character line", function()
    open(file("marked", 10000))
    vim.api.nvim_win_set_cursor(0, { 2, 100 })
    budget("type 10 chars in a 10,000-character line", 1500, function()
      for _ = 1, 10 do
        vim.cmd("normal! ix")
        require("org.files").get_buffer(0)
        vim.cmd("redraw")
      end
    end)
  end)

  it("parse, export and lint a file of long lines", function()
    open(gen.long_lines(20000))
    budget("parse long lines", 100, function()
      require("org.parser").parse(vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)
    budget("export long lines to HTML", 1500, function()
      require("org.export").to_string("html", { bufnr = 0 })
    end)
    budget("export long lines to Markdown", 1500, function()
      require("org.export").to_string("md", { bufnr = 0 })
    end)
    budget("lint long lines", 1500, function()
      require("org.lint").lint(0)
    end)
  end)
end)

describe("perf: deep nesting", function()
  setup()
  local function deep()
    local lines = {}
    vim.list_extend(lines, gen.deep_headlines(60))
    vim.list_extend(lines, gen.deep_list(40))
    vim.list_extend(lines, gen.deep_blocks(30))
    return lines
  end

  it("opens, parses and folds 60 levels, 40-deep lists and 30 nested blocks", function()
    local lines = deep()
    budget("open deep nesting", 1000, function()
      open(lines)
    end)
    local file = require("org.files").get_buffer(0)
    -- (and the headlines of the list and block parts)
    eq(62, #file.headlines)
    eq(60, file.headlines[60].level)
    -- fold levels: the incremental levels agree with a full recompute
    local want = fold.compute(lines)
    for l = 1, #lines do
      eq(want[l], fold.foldexpr(l), "fold level of line " .. l)
    end
    budget("zM zR deep nesting", 500, function()
      vim.cmd("normal! zMzR")
      vim.cmd("redraw")
    end)
    budget("export deep nesting", 1500, function()
      require("org.export").to_string("html", { bufnr = 0 })
    end)
    budget("lint deep nesting", 1000, function()
      require("org.lint").lint(0)
    end)
  end)
end)

describe("perf: 10,000 headlines", function()
  setup()
  local path
  local lines = gen.headlines(10000)
  before_each(function()
    path = vim.fn.tempname() .. ".org"
    vim.fn.writefile(lines, path)
  end)

  it("parses in budget and linearly", function()
    budget("parse 10,000 headlines", 1500, function()
      require("org.parser").parse(lines)
    end)
    linear("parse headlines", 2000, function(l)
      require("org.parser").parse(l)
    end, gen.headlines)
  end)

  it("opens and edits in budget", function()
    budget("open 10,000 headlines", 3000, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      vim.fn.foldlevel(vim.api.nvim_buf_line_count(0))
      vim.cmd("redraw!")
    end)
    local files = require("org.files")
    files.get_buffer(0)
    local mid = files.get_buffer(0).headlines[5000].line
    vim.api.nvim_win_set_cursor(0, { mid + 9, 0 })
    budget("type 10 chars in 10,000 headlines", 2000, function()
      for _ = 1, 10 do
        vim.cmd("normal! ix")
        vim.cmd("redraw")
      end
    end)
    vim.api.nvim_win_set_cursor(0, { mid, 0 })
    budget("cycle TODO 5x in 10,000 headlines", 3000, function()
      for _ = 1, 5 do
        require("org.todo").cycle_next()
        vim.cmd("redraw")
      end
    end)
    local second = files.get_buffer(0).headlines[2].line
    vim.api.nvim_win_set_cursor(0, { second, 0 })
    budget("demote and promote a subtree 3x in 10,000 headlines", 3000, function()
      for _ = 1, 3 do
        require("org.structure").demote_subtree()
        require("org.structure").promote_subtree()
        vim.cmd("redraw")
      end
    end)
    local function squash(l)
      return (l:gsub("%s+", " "))
    end
    eq(squash(lines[second]), squash(vim.api.nvim_buf_get_lines(0, second - 1, second, false)[1]))
    budget("zM, zR in 10,000 headlines", 2000, function()
      vim.cmd("normal! zM")
      vim.cmd("redraw")
      vim.cmd("normal! zR")
      vim.cmd("redraw")
    end)
    vim.api.nvim_win_set_cursor(0, { mid, 0 })
    budget("cycle a subtree 6x in 10,000 headlines", 2000, function()
      for _ = 1, 6 do
        fold.cycle()
        vim.cmd("redraw")
      end
    end)
  end)

  describe("agenda", function()
    local saved
    before_each(function()
      saved = config.opts.agenda_files
      config.opts.agenda_files = { path }
    end)
    after_each(function()
      config.opts.agenda_files = saved
    end)

    it("builds views over the file in budget", function()
      local agenda = require("org.agenda")
      local anchor = require("org.date").parse("<2026-05-13 Wed>"):days()
      budget("agenda week of 10,000 headlines", 3000, function()
        agenda.open({ type = "agenda" }, { span = "week", anchor = anchor })
        vim.cmd("redraw")
      end)
      ok(#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 100)
      budget("todo list of 10,000 headlines", 3000, function()
        agenda.open({ type = "todo" })
        vim.cmd("redraw")
      end)
      budget("tags match in 10,000 headlines", 3000, function()
        agenda.open({ type = "tags", match = "t7+shared" })
        vim.cmd("redraw")
      end)
    end)
  end)

  it("lints in budget", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    budget("lint 10,000 headlines", 12000, function()
      require("org.lint").lint(0)
    end)
  end)
end)

describe("perf: export and lint grow linearly", function()
  setup()
  local function export(format)
    return function(lines)
      require("org.export").to_string(format, { lines = lines })
    end
  end

  -- (Markdown asked for each headline whether a link refers to it, by
  -- walking the whole tree: minutes for 5,000 headlines)
  it("headlines", function()
    linear("export headlines to Markdown", 500, export("md"), gen.headlines, 30)
    linear("export headlines to HTML", 500, export("html"), gen.headlines, 30)
  end)

  -- (emphasis looked for its end from each opening marker, plain links
  -- for a colon over each long word)
  it("long lines", function()
    linear("export long lines to HTML", 20000, export("html"), gen.long_lines, 30)
  end)

  it("table rows", function()
    linear("export table rows to HTML", 500, export("html"), function(n)
      return gen.table(n, 20)
    end, 30)
  end)

  it("top-level headlines with planning lines", function()
    local buf = open({ "" })
    linear("lint top-level headlines", 4000, function()
      require("org.lint").lint(buf)
    end, function(n)
      local lines = {}
      for i = 1, n do
        vim.list_extend(lines, { "* H" .. i, "SCHEDULED: <2026-05-13 Wed>", ":LOGBOOK:", ":END:" })
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end, 30)
  end)
end)

describe("perf: decorations", function()
  setup()
  local ui = config.opts.ui
  local saved
  before_each(function()
    saved = vim.deepcopy(ui)
    ui.hide_leading_stars, ui.bullets, ui.checkboxes = true, { "◉", "○" }, { " ", "◐", "✓" }
    ui.indent_mode, ui.pretty_entities, ui.num = true, true, true
  end)
  after_each(function()
    for k in pairs(ui) do
      ui[k] = saved[k]
    end
  end)

  it("of long lines grow linearly", function()
    local deco = require("org.ui.decorations")
    local buf = open({ "" })
    linear("decorations of long lines", 10000, function()
      deco.compute(buf, 0, vim.api.nvim_buf_line_count(buf) - 1, deco.ui_options(buf))
    end, function(n)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, gen.long_lines(n))
      deco.render(buf)
    end)
  end)
end)

describe("perf: tables", function()
  setup()
  it("realigns 2,000 rows x 20 columns in budget, linearly", function()
    open(gen.table(2000, 20))
    vim.api.nvim_win_set_cursor(0, { 10, 2 })
    budget("realign 2,000 x 20", 3000, function()
      vim.cmd("normal! ixxxxxxxxx")
      require("org.table").align()
      vim.cmd("redraw")
    end)
    local row = vim.api.nvim_get_current_line()
    ok(row:find("xxxxxxxxx", 1, true), row)
    -- aligned: every row as wide as the edited one
    eq(#row, #vim.fn.getline(4))
    eq(#row, #vim.fn.getline(2002))
    local buf = vim.api.nvim_get_current_buf()
    linear("realign rows", 500, function()
      vim.api.nvim_win_set_cursor(0, { 10, 2 })
      require("org.table").align()
    end, function(n)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, gen.table(n, 20))
    end)
  end)

  it("draws and realigns a table with a 20,000-character cell", function()
    open(gen.table(50, 5, { long_cell = 20000 }))
    vim.api.nvim_win_set_cursor(0, { 10, 2 })
    vim.cmd("messages clear")
    budget("realign and draw a 20,000-character cell", 1500, function()
      require("org.table").align()
      vim.cmd("redraw!")
    end)
    local m = messages()
    ok(not m:find("redrawtime"), m)
    ok(not m:find("E363"), m)
    eq("OrgTable", syn(10, 3))
  end)

  it("recalculates formulas linearly", function()
    local buf = open({ "" })
    local n
    linear("recalculate a table", 300, function()
      require("org.table").recalc(buf, 3)
    end, function(size)
      n = size
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, gen.table(n, 6, { formula = "$6=$1+$2+$3::@2$5=vsum(@3..@>)" }))
    end, 50)
    -- the column formula ran on every row
    eq(tostring(6 * n), vim.fn.getline(n + 3):match("(%d+)%s*|$"))
  end)
end)

describe("perf: 100,000 lines", function()
  setup()
  it("opens, folds and edits in budget", function()
    local lines = gen.big_file(100000)
    budget("open 100,000 lines", 5000, function()
      open(lines)
    end)
    vim.api.nvim_win_set_cursor(0, { 50000, 0 })
    budget("type 10 chars in 100,000 lines", 1500, function()
      for _ = 1, 10 do
        vim.cmd("normal! ix")
        vim.cmd("redraw")
      end
    end)
    budget("zM, zR in 100,000 lines", 3000, function()
      vim.cmd("normal! zM")
      vim.cmd("redraw")
      vim.cmd("normal! zR")
      vim.cmd("redraw")
    end)
    eq(fold.compute(vim.api.nvim_buf_get_lines(0, 0, -1, false))[50001], fold.foldexpr(50001))
  end)
end)

describe("perf: links and footnotes", function()
  setup()
  it("export and lint grow linearly", function()
    linear("export links and footnotes", 1000, function(l)
      require("org.export").to_string("html", { lines = l })
    end, gen.links_footnotes, 30)
    local buf = open({ "" })
    linear("lint links and footnotes", 1000, function()
      require("org.lint").lint(buf)
    end, function(n)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, gen.links_footnotes(n))
    end, 30)
  end)
end)

-- An export keeps nothing of its document once it has returned. A cache
-- of positions in the exported tree, with weak keys and values that
-- reached the keys (which LuaJIT never lets go), kept every tree alive:
-- exporting examples/19-export.org to four formats grew the heap by
-- 4.7 MB each time.
describe("perf: memory", function()
  local ox = require("org.export.ox")
  local export = require("org.export")
  local FORMATS = { "html", "md", "latex", "ascii" }
  local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
  local file = root .. "/examples/19-export.org"
  local lines = vim.fn.readfile(file)
  local saved
  before_each(function()
    saved = config.opts.babel.evaluate_on_export
    config.opts.babel.evaluate_on_export = false
  end)
  after_each(function()
    config.opts.babel.evaluate_on_export = saved
  end)

  local function heap()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count") / 1024
  end

  it("frees the tree of each export", function()
    local trees = setmetatable({}, { __mode = "k" })
    -- (in a function: its locals are gone when the garbage is collected)
    local function export_all()
      for _, fmt in ipairs(FORMATS) do
        local _, info = ox.export_as(fmt, lines, { filename = file })
        trees[info.parse_tree] = fmt
      end
    end
    export_all()
    heap()
    local kept = {}
    for _, fmt in pairs(trees) do
      kept[#kept + 1] = fmt
    end
    table.sort(kept)
    eq({}, kept, "the trees still in memory")
  end)

  it("keeps the heap flat over repeated exports", function()
    local function round()
      for _, fmt in ipairs(FORMATS) do
        export.to_string(fmt, { lines = lines, filename = file })
      end
    end
    -- (the first round loads the exporters and fills their caches)
    round()
    local before = heap()
    for _ = 1, 5 do
      round()
    end
    local grown = heap() - before
    report("heap growth over 5 rounds of exports", grown, nil, "MB")
    ok(grown < 5, ("the heap grew %.1f MB over 5 rounds of exports (%.1f MB before them)"):format(grown, before))
  end)
end)
