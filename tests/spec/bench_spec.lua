-- `make bench` (scripts/bench.lua) on a tiny corpus, so that it keeps
-- working: every operation measured, every view finding entries.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

describe("make bench", function()
  it("measures every operation on a small corpus", function()
    local res = vim
      .system({
        vim.v.progpath,
        "--clean",
        "--headless",
        "-l",
        root .. "/scripts/bench.lua",
        "--runs",
        "1",
        "--files",
        "3",
        "--headlines",
        "40",
        "--json",
      }, { text = true })
      :wait(120000)
    eq(0, res.code, res.stderr)
    local lines = vim.split(vim.trim(res.stdout), "\n")
    local r = vim.json.decode(lines[#lines])
    eq(3, r.files)
    eq(120, r.headlines)
    for _, key in ipairs({
      "setup_ms",
      "open_ms",
      "cold_week",
      "warm_week",
      "hot_week",
      "tags",
      "todo",
      "refresh",
      "background_week",
    }) do
      ok(type(r.ms[key]) == "number" and r.ms[key] > 0, key .. ": " .. vim.inspect(r.ms[key]))
    end
  end)

  it("generates the same corpus every time", function()
    local gen = require("tests.helpers.gen")
    local a, b = gen.agenda_corpus(2, 30), gen.agenda_corpus(2, 30)
    eq(a, b)
    eq("project001.org", a[1].name)
    local text = table.concat(a[1].lines, "\n") .. table.concat(a[2].lines, "\n")
    ok(text:find("SCHEDULED: <", 1, true))
    ok(text:find(":STYLE: habit", 1, true) or text:find("DEADLINE: <", 1, true))
  end)
end)
