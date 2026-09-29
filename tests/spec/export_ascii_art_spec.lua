-- org-ascii-table-use-ascii-art: table.el tables drawn with box characters
-- (ascii-art-to-unicode). The expected drawing comes from aa2u 1.13 (GNU
-- ELPA) run in Emacs on the same table; Org 9.8.10 itself never calls it
-- (see :h org-differences).
local export = require("org.export")
local config = require("org.config")

local TABLE = { "+-----+----+", "| a-b | c  |", "+=====+====+", "| 1   | 2  |", "+-----+----+" }

describe("ascii table art", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
  end)
  after_each(function()
    config.opts.export.ascii.table_use_ascii_art = false
    config.opts.babel.evaluate_on_export = true
  end)

  it("converts like aa2u", function()
    local lines = vim.list_extend(vim.deepcopy(TABLE), { "+" })
    eq({
      "┌─────┬────┐",
      "│ a─b │ c  │",
      "│=====│====│",
      "│ 1   │ 2  │",
      "├─────┴────┘",
      "╵",
    }, require("org.export.ascii").aa2u(lines))
  end)

  it("draws table.el tables in UTF-8 exports only", function()
    config.opts.export.ascii.table_use_ascii_art = true
    eq(
      "┌─────┬────┐\n│ a─b │ c  │\n│=====│====│\n│ 1   │ 2  │\n└─────┴────┘\n",
      export.to_string("utf8", { lines = TABLE, body_only = true })
    )
    eq(table.concat(TABLE, "\n") .. "\n", export.to_string("ascii", { lines = TABLE, body_only = true }))
    config.opts.export.ascii.table_use_ascii_art = false
    eq(table.concat(TABLE, "\n") .. "\n", export.to_string("utf8", { lines = TABLE, body_only = true }))
  end)
end)
