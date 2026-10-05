-- Time budgets on pathological input (tests/helpers/gen.lua): very long
-- lines, deep nesting, 10,000 headlines, big tables, a 100,000-line file.
--
-- Budgets are about 10x what a laptop takes, so they hold on slow shared CI
-- runners; ORG_PERF_SCALE=3 multiplies them (and ORG_PERF_SCALE=0.2 makes
-- them strict when hunting a regression). Growth checks time the same work
-- at size N and 4N: 4 times the input may take at most 10x the time, which a
-- linear algorithm passes on any machine and a quadratic one (16x) fails;
-- N is first doubled until the work, not the timer or a fixed cost, makes
-- the time ("perf: growth checks" feeds them work of known growth).
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

--- Milliseconds of processor time this process has used (wall time where
--- os.clock() is that, as on Windows).
local function cpu()
  return os.clock() * 1000
end

--- Milliseconds `fn` takes: the best of `runs` (default 1), by `clock`
--- (default `now`).
local function time(fn, runs, clock)
  clock = clock or now
  local best = math.huge
  for _ = 1, runs or 1 do
    collectgarbage()
    local t = clock()
    fn()
    best = math.min(best, clock() - t)
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

-- Growth checks: 4 times the work takes 4 times the time when it is
-- linear, 16 times when it is quadratic; the limit is 10 times (LIMIT),
-- plus NOISE_MS. Linear work that allocates a lot takes more than 4 times:
-- the larger input fits the caches less well, and the smaller one runs
-- faster after it (the allocator already holds the memory). A parse of
-- headlines takes 5 to 7 times at 4n, and took 3.2 to 4 times at 2n on CI,
-- where the limit was then 3 times. Work whose input can't grow 4 times
-- is checked at 2n, against 3 times. That tells them apart only when the
-- time measured is the work's: at least MIN_MS (the noise of the timer is
-- then a few percent of it), and DOMINANT times the time at n/16, so that
-- a fixed cost (setting up the syntax, a buffer) doesn't drown the work:
-- what grows is then at least 5 times what doesn't, and quadratic work
-- takes 13.5 times as long at 4n (3.5 times at 2n).
-- n is doubled until it is, at most MAX_DOUBLINGS times.
local MIN_MS, NOISE_MS, DOMINANT, MAX_DOUBLINGS = 25, 2, 6, 6
local LIMIT = { [2] = 3, [4] = 10 }

--- The time of `fn` at n and at `factor` (4 or 2, default 4) times n (the
--- best of 3 runs; `setup(size)` prepares untimed state and returns the
--- argument for `fn`), n doubled first, the larger size up to `max`
--- (default: no limit), until the work dominates the time. Returns { n,
--- factor, t1, t2, small (the time at n/16), limit, measurable, linear }.
local function growth(n, fn, setup, max, factor)
  factor = factor or 4
  local function run(size)
    -- (set up again for each run, outside the timing)
    -- (processor time: on a runner busy with the other spec files, the
    -- wall time also counts the time the process waits for a CPU)
    local arg = setup and setup(size) or size
    return time(function()
      fn(arg)
    end, 1, cpu)
  end
  local function best(size)
    local t = math.huge
    for _ = 1, 3 do
      t = math.min(t, run(size))
    end
    return t
  end
  local t1, small, measurable
  local doublings = 0
  while true do
    t1 = best(n)
    small = best(math.max(1, math.floor(n / 16)))
    measurable = t1 >= MIN_MS and t1 >= DOMINANT * small
    if measurable or doublings == MAX_DOUBLINGS or (max and factor * n > max) then
      break
    end
    n = 2 * n
    doublings = doublings + 1
  end
  -- n and the larger size in turn, the best of 3 runs each: a burst of load from other
  -- processes (CI runs the spec files in parallel) then slows both sizes
  -- alike instead of only the second
  local t2 = math.huge
  for _ = 1, 3 do
    t1 = math.min(t1, run(n))
    t2 = math.min(t2, run(factor * n))
  end
  local g = { n = n, factor = factor, t1 = t1, t2 = t2, small = small, measurable = measurable }
  g.limit = LIMIT[factor] * t1 + NOISE_MS
  g.linear = g.t2 <= g.limit
  return g
