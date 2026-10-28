-- Column view (feature map: .claude/skills/verify-org/features/columns.md).
local garden = {
  "* Garden",
  "  :PROPERTIES:",
  "  :COLUMNS:  %25ITEM %TODO %Effort{:}",
  "  :Effort_ALL: 0:30 1:00 2:00",
  "  :END:",
  "** TODO Plant the bulbs",
  "   :PROPERTIES:",
  "   :Effort:   1:00",
  "   :END:",
  "** TODO Mow the lawn",
  "   :PROPERTIES:",
  "   :Effort:   0:30",
  "   :END:",
}

return {
  {
    name = "column view draws the COLUMNS format over the headlines",
    files = { ["garden.org"] = garden },
    open = "garden.org",
    steps = {
      {
        key = "{{org.column_view}}",
        expect = {
          screen = {
            "ITEM                      | TODO | Effort |",
            "* Garden                  |      | 1:30   |",
            "** Plant the bulbs        | TODO | 1:00   |",
            "** Mow the lawn           | TODO | 0:30   |",
          },
        },
      },
      {
        note = "q restores the headlines",
        key = "q",
        expect = { screen = "** TODO Mow the lawn", no_screen = "| TODO |" },
      },
    },
  },
  {
    name = "n on a column takes the next allowed value and updates the summary",
    files = { ["garden.org"] = garden },
    open = "garden.org",
    steps = {
      { key = "{{org.column_view}}" },
      { at = "Mow the lawn" },
      { note = "$ goes to the last column (Effort)", key = "$" },
      {
        key = "n",
        expect = {
          screen = { "** Mow the lawn           | TODO | 1:00   |", "* Garden                  |      | 2:00   |" },
        },
      },
      { key = "q" },
      { cmd = "write" },
      { expect = { file = { "garden.org", "^%s+:Effort:%s+1:00$" } } },
      {
        expect = {
          file = {
            "garden.org",
            lines = {
              "* Garden",
              "  :PROPERTIES:",
              "  :COLUMNS:  %25ITEM %TODO %Effort{:}",
              "  :Effort_ALL: 0:30 1:00 2:00",
              "  :END:",
              "** TODO Plant the bulbs",
              "   :PROPERTIES:",
              "   :Effort:   1:00",
              "   :END:",
              "** TODO Mow the lawn",
              "   :PROPERTIES:",
              "   :Effort:   1:00",
              "   :END:",
            },
          },
        },
      },
    },
  },
  {
    name = "e picks a value from the allowed ones",
    files = { ["garden.org"] = garden },
    open = "garden.org",
    steps = {
      { key = "{{org.column_view}}" },
      { at = "Plant the bulbs" },
      { key = "$" },
      {
        note = "with Effort_ALL, e lists the allowed values (an inputlist)",
        key = "e",
        expect = { screen = { "Effort value", "1: 0:30", "3: 2:00", "Type number and <Enter>" } },
      },
      { key = "3<CR>" },
      {
        expect = {
          screen = { "** Plant the bulbs        | TODO | 2:00   |", "* Garden                  |      | 2:30   |" },
        },
      },
      { key = "q" },
      { cmd = "write" },
      { expect = { file = { "garden.org", "^   :Effort:   2:00$" } } },
    },
  },
  {
    name = "the TODO column cycles the keyword; headlines are read-only",
    files = { ["garden.org"] = garden },
    open = "garden.org",
    steps = {
      { key = "{{org.column_view}}" },
      { at = "Plant the bulbs" },
      { note = "l goes to the next column (TODO)", key = "l" },
      { key = "n", expect = { screen = "** Plant the bulbs        | DONE | 1:00   |" } },
      {
        note = "a key that edits text is refused on a column row",
        key = "x",
        expect = { screen = { "Text is read-only: Type ‘e’ to edit property", "| DONE | 1:00   |" } },
      },
      { key = "q", expect = { screen = "** DONE Plant the bulbs" } },
      { cmd = "write" },
      { expect = { file = { "garden.org", "^%*%* DONE Plant the bulbs$" } } },
      { expect = { file = { "garden.org", "^%*%* TODO Mow the lawn$" } } },
    },
  },
}
