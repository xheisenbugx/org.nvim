-- Fuzz: the structural merge (org.extensions.merge) of random Org text.
-- When only one side changed, the result is that side, without conflicts;
-- a merge of three different versions raises no error. A few fixed seeds
-- by default; see tests/helpers/fuzz.lua for ORG_FUZZ_ITERATIONS /
-- ORG_FUZZ_SEED.
local fuzz = require("tests.helpers.fuzz")
local merge = require("org.extensions.merge.merge")

local SEEDS = fuzz.seeds(60)

describe("fuzz merge", function()
  it("keeps one-sided changes and raises no error", function()
    local failures = {}
    local function fail(seed, what, sides, res)
      local t = { ("seed %d: %s"):format(seed, what) }
      for _, s in ipairs(sides) do
        t[#t + 1] = s[1] .. " = " .. fuzz.dump(s[2])
      end
      if res then
        t[#t + 1] = ("got (%d conflicts) = %s"):format(res.conflicts, fuzz.dump(res.lines))
      end
      failures[#failures + 1] = table.concat(t, "\n")
    end
    local function expect(seed, what, b, o, t, want)
      local okm, res = pcall(merge.merge, b, o, t)
      local sides = { { "base", b }, { "ours", o }, { "theirs", t } }
      if not okm then
        fail(seed, what .. ": " .. tostring(res), sides)
      elseif res.conflicts ~= 0 or not vim.deep_equal(res.lines, want) then
        fail(seed, what, sides, res)
      end
    end
    for _, seed in ipairs(SEEDS) do
      local rng = fuzz.rng(seed)
      -- CRLF and a BOM only for the identity merge: an edit in another
      -- style would change the style of the result
      local x = fuzz.doc(rng)
      expect(seed, "merge(x, x, x) == x", x, x, x, x)
      local base = fuzz.doc(rng, { crlf = false })
      local ours = fuzz.mutate(rng, base)
      local theirs = fuzz.mutate(rng, base)
      expect(seed, "merge(base, base, theirs) == theirs", base, base, theirs, theirs)
      expect(seed, "merge(base, ours, base) == ours", base, ours, base, ours)
      expect(seed, "merge(base, ours, ours) == ours", base, ours, ours, ours)
      local okm, res = pcall(merge.merge, base, ours, theirs)
      if not okm then
        fail(
          seed,
          "merge(base, ours, theirs): " .. tostring(res),
          { { "base", base }, { "ours", ours }, { "theirs", theirs } }
        )
      end
    end
    if #failures > 0 then
      error(("%d failures\n%s"):format(#failures, table.concat(failures, "\n\n", 1, math.min(#failures, 5))))
    end
  end)
end)
