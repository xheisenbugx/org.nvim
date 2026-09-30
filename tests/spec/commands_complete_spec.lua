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
end)
