-- Refile and archive (feature map: .claude/skills/verify-org/features/refile.md).
-- The clock is Monday 2026-10-12 09:00. The target picker is Neovim's
-- default vim.ui.select: a numbered list, answered with a number and <CR>.
local tasks = {
  "* Inbox",
  "** TODO Call the plumber",
  "Ask about the tap.",
  "* Home",
  "** TODO Paint the fence",
  "* Work",
}

return {
  {
    name = "refile a subtree under another heading of the same file",
    files = { ["tasks.org"] = tasks },
    open = "tasks.org",
    steps = {
      { at = "Call the plumber" },
      { key = "{{org.refile}}", expect = { screen = { "1: Inbox", "2: Home", "3: Work" } } },
      { type = "2" },
      { key = "<CR>", expect = { mode = "n" } },
      {
        expect = {
          buffer = "^%* Inbox$",
          lua = [[
            local want = { "* Inbox", "* Home", "** TODO Paint the fence", "** TODO Call the plumber",
              "Ask about the tap.", "* Work" }
            return vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), want)
          ]],
        },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "tasks.org",
            lines = {
              "* Inbox",
              "* Home",
              "** TODO Paint the fence",
              "** TODO Call the plumber",
              "Ask about the tap.",
              "* Work",
            },
          },
        },
      },
    },
  },
  {
    name = "refile to a heading in another file saves that file",
    files = {
      ["tasks.org"] = tasks,
      ["projects.org"] = { "* Garden", "* Kitchen" },
    },
    open = "tasks.org",
    setup = { refile = { targets = { { files = "{{dir}}/projects.org", max_level = 1 } } } },
    steps = {
      { at = "Call the plumber" },
      {
        key = "{{org.refile}}",
        expect = { screen = { "1: Garden (projects.org)", "2: Kitchen (projects.org)" } },
      },
      { type = "2" },
      { key = "<CR>", expect = { no_screen = "** TODO Call the plumber" } },
      {
        expect = {
          file = {
            "projects.org",
            lines = { "* Garden", "* Kitchen", "** TODO Call the plumber", "Ask about the tap." },
          },
        },
      },
      { note = "the source buffer is changed but not saved", expect = { file = { "tasks.org", "Call the plumber" } } },
      { cmd = "write" },
      {
        expect = {
          file = { "tasks.org", lines = { "* Inbox", "* Home", "** TODO Paint the fence", "* Work" } },
        },
      },
    },
  },
  {
    name = "a cancelled refile changes nothing",
    files = { ["tasks.org"] = tasks },
    open = "tasks.org",
    steps = {
      { at = "Call the plumber" },
      { key = "{{org.refile}}", expect = { screen = "Type number and <Enter>" } },
      { key = "<CR>", expect = { mode = "n", screen = "** TODO Call the plumber" } },
      { expect = { lua = [[return not vim.bo.modified]] } },
    },
  },
  {
    name = "archive a subtree to the archive file with its context",
    files = { ["tasks.org"] = tasks },
    open = "tasks.org",
    steps = {
      { at = "Call the plumber" },
      {
        key = "{{org.archive_subtree}}",
        expect = { no_screen = "** TODO Call the plumber", screen = "archived in" },
      },
      {
        note = "the archive file is saved; its header and ARCHIVE_FILE name the source by its full path",
        expect = {
          lua = [[
            local dir = ...
            local got = vim.fn.readfile(dir .. "/tasks.org_archive")
            local want = { "^#    %-%*%- mode: org %-%*%-$", "^$", "^$", "^Archived entries from file .*tasks%.org$",
              "^$", "^$", "^%* TODO Call the plumber$", "^:PROPERTIES:$", "^:ARCHIVE_TIME: 2026%-10%-12 Mon 09:00$",
              "^:ARCHIVE_FILE: .*tasks%.org$", "^:ARCHIVE_OLPATH: Inbox$", "^:ARCHIVE_CATEGORY: tasks$",
              "^:ARCHIVE_TODO: TODO$", "^:END:$", "^Ask about the tap%.$" }
            if #got ~= #want then
              return false
            end
            for i, pat in ipairs(want) do
              if not got[i]:find(pat) then
                return false
              end
            end
            return true
          ]],
        },
      },
      { note = "the source is changed, not saved", expect = { file = { "tasks.org", "Call the plumber" } } },
      { cmd = "write" },
      {
        expect = {
          file = { "tasks.org", lines = { "* Inbox", "* Home", "** TODO Paint the fence", "* Work" } },
        },
      },
    },
  },
  {
    name = "the archive tag folds a subtree and keeps it folded",
    files = { ["tasks.org"] = tasks },
    open = "tasks.org",
    steps = {
      { at = "Call the plumber" },
      { key = "{{org.toggle_archive_tag}}", expect = { line = "^%*%* TODO Call the plumber%s+:ARCHIVE:$" } },
      { expect = { no_screen = "Ask about the tap." } },
      {
        key = "{{org.cycle}}",
        expect = { no_screen = "Ask about the tap.", screen = "Subtree is archived and stays closed." },
      },
      { key = "{{emacs.force_cycle_archived}}", expect = { screen = "Ask about the tap." } },
      { key = "{{org.toggle_archive_tag}}", expect = { line = "^%*%* TODO Call the plumber$" } },
    },
  },
  {
    name = "refile_copy files a copy and keeps the original",
    files = { ["tasks.org"] = tasks },
    open = "tasks.org",
    steps = {
      { at = "Call the plumber" },
      { key = "{{org.refile_copy}}", expect = { screen = "3: Work" } },
      { type = "3" },
      { key = "<CR>", expect = { mode = "n" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "tasks.org",
            lines = {
              "* Inbox",
              "** TODO Call the plumber",
              "Ask about the tap.",
              "* Home",
              "** TODO Paint the fence",
              "* Work",
              "** TODO Call the plumber",
              "Ask about the tap.",
            },
          },
        },
      },
    },
  },
  {
    name = "archive to the Archive sibling",
    files = { ["tasks.org"] = tasks },
    open = "tasks.org",
    steps = {
      { at = "Call the plumber" },
      { key = "{{emacs.archive_to_sibling}}" },
      { cmd = "write" },
      {
        expect = {
          lua = [[
            local got = vim.fn.readfile((...) .. "/tasks.org")
            local want = { "^%* Inbox$", "^%*%* Archive%s+:ARCHIVE:$", "^%*%*%* TODO Call the plumber$",
              "^:PROPERTIES:$", "^:ARCHIVE_TIME: 2026%-10%-12 Mon 09:00$" }
            for i, pat in ipairs(want) do
              if not (got[i] or ""):find(pat) then
                return false
              end
            end
            return true
          ]],
        },
      },
    },
  },
}
