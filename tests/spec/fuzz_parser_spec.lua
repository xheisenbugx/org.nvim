-- Fuzz: the parser, the element parser and the fold levels hold their
-- invariants on random Org text. A few fixed seeds by default; see
-- tests/helpers/fuzz.lua for ORG_FUZZ_ITERATIONS / ORG_FUZZ_SEED.
local fuzz = require("tests.helpers.fuzz")
local parser = require("org.parser")
local files = require("org.files")
local element = require("org.element")
local fold = require("org.fold")

local SEEDS = fuzz.seeds(25)

--- Fail a check of the input being verified: `verify` reports it with the
--- seed and the input.
local function check(cond, msg)
  if not cond then
    error({ fuzz = msg }, 2)
  end
end

local function failure(err)
  return type(err) == "table" and err.fuzz or tostring(err)
end

--- Run `body(lines)`, which checks invariants. When one fails, shrink
--- `lines` to a smaller input failing the same way and fail with the seed,
--- the replay command and both inputs, ready to paste into
--- fuzz_regressions_spec.lua.
local function verify(seed, lines, body)
  local ok_, err = pcall(body, lines)
  if ok_ then
    return
  end
  local msg = failure(err)
  local kind = fuzz.kind(msg)
  local small = fuzz.shrink(lines, function(cand)
    local o, e = pcall(body, cand)
    return not o and fuzz.kind(failure(e)) == kind
  end)
  error(fuzz.report(seed, msg, lines, small), 0)
end

--- A plain-data copy of a parse (no back references), to compare parses.
local function plain(v, depth, seen)
  if type(v) ~= "table" then
    return type(v) == "function" and "<fn>" or v
  end
  if depth > 6 or seen[v] then
    return "<cycle>"
  end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    if k ~= "file" and k ~= "parent" and k ~= "children" and k ~= "bufnr" and k ~= "filename" then
      out[k] = plain(x, depth + 1, seen)
    end
  end
  seen[v] = nil
  return out
end

local SECTION = { "planning", "planning_line", "properties", "properties_range", "drawers", "logbook", "clocks" }

local function summary(file)
  local hls = {}
  for i, hl in ipairs(file.headlines) do
    local h = {
      level = hl.level,
      line = hl.line,
      end_line = hl.end_line,
      body_end = hl.body_end,
      raw = hl.raw,
      todo = hl.todo,
      priority = hl.priority,
      commented = hl.commented,
      title = hl.title,
      tags = hl.tags,
      inlinetask = hl.inlinetask,
      parent = hl.parent and hl.parent.index,
      timestamps = plain(hl.timestamps, 0, {}),
    }
    for _, k in ipairs(SECTION) do
      h[k] = plain(hl[k], 0, {})
    end
    hls[i] = h
  end
  return {
    n = #file.lines,
    preamble_end = file.preamble_end,
    properties = file.properties,
    properties_range = file.properties_range,
    headlines = hls,
  }
end

