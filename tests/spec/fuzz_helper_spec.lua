-- tests/helpers/fuzz.lua: the seeds the environment asks for, and the
-- shrinking of a failing input.
local fuzz = require("tests.helpers.fuzz")

describe("fuzz helper", function()
  local saved
  before_each(function()
    saved = {}
    for _, k in ipairs({ "ORG_FUZZ_SEED", "ORG_FUZZ_ITERATIONS", "ORG_FUZZ_SCALE", "ORG_FUZZ_START" }) do
      saved[k] = vim.env[k]
      vim.env[k] = nil
    end
  end)
  after_each(function()
    for k, v in pairs(saved) do
      vim.env[k] = v
    end
  end)

  it("runs the default seeds, or the ones the environment asks for", function()
    eq({ 1, 2, 3 }, fuzz.seeds(3))
    vim.env.ORG_FUZZ_SCALE = "2"
    eq({ 1, 2, 3, 4, 5, 6 }, fuzz.seeds(3))
    vim.env.ORG_FUZZ_START = "100"
    eq({ 100, 101, 102, 103, 104, 105 }, fuzz.seeds(3))
    vim.env.ORG_FUZZ_ITERATIONS = "2"
    eq({ 100, 101 }, fuzz.seeds(3))
    vim.env.ORG_FUZZ_SEED = "42"
    eq({ 42 }, fuzz.seeds(3))
  end)

  it("shrinks an input to the lines that make it fail", function()
    local lines = {}
    for i = 1, 40 do
      lines[i] = "line " .. i
    end
    lines[7], lines[31] = "#+begin_src", "#+end_src"
    local function fails(l)
      local b, e = false, false
      for _, s in ipairs(l) do
        b = b or s == "#+begin_src"
        e = e or s == "#+end_src"
      end
      return b and e
    end
    eq({ "#+begin_src", "#+end_src" }, (fuzz.shrink(lines, fails)))
    -- the kept line survives, and its new index is returned
    local small, k = fuzz.shrink(lines, fails, 20)
    eq({ "#+begin_src", "line 20", "#+end_src" }, small)
    eq(2, k)
  end)

  it("reports the seed, the replay command and the minimal input", function()
    local msg = fuzz.report(7, "boom", { "a", "b", "c" }, { "b" })
    ok(msg:find("seed 7: boom", 1, true))
    ok(msg:find("replay: ORG_FUZZ_SEED=7 make test SPEC=tests/spec/fuzz_helper_spec.lua", 1, true))
    ok(msg:find('minimal input = {\n  "b",\n}', 1, true))
  end)
end)
