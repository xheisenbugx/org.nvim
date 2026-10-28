-- Clocking time (feature map: .claude/skills/verify-org/features/clock.md).
-- The clock is Monday 2026-10-12 09:00; a `wait` step moves it on.
local tasks = { "* Project", "** TODO Write the report", "** TODO Review the slides" }

return {
  {
    name = "clock in and out writes a CLOCK line with its duration",
    files = { ["work.org"] = tasks },
    open = "work.org",
    steps = {
      { at = "Write the report" },
      { key = "{{org.clock_in}}", expect = { buffer = "^CLOCK: %[2026%-10%-12 Mon 09:00%]$" } },
      {
        note = "the driver's statusline hides org's: show it",
        cmd = "set statusline=%{v:lua.require'org'.statusline()}",
      },
      { wait = 90 },
      {
        note = "a statusline is drawn again only when Neovim redraws it",
        cmd = "redrawstatus",
        expect = { screen = "[1:30] (Write the report)" },
      },
      {
        key = "{{org.clock_out}}",
        expect = { buffer = "=>  1:30$", screen = "Clock stopped at [2026-10-12 Mon 10:30] after 1:30" },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "work.org",
            lines = {
              "* Project",
              "** TODO Write the report",
              ":LOGBOOK:",
              "CLOCK: [2026-10-12 Mon 09:00]--[2026-10-12 Mon 10:30] =>  1:30",
              ":END:",
              "** TODO Review the slides",
            },
          },
        },
      },
    },
  },
  {
    name = "clocking in elsewhere clocks the running task out",
    files = { ["work.org"] = tasks },
    open = "work.org",
    steps = {
      { at = "Write the report" },
      { key = "{{org.clock_in}}" },
      { wait = 25 },
      { at = "Review the slides" },
      { key = "{{org.clock_in}}" },
      { wait = 5 },
      { key = "{{org.clock_out}}" },
      { cmd = "write" },
      {
        expect = { file = { "work.org", "^CLOCK: %[2026%-10%-12 Mon 09:00%]%-%-%[2026%-10%-12 Mon 09:25%] =>  0:25$" } },
      },
      {
        expect = { file = { "work.org", "^CLOCK: %[2026%-10%-12 Mon 09:25%]%-%-%[2026%-10%-12 Mon 09:30%] =>  0:05$" } },
      },
    },
  },
  {
    name = "clock display shows the time next to each headline",
    files = {
      ["work.org"] = {
        "* Project",
        "** TODO Write the report",
        ":LOGBOOK:",
        "CLOCK: [2026-10-12 Mon 08:00]--[2026-10-12 Mon 08:45] =>  0:45",
        ":END:",
        "** TODO Review the slides",
        ":LOGBOOK:",
        "CLOCK: [2026-10-09 Fri 14:00]--[2026-10-09 Fri 15:30] =>  1:30",
        ":END:",
      },
    },
    open = "work.org",
    steps = {
      {
        key = "{{org.clock_display}}",
        expect = {
          screen = {
            "* Project···",
            "      2:15",
            "      0:45",
            "Total file time: 2:15 (2 hours and 15 minutes)",
          },
        },
      },
    },
  },
  {
    name = "a clock report is inserted as a clocktable block",
    files = {
      ["work.org"] = {
        "* Project",
        "** TODO Write the report",
        ":LOGBOOK:",
        "CLOCK: [2026-10-12 Mon 08:00]--[2026-10-12 Mon 08:45] =>  0:45",
        ":END:",
      },
    },
    open = "work.org",
    steps = {
      { at = "* Project" },
      { key = "{{org.clock_report}}", expect = { buffer = "^#%+BEGIN: clocktable" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "work.org",
            lines = {
              "* Project",
              "#+BEGIN: clocktable :scope subtree :maxlevel 2",
              "#+CAPTION: Clock summary at [2026-10-12 Mon 09:00]",
              "| Headline             | Time   |      |",
              "|----------------------+--------+------|",
              "| *Total time*         | *0:45* |      |",
              "|----------------------+--------+------|",
              "| Project              | 0:45   |      |",
              "| \\_  Write the report |        | 0:45 |",
              "#+END:",
              "** TODO Write the report",
              ":LOGBOOK:",
              "CLOCK: [2026-10-12 Mon 08:00]--[2026-10-12 Mon 08:45] =>  0:45",
              ":END:",
            },
          },
        },
      },
    },
  },
}