--- The outline a naive reading gives (no inline tasks): every headline,
--- its section's last line, its subtree's last line and its parent.
local function reference(lines)
  local hls = {}
  for i, l in ipairs(lines) do
    local lv = l:match("^(%*+) ")
    if lv then
      hls[#hls + 1] = { line = i, level = #lv }
    end
  end
  for k, h in ipairs(hls) do
    h.body_end = hls[k + 1] and hls[k + 1].line - 1 or #lines
    h.end_line = #lines
    for j = k + 1, #hls do
      if hls[j].level <= h.level then
        h.end_line = hls[j].line - 1
        break
      end
    end
    for j = k - 1, 1, -1 do
      if hls[j].level < h.level then
        h.parent = j
        break
      end
    end
  end
  return hls
end

local function check_outline(lines, file, inline)
  local n = #lines
  local hls = file.headlines
  local outline = {}
  for i, hl in ipairs(hls) do
    check(hl.index == i, "index of headline " .. i)
    check(i == 1 or hls[i - 1].line < hl.line, "headlines out of order at " .. hl.line)
    check(parser.headline_level(lines[hl.line]) == hl.level, "level of line " .. hl.line)
    check(hl.raw == lines[hl.line], "raw of line " .. hl.line)
    check(
      hl.line <= hl.body_end and hl.body_end <= hl.end_line and hl.end_line <= n,
      ("ranges of %d: body_end %d end_line %d"):format(hl.line, hl.body_end, hl.end_line)
    )
    if hl.parent then
      local p = hl.parent
      check(p.level < hl.level, "parent level of " .. hl.line)
      check(p.line < hl.line and hl.end_line <= p.end_line, "child outside parent at " .. hl.line)
    end
    for _, c in ipairs(hl.children) do
      check(c.parent == hl, "child's parent at " .. c.line)
      check(not c.inlinetask, "inline task among children at " .. c.line)
    end
    if not hl.inlinetask then
      outline[#outline + 1] = hl
    end
  end
  for _, c in ipairs(file.children) do
    check(c.parent == nil, "top-level entry with a parent at " .. c.line)
  end
  if not inline then
    local ref = reference(lines)
    check(#ref == #hls, ("%d headlines, expected %d"):format(#hls, #ref))
    for k, r in ipairs(ref) do
      local hl = hls[k]
      check(hl.line == r.line, "headline line " .. r.line)
      check(hl.end_line == r.end_line, ("end_line of %d: %d, expected %d"):format(r.line, hl.end_line, r.end_line))
      check(hl.body_end == r.body_end, "body_end of " .. r.line)
      check((hl.parent and hl.parent.index) == r.parent, "parent of " .. r.line)
    end
    -- every line belongs to the nearest headline above it
    local k = 0
    for l = 1, n do
      while ref[k + 1] and ref[k + 1].line <= l do
        k = k + 1
      end
      local at = file:headline_at(l)
      check((at and at.index) == (k > 0 and k or nil), "headline_at(" .. l .. ")")
    end
    check(file.preamble_end == (ref[1] and ref[1].line - 1 or n), "preamble_end")
  else
    for l = 1, n do
      local at = file:headline_at(l)
      check(not at or (at.line <= l and l <= at.end_line), "headline_at(" .. l .. ") outside its entry")
    end
  end
  -- the section of an outline entry: the lines up to the next outline headline
  for k, hl in ipairs(outline) do
    local nxt = outline[k + 1]
    check(hl.body_end == (nxt and nxt.line - 1 or n), "body_end with inline tasks at " .. hl.line)
  end
end

local function check_sections(lines, file)
  for _, hl in ipairs(file.headlines) do
    local ok_, err = pcall(function()
      return hl.todo, hl.title, hl.tags, hl.planning, hl.properties, hl.drawers, hl.clocks, hl.timestamps
    end)
    check(ok_, "lazy fields of " .. hl.line .. ": " .. tostring(err))
    -- an inline task without END reads the text up to the next heading
    -- (parser.section_to), as org-back-to-heading finds it there
    local s, e = hl.line + 1, parser.section_to(hl)
    if hl.planning_line then
      check(hl.planning_line >= s and hl.planning_line <= e, "planning line of " .. hl.line)
    end
    local function within(r, what)
      check(r[1] >= s and r[2] <= e and r[1] <= r[2], what .. " of " .. hl.line)
    end
    if hl.properties_range then
      within(hl.properties_range, "properties_range")
    end
    for _, d in ipairs(hl.drawers) do
      within({ d.start, d["end"] }, "drawer " .. d.name)
    end
    if hl.logbook then
      within({ hl.logbook.start, hl.logbook["end"] }, "logbook")
    end
    for _, c in ipairs(hl.clocks) do
      check(c.line >= s and c.line <= e, "clock line of " .. hl.line)
    end
    for _, t in ipairs(hl.timestamps) do
      check(t.line >= hl.line and t.line <= e, "timestamp line of " .. hl.line)
      check(t.start_col >= 1 and t.end_col <= #lines[t.line], "timestamp cols on " .. t.line)
    end
  end
end

--- Elements of [s, e]: in order, not overlapping, inside their parent.
local function check_elements(lines, els, s, e, where)
  local prev = s - 1
  for _, el in ipairs(els) do
    local tag = ("%s %s %d-%d"):format(where, el.type, el.first, el.last or -1)
    check(el.first > prev, "elements overlap: " .. tag)
    check(el.first <= el.post and el.post <= el.clast and el.clast <= el.last, "element bounds: " .. tag)
    check(el.last <= e, "element past its container: " .. tag)
    if el.children and #el.children > 0 then
      check(el.cfirst and el.cend, "children without contents: " .. tag)
      check_elements(lines, el.children, el.cfirst, el.cend, tag)
    end
    prev = el.last
  end
end

local function check_element_parse(lines, file)
  local sections = { { 1, file.preamble_end } }
  for _, hl in ipairs(file.headlines) do
    if not hl.inlinetask then
      sections[#sections + 1] = { hl.line + 1, hl.body_end }
    end
  end
  for _, r in ipairs(sections) do
    local ok_, els = pcall(element.parse, lines, r[1], r[2])
    check(ok_, ("element.parse(%d, %d): %s"):format(r[1], r[2], tostring(els)))
    check_elements(lines, els, r[1], r[2], "section " .. r[1])
  end
end

local function run_parse(inline)
  for _, seed in ipairs(SEEDS) do
    verify(seed, fuzz.doc(fuzz.rng(seed)), function(lines)
      local ok_, file = pcall(parser.parse, lines)
      check(ok_, "parse error: " .. tostring(file))
      check_outline(lines, file, inline)
      check_sections(lines, file)
      check_element_parse(lines, file)
    end)
  end
end

describe("fuzz parser", function()
  it("keeps the outline invariants", function()
    run_parse(false)
  end)

  describe("with inline tasks", function()
    with_config({ inlinetask_min_level = 15 })
    it("keeps the outline invariants", function()
      run_parse(true)
    end)
  end)

  it("gives the same parse for a buffer and its file on disk", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local n = 0
    local function same_parse(lines)
      if #lines == 0 then
        return
      end
      n = n + 1
      local path = dir .. "/f" .. n .. ".org"
      local fd = assert(io.open(path, "wb"))
      fd:write(table.concat(lines, "\n"), "\n")
      fd:close()
      files.invalidate(path)
      local disk = summary(files.get(path))
      vim.cmd("silent edit " .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      local ok_, err = pcall(function()
        local inbuf = summary(files.get_buffer(buf))
        check(vim.deep_equal(disk, inbuf), "disk and buffer parses differ")
        -- a no-op edit makes a new parse, which must be the same
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, vim.api.nvim_buf_get_lines(buf, 0, 1, false))
        check(vim.deep_equal(inbuf, summary(files.get_buffer(buf))), "re-parse after a no-op edit")
      end)
      vim.cmd("silent bwipeout! " .. buf)
      if not ok_ then
        error(err, 0)
      end
    end
    for _, seed in ipairs(SEEDS) do
      verify(seed, fuzz.doc(fuzz.rng(seed)), same_parse)
    end
    vim.fn.delete(dir, "rf")
  end)

  it("element.at works on any line", function()
    for _, seed in ipairs(SEEDS) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng, { crlf = false })
      local buf = org_buffer(lines)
      -- every line of a short text, 60 random ones of a long one
      local lnums = {}
      for l = 1, #lines do
        lnums[l] = l
      end
      if #lines > 60 then
        for k = 1, 60 do
          lnums[k] = rng:int(#lines)
        end
        for k = #lines, 61, -1 do
          lnums[k] = nil
        end
      end
      verify(seed, lines, function(cand)
        if cand ~= lines then
          -- shrinking: every line of the smaller text
          buf = org_buffer(cand)
          lnums = {}
          for l = 1, #cand do
            lnums[l] = l
          end
        end
        for _, l in ipairs(lnums) do
          local ok_, err = pcall(element.at, buf, l)
          check(ok_, ("element.at(%d): %s"):format(l, tostring(err)))
        end
      end)
    end
  end)
end)

describe("fuzz fold levels", function()
  local function run(steps_per_seed)
    for _, seed in ipairs(SEEDS) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng, { crlf = false })
      local buf = org_buffer(lines)
      local hist = {}
      local function compare(what)
        local cur = buf_lines(buf)
        local want = fold.compute(cur)
        local got = {}
        for l = 1, #cur do
          got[l] = fold.foldexpr(l)
        end
        if not vim.deep_equal(want, got) then
          local first
          for l = 1, #cur do
            if want[l] ~= got[l] then
              first = l
              break
            end
          end
          error(
            fuzz.report(
              seed,
              ("%s: incremental fold level of line %s is %s, full compute %s"):format(
                what,
                tostring(first),
                tostring(first and got[first]),
                tostring(first and want[first])
              ),
              lines,
              nil,
              "edits: " .. table.concat(hist, " | ")
            ),
            0
          )
        end
      end
      compare("initial")
      for step = 1, steps_per_seed do
        local n = vim.api.nvim_buf_line_count(buf)
        local i = rng:int(0, n)
        local r = rng:float()
        if r < 0.35 then
          local new = {}
          for k = 1, rng:int(1, 3) do
            new[k] = fuzz.line(rng)
          end
          vim.api.nvim_buf_set_lines(buf, i, i, false, new)
          hist[#hist + 1] = ("insert %d %s"):format(i, vim.inspect(new))
        elseif r < 0.6 then
          local cnt = rng:int(1, 3)
          vim.api.nvim_buf_set_lines(buf, math.min(i, n - 1), math.min(i + cnt, n), false, {})
          hist[#hist + 1] = ("delete %d +%d"):format(i, cnt)
        elseif r < 0.85 then
          local l = math.min(i, n - 1)
          local new = fuzz.line(rng)
          vim.api.nvim_buf_set_lines(buf, l, l + 1, false, { new })
          hist[#hist + 1] = ("replace %d %q"):format(l, new)
        else
          local e = fuzz.entry(rng)
          vim.api.nvim_buf_set_lines(buf, i, i, false, e)
          hist[#hist + 1] = ("insert %d %s"):format(i, vim.inspect(e))
        end
        -- several edits between two lookups, sometimes
        if rng:chance(0.7) then
          compare("step " .. step)
        end
      end
      compare("end")
    end
  end

  it("incremental updates match a full compute", function()
    run(30)
  end)

  describe("with inline tasks", function()
    with_config({ inlinetask_min_level = 15 })
    it("incremental updates match a full compute", function()
      run(30)
    end)
  end)
end)
