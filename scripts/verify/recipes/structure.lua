-- Outline editing (feature map:
-- .claude/skills/verify-org/features/structure.md). The clock is Monday
-- 2026-10-12 09:00.
local house = {
  "* Chores",
  "** Laundry",
  "Whites first.",
  "** Dishes",
  "Run the dishwasher.",
  "* Errands",
}

local projects = {
  "* Projects",
  "** Garden",
  "*** Plant tulips",
  "SCHEDULED: <2026-10-12 Mon>",
  "*** Fix the gate",
  "** Kitchen",
}

return {
  {
    name = "M-CR adds a heading below, insert_todo_heading and insert_subheading",
    files = { ["house.org"] = house },
    open = "house.org",
    steps = {
      { at = "Laundry" },
      {
        note = "Normal mode: the new heading goes right below the headline line, at its level",
        key = "{{org.meta_return}}",
        expect = { line = "^%*%* $", mode = "i" },
      },
      { type = "Ironing" },
      { key = "<Esc>" },
      { at = "Dishes" },
      {
        note = "after the subtree, not below the headline line (org-insert-todo-heading-respect-content)",
        key = "{{org.insert_todo_heading}}",
        expect = { line = "^%*%* TODO $", mode = "i" },
      },
      { type = "Buy soap" },
      { key = "<Esc>" },
      { at = "Errands" },
      { key = "{{org.insert_subheading}}", expect = { line = "^%*%* $", mode = "i" } },
      { type = "Post office" },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = {
            "house.org",
            lines = {
              "* Chores",
              "** Laundry",
              "** Ironing",
              "Whites first.",
              "** Dishes",
              "Run the dishwasher.",
              "** TODO Buy soap",
              "* Errands",
              "** Post office",
            },
          },
        },
      },
    },
  },
  {
    name = "promote and demote a heading, then the whole subtree",
    files = { ["projects.org"] = projects },
    open = "projects.org",
    steps = {
      { at = "Garden" },
      {
        note = ">> moves the headline alone: its children keep their level",
        key = "{{org.demote_heading}}",
        expect = { line = "^%*%*%* Garden$", screen = { "*** Plant tulips", "*** Fix the gate" } },
      },
      { key = "{{org.promote_heading}}", expect = { line = "^%*%* Garden$" } },
      {
        key = "{{org.demote_subtree}}",
        expect = { line = "^%*%*%* Garden$", screen = { "**** Plant tulips", "**** Fix the gate", "** Kitchen" } },
      },
      { at = "Kitchen" },
      {
        note = "M-l demotes the headline too (org-metaright)",
        key = "{{org.meta_right}}",
        expect = { line = "^%*%*%* Kitchen$" },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "projects.org",
            lines = {
              "* Projects",
              "*** Garden",
              "**** Plant tulips",
              "SCHEDULED: <2026-10-12 Mon>",
              "**** Fix the gate",
              "*** Kitchen",
            },
          },
        },
      },
    },
  },
  {
    name = "move a subtree down past its sibling and back up",
    files = { ["projects.org"] = projects },
    open = "projects.org",
    steps = {
      { at = "Garden" },
      {
        key = "{{org.meta_down}}",
        expect = {
          line = "^%*%* Garden$",
          lua = [[
            local want = { "* Projects", "** Kitchen", "** Garden", "*** Plant tulips",
              "SCHEDULED: <2026-10-12 Mon>", "*** Fix the gate" }
            return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), want)
          ]],
        },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "projects.org",
            lines = {
              "* Projects",
              "** Kitchen",
              "** Garden",
              "*** Plant tulips",
              "SCHEDULED: <2026-10-12 Mon>",
              "*** Fix the gate",
            },
          },
        },
      },
      { at = "Plant tulips" },
      {
        note = "the first child can't move up: a warning, nothing changes",
        key = "{{org.move_subtree_up}}",
        expect = { screen = "Cannot move past superior level or buffer limit", line = "^%*%*%* Plant tulips$" },
      },
      { at = "Garden" },
      { key = "{{org.move_subtree_up}}", expect = { buffer = "^%*%* Garden$" } },
      { cmd = "write" },
      { expect = { file = { "projects.org", lines = projects } } },
    },
  },
  {
    name = "cut a subtree and paste it before another heading at that level",
    files = { ["projects.org"] = projects },
    open = "projects.org",
    steps = {
      { at = "Plant tulips" },
      {
        key = "{{org.cut_subtree}}",
        expect = { no_screen = "*** Plant tulips", screen = "Cut: Subtree(s) with" },
      },
      { at = "** Kitchen" },
      {
        note = "in column 0 of a headline: pasted before it, at its level",
        key = "{{org.paste_subtree}}",
        expect = { screen = "Clipboard pasted as level 2 subtree", line = "^%*%* Plant tulips$" },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "projects.org",
            lines = {
              "* Projects",
              "** Garden",
              "*** Fix the gate",
              "** Plant tulips",
              "SCHEDULED: <2026-10-12 Mon>",
              "** Kitchen",
            },
          },
        },
      },
    },
  },
  {
    name = "clone a subtree with a date shift",
    files = { ["projects.org"] = projects },
    open = "projects.org",
    steps = {
      { at = "Plant tulips" },
      { key = "{{org.clone_subtree}}", expect = { screen = "Number of clones to produce:" } },
      { type = "2" },
      { key = "<CR>", expect = { screen = "Date shift per clone" } },
      { type = "+1w" },
      { key = "<CR>", expect = { mode = "n" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "projects.org",
            lines = {
              "* Projects",
              "** Garden",
              "*** Plant tulips",
              "SCHEDULED: <2026-10-12 Mon>",
              "*** Plant tulips",
              "SCHEDULED: <2026-10-19 Mon>",
              "*** Plant tulips",
              "SCHEDULED: <2026-10-26 Mon>",
              "*** Fix the gate",
              "** Kitchen",
            },
          },
        },
      },
    },
  },
  {
    name = "sort the children of a heading alphabetically and in reverse",
    files = { ["shopping.org"] = { "* Shopping", "** pears", "** Apples", "** bananas", "* Notes" } },
    open = "shopping.org",
    steps = {
      { at = "Shopping" },
      { key = "{{org.sort}}", expect = { screen = { "alphabetically", "by TODO order" } } },
      {
        note = "case-insensitive without a count",
        key = "a",
        expect = {
          lua = [[
            return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false),
              { "* Shopping", "** Apples", "** bananas", "** pears", "* Notes" })
          ]],
        },
      },
      { key = "{{org.sort}}", expect = { screen = "alphabetically (reverse)" } },
      { key = "A" },
      { cmd = "write" },
      {
        expect = {
          file = { "shopping.org", lines = { "* Shopping", "** pears", "** bananas", "** Apples", "* Notes" } },
        },
      },
    },
  },
  {
    name = "narrow to a subtree, edit it, and write it back",
    files = { ["projects.org"] = projects },
    open = "projects.org",
    steps = {
      { at = "Garden" },
      {
        key = "{{org.narrow_subtree}}",
        expect = { lua = [[return vim.api.nvim_win_get_config(0).relative ~= ""]], screen = "narrow Garden" },
      },
      { at = "Fix the gate" },
      { key = "{{org.meta_return}}", expect = { line = "^%*%*%* $" } },
      { type = "Rake leaves" },
      { key = "<Esc>" },
      { key = "{{edit_src.save_exit}}", expect = { screen = { "*** Rake leaves", "** Kitchen" } } },
      { expect = { lua = [[return vim.api.nvim_win_get_config(0).relative == ""]] } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "projects.org",
            lines = {
              "* Projects",
              "** Garden",
              "*** Plant tulips",
              "SCHEDULED: <2026-10-12 Mon>",
              "*** Fix the gate",
              "*** Rake leaves",
              "** Kitchen",
            },
          },
        },
      },
    },
  },
  {
    name = "heading motions",
    files = { ["projects.org"] = projects },
    open = "projects.org",
    steps = {
      { at = "Plant tulips" },
      { key = "{{org.next_heading}}", expect = { line = "^%*%*%* Fix the gate$" } },
      { key = "{{org.goto_parent}}", expect = { line = "^%*%* Garden$" } },
      { key = "{{org.next_sibling}}", expect = { line = "^%*%* Kitchen$" } },
      { key = "{{org.prev_sibling}}", expect = { line = "^%*%* Garden$" } },
      { key = "{{org.prev_heading}}", expect = { line = "^%* Projects$" } },
      { note = "motions don't change the buffer", expect = { lua = [[return not vim.bo.modified]] } },
    },
  },
}