end

--- `fn` must take time linear in the size of its input (`growth`): at 4n
--- at most 10 times its time at n (at 2n, 3 times, with `factor` 2). A
--- check that fails is measured again, up to 3 times in all: load from
--- elsewhere can still slow one measurement, but quadratic work fails
--- every time.
local function linear(label, n, fn, setup, max, factor)
  if not TIMED then
    -- (once, for the lines it runs)
    fn(setup and setup(n) or n)
    return
  end
  local g, attempts
  for attempt = 1, 3 do
    g = growth(g and g.n or n, fn, setup, max, factor)
    attempts = attempt
    if not g.measurable or g.linear then
      break
    end
  end
  report(
    label,
    g.t2,
    (" (n=%d: %.1f ms, %dn: %.1f ms, limit %.1f, n/16: %.1f ms%s)"):format(
      g.n,
      g.t1,
      g.factor,
      g.t2,
      g.limit,
      g.small,
      attempts > 1 and (", attempt %d"):format(attempts) or ""
    )
  )
  ok(
    g.measurable,
    ("%s: %.1f ms at n=%d, %.1f ms at n/16: too little of it grows with n to tell linear from quadratic"):format(
      label,
      g.t1,
      g.n,
      g.small
    )
  )
  ok(
    g.linear,
    ("%s: %.1f ms at n=%d, %.1f ms at %dn: grows faster than linear (3 attempts)"):format(
      label,
      g.t1,
      g.n,
      g.t2,
      g.factor
    )
  )
end

