describe(":Org completion", function()
  local commands = require("org.commands")

  after_each(function()
    commands.extra.test_complete = nil
  end)

  it("completes the arguments of an extra subcommand with its complete function", function()
    local seen
    commands.extra.test_complete = {
      fn = function() end,
      desc = "test",
      complete = function(arglead, cmdline)
        seen = { arglead, cmdline }
        return { "alpha", "beta", "almond", 3 }
      end,
    }
    eq({ "alpha", "almond" }, commands.complete("al", "Org test_complete al"))
    eq({ "al", "Org test_complete al" }, seen)
  end)

  it("returns nothing when the complete function fails or is missing", function()
    commands.extra.test_complete = {
      fn = function() end,
      complete = function()
        error("boom")
      end,
    }
    eq({}, commands.complete("", "Org test_complete "))
    commands.extra.test_complete = { fn = function() end }
    eq({}, commands.complete("", "Org test_complete "))
  end)

  it("completes subcommand names, also after a range or a modifier", function()
    local got = commands.complete("clock_go", "Org clock_go")
    ok(vim.tbl_contains(got, "clock_goto"))
    for _, n in ipairs(got) do
      eq(1, n:find("clock_go", 1, true))
    end
    eq(got, commands.complete("clock_go", "'<,'>Org clock_go"))
    eq(got, commands.complete("clock_go", "silent Org clock_go"))
    eq({ "html" }, commands.complete("ht", "silent Org export ht"))
  end)

  describe("with custom commands and templates", function()
    with_config({
      agenda = { custom_commands = { wx = { description = "Work", type = "tags", match = "+work" } } },
      capture = { templates = { t = { description = "Task", template = "* TODO %?" }, w = "Work" } },
    })

    it("filters agenda keys and capture templates by the typed prefix", function()
      eq({ "week", "wx" }, commands.complete("w", "Org agenda w"))
      eq({ "S" }, commands.complete("S", "Org agenda S"))
      eq({ "t" }, commands.complete("t", "Org capture t"))
      eq({ "t", "w" }, commands.complete("", "Org capture "))
    end)
  end)
end)
