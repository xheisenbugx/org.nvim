-- The differential test: generated Org documents (tests/difftest/gen.lua)
-- through org.nvim and Emacs Org 9.8.10, oracle by oracle
-- (tests/difftest/oracles.lua, scripts/emacs-parity/difftest.el); every
-- difference that isn't a known one (tests/difftest/known.lua) is shrunk
-- to a small input and reported. `make difftest` runs it
-- (scripts/difftest.lua); see "Differential testing" in CONTRIBUTING.md.

local gen = require("tests.difftest.gen")
local oracles = require("tests.difftest.oracles")
local compare = require("tests.difftest.compare")
local minimise = require("tests.difftest.minimise")

local M = {}

---@class difftest.Opts
---@field seed integer first seed (documents use seed, seed+1, ...)
---@field count integer number of documents
---@field oracles string[]
---@field out string output directory (emptied first)
---@field jobs? integer Emacs workers (default 4)
---@field minimise? integer at most this many failures are minimised (default 20)
---@field budget? integer oracle runs per minimisation (default 300)
---@field known? table[] known differences (default tests/difftest/known.lua)
---@field pool? fun(jobs: integer): difftest.Pool the Emacs workers (tests pass a fake)
---@field log? fun(msg: string)
---@field docs? fun(seed: integer): string[] the generator (default gen.doc)

---@class difftest.Failure
---@field seed integer
---@field oracle string
---@field input string[]
---@field result difftest.Result
---@field signature string
---@field minimal? string[]
---@field minimal_result? difftest.Result
---@field calls? integer

local function write(path, s)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- The command that reruns one document and oracle.
function M.replay(seed, oracle)
  return ("make difftest SEED=%d COUNT=1 ORACLES=%s"):format(seed, oracle)
end

