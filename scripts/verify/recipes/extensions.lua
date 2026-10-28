-- Extensions, each enabled in its scenario's `setup = { extensions = { ... } }`
-- (feature map: .claude/skills/verify-org/features/extensions.md): the
-- kanban board, the journal and presentations. The clock is Monday
-- 2026-10-12 09:00.
local board = {
  "* TODO Write the report",
  "* TODO Book the train",
  "* DONE Pay the rent",
}

return {
  {
    name = "kanban: a card moved to the next column changes its TODO keyword",
    files = { ["tasks.org"] = board },
    open = "tasks.org",
    setup = { agenda_files = { "{{dir}}/*.org" }, extensions = { kanban = { save = true } } },
    steps = {
      {
        key = "{{global.kanban_open}}",
        expect = { filetype = "orgkanban", screen = { "TODO  2", "DONE  1", "Write the report", "Pay the rent" } },
      },
      { key = "l", expect = { screen = { "TODO  1", "DONE  2" } } },
      {
        note = "save = true writes the file at once",
        expect = {
          file = { "tasks.org", lines = { "* DONE Write the report", "* TODO Book the train", "* DONE Pay the rent" } },
        },
      },
      { key = "q", expect = { filetype = "org", no_screen = "Kanban" } },
    },
  },
  {
    name = "kanban: without save a moved card changes the buffer, not the file",
    files = { ["tasks.org"] = board },
    open = "tasks.org",
    setup = { agenda_files = { "{{dir}}/*.org" }, extensions = { kanban = true } },
    steps = {
      { key = "{{global.kanban_open}}", expect = { screen = "TODO  2" } },
      { key = "l", expect = { screen = "DONE  2" } },
      { key = "q", expect = { filetype = "org", buffer = "^%* DONE Write the report$" } },
      { expect = { file = { "tasks.org", lines = board } } },
    },
  },
  {
    name = "journal: a new entry makes today's file, day and time headings",
    setup = { extensions = { journal = { directory = "{{dir}}/journal" } } },
    steps = {
      { key = "{{global.journal_new_entry}}", expect = { mode = "i", line = "^%*%* 09:00 $" } },
      { type = "Planted the bulbs" },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = { "journal/20261012.org", lines = { "* Monday, 2026-10-12", "** 09:00 Planted the bulbs" } },
        },
      },
      { wait = 90 },
      { key = "{{global.journal_new_entry}}", expect = { mode = "i", line = "^%*%* 10:30 $" } },
      { type = "Watered them" },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = {
            "journal/20261012.org",
            lines = { "* Monday, 2026-10-12", "** 09:00 Planted the bulbs", "** 10:30 Watered them" },
          },
        },
      },
    },
  },
  {
    name = "present: slides from the headlines, next and quit",
    files = {
      ["talk.org"] = {
        "#+TITLE: Gardening",
        "* Soil",
        "Dig it over.",
        "* Seeds",
        "Sow in rows.",
      },
    },
    open = "talk.org",
    setup = { extensions = { present = true } },
    steps = {
      { key = "{{org.present_start}}", expect = { screen = { "1/3", "Gardening" } } },
      { key = "n", expect = { screen = { "2/3", "Soil", "Dig it over." }, no_screen = "Sow in rows." } },
      { key = "n", expect = { screen = { "3/3", "Seeds", "Sow in rows." }, no_screen = "Dig it over." } },
      { key = "p", expect = { screen = "2/3" } },
      { key = "q", expect = { screen = { "#+TITLE: Gardening", "* Soil", "* Seeds" }, no_screen = "2/3" } },
      { note = "the cursor is back on the slide it left", expect = { line = "^%* Soil$" } },
    },
  },
}
