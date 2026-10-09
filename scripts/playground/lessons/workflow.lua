-- What the playground recording of tutor/org/workflow.org does, exercise
-- by exercise (see scripts/playground/record.lua for the step format).
return {
  { id = "intro", title = "Welcome", hold = 2.5 },
  {
    id = "1.1",
    steps = {
      { at = "Inbox" },
      { key = ":Org capture_here<CR>" },
      { key = "t" },
      { type = "Call Bob" },
      { key = "<Esc>" },
      { key = "{{capture.finalize}}" },
    },
  },
  {
    id = "2.1",
    steps = {
      { key = "{{global.agenda}}" },
      { key = "<" },
      { key = "t" },
      { at = "Call the dentist", col = "Call the dentist" },
      { key = "{{agenda.todo}}" },
      { key = "{{agenda.quit}}" },
    },
  },
  {
    id = "2.2",
    steps = {
      { at = "Water the plants" },
      { key = "{{org.schedule}}" },
      { key = "<CR>" },
      { key = "{{global.agenda}}" },
      { key = "<" },
      { key = "a" },
      { key = "{{agenda.quit}}" },
    },
  },
  {
    id = "3.1",
    steps = {
      { at = "Write the report" },
      { key = "{{org.clock_in}}" },
      { wait = 25 },
      { key = "{{org.clock_out}}" },
      { at = ":LOGBOOK:" },
      { key = "{{org.cycle}}" },
    },
  },
  {
    id = "3.2",
    steps = {
      { at = "Time spent" },
      { key = "{{org.clock_report}}" },
      -- zv: the child Neovim can show the new block folded (stale folds)
      { at = "#+BEGIN: clocktable", col = "subtree" },
      { key = "zv" },
      { key = "ciw" },
      { type = "file" },
      { key = "<Esc>" },
      { key = "{{org.context_action}}" },
    },
  },
}