-- The growth check itself, fed work whose growth is known: it fails
-- quadratic work, also behind a fixed cost, passes linear work behind
-- one, and doesn't judge work that doesn't grow.
describe("perf: growth checks", function()
  --- Busy for `ms` milliseconds of processor time: work of a known time.
  local function busy(ms)
    local t = cpu()
    while cpu() - t < ms do
    end
  end
  --- 1..n
  local function list_of(n)
    local l = {}
    for i = 1, n do
      l[i] = i
    end
    return l
  end
  --- Each element looked up by a search of the list, as the exporters
  --- did for each footnote reference: quadratic.
  local function search_each(list)
    local found = 0
    for _, x in ipairs(list) do
      for _, y in ipairs(list) do
        if y == x then
          found = found + 1
          break
        end
      end
    end
    return found
  end
  --- (timing: not under `make coverage`)
  local function timed(name, fn)
    it(name, function()
      if TIMED then
        fn()
      end
    end)
  end

  timed("fails quadratic work", function()
    local g = growth(1000, search_each, list_of)
    ok(g.measurable and not g.linear, vim.inspect(g))
    g = growth(100, function(n)
      busy(n * n / 1e4)
    end)
    ok(g.measurable and not g.linear, vim.inspect(g))
  end)

  timed("fails quadratic work behind a fixed cost", function()
    local g = growth(100, function(n)
      busy(10 + n * n / 1e4)
    end)
    ok(g.measurable and not g.linear, vim.inspect(g))
  end)

  timed("passes linear work behind a fixed cost", function()
    local g = growth(1000, function(n)
      busy(10 + n / 10)
    end)
    ok(g.measurable and g.linear, vim.inspect(g))
  end)

  timed("doesn't judge work that doesn't grow", function()
    local g = growth(100, function()
      busy(30)
    end)
    ok(not g.measurable, vim.inspect(g))
  end)
end)

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
  --- A line of `kind` of `n` characters.
  local function line(kind, n)
    return ({
      prose = gen.prose,
      marked = gen.marked,
      markers = gen.markers,
      bold = function(k)
        return string.rep("*a* ", math.ceil(k / 4)):sub(1, k)
      end,
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
  end

  --- A file with one `kind` of long line between two headlines.
  local function file(kind, n)
    return { "* Before", line(kind, n), "* After *bold*" }
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

  -- How drawing grows with the length of the lines, on a screen of 20 of
  -- them shorter than 'synmaxcol', where every column is drawn (past it
  -- nothing more is, so a line twice as long there is no more work). A
  -- look-behind for a table row on each emphasis marker went back to the
  -- start of the line: 20 lines of 2,900 characters of bold took 1.4 s to
  -- draw, 3.7x the time of 1,450.
  describe("a screen of lines", function()
    local wrap
    before_each(function()
      wrap = vim.wo.wrap
    end)
    after_each(function()
      vim.wo.wrap = wrap
    end)
    -- (2n and what a kind adds to a line within 'synmaxcol')
    local max = math.floor(vim.o.synmaxcol / 2) - 50

    for _, kind in ipairs({ "prose", "marked", "bold", "list", "table", "headline" }) do
      it(kind .. ": drawing time grows linearly with the lines", function()
        local buf = open({ "" })
        -- (a screen row per line: all 20 are drawn)
        vim.wo.wrap = false
        local function screen(n)
          local lines = { "* Before" }
          for _ = 1, 20 do
            lines[#lines + 1] = line(kind, n)
          end
          lines[#lines + 1] = "* After *bold*"
          return lines
        end
        vim.cmd("messages clear")
        -- (3 times: n can't grow past 'synmaxcol', the time must be well
        -- above the timer's noise on a fast machine too)
        -- (at 2n: n can't grow 4 times within 'synmaxcol')
        linear("draw 20 " .. kind .. " lines 3x", math.floor(max / 2), function()
          for _ = 1, 3 do
            redraw_fresh()
          end
        end, function(n)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, screen(n))
        end, max, 2)
        -- ('redrawtime' caps a drawing that turns syntax off)
        local m = messages()
        ok(not m:find("redrawtime"), m)
        eq("OrgHeadlineLevel1", syn(22, 1))
        eq("OrgBold", syn(22, 11))
      end)
    end
  end)

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
    linear("parse headlines", 20000, function(l)
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
    linear("export headlines to Markdown", 500, export("md"), gen.headlines)
    linear("export headlines to HTML", 500, export("html"), gen.headlines)
  end)

  -- (emphasis looked for its end from each opening marker, plain links
  -- for a colon over each long word)
  it("long lines", function()
    linear("export long lines to HTML", 20000, export("html"), gen.long_lines)
  end)

  it("table rows", function()
    linear("export table rows to HTML", 500, export("html"), function(n)
      return gen.table(n, 20)
    end)
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
    end)
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
    linear("decorations of long lines", 40000, function()
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
    linear("realign rows", 1000, function()
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
    linear("recalculate a table", 600, function()
      require("org.table").recalc(buf, 3)
    end, function(size)
      n = size
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, gen.table(n, 6, { formula = "$6=$1+$2+$3::@2$5=vsum(@3..@>)" }))
    end)
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

-- Src blocks drawn with tree-sitter (ui.src_highlight_engine "auto", the
-- bundled lua parser) and, to compare, with the lua syntax included. On a
-- laptop (Neovim 0.13-dev), tree-sitter / syntax: 1,000 blocks of 20 lines
-- open in 0.1 s with either and are gone through a screen at a time in
-- 0.4 s / 1.6 s; a 10,000-line block opens in 0.14 s / 0.07 s, its middle
-- draws in 17 ms / 360 ms, and a character typed in it takes 35 ms / 13 ms
-- (tree-sitter parses the block again from the tree it had); in a
-- 1,000-line block, parsed whole with its injected languages, 19 ms / 5 ms.
describe("perf: src blocks", function()
  setup()
  local ui = config.opts.ui
  local saved_engine, saved_rtp
  before_each(function()
    saved_engine, saved_rtp = ui.src_highlight_engine, vim.o.runtimepath
    local lib = vim.fs.normalize(vim.env.VIMRUNTIME .. "/../../../lib/nvim")
    if vim.uv.fs_stat(lib .. "/parser") then
      vim.opt.runtimepath:append(lib)
    end
  end)
  after_each(function()
    ui.src_highlight_engine, vim.o.runtimepath = saved_engine, saved_rtp
  end)

  for _, engine in ipairs({ "auto", "syntax" }) do
    it(engine .. ": 1,000 blocks and a 10,000-line block in budget", function()
      ui.src_highlight_engine = engine
      local label = engine == "auto" and "tree-sitter" or "syntax"
      local lines = gen.src_blocks(1000, 20)
      budget(label .. ": open 1,000 src blocks", 3000, function()
        open(lines)
      end)
      budget(label .. ": draw 1,000 src blocks a screen at a time", 10000, function()
        for l = 1, #lines, 40 do
          vim.api.nvim_win_set_cursor(0, { l, 0 })
          vim.cmd("normal! zt")
          vim.cmd("redraw")
        end
      end)
      vim.api.nvim_win_set_cursor(0, { 12000, 0 })
      budget(label .. ": type 10 chars among 1,000 src blocks", 1500, function()
        for _ = 1, 10 do
          vim.cmd("normal! ix")
          vim.cmd("redraw")
        end
      end)
      vim.cmd("silent! %bwipeout!")
      budget(label .. ": open a 10,000-line src block", 2000, function()
        open(gen.src_blocks(1, 10000))
      end)
      vim.api.nvim_win_set_cursor(0, { 5000, 0 })
      budget(label .. ": draw the middle of a 10,000-line src block", 3000, function()
        vim.cmd("normal! zz")
        vim.cmd("redraw!")
      end)
      budget(label .. ": type 10 chars in a 10,000-line src block", 4000, function()
        for _ = 1, 10 do
          vim.cmd("normal! ix")
          vim.cmd("redraw")
        end
      end)
      if engine == "auto" then
        local ts = require("org.ui.src_highlight")
        ok(ts.highlights_at(0, 4999)[1] ~= nil, "no tree-sitter highlights")
      end
      -- (up to inject_max lines, a block is parsed whole with its injections)
      vim.cmd("silent! %bwipeout!")
      open(gen.src_blocks(1, 1000))
      vim.api.nvim_win_set_cursor(0, { 500, 0 })
      budget(label .. ": type 10 chars in a 1,000-line src block", 3000, function()
        for _ = 1, 10 do
          vim.cmd("normal! ix")
          vim.cmd("redraw")
        end
      end)
    end)
  end

  it("tree-sitter: drawing a block grows linearly with its lines", function()
    -- (the highlights of a row in the middle, as the first row drawn: the
    -- block found, read and parsed; not the redraw, whose syntax syncing
    -- in a long region is the same with either engine)
    local ts = require("org.ui.src_highlight")
    local parses
    -- (the slower way: with the injected languages, at any size)
    local inject_max = ts.inject_max
    ts.inject_max = math.huge
    linear("tree-sitter: find, parse and highlight a src block", 2000, function(buf)
      ok(ts.highlights_at(buf, math.floor(vim.api.nvim_buf_line_count(buf) / 2))[1] ~= nil)
    end, function(n)
      vim.cmd("silent! %bwipeout!")
      -- (opened as a file: its languages are known)
      local buf = open(gen.src_blocks(1, n))
      ts.refresh(buf)
      parses = ts.parses
      return buf
    end)
    ts.inject_max = inject_max
    eq(parses + 1, ts.parses)
  end)
end)

describe("perf: links and footnotes", function()
  setup()
  it("export and lint grow linearly", function()
    linear("export links and footnotes", 1000, function(l)
      require("org.export").to_string("html", { lines = l })
    end, gen.links_footnotes)
    local buf = open({ "" })
    linear("lint links and footnotes", 1000, function()
      require("org.lint").lint(buf)
    end, function(n)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, gen.links_footnotes(n))
    end)
  end)
end)

-- Many agenda files (:h org-agenda-index): a first agenda view built from
-- the index on disk (the files read, their outline found, the rest filled
-- in), the background parse of them all, and a view after it. Without the
-- index, 2,000 files of 20 headlines took 1.1 s to the first week view on a
-- laptop; from the index 0.7 s, after the background parse 0.4 s.
describe("perf: agenda index", function()
  setup()
  local files = require("org.files")
  local index = require("org.agenda.index")
  local dirs = {}
  local saved_files, saved_index

  --- A directory of `n` agenda files of 20 headlines each.
  local function dir_of(n)
    if not dirs[n] then
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local lines = gen.headlines(20)
      for i = 1, n do
        lines[1] = "#+TITLE: File " .. i
        vim.fn.writefile(lines, ("%s/f%04d.org"):format(dir, i))
      end
      dirs[n] = dir
    end
    return dirs[n]
  end

  --- The agenda files are the `n` files, indexed (on disk), and parsed
  --- neither in memory nor in the index's memory: a new session.
  local function indexed(n)
    index.reset()
    os.remove(index.path())
    files.invalidate()
    config.opts.agenda_files = { dir_of(n) }
    files.agenda_files()
    index.flush()
    index.reset()
    files.invalidate()
  end

  local anchor = require("org.date").parse("<2026-05-13 Wed>"):days()
  local function week()
    require("org.agenda").open({ type = "agenda" }, { span = "week", anchor = anchor })
  end

  before_each(function()
    saved_files = config.opts.agenda_files
    saved_index = config.opts.agenda.index
    config.opts.agenda.index = vim.tbl_extend("force", saved_index, { background = false, watch = false })
  end)
  after_each(function()
    index.reset()
    config.opts.agenda_files = saved_files
    config.opts.agenda.index = saved_index
    files.invalidate()
  end)

  it("builds the first agenda over 300 files from the index in budget", function()
    indexed(300)
    budget("agenda week over 300 indexed files", 1500, function()
      week()
      vim.cmd("redraw")
    end)
    ok(index.status().hits >= 300)
  end)

  it("parses 300 agenda files in the background in budget, then views them in budget", function()
    index.reset()
    os.remove(index.path())
    files.invalidate()
    config.opts.agenda_files = { dir_of(300) }
    config.opts.agenda.index.background = true
    budget("background parse of 300 agenda files", 5000, function()
      index.start()
      ok(index.wait(60000))
    end)
    budget("agenda week over 300 files parsed in the background", 1500, function()
      week()
      vim.cmd("redraw")
    end)
  end)

  -- agenda.index.threads: the main loop finds each file's outline, the
  -- workers parse the rest. 50 files of 300 headlines took 0.2 s on a
  -- laptop with 2 workers, the main loop blocked for 12 ms at most (1.3 s
  -- and 50 ms, a whole file's parse at a time, without them).
  it("parses large agenda files on worker threads in budget, the main loop free", function()
    index.reset()
    os.remove(index.path())
    files.invalidate()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local lines = gen.headlines(300)
    for i = 1, 50 do
      lines[1] = "#+TITLE: File " .. i
      vim.fn.writefile(lines, ("%s/f%04d.org"):format(dir, i))
    end
    config.opts.agenda_files = { dir }
    config.opts.agenda.index.background = true
    config.opts.agenda.index.threads = 2
    local before = index.status().threaded
    -- the longest the main loop went without running a 1 ms timer
    local max = 0
    local timer = assert(vim.uv.new_timer())
    budget("background parse of 50 large agenda files on 2 threads", 3000, function()
      local last = vim.uv.hrtime()
      timer:start(1, 1, function()
        local t = vim.uv.hrtime()
        max = math.max(max, (t - last) / 1e6)
        last = t
      end)
      index.start()
      ok(index.wait(60000))
      timer:stop()
    end)
    timer:close()
    eq(50, index.status().threaded - before)
    report("longest main-loop block during it", max, (" (budget %d)"):format(100 * SCALE))
    ok(max <= 100 * SCALE or not TIMED, ("the main loop was blocked for %.0f ms"):format(max))
    vim.fn.delete(dir, "rf")
  end)

  it("builds an agenda from the index in time linear in the number of files", function()
    linear("agenda week from the index", 25, week, function(n)
      indexed(n)
    end, 1600)
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
