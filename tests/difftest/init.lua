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
---@field out string output directory (emptied first; one that isn't empty must hold the M.MARKER file of an earlier run)
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
---@field unshrunk? boolean not shrunk (past opts.minimise): minimal is the input

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

--- The file that marks a directory as difftest's output: only such a
--- directory (or an empty one) is emptied by a run.
M.MARKER = ".difftest-out"

--- Empty `out` for a run, refusing a directory with other contents.
local function prepare_out(out)
  local st = vim.uv.fs_stat(out)
  if st then
    if st.type ~= "directory" then
      error(("difftest: %s is not a directory"):format(out), 0)
    end
    if #vim.fn.readdir(out) > 0 and not vim.uv.fs_stat(out .. "/" .. M.MARKER) then
      error(
        ("difftest: %s is not empty and has no %s file (from an earlier run): not emptying it"):format(out, M.MARKER),
        0
      )
    end
    if vim.fn.delete(out, "rf") ~= 0 then
      error(("difftest: cannot empty %s"):format(out), 0)
    end
  end
  write(out .. "/" .. M.MARKER, "")
end

--- Why the Emacs side looks broken rather than the documents odd (nil
--- when it doesn't): more than a tenth of the comparisons (and more than
--- two) got an Emacs error or timeout, or every comparison (three or more)
--- of an oracle did.
---@param stats table
---@param oracles string[]
---@return string?
function M.infrastructure(stats, oracles)
  if stats.emacs_errors > 2 and stats.emacs_errors > stats.compared / 10 then
    return ("Emacs raised an error or timed out on %d of %d comparisons"):format(stats.emacs_errors, stats.compared)
  end
  for _, o in ipairs(oracles) do
    local n = stats.by_oracle[o]
    if n and n.compared >= 3 and n.errors == n.compared then
      return ("Emacs raised an error or timed out on every %s comparison (%d)"):format(o, n.compared)
    end
  end
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
  prepare_out(out)
  local work = out .. "/work"
  local t0 = vim.uv.hrtime()
  local sec, usec = vim.uv.gettimeofday()
  local t0_wall = sec + usec / 1e6
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
  -- when Emacs wrote its last output (it may have finished before
  -- org.nvim did)
  local t_emacs = 0
  for _, c in ipairs(cases) do
    for _, o in ipairs(opts.oracles) do
      local st = vim.uv.fs_stat(("%s/emacs/d%d.%s"):format(work, c.seed, o))
      if st then
        t_emacs = math.max(t_emacs, st.mtime.sec + st.mtime.nsec / 1e9 - t0_wall)
      end
    end
  end

  -- 3. compare
  ---@type difftest.Failure[]
  local failures = {}
  local stats =
    { compared = 0, same = 0, known = 0, emacs_errors = 0, emacs_partial = 0, by_known = {}, by_oracle = {} }
  for _, c in ipairs(cases) do
    for _, o in ipairs(opts.oracles) do
      local emacs = read(("%s/emacs/d%d.%s"):format(work, c.seed, o)) or "!error no output from Emacs\n"
      local res = compare.compare(o, emacs, c.ours[o], { dir = c.dir, known = known, input = c.lines })
      stats.compared = stats.compared + 1
      local by = stats.by_oracle[o] or { compared = 0, errors = 0 }
      stats.by_oracle[o] = by
      by.compared = by.compared + 1
      if res.emacs_error or #res.skipped > 0 then
        stats.emacs_errors = stats.emacs_errors + 1
        by.errors = by.errors + 1
        if not res.emacs_error then
          stats.emacs_partial = stats.emacs_partial + 1
        end
      end
      if res.emacs_error then
        -- nothing compared
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

  stats.infra = M.infrastructure(stats, opts.oracles)

  -- 4. shrink one failure per signature (up to opts.minimise of them; not
  -- when the Emacs side is broken); the others keep their whole input
  local nmin, attempt = 0, 0
  local seen = {}
  local fatal -- the Emacs workers failed: stop shrinking
  for _, f in ipairs(failures) do
    if not seen[f.signature] and (nmin >= (opts.minimise or 20) or stats.infra) then
      seen[f.signature] = true
      f.minimal, f.minimal_result, f.unshrunk = f.input, f.result, true
    elseif not seen[f.signature] then
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
    ("difftest: %d comparisons: %d same, %d only known differences, %d Emacs errors (%d in some sections only, %d timeouts), %d failing (%d distinct)"):format(
      stats.compared,
      stats.same,
      stats.known,
      stats.emacs_errors,
      stats.emacs_partial,
      stats.emacs_timeouts,
      #failures,
      #distinct
    )
  )
  if stats.infra then
    log(("difftest: infrastructure failure: %s; Emacs' outputs are in %s/emacs/"):format(stats.infra, work))
  end
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
  return { failures = failures, distinct = distinct, stats = stats, infra = stats.infra }
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
    ("%d comparisons: %d same, %d with only known differences, %d where Emacs raised an error or timed out (%d of them in some agenda views, S-TAB steps or tables only, compared without those), %d failing."):format(
      stats.compared,
      stats.same,
      stats.known,
      stats.emacs_errors,
      stats.emacs_partial or 0,
      #failures
    ),
  }
  if stats.infra then
    vim.list_extend(t, { "", "**Infrastructure failure**: " .. stats.infra .. ". The results can't be trusted." })
  end
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
      f.unshrunk and ("Input (not shrunk, %d lines):"):format(#f.input)
        or ("Minimal input (%d of %d lines):"):format(#f.minimal, #f.input),
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