---@param opts difftest.Opts
function M.run(opts)
  local log = opts.log or function(msg)
    io.stdout:write(msg .. "\n")
  end
  local known = opts.known or require("tests.difftest.known")
  local docs = opts.docs or gen.doc
  local out = vim.fs.normalize(vim.fn.fnamemodify(opts.out, ":p")):gsub("/$", "")
  vim.fn.delete(out, "rf")
  local work = out .. "/work"
  local t0 = vim.uv.hrtime()
  local function elapsed()
    return (vim.uv.hrtime() - t0) / 1e9
  end

  local pool = (opts.pool or function(jobs)
    return require("tests.difftest.emacs").start({ jobs = jobs, timeout = 20 })
  end)(opts.jobs or 4)

  -- 1. the documents, and every request to Emacs at once
  local cases = {}
  for i = 1, opts.count do
    local seed = opts.seed + i - 1
    local name = ("d%d"):format(seed)
    local dir = work .. "/docs"
    local file = dir .. "/" .. name .. ".org"
    local lines = docs(seed)
    write(file, table.concat(lines, "\n") .. "\n")
    cases[i] = { seed = seed, file = file, dir = dir, lines = lines }
    for _, o in ipairs(opts.oracles) do
      pool:request(o, file, ("%s/emacs/%s.%s"):format(work, name, o))
    end
  end
  log(
    ("difftest: %d documents from seed %d, oracles %s"):format(opts.count, opts.seed, table.concat(opts.oracles, " "))
  )

  -- 2. org.nvim's side, while Emacs works
  for _, c in ipairs(cases) do
    c.ours = {}
    for _, o in ipairs(opts.oracles) do
      c.ours[o] = oracles.frozen(function()
        return oracles.run(o, c.file)
      end)
      write(("%s/ours/d%d.%s"):format(work, c.seed, o), c.ours[o])
    end
  end
  local t_ours = elapsed()
  pool:wait()
  local t_emacs = elapsed()

  -- 3. compare
  ---@type difftest.Failure[]
  local failures = {}
  local stats = { compared = 0, same = 0, known = 0, emacs_errors = 0, by_known = {} }
  for _, c in ipairs(cases) do
    for _, o in ipairs(opts.oracles) do
      local emacs = read(("%s/emacs/d%d.%s"):format(work, c.seed, o)) or "!error no output from Emacs\n"
      local res = compare.compare(o, emacs, c.ours[o], { dir = c.dir, known = known, input = c.lines })
      stats.compared = stats.compared + 1
      if res.emacs_error then
        stats.emacs_errors = stats.emacs_errors + 1
      elseif #res.hunks == 0 then
        stats.same = stats.same + 1
      elseif #res.unknown == 0 then
        stats.known = stats.known + 1
      end
      for _, h in ipairs(res.hunks) do
        if h.known then
          stats.by_known[h.known] = (stats.by_known[h.known] or 0) + 1
        end
      end
      if #res.unknown > 0 then
        failures[#failures + 1] = {
          seed = c.seed,
          oracle = o,
          input = c.lines,
          result = res,
          signature = compare.signature(o, res.unknown[1]),
        }
      end
    end
  end

  -- 4. shrink one failure per signature (up to opts.minimise of them)
  local nmin, attempt = 0, 0
  local seen = {}
  local fatal -- the Emacs workers failed: stop shrinking
  for _, f in ipairs(failures) do
    if not seen[f.signature] and nmin < (opts.minimise or 20) then
      seen[f.signature] = true
      nmin = nmin + 1
      local last
      f.minimal, f.calls = minimise.minimise(f.input, function(lines)
        if fatal then
          return false
        end
        attempt = attempt + 1
        local dir = ("%s/min/%d"):format(work, attempt)
        local file = ("%s/d%d.org"):format(dir, f.seed)
        write(file, table.concat(lines, "\n") .. "\n")
        local efile = dir .. "/emacs." .. f.oracle
        local okp, err = pcall(pool.request, pool, f.oracle, file, efile)
        local ours = oracles.frozen(function()
          return oracles.run(f.oracle, file)
        end)
        if okp then
          okp, err = pcall(pool.wait, pool)
        end
        if not okp then
          fatal = err
          return false
        end
        local res = compare.compare(
          f.oracle,
          read(efile) or "!error no output\n",
          ours,
          { dir = dir, known = known, input = lines }
        )
        -- the same kind of difference: not another one met on the way
        for _, h in ipairs(res.unknown) do
          if compare.signature(f.oracle, h) == f.signature then
            last = { lines = lines, res = res }
            return true
          end
        end
        return false
      end, opts.budget or 300)
      if last and vim.deep_equal(last.lines, f.minimal) then
        f.minimal_result = last.res
      else
        f.minimal, f.minimal_result = f.input, f.result
      end
      if fatal then
        pool:stop()
        error(fatal, 0)
      end
      log(("  shrunk seed %d %s: %d -> %d lines (%d runs)"):format(f.seed, f.oracle, #f.input, #f.minimal, f.calls))
    end
  end
  stats.emacs_timeouts = pool.timeouts or 0
  pool:stop()

  -- 5. report
  local distinct = {}
  for _, f in ipairs(failures) do
    if f.minimal then
      local sig = compare.signature(f.oracle, f.minimal_result.unknown[1] or f.result.unknown[1])
      if not distinct[sig] then
        distinct[sig] = true
        distinct[#distinct + 1] = f
      end
    end
  end
  local report = M.report(opts, failures, distinct, stats, known)
  write(out .. "/report.md", report)
  for i, f in ipairs(distinct) do
    local base = ("%s/repros/%02d-%s-seed%d"):format(out, i, f.oracle, f.seed)
    write(base .. ".org", table.concat(f.minimal, "\n") .. "\n")
    write(base .. ".diff", compare.unified(f.minimal_result))
  end
  local total = elapsed()
  stats.time = { ours = t_ours, emacs = t_emacs, total = total }
  log(
    ("difftest: %d comparisons: %d same, %d only known differences, %d Emacs errors (%d timeouts), %d failing (%d distinct)"):format(
      stats.compared,
      stats.same,
      stats.known,
      stats.emacs_errors,
      stats.emacs_timeouts,
      #failures,
      #distinct
    )
  )
  log(
    ("difftest: org.nvim %.1fs, Emacs done at %.1fs, total %.1fs; report in %s/report.md"):format(
      t_ours,
      t_emacs,
      total,
      out
    )
  )
  if #distinct > 0 then
    log("\n" .. report)
  end
  return { failures = failures, distinct = distinct, stats = stats }
end

--- The Markdown report: settings, then each distinct failure with its
--- minimal input and diff.
function M.report(opts, failures, distinct, stats, known)
  local t = {
    ("Seeds %d..%d (%d documents), oracles: %s."):format(
      opts.seed,
      opts.seed + opts.count - 1,
      opts.count,
      table.concat(opts.oracles, " ")
    ),
    "",
    ("%d comparisons: %d same, %d with only known differences, %d where Emacs raised an error, %d failing."):format(
      stats.compared,
      stats.same,
      stats.known,
      stats.emacs_errors,
      #failures
    ),
  }
  local hits = {}
  for _, k in ipairs(known) do
    if stats.by_known[k] then
      hits[#hits + 1] = ("- %d× %s"):format(stats.by_known[k], k.reason)
    end
  end
  if #hits > 0 then
    vim.list_extend(t, { "", "Known differences seen (tests/difftest/known.lua):", "" })
    vim.list_extend(t, hits)
  end
  if #failures > 0 then
    -- the kinds of difference, most frequent first, with their seeds
    local kinds, order = {}, {}
    for _, f in ipairs(failures) do
      local k = kinds[f.signature]
      if not k then
        k = { sig = f.signature, seeds = {} }
        kinds[f.signature] = k
        order[#order + 1] = k
      end
      k.seeds[#k.seeds + 1] = f.seed
    end
    table.sort(order, function(a, b)
      if #a.seeds ~= #b.seeds then
        return #a.seeds > #b.seeds
      end
      return a.seeds[1] < b.seeds[1]
    end)
    vim.list_extend(t, { "", "Failing, by kind of difference (words only one side has, Emacs => org.nvim):", "" })
    for i, k in ipairs(order) do
      if i > 40 then
        t[#t + 1] = ("- ... and %d more kinds"):format(#order - 40)
        break
      end
      local seeds = vim.list_slice(k.seeds, 1, 8)
      t[#t + 1] = ("- %d× `%s` (seeds %s%s)"):format(
        #k.seeds,
        k.sig:gsub("`", "'"),
        table.concat(seeds, " "),
        #k.seeds > 8 and " ..." or ""
      )
    end
  end
  for i, f in ipairs(distinct) do
    vim.list_extend(t, {
      "",
      ("## %d. %s, seed %d"):format(i, f.oracle, f.seed),
      "",
      "Replay: `" .. M.replay(f.seed, f.oracle) .. "`",
      "",
      ("Minimal input (%d of %d lines):"):format(#f.minimal, #f.input),
      "",
      "```org",
    })
    vim.list_extend(t, f.minimal)
    vim.list_extend(t, { "```", "", "```diff" })
    vim.list_extend(t, vim.split(vim.trim(compare.unified(f.minimal_result)), "\n", { plain = true }))
    t[#t + 1] = "```"
  end
  return table.concat(t, "\n") .. "\n"
end

return M
