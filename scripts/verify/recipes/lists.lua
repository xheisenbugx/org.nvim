-- Plain lists and checkboxes (feature map:
-- .claude/skills/verify-org/features/lists.md).
local packing = { "* Packing [/]", "- [ ] Passport", "- [ ] Tickets", "- [ ] Charger" }

return {
  {
    name = "M-CR adds an item, M-S-CR one with a checkbox",
    files = { ["packing.org"] = { "* Packing", "- [ ] Passport", "- [ ] Tickets" } },
    open = "packing.org",
    steps = {
      { at = "Passport" },
      {
        note = "org-insert-item: no checkbox, as in Emacs",
        key = "{{org.meta_return}}",
        expect = { line = "^%- $", mode = "i" },
      },
      { type = "Charger" },
      { key = "<Esc>" },
      {
        note = "org-insert-todo-heading on an item: a checkbox",
        key = "{{org.meta_shift_return}}",
        expect = { line = "^%- %[ %] $", mode = "i" },
      },
      { type = "Adapter" },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = {
            "packing.org",
            lines = { "* Packing", "- [ ] Passport", "- Charger", "- [ ] Adapter", "- [ ] Tickets" },
          },
        },
      },
    },
  },
  {
    name = "a toggled checkbox updates the [n/m] cookie",
    files = { ["packing.org"] = packing },
    open = "packing.org",
    steps = {
      { note = "an empty cookie stays empty until something updates it", expect = { screen = "* Packing [/]" } },
      { key = "{{org.update_statistics}}", expect = { screen = "* Packing [0/3]" } },
      { at = "Tickets" },
      {
        key = "{{org.toggle_checkbox}}",
        expect = { screen = { "* Packing [1/3]", "- [X] Tickets" } },
      },
      { at = "Charger" },
      {
        note = "C-c C-c on an item's first line toggles it too",
        key = "{{org.context_action}}",
        expect = { screen = { "* Packing [2/3]", "- [X] Charger" } },
      },
      { at = "Tickets" },
      { key = "{{org.toggle_checkbox}}", expect = { screen = { "* Packing [1/3]", "- [ ] Tickets" } } },
      { cmd = "write" },
      {
        expect = {
          file = { "packing.org", lines = { "* Packing [1/3]", "- [ ] Passport", "- [ ] Tickets", "- [X] Charger" } },
        },
      },
    },
  },
  {
    name = "a numbered item inserted renumbers the list; the bullet cycles",
    files = { ["steps.org"] = { "* Steps", "1. Boil water", "2. Add pasta", "3. Drain" } },
    open = "steps.org",
    steps = {
      { at = "Boil" },
      {
        key = "{{org.meta_return}}",
        expect = { line = "^2%. $", screen = { "3. Add pasta", "4. Drain" }, mode = "i" },
      },
      { type = "Salt it" },
      { key = "<Esc>" },
      {
        note = "1. -> 1) is the next style (org-cycle-list-bullet), for the whole list",
        key = "{{org.cycle_bullet}}",
        expect = { screen = { "1) Boil water", "2) Salt it", "4) Drain" } },
      },
      { cmd = "write" },
      {
        expect = {
          file = { "steps.org", lines = { "* Steps", "1) Boil water", "2) Salt it", "3) Add pasta", "4) Drain" } },
        },
      },
    },
  },
}
