-- Visibility cycling and folds (feature map:
-- .claude/skills/verify-org/features/folding.md).
local outline = {
  "* Projects",
  "** Garden",
  "Plant the bulbs.",
  "** Kitchen",
  "Fix the tap.",
  "* Errands",
  "Post office.",
}

return {
  {
    name = "Tab cycles a subtree: folded, children, subtree",
    files = { ["outline.org"] = outline },
    open = "outline.org",
    setup = { startup_folded = "overview" },
    steps = {
      { expect = { screen = { "* Projects", "* Errands" }, no_screen = "** Garden" } },
      { key = "{{org.cycle}}", expect = { screen = { "** Garden", "** Kitchen" }, no_screen = "Plant the bulbs." } },
      {
        key = "{{org.cycle}}",
        expect = { screen = { "Plant the bulbs.", "Fix the tap." }, no_screen = "Post office." },
      },
      { key = "{{org.cycle}}", expect = { no_screen = "** Garden" } },
    },
  },
  {
    name = "S-Tab cycles the whole buffer: overview, contents, show all",
    files = { ["outline.org"] = outline },
    open = "outline.org",
    setup = { startup_folded = "showeverything" },
    steps = {
      { expect = { screen = { "Plant the bulbs.", "Post office." } } },
      { key = "{{org.global_cycle}}", expect = { screen = "* Errands", no_screen = { "** Garden", "Post office." } } },
      {
        key = "{{org.global_cycle}}",
        expect = { screen = { "** Garden", "** Kitchen" }, no_screen = "Plant the bulbs." },
      },
      { key = "{{org.global_cycle}}", expect = { screen = { "Plant the bulbs.", "Post office." } } },
    },
  },
  {
    name = "a heading inserted in a folded tree folds with it",
    files = { ["outline.org"] = outline },
    open = "outline.org",
    setup = { startup_folded = "overview" },
    steps = {
      { at = "* Errands" },
      { key = "{{org.insert_heading}}", expect = { mode = "i", line = "^%* $" } },
      { type = "Chores" },
      { key = "<Esc>", expect = { screen = { "* Projects", "* Errands", "* Chores" }, no_screen = "** Garden" } },
    },
  },
}
