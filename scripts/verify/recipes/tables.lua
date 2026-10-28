-- Tables (feature map: .claude/skills/verify-org/features/tables.md).
local stock = {
  "* Stock",
  "| Item   | Qty | Price |",
  "|--------+-----+-------|",
  "| Apples |  12 |     2 |",
  "| Pears  |   3 |     5 |",
}

local priced = {
  "* Stock",
  "| Item   | Qty | Price | Total |",
  "|--------+-----+-------+-------|",
  "| Apples |  12 |     2 |       |",
  "| Pears  |   3 |     5 |       |",
  "#+TBLFM: $4=$2*$3",
}

return {
  {
    name = "a table typed in Insert mode realigns on Tab",
    files = { ["shop.org"] = { "* Shopping", "" } },
    open = "shop.org",
    cursor = { 2, 0 },
    steps = {
      { key = "i" },
      { type = "|Item|Qty" },
      {
        note = "Tab in the last field realigns and opens a new row",
        key = "{{org_insert.insert_tab}}",
        expect = { buffer = "^| Item | Qty |$", line = "^|%s+|%s+|$", mode = "i" },
      },
      { type = "Apples" },
      { key = "{{org_insert.insert_tab}}" },
      { type = "12" },
      { key = "{{org_insert.insert_tab}}" },
      { type = "Pears" },
      { key = "{{org_insert.insert_tab}}" },
      { type = "3" },
      { key = "<Esc>", expect = { screen = { "| Apples |  12 |", "| Pears  |   3 |" }, mode = "n" } },
      { at = "Item" },
      { key = "{{org.table_insert_hline}}", expect = { screen = "|--------+-----|" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "shop.org",
            lines = { "* Shopping", "| Item   | Qty |", "|--------+-----|", "| Apples |  12 |", "| Pears  |   3 |" },
          },
        },
      },
    },
  },
  {
    name = "a row and a column inserted at the cursor",
    files = { ["stock.org"] = stock },
    open = "stock.org",
    steps = {
      { at = "Pears", col = "3" },
      {
        note = "M-J (org-table-insert-row): a row above the cursor",
        key = "{{org.shift_meta_down}}",
        expect = { line = "^|%s+|%s+|%s+|$" },
      },
      { at = "Apples", col = "12" },
      {
        note = "M-L (org-table-insert-column): a column left of the cursor's",
        key = "{{org.shift_meta_right}}",
        expect = { screen = "| Item   |   | Qty | Price |" },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "stock.org",
            lines = {
              "* Stock",
              "| Item   |   | Qty | Price |",
              "|--------+---+-----+-------|",
              "| Apples |   |  12 |     2 |",
              "|        |   |     |       |",
              "| Pears  |   |   3 |     5 |",
            },
          },
        },
      },
    },
  },
  {
    name = "<CR> after the last | of a row starts a new line (org-return)",
    files = { ["shop.org"] = { "* Shopping", "" } },
    open = "shop.org",
    cursor = { 2, 0 },
    steps = {
      { key = "i" },
      { type = "|Item|Qty|" },
      {
        note = "at the end of the row <CR> is a plain newline, no new row",
        key = "{{org_insert.table_next_row}}",
        expect = { buffer = "^|Item|Qty|$", line = "^$", mode = "i" },
      },
      { type = "|-" },
      {
        note = "|- then Tab turns into an hline and opens the first row",
        key = "{{org_insert.insert_tab}}",
        expect = { screen = { "| Item | Qty |", "|------+-----|" }, mode = "i" },
      },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = {
            "shop.org",
            lines = { "* Shopping", "| Item | Qty |", "|------+-----|", "|      |     |" },
          },
        },
      },
    },
  },
  {
    name = "table_insert_row puts the row above, with a count below",
    files = { ["stock.org"] = stock },
    open = "stock.org",
    steps = {
      { at = "Pears", col = "3" },
      {
        note = "org-table-insert-row: a row above the cursor's",
        key = "{{org.table_insert_row}}",
        expect = { line = "^|%s+|%s+|%s+|$" },
      },
      { at = "Apples", col = "12" },
      {
        note = "with a count (C-u): a row below the cursor's",
        key = "4{{org.table_insert_row}}",
        expect = { line = "^|%s+|%s+|%s+|$" },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "stock.org",
            lines = {
              "* Stock",
              "| Item   | Qty | Price |",
              "|--------+-----+-------|",
              "| Apples |  12 |     2 |",
              "|        |     |       |",
              "|        |     |       |",
              "| Pears  |   3 |     5 |",
            },
          },
        },
      },
    },
  },
  {
    name = "a TBLFM formula fills a column and recalculates after an edit",
    files = { ["stock.org"] = priced },
    open = "stock.org",
    steps = {
      { at = "#+TBLFM" },
      {
        note = "C-c C-c on the #+TBLFM line applies it",
        key = "{{org.context_action}}",
        expect = { screen = { "| Apples |  12 |     2 |    24 |", "| Pears  |   3 |     5 |    15 |" } },
      },
      { at = "Pears", col = "3" },
      { key = "r4" },
      { key = "{{org.table_recalc}}", expect = { screen = "| Pears  |   4 |     5 |    20 |" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "stock.org",
            lines = {
              "* Stock",
              "| Item   | Qty | Price | Total |",
              "|--------+-----+-------+-------|",
              "| Apples |  12 |     2 |    24 |",
              "| Pears  |   4 |     5 |    20 |",
              "#+TBLFM: $4=$2*$3",
            },
          },
        },
      },
    },
  },
}
